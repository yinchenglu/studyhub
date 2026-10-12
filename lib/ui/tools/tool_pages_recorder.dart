import 'dart:async';
import 'dart:io';
// 和 tool_pages_v15 / compass 一样：material.dart 不保证导出 dart:ui 的
// FontFeature，要用就得自己 show 出来（计时器需要等宽数字，不然秒数会左右跳）。
import 'dart:ui' show FontFeature;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
// media_kit 的 Player / Media。项目里本来就有这个内核（播放器、翻译发音、
// 番茄时钟铃声都在用），录完的音视频直接在页面里回放，不另引音频包。
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../core/recorder.dart';
import '../../core/utils.dart';
import 'tool_pages.dart';

/// 后台录音录像
///
/// 用户第 1 条第 ① 项：「后台录音录像工具，类似 Alibi，可以参考他的源码。」
///
/// ── 为什么分成「真后台的录音」和「只能前台录的录像」两件事 ──────
/// Alibi 是那种「放兜里一直在录」的工具。它在老 Android 上能做到音视频一起录，
/// 但现在的 Android 不允许了：
///
///   * **录音**可以真后台 —— 申请一个前台服务（`foregroundServiceType="microphone"`，
///     Android 14 起是硬要求），挂上常驻通知，息屏、切到别的 App、清空最近任务
///     都还在录。这部分在原生 `RecorderService` 里做（见 MainActivity.kt）。
///
///   * **录像**做不到后台上。Android 9 起就**禁止后台应用访问摄像头**，
///     前台服务的 `camera` 类型也只能在前台用（一退到后台系统就掐画面）。
///     硬做只能靠一个常驻的悬浮窗 hack，代价是用户得一直看着那个窗。
///     所以这里的录像就是**老老实实的前台录像**（屏幕亮着、App 在前台），
///     音频一起录进去。页面上写得明明白白，不骗用户。
///
/// ── 文件存在哪儿 ────────────────────────────────────────
/// 应用私有目录 `文档/recordings/`，文件名 `录音_20261012_153000.m4a` /
/// `录像_20261012_153000.mp4`。这个位置**不需要任何存储权限**，
/// 服务启动时不用先弹权限框（少一步就少一处「点开始没反应」）。
/// 要拿出来有两条路：共享给别人，或者导出到手机的「下载」目录。
class AudioRecorderPage extends StatefulWidget {
  const AudioRecorderPage({super.key});

  @override
  State<AudioRecorderPage> createState() => _AudioRecorderPageState();
}

/// 两种模式。录音走原生服务，录像走 camera 插件 —— 完全不同的两条路。
enum _Mode { audio, video }

class _AudioRecorderPageState extends State<AudioRecorderPage> {
  _Mode _mode = _Mode.audio;

  // ---------------- 录音 ----------------
  RecorderStatus _st = const RecorderStatus();
  Timer? _tick;
  File? _pending; // 刚刚开始录的那个文件（用来在界面上显示文件名）
  bool _audioBusy = false;
  String? _audioErr;

  // ---------------- 录像 ----------------
  CameraController? _cam;
  bool _camInit = false;
  bool _recording = false;
  bool _videoBusy = false;
  String? _videoErr;

  // ---------------- 文件列表 ----------------
  List<File> _files = const <File>[];

