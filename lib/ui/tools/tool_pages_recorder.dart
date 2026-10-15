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

import '../../core/constants.dart';
import '../../core/recorder.dart';
import '../../core/utils.dart';
import '../../core/video_recorder.dart';
import '../../data/local/settings_store.dart';
import '../widgets/folder_picker.dart';
import 'tool_pages.dart';

/// 后台录音录像
///
/// 用户第 1 条第 ① 项：「后台录音录像工具，类似 Alibi，可以参考他的源码。」
///
/// ── 录音和录像走的是两条完全不同的路 ────────────────────
/// Alibi 是那种「放兜里一直在录」的工具。它能做到音视频一起后台录，
/// 靠的是**前台服务**。这个工具也照这个思路做，但两条路难度不一样：
///
///   * **录音**：原生前台服务（`foregroundServiceType="microphone"`，
///     Android 14 起是硬要求）+ 部分唤醒锁，息屏、切到别的 App、
///     清空最近任务都还在录。见 `MainActivity.kt` 的 `RecorderService`。
///
///   * **录像**：v1.6.0 之前这里写的是「做不到，系统不让」—— 那个结论是错的。
///     正确的做法和 Alibi 一样：把相机交给一个 `foregroundServiceType="camera"`
///     的前台服务（见 `MainActivity.kt` 的 `VideoRecorderService`），
///     只要**在前台启动**这个服务，之后退到后台相机依然是我们的。
///     代价是相机被服务独占，页面上就没有实时画面了 ——
///     所以这里留了两种模式给用户挑：
///       · 后台录像：能息屏、能切后台，没画面；
///       · 前台录像：页面里能看到画面（`camera` 插件），退到后台就停。
///
/// ── 文件存在哪儿 ────────────────────────────────────────
/// 默认是应用私有目录 `文档/recordings/`，文件名
/// `录音_20261012_153000.m4a` / `录像_20261012_153000.mp4`。
/// v1.6.0 起可以在页面上改成别的文件夹（比如系统「下载」目录）——
/// 原生服务需要一个**真实路径**，所以用的是自己写的文件夹浏览器，
/// 不是系统的 SAF 选择器（那个给的是 content:// URI，MediaRecorder 不认）。
/// 要拿出来还有两条路：共享给别人，或者导出到手机的「下载」目录。
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
  /// 后台录像（走原生前台服务）的当前状态。
  RecorderStatus _vst = const RecorderStatus();
  File? _vPending;

  /// 前台录像（走 camera 插件）的控制器。只有「前台录像」模式才非空。
  CameraController? _cam;
  bool _camInit = false;
  bool _recording = false;
  bool _videoBusy = false;
  String? _videoErr;

  // ---------------- 设置（v1.6.0）----------------
  /// 录像方式：true = 后台录像（能息屏、无画面），false = 前台录像（有画面）。
  bool _bgVideo = true;

  /// 摄像头：'back' / 'front'。
  ///
  /// v1.6.0 修的真 bug：以前这个页面**只能**用后置 —— 那个看着像「切换摄像头」
  /// 的按钮其实只是重新 `_initCam()` 一次，选的还是后置。用户反馈的
  /// 「只能调用后摄像头，前摄失败」说的就是这事。
  String _lens = 'back';

  /// 录像要不要录声音。
  bool _vAudio = true;

  /// 录音 / 录像的最长时长（分钟，0 = 不限）
  int _audioMaxMin = Defaults.audioMaxMinutes;
  int _videoMaxMin = Defaults.videoMaxMinutes;

  /// 自定义保存目录（null = 应用私有目录 `文档/recordings/`）
  String? _saveDir;
  String _defaultSaveDir = '';

  // ---------------- 文件列表 ----------------
  List<File> _files = const <File>[];

  // ---------------- 回放 ----------------
  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  File? _playing;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  /// 录像是否在跑（两种模式合一，界面上一处判断就够）。
  bool get _anyVideoRunning => _bgVideo ? _vst.running : _recording;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _refreshStatus();
    _reloadFiles();
    // 每秒问一次原生服务。为什么不用 Dart 自己数秒：
    // App 在后台时 Flutter 引擎会被冻结，Dart 的 Timer 跟着停；
    // 而原生服务在跑前台通知，时间一直在走。以原生为准才不会「用户切回来
    // 发现计时少了 40 秒」。
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
  }

  Future<void> _loadSettings() async {
    final s = SettingsStore.instance;
    final bg = await s.videoBackground();
    final lens = await s.recorderLens();
    final va = await s.videoWithAudio();
    final am = await s.audioMaxMinutes();
    final vm = await s.videoMaxMinutes();
    final dir = await s.recorderDirPath();
    // 默认目录（应用私有）也先算出来，好在界面上显示完整路径
    String defDir = '';
    try {
      final d = await AudioRecorder.defaultDir();
      defDir = d.path;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _bgVideo = bg;
      _lens = lens;
      _vAudio = va;
      _audioMaxMin = am;
      _videoMaxMin = vm;
      _saveDir = dir;
      _defaultSaveDir = defDir;
    });
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
    final v = await VideoRecorder.status();
    if (!mounted) return;
    // 只在值真变了的时候 setState：每秒无脑重画整个页面没必要
    final changed = s.running != _st.running ||
        s.elapsedMs != _st.elapsedMs ||
        s.error != _st.error ||
        v.running != _vst.running ||
        v.elapsedMs != _vst.elapsedMs ||
        v.error != _vst.error;
    if (!changed) return;
    setState(() {
      _st = s;
      _vst = v;
    });
    // 从「在录」变成「不在录」——那段文件已经落盘了，刷新列表
    var needReload = false;
    if (!s.running && _pending != null) {
      _pending = null;
      needReload = true;
    }
    if (!v.running && _vPending != null) {
      // 后台录像停下来时，顺手把「只建了文件、一个字节都没写」的空壳删掉，
      // 免得列表里挂着一条点不开的 0 B 录像
      final f = _vPending;
      _vPending = null;
      if (f != null) await VideoRecorder.removeIfEmpty(f);
      needReload = true;
    }
    if (needReload) await _reloadFiles();
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
      await AudioRecorder.start(f, maxDurationMs: _audioMaxMin * 60 * 1000);
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

  /// 把当前选的那一侧摄像头翻译成 camera 插件要的枚举。
  CameraLensDirection get _wantLens => _lens == 'front'
      ? CameraLensDirection.front
      : CameraLensDirection.back;

  /// 打开前台录像用的摄像头（有画面那条路）。
  ///
  /// v1.6.0 修：以前这里写死了 `lensDirection == back`，那个像「切换摄像头」
  /// 的按钮也只是重开一次后摄 —— 用户说「只能调用后摄像头，前摄失败」就是这个。
  /// 现在按 [_lens] 挑，找不到想要的那一侧才退回第一个。
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
      final want = _wantLens;
      final hit = cams.where((d) => d.lensDirection == want);
      final desc = hit.isNotEmpty ? hit.first : cams.first;
      if (hit.isEmpty && mounted && want == CameraLensDirection.front) {
        // 明确告诉用户「这台机器没有前摄」，不要静默给个后摄画面
        toast(context, '这台设备没有前置摄像头，先用后置的');
      }

      c = CameraController(desc, ResolutionPreset.high, enableAudio: _vAudio);
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

  /// 换摄像头（两种模式共用）。
  ///
  /// 后台模式要先把服务停掉再换 —— 相机在同一时刻只能有一个持有者。
  Future<void> _switchLens() async {
    final next = _lens == 'front' ? 'back' : 'front';
    if (_anyVideoRunning) {
      toast(context, '正在录像，先停下来再换摄像头');
      return;
    }
    if (!_bgVideo) {
      // 前台模式：重开一次控制器就行
      final c = _cam;
      _cam = null;
      _camInit = false;
      await c?.dispose();
    }
    if (!mounted) return;
    setState(() => _lens = next);
    await SettingsStore.instance.setRecorderLens(next);
    if (!_bgVideo && mounted) await _initCam();
  }

  Future<void> _setBgVideo(bool v) async {
    if (_anyVideoRunning) {
      toast(context, '正在录像，先停下来再切换方式');
      return;
    }
    // 换方式前把旧那条路的相机关掉，免得两个客户端抢相机
    if (v && _cam != null) {
      final c = _cam;
      _cam = null;
      _camInit = false;
      await c?.dispose();
      keepScreenOn(false);
    }
    if (!mounted) return;
    setState(() => _bgVideo = v);
    await SettingsStore.instance.setVideoBackground(v);
    if (!v && mounted) await _initCam();
  }

  Future<void> _setVAudio(bool v) async {
    if (_anyVideoRunning) {
      toast(context, '正在录像，先停下来再改这个');
      return;
    }
    setState(() => _vAudio = v);
    await SettingsStore.instance.setVideoWithAudio(v);
    if (!_bgVideo && mounted) await _initCam();
  }

  // ---------------- 后台录像（原生前台服务，能息屏）----------------

  Future<void> _startBgVideo() async {
    setState(() {
      _videoBusy = true;
      _videoErr = null;
    });
    try {
      final cs = await Permission.camera.request();
      if (!cs.isGranted) {
        if (mounted) setState(() => _videoErr = '没有相机权限，录不了像。');
        return;
      }
      // ★ v1.8.0 修：麦克风没授权时要**真的降级成无声录像**。
      //   原来这里只是弹个提示（还写着「画面正常录」），audio 照样传 true ——
      //   于是原生侧仍然去 startForeground(… | FOREGROUND_SERVICE_TYPE_MICROPHONE)
      //   并 setAudioSource(MIC)。Android 14 上这会直接抛 SecurityException，
      //   **连画面都一起录不成**，跟提示说的完全不是一回事。
      //   现在改成：没权限就 withAudio = false，提示也改成「这次录成无声的」。
      var withAudio = _vAudio;
      if (withAudio) {
        final ms = await Permission.microphone.request();
        if (!ms.isGranted) {
          withAudio = false;
          if (mounted) {
            setState(() => _videoErr = '没有麦克风权限，这次录成无声的（画面照录）。');
          }
        }
      }
      // 相机在同一时刻只能有一个持有者 —— 把前台预览那条路先让开
      final c = _cam;
      if (c != null) {
        _cam = null;
        _camInit = false;
        try {
          await c.dispose();
        } catch (_) {}
      }
      // 后台录像要真能息屏，就不能再靠 keepScreenOn 撑着了
      keepScreenOn(false);

      final f = await AudioRecorder.nextFile(prefix: '录像', ext: '.mp4');
      await VideoRecorder.start(
        file: f,
        lens: _lens,
        audio: withAudio,
        maxDurationMs: _videoMaxMin * 60 * 1000,
      );
      if (mounted) setState(() => _vPending = f);
      // 服务是异步起来的（要先 startForeground 再开相机、再配会话），轮着问几次。
      // v1.7.0 修：原来只等 1.2 秒问一次，而且**只有在「既没在跑、也没报错」
      // 时才提示** —— 一旦原生日志里带了 lastError，这里就一个字都不说，
      // 用户看到的就是「点了开始录像，什么都没发生」。
      // 现在无论哪种失败都必须出话，而且额外弹一条 SnackBar，跑不掉。
      //
      // v1.8.0 修：窗口从 4 秒拉到 7 秒。原生侧现在也是「会话真的配好、
      // `MediaRecorder.start()` 真的成功」才把 running 置真（以前一进服务就置真，
      // 于是这里永远看到「在录」，真失败反而看不出来），
      // 另外原生侧挂了一个 6 秒的「相机打开超时」看门狗 ——
      // 这个窗口必须比看门狗长，否则会在看门狗定案之前就先误报「没起来」。
      // 两边一起改：`MainActivity.kt` 的 OPEN_TIMEOUT_MS。
      String? failMsg;
      for (var i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        await _refreshStatus();
        if (_vst.running) break;
      }
      if (mounted && !_vst.running) {
        failMsg = _vst.hasError
            ? '后台录像没起来：${_vst.error}'
            : '录像服务没起来（等了 7 秒）。若是第一次用，'
                '请检查是否允许了「相机」「录音」权限和通知权限；'
                '也可能是相机被别的应用占着。';
        setState(() => _videoErr = failMsg);
        toast(context, failMsg);
      }
    } catch (e) {
      final m = '启动录像失败：$e';
      if (mounted) {
        setState(() => _videoErr = m);
        toast(context, m);
      }
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _stopBgVideo() async {
    setState(() {
      _videoBusy = true;
      _videoErr = null;
    });
    try {
      await VideoRecorder.stop();
      // 服务收尾（关会话、关相机、写 moov）不是瞬时的，最多等 6 秒
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final s = await VideoRecorder.status();
        if (!s.running) break;
      }
      await _refreshStatus();
      await _reloadFiles();
    } catch (e) {
      if (mounted) setState(() => _videoErr = '停止录像失败：$e');
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  // ---------------- 前台录像（camera 插件，有画面）----------------

  Future<void> _startVideo() async {
    final c = _cam;
    if (c == null || !c.value.isInitialized) {
      // v1.7.0 修：原来这里直接 `return`，一个字都不说 —— 预览没起来的时候
      // （相机权限没给、被别的 App 占着、或者初始化还在路上），
      // 用户点「开始录像」就是彻底的没反应，连红字都没有。
      // 这是「点击开始录像没有反应」最像的那个原因。
      if (mounted) {
        final m = '还没有可用的摄像头预览，录不了像：'
            '${_videoErr ?? '摄像头没打开（检查相机权限，或被别的应用占用）'}';
        setState(() => _videoErr = m);
        toast(context, m);
      }
      return;
    }
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
      if (!_bgVideo) _initCam();
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

    final running = _mode == _Mode.audio ? _st.running : _anyVideoRunning;
    return ToolScaffold(
      title: '后台录音录像',
      subtitle: _mode == _Mode.audio
          ? '息屏 / 切后台都继续录'
          : (_bgVideo ? '息屏 / 切后台都继续录（无画面）' : '有画面，但需要保持前台'),
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
                label: const Text('录像'),
                selected: _mode == _Mode.video,
                onSelected: (_) => _switchMode(_Mode.video),
              ),
              if (running)
                Chip(
                  avatar: Icon(Icons.fiber_manual_record,
                      size: 13, color: Theme.of(context).colorScheme.error),
                  label: const Text('录制中'),
                  labelStyle: TextStyle(
                      fontSize: 11.5, color: Theme.of(context).colorScheme.error),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 10),

          // ---------------- 保存位置（录音 / 录像共用，v1.6.0 新增）----------------
          _saveDirRow(scheme),
          const SizedBox(height: 10),

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

  // ---------------- 保存位置（v1.6.0）----------------

  /// 当前实际生效的保存目录：自定义优先，没设就用应用私有目录。
  String get _effectiveDir =>
      (_saveDir != null && _saveDir!.isNotEmpty) ? _saveDir! : _defaultSaveDir;

  Widget _saveDirRow(ColorScheme scheme) {
    final custom = _saveDir != null && _saveDir!.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(custom ? '保存位置：自定义文件夹' : '保存位置：应用私有目录',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _effectiveDir.isEmpty ? '（正在读取…）' : _effectiveDir,
                    maxLines: 2,
                    style: TextStyle(fontSize: 10.5, height: 1.45, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '保存位置',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                if (v == 'browse') _pickSaveDir();
                if (v == 'reset') _resetSaveDir();
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'browse', child: Text('选择文件夹…')),
                PopupMenuItem<String>(value: 'reset', child: Text('恢复成应用私有目录')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSaveDir() async {
    // 起点优先用「现在的目录」，它不存在的话退到应用私有目录
    var start = _effectiveDir;
    if (start.isEmpty) {
      try {
        start = (await AudioRecorder.defaultDir()).path;
      } catch (_) {
        start = '/storage/emulated/0';
      }
    }
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => FolderPicker(
        initial: start,
        title: '录音录像存到哪儿',
        confirmText: '就存这儿',
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await SettingsStore.instance.setRecorderDirPath(picked);
    if (!mounted) return;
    setState(() => _saveDir = picked);
    // 立刻验一下能不能写：选了「下载」这类公共目录又没给
    // 「所有文件访问权限」的话，这里就该报出来，而不是等用户录了半小时才发现
    await _probeDir(picked);
  }

  Future<void> _resetSaveDir() async {
    await SettingsStore.instance.setRecorderDirPath(null);
    if (!mounted) return;
    setState(() => _saveDir = null);
    toast(context, '已恢复成应用私有目录');
  }

  /// 试写一个小文件，验证目录真的能写。
  Future<void> _probeDir(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File(p.join(d.path, '.studyhub_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      if (mounted) toast(context, '这个文件夹可以写，就用它了');
    } catch (e) {
      if (!mounted) return;
      toast(context, '写不进去（多半是没有「所有文件访问」权限）：$e');
    }
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
            const SizedBox(height: 6),
            // v1.6.0：最长录多久。到点由**原生服务**自己停（Dart 的 Timer
            // 在 App 被冻结后是停的，拿它限时会直接失控）。
            _maxDurRow(
              scheme,
              icon: Icons.timer_outlined,
              label: '最长录音时长',
              value: _audioMaxMin,
              options: Defaults.audioMaxOptions,
              enabled: !running,
              onChanged: (v) async {
                setState(() => _audioMaxMin = v);
                await SettingsStore.instance.setAudioMaxMinutes(v);
              },
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

  // ---------------- 通用小行：时长上限 ----------------

  /// 一行「名字 + 下拉框」的时长上限设置。
  ///
  /// 0 显示成「不限」。用下拉而不是滑块：时长的档位本来就是几个整数，
  /// 滑块反而拖不准（想要整整 30 分钟，滑出来是 29.8）。
  Widget _maxDurRow(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required int value,
    required List<int> options,
    required bool enabled,
    required ValueChanged<int> onChanged,
  }) =>
      Row(
        children: [
          Icon(icon, size: 17, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 12.5)),
          ),
          DropdownButton<int>(
            value: value,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(
                fontSize: 12.5,
                color: enabled ? scheme.onSurface : scheme.onSurfaceVariant),
            items: [
              for (final m in options)
                DropdownMenuItem<int>(
                    value: m, child: Text(m == 0 ? '不限' : '$m 分钟')),
            ],
            // 正在录的时候不让改：改了也来不及生效，还会让人以为设置生效了
            onChanged: enabled ? (v) {
              if (v != null) onChanged(v);
            } : null,
          ),
        ],
      );

  // ---------------- 录像卡片 ----------------

  Widget _videoCard(ColorScheme scheme) {
    final running = _anyVideoRunning;
    final c = _cam;
    final ready = _camInit && c != null && c.value.isInitialized;
    final err = _videoErr ?? (_bgVideo ? (_vst.hasError ? _vst.error : null) : null);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 录制方式 ----------
            const Text('录制方式', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('后台录像（能息屏）'),
                  selected: _bgVideo,
                  onSelected: running ? null : (_) => _setBgVideo(true),
                ),
                ChoiceChip(
                  label: const Text('前台录像（有画面）'),
                  selected: !_bgVideo,
                  onSelected: running ? null : (_) => _setBgVideo(false),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _bgVideo
                  ? '相机交给原生前台服务持有，**页面上没有画面**，但锁屏、切到别的 App 都继续录。'
                  : '页面里有实时画面，但**必须让 App 停在前台**，退出去就会停。',
              style: TextStyle(fontSize: 11, height: 1.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),

            // ---------- 取景区 / 状态区 ----------
            SizedBox(
              height: 210,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _bgVideo
                    ? _bgPanel(scheme, running)
                    : (ready
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
                          )),
              ),
            ),
            const SizedBox(height: 12),

            // ---------- 摄像头 / 声音 ----------
            Row(
              children: [
                Icon(Icons.cameraswitch_outlined, size: 17, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _lens == 'front' ? '摄像头：前置' : '摄像头：后置',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                TextButton(
                  onPressed: running ? null : _switchLens,
                  child: const Text('切换'),
                ),
              ],
            ),
            Row(
              children: [
                Icon(Icons.mic_none, size: 17, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('录制声音', style: TextStyle(fontSize: 12.5)),
                ),
                Switch(
                  value: _vAudio,
                  onChanged: running ? null : (v) => _setVAudio(v),
                ),
              ],
            ),
            _maxDurRow(
              scheme,
              icon: Icons.timer_outlined,
              label: '最长录像时长',
              value: _videoMaxMin,
              options: Defaults.videoMaxOptions,
              enabled: !running,
              onChanged: (v) async {
                setState(() => _videoMaxMin = v);
                await SettingsStore.instance.setVideoMaxMinutes(v);
              },
            ),
            const SizedBox(height: 12),

            // ---------- 开始 / 停止 ----------
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _videoBusy || (!_bgVideo && !ready && !_recording)
                        ? null
                        : (running
                            ? (_bgVideo ? _stopBgVideo : _stopVideo)
                            : (_bgVideo ? _startBgVideo : _startVideo)),
                    icon: Icon(running ? Icons.stop : Icons.videocam, size: 20),
                    label: Text(running ? '停止并保存' : '开始录像'),
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

  /// 后台录像时替掉取景框的那块状态面板。
  ///
  /// 为什么不做个小预览：相机同一时刻只能有一个持有者。画面被前台服务拿走了，
  /// Activity 这边就什么都看不到 —— 与其画个假的，不如老实说清楚，
  /// 并把「录了多久」这个真正有用的信息放大给用户。
  Widget _bgPanel(ColorScheme scheme, bool running) {
    final name = _vPending == null ? '' : p.basename(_vPending!.path);
    return Container(
      color: const Color(0xFF14110F),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Color(0xFFE5484D)),
                ),
                const SizedBox(width: 8),
                const Text('正在录像',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFE5484D))),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              AudioRecorder.elapsedText(_vst.elapsedMs),
              style: const TextStyle(
                fontSize: 42,
                height: 1.1,
                fontWeight: FontWeight.w300,
                letterSpacing: 1,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            const Text('可以锁屏、可以切到别的 App\n回来点「停止并保存」',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, height: 1.6, color: Colors.white70)),
            if (name.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ] else ...[
            const Icon(Icons.videocam_outlined, size: 34, color: Colors.white38),
            const SizedBox(height: 10),
            const Text('后台录像没有预览画面',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70)),
            const SizedBox(height: 6),
            Text(
              '相机被后台服务独占，换取的是「锁屏也继续录」。\n'
              '想看画面就切到「前台录像」。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.6, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ],
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
            _note(scheme, '**录像也能后台**（v1.6.0 新加）：同样是前台服务，只不过类型声明成 `camera`。'
                'Android 9 起的限制是「后台应用不能碰相机」，而一条 camera 类型的前台服务**不算后台** —— '
                '这也是 Alibi 的做法。唯一的规矩是必须**在前台把服务启动起来**（也就是你点「开始录像」的时候），'
                '之后锁屏、切走都继续录。'),
            _note(scheme, '**两种录像方式的取舍**：后台录像没有画面（相机被服务独占了），'
                '换来的是能息屏；前台录像有实时画面，但退到后台就停。按需要挑。'),
            _note(scheme, '**录像时可以去忙别的**：切到后台之后系统会用相机/麦克风指示灯'
                '和那条常驻通知提醒你——这是 Android 的硬性规定，任何 App 都关不掉，'
                '所以录之前想清楚合不合适。'),
            _note(scheme, '文件默认存在**应用私有目录**（`文档/recordings/`），不需要存储权限；'
                '页面顶部可以改成别的文件夹（比如系统「下载」目录，那种目录要先给「所有文件访问」权限）。'
                '拿到别处还有两条路：行末菜单「导出到「下载」目录」，或者直接「分享」。'),
            _note(scheme, '录音格式是 `m4a`（AAC 96 kbps 单声道 44.1 kHz），'
                '一个小时约 43 MB，手机和电脑都能直接播；录像格式是 `mp4`（H.264，约 1080p，'
                '一分钟 40~60 MB）。'),
            // v1.7.0：用户问过「为什么不是 mp3」，这里把结论钉住，免得来回改。
            _note(scheme, '**为什么不是 mp3**：Android 框架里**根本没有 MP3 编码器**。'
                '`MediaRecorder` 的 `OutputFormat` 只有 MPEG_4 / 3GPP / AMR / AAC / OGG / WEBM 这些，'
                '没有 MP3。要出真 mp3 只能另外引一个 LAME 编码器（纯 Java 的 jump3r 之类），'
                '录完再用 MediaCodec 解成 PCM 再压一遍 —— 多一个依赖、多等几秒，而且云端构建更容易翻车。'
                '`m4a`（AAC）在手机、电脑、微信里都能直接放，音质还比 128k 的 mp3 好，所以不改。'),
            _note(scheme, '录音和录像**不要同时开** —— 两个都在抢麦克风，'
                '后开的那个大概率录不到声音。'),
            _note(scheme, '**时长上限**到点由服务自己停并保存，不依赖 App 在前台 —— '
                '设了 10 分钟然后锁屏走人，到点它也会老老实实收尾。'),
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