  // ---------------- 回放 ----------------
  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  File? _playing;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _reloadFiles();
    // 每秒问一次原生服务。为什么不用 Dart 自己数秒：
    // App 在后台时 Flutter 引擎会被冻结，Dart 的 Timer 跟着停；
    // 而原生服务在跑前台通知，时间一直在走。以原生为准才不会「用户切回来
    // 发现计时少了 40 秒」。
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    final c = _cam;
    _cam = null;
    c?.dispose();
    keepScreenOn(false);
    super.dispose();
  }

  // ==================================================== 状态与文件

  Future<void> _refreshStatus() async {
    final s = await AudioRecorder.status();
    if (!mounted) return;
    // 只在值真变了的时候 setState：每秒无脑重画整个页面没必要
    final changed = s.running != _st.running ||
        s.elapsedMs != _st.elapsedMs ||
        s.error != _st.error;
    if (changed) {
      setState(() => _st = s);
      // 从「在录」变成「不在录」——那段文件已经落盘了，刷新列表
      if (_st.running == false && _pending != null) {
        _pending = null;
        _reloadFiles();
      }
    }
  }

  Future<void> _reloadFiles() async {
    final fs = await AudioRecorder.listAll();
    if (!mounted) return;
    setState(() => _files = fs);
  }

  // ==================================================== 录音

  Future<void> _startAudio() async {
    setState(() {
      _audioBusy = true;
      _audioErr = null;
    });
    try {
      final ps = await Permission.microphone.request();
      if (!ps.isGranted) {
        if (mounted) setState(() => _audioErr = '没有麦克风权限，录不了音。去系统设置里允许「录音」。');
        return;
      }
      final f = await AudioRecorder.nextFile(prefix: '录音', ext: '.m4a');
      await AudioRecorder.start(f);
      if (mounted) setState(() => _pending = f);
      // 服务是异步起来的，给它一点时间再把状态拉回来
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refreshStatus();
      if (mounted && !_st.running && !_st.hasError) {
        setState(() => _audioErr = '录音服务没起来。若是第一次用，'
            '请检查是否允许了「录音」权限和通知权限。');
      }
    } catch (e) {
      if (mounted) setState(() => _audioErr = '启动录音失败：$e');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _stopAudio() async {
    setState(() {
      _audioBusy = true;
      _audioErr = null;
    });
    try {
      await AudioRecorder.stop();
      // 服务收尾（stop + release + 写 moov）不是瞬时的，等 running 变 false，
      // 最多等 5 秒 —— 服务真卡住了也不能让按钮一直转圈。
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final s = await AudioRecorder.status();
        if (!s.running) break;
      }
      await _refreshStatus();
      await _reloadFiles();
    } catch (e) {
      if (mounted) setState(() => _audioErr = '停止录音失败：$e');
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  // ==================================================== 录像

  Future<void> _initCam() async {
    setState(() {
      _videoBusy = true;
      _videoErr = null;
    });
    CameraController? c;
    try {
      final cs = await Permission.camera.request();
      if (!cs.isGranted) {
        if (mounted) setState(() => _videoErr = '没有相机权限，录不了像。');
        return;
      }
      // 录像要带声音，所以还得单独要麦克风权限（camera 插件自己不会申请）
      final ms = await Permission.microphone.request();
      if (!ms.isGranted) {
        if (mounted) setState(() => _videoErr = '没有麦克风权限，录出来的视频会没声音。'
            '（仍可继续，画面正常录）');
      }

      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _videoErr = '这台设备上没有找到可用的摄像头。');
        return;
      }
      // 优先后置；没有后置（少见）就用第一个
      final back = cams.where((d) => d.lensDirection == CameraLensDirection.back);
      final desc = back.isNotEmpty ? back.first : cams.first;

      c = CameraController(desc, ResolutionPreset.high, enableAudio: true);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final old = _cam;
      setState(() {
        _cam = c;
        _camInit = true;
      });
      if (old != null && old != c) old.dispose();
      // 录像是对着屏幕拍的，中途黑屏等于白录
      keepScreenOn(true);
    } catch (e) {
      if (mounted) setState(() => _videoErr = '打开摄像头失败：$e');
      // 半成品控制器必须收掉，不然相机资源一直被占着，下次打不开
      try {
        await c?.dispose();
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _startVideo() async {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      _videoBusy = true;
      _videoErr = null;
    });
    try {
      await c.startVideoRecording();
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (mounted) setState(() => _videoErr = '开始录像失败：$e');
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _stopVideo() async {
    final c = _cam;
    if (c == null) return;
    setState(() {
      _videoBusy = true;
      _videoErr = null;
    });
    XFile? raw;
    try {
      raw = await c.stopVideoRecording();
    } catch (e) {
      if (mounted) setState(() => _videoErr = '停止录像失败：$e');
    }
    if (mounted) setState(() => _recording = false);

    // camera 插件把文件先扔在它自己的缓存目录，得搬到我们的 recordings/ 里
    // 并换成统一的命名。搬失败不算致命（文件还在插件目录里），只提示一下。
    if (raw != null) {
      try {
        final target = await AudioRecorder.nextFile(prefix: '录像', ext: '.mp4');
        final src = File(raw.path);
        try {
          await src.rename(target.path);
        } on FileSystemException {
          // 缓存目录和文档目录可能不在同一个分区，rename 会跨设备失败 → 退回复制
          await src.copy(target.path);
          try {
            await src.delete();
          } catch (_) {}
        }
        await _reloadFiles();
      } catch (e) {
        if (mounted) setState(() => _videoErr = '录像文件保存失败：$e');
      }
    }
    if (mounted) setState(() => _videoBusy = false);
  }

  void _switchMode(_Mode m) {
    if (_mode == m) return;
    if (m == _Mode.video) {
      // 进录像页时如果正在后台录音，提示一下（两个都用麦克风会互相打架）
      if (_st.running) {
        toast(context, '后台录音还在进行，录像可能收不到声音');
      }
      _initCam();
    } else {
      if (_recording) _stopVideo();
      final c = _cam;
      _cam = null;
      _camInit = false;
      c?.dispose();
      keepScreenOn(false);
    }
    setState(() => _mode = m);
  }

  // ==================================================== 回放

  Future<void> _togglePlay(File f) async {
    if (_playing?.path == f.path) {
      await _stopPlay();
      return;
    }
    await _stopPlay();
    try {
      _player ??= Player();
      final pl = _player!;
      if (_subs.isEmpty) {
        _subs.add(pl.stream.position.listen((d) {
          if (mounted) setState(() => _pos = d);
        }));
        _subs.add(pl.stream.duration.listen((d) {
          if (mounted) setState(() => _dur = d);
        }));
        _subs.add(pl.stream.completed.listen((done) {
          if (done && mounted) setState(() => _playing = null);
        }));
      }
      await pl.open(Media('file://${f.path}'));
      if (!mounted) return;
      setState(() {
        _playing = f;
        _pos = Duration.zero;
        _dur = Duration.zero;
      });
    } catch (e) {
      if (mounted) toast(context, '播放失败：$e');
    }
  }

  Future<void> _stopPlay() async {
    try {
      await _player?.stop();
    } catch (_) {}
    if (mounted && _playing != null) {
      setState(() {
        _playing = null;
        _pos = Duration.zero;
        _dur = Duration.zero;
      });
    }
  }

  // ==================================================== 文件操作

  Future<void> _share(File f) => shareFiles(context, <File>[f], text: p.basename(f.path));

  Future<void> _export(File f) async {
    try {
      final bytes = await f.readAsBytes();
      final out = await saveToDownload(p.basename(f.path), bytes);
      if (!mounted) return;
      toast(context, out == null ? '导出失败（可能是没有存储权限）' : '已导出到：${out.path}');
    } catch (e) {
      if (mounted) toast(context, '导出失败：$e');
    }
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个文件？'),
        content: Text('${p.basename(f.path)}\n删掉就找不回来了。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    if (_playing?.path == f.path) await _stopPlay();
    try {
      await f.delete();
    } catch (e) {
      if (mounted) toast(context, '删除失败：$e');
    }
    await _reloadFiles();
  }

  // ==================================================== 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ToolScaffold(
      title: '后台录音录像',
      subtitle: _mode == _Mode.audio ? '息屏 / 切后台都继续录' : '录像需要保持前台',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('录音（真后台）'),
                selected: _mode == _Mode.audio,
                onSelected: (_) => _switchMode(_Mode.audio),
              ),
              ChoiceChip(
                label: const Text('录像（前台）'),
                selected: _mode == _Mode.video,
                onSelected: (_) => _switchMode(_Mode.video),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_mode == _Mode.audio) _audioCard(scheme) else _videoCard(scheme),

          // ---------------- 回放条 ----------------
          if (_playing != null) ...[
            const SizedBox(height: 10),
            _playingBar(scheme),
          ],

          // ---------------- 文件列表 ----------------
          ToolSection('已录制 ${_files.length} 个'),
          if (_files.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('还没有录过东西。录完文件会出现在这里，'
                    '可以试听、分享、导出到「下载」目录。',
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: scheme.onSurfaceVariant)),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < _files.length; i++) ...[
                    _fileRow(scheme, _files[i]),
                    if (i != _files.length - 1)
                      Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  ],
                ],
              ),
            ),

          const SizedBox(height: 14),
          _aboutCard(scheme),
        ],
      ),
    );
  }

  // ---------------- 录音卡片 ----------------

  Widget _audioCard(ColorScheme scheme) {
    final running = _st.running;
    final err = _audioErr ?? (_st.hasError ? _st.error : null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: running
                        ? scheme.error.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: running ? scheme.error : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(running ? '录音中' : '未开始',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: running ? scheme.error : scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const Spacer(),
                if (_pending != null && running)
                  Flexible(
                    child: Text(
                      p.basename(_pending!.path),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                AudioRecorder.elapsedText(_st.elapsedMs),
                style: TextStyle(
                  fontSize: 46,
                  height: 1.1,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: running ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                running ? '息屏、切走、清最近任务都还在录' : '点开始后可以退到后台',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _audioBusy ? null : (running ? _stopAudio : _startAudio),
                    icon: _audioBusy
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(running ? Icons.stop : Icons.fiber_manual_record, size: 20),
                    label: Text(running ? '停止并保存' : '开始录音'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      backgroundColor: running ? scheme.error : null,
                    ),
                  ),
                ),
              ],
            ),
            if (err != null) ...[
              const SizedBox(height: 10),
              _errBox(scheme, err),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 录像卡片 ----------------

  Widget _videoCard(ColorScheme scheme) {
    final c = _cam;
    final ready = _camInit && c != null && c.value.isInitialized;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 230,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ready
                    ? Center(child: CameraPreview(c))
                    : Container(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                        alignment: Alignment.center,
                        child: _videoBusy
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: scheme.primary),
                                  ),
                                  const SizedBox(height: 10),
                                  Text('正在打开摄像头…',
                                      style: TextStyle(
                                          fontSize: 12, color: scheme.onSurfaceVariant)),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.videocam_off_outlined,
                                      size: 34, color: scheme.onSurfaceVariant),
                                  const SizedBox(height: 8),
                                  Text('摄像头还没打开',
                                      style: TextStyle(
                                          fontSize: 12, color: scheme.onSurfaceVariant)),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: _videoBusy ? null : _initCam,
                                    icon: const Icon(Icons.videocam, size: 18),
                                    label: const Text('打开摄像头'),
                                  ),
                                ],
                              ),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_videoBusy || (!ready && !_recording))
                        ? null
                        : (_recording ? _stopVideo : _startVideo),
                    icon: Icon(_recording ? Icons.stop : Icons.videocam, size: 20),
                    label: Text(_recording ? '停止并保存' : '开始录像'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      backgroundColor: _recording ? scheme.error : null,
                    ),
                  ),
                ),
                if (ready && !_recording) ...[
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: '重置摄像头',
                    onPressed: _videoBusy ? null : _initCam,
                    icon: const Icon(Icons.cameraswitch_outlined, size: 20),
                  ),
                ],
              ],
            ),
            if (_recording) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.fiber_manual_record, size: 13, color: scheme.error),
                  const SizedBox(width: 6),
                  Text('正在录像（请保持 App 在前台）',
                      style: TextStyle(fontSize: 12, color: scheme.error)),
                ],
              ),
            ],
            if (_videoErr != null) ...[
              const SizedBox(height: 10),
              _errBox(scheme, _videoErr!),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 回放条 ----------------

  Widget _playingBar(ColorScheme scheme) {
    final total = _dur.inMilliseconds;
    final value = total <= 0 ? 0.0 : (_pos.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.graphic_eq, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(_playing!.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                  const SizedBox(height: 5),
                  LinearProgressIndicator(value: value, minHeight: 3),
                  const SizedBox(height: 4),
                  Text(
                    '${AudioRecorder.elapsedText(_pos.inMilliseconds)}'
                    '${total > 0 ? ' / ${AudioRecorder.elapsedText(total)}' : ''}',
                    style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '停止播放',
              onPressed: _stopPlay,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 文件行 ----------------

  Widget _fileRow(ColorScheme scheme, File f) {
    final name = p.basename(f.path);
    final isVideo = name.startsWith('录像_');
    final playing = _playing?.path == f.path;
    int size = 0;
    String when = '';
    try {
      final st = f.statSync();
      size = st.size;
      final m = st.modified;
      String two(int v) => v < 10 ? '0$v' : '$v';
      when = '${two(m.month)}-${two(m.day)} ${two(m.hour)}:${two(m.minute)}';
    } catch (_) {}

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (isVideo ? scheme.primary : scheme.tertiary).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(isVideo ? Icons.videocam : Icons.mic,
                size: 17, color: isVideo ? scheme.primary : scheme.tertiary),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: playing ? FontWeight.w600 : FontWeight.normal,
                        color: playing ? scheme.primary : scheme.onSurface)),
                const SizedBox(height: 2),
                Text('${formatBytes(size)}${when.isEmpty ? '' : ' · $when'}',
                    style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            tooltip: playing ? '停止' : '播放',
            visualDensity: VisualDensity.compact,
            onPressed: () => _togglePlay(f),
            icon: Icon(playing ? Icons.stop_circle : Icons.play_circle_outline, size: 22),
          ),
          IconButton(
            tooltip: '分享',
            visualDensity: VisualDensity.compact,
            onPressed: () => _share(f),
            icon: const Icon(Icons.ios_share, size: 19),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'export') _export(f);
              if (v == 'delete') _delete(f);
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'export', child: Text('导出到「下载」目录')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 说明 ----------------

  Widget _aboutCard(ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Text('这个工具能做到什么',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
              ],
            ),
            const SizedBox(height: 8),
            _note(scheme, '**录音是真后台**：靠一个前台服务在跑（通知栏会有一条常驻通知），'
                '息屏、切到别的 App、清掉最近任务都还在录。这也是 Android 对麦克风的硬性要求 —— '
                '没有前台服务，后台一秒钟都录不到。'),
            _note(scheme, '**录像做不到后台**：Android 9 起禁止后台访问摄像头，'
                '所以录像必须让 App 停在屏幕上。这点和 Alibi 在老系统上的体验不一样，'
                '不是没做，是系统不让。'),
            _note(scheme, '文件存在**应用私有目录**（`文档/recordings/`），不需要存储权限。'
                '想拿到手机公共目录里，用行末菜单的「导出到「下载」目录」，'
                '或者直接「分享」给别人。'),
            _note(scheme, '录音格式是 `m4a`（AAC 96 kbps 单声道 44.1 kHz），'
                '一个小时约 43 MB，手机和电脑都能直接播；录像格式是 `mp4`。'),
            _note(scheme, '录音和录像**不要同时开** —— 两个都在抢麦克风，'
                '后开的那个大概率录不到声音。'),
          ],
        ),
      ),
    );
  }

  Widget _note(ColorScheme scheme, String text) {
    final parts = text.split('**');
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(
        text: parts[i],
        style: TextStyle(
          fontWeight: i.isOdd ? FontWeight.w600 : FontWeight.normal,
          color: i.isOdd ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· ', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          Expanded(
            child: Text.rich(TextSpan(
              style: TextStyle(fontSize: 12.5, height: 1.7, color: scheme.onSurfaceVariant),
              children: spans,
            )),
          ),
        ],
      ),
    );
  }

  Widget _errBox(ColorScheme scheme, String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onErrorContainer)),
      );
}
