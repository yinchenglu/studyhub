import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/downloader.dart';
import '../../core/screen_orientation.dart';
import '../../core/system_volume.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/local/settings_store.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

/// 视频播放页：nplayer 风格
/// · 双击左右两侧：快退 / 快进 10 秒
/// · 左右滑动：拖进度（松手才跳，带预览时间）
/// · 右半屏上下滑：音量（上滑变大）；左半屏上下滑：画面亮度（上滑变亮）
/// · 底栏最右那个喇叭：点一下静音、再点一下恢复音量
///   （v1.5.0 起取代了原来的音量滑条 —— 竖屏底栏放不下，滑条把音量图标挤没了。
///    调音量没丢，右半屏上下滑照样能调）
/// · 长按：锁定 / 解锁屏幕方向（v1.3.0 及以前这里是「临时 2 倍速」，v1.4.0 改掉）
/// · 跟着手机方向自动翻转：竖屏 / 左横屏 / 右横屏；锁定后不再自动翻转，
///   而且点击屏幕也不呼出控制栏 —— 躺床上单手划着看时不会误触出一堆按钮
/// · 倍速菜单 0.5× ~ 3.0×
/// · 自动记忆播放进度，下次接着看
class PlayerPage extends ConsumerStatefulWidget {
  final List<MediaItem> playlist;
  final int initialIndex;

  const PlayerPage({super.key, required this.playlist, this.initialIndex = 0});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  int _index = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  double _rate = 1.0;

  /// 当前音量（0~100）。
  ///
  /// v1.6.0 起这**不再是播放器自己的系数，而是系统媒体音量**：
  /// 用户要求「视频要能直接调用系统的音量，在不按音量键的情况也能把音量开到最大」。
  /// media_kit 的 `setVolume` 是乘在系统音量之上的，只调它永远到不了手机的最大声 ——
  /// 必须去动 `AudioManager.STREAM_MUSIC`。见 `core/system_volume.dart`。
  double _volume = 60;

  /// 「静音」不单独存一个状态位，而是**从音量推出来**（`_volume <= 0` 就是静音）。
  /// 这样右半屏上下滑音量滑到 0 时图标会自动变成静音、滑上来又自动恢复，
  /// 不会出现「明明滑上去了图标还显示静音」的状态不一致。
  /// 这个变量只负责记住「静音前是多少」，取消静音时还原回去。
  double _lastVolume = 60;
  bool get _muted => _volume <= 0;

  /// 系统音量通道能不能用。不能用（非 Android、或原生没编进去）就退回
  /// `Player.setVolume` 的老路子，顶多是「最大就到系统音量」，
  /// 不至于整个功能坏掉。
  bool _sysVolume = false;

  /// 拖动音量的写入去抖：一次滑动会来几十次 drag update，
  /// 每次都发一个 MethodChannel 调用会卡手。
  Timer? _volPushTimer;

  /// 反向同步：用户按了手机侧面音量键时，这边的 `_volume` 是旧的。
  /// 定时读一次系统音量补上，免得图标显示和实际响度对不上。
  Timer? _volPollTimer;

  double _dim = 0; // 亮度遮罩：0 全亮，0.7 最暗
  bool _uiVisible = true;

  /// 屏幕方向是否被钉死（v1.4.0 起替代了 v1.3.0 那个手动的横/竖屏开关）。
  /// 锁定时：不跟随重力翻转，并且点击屏幕不再呼出控制栏。
  bool _locked = false;

  String? _error;

  // 拖进度预览
  bool _seeking = false;
  Duration _seekTarget = Duration.zero;

  Timer? _hideTimer;
  Timer? _saveTimer;
  final List<StreamSubscription> _subs = [];

  MediaItem get _current => widget.playlist[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _player = Player();
    _controller = VideoController(_player);
    // 一进来就允许跟着手机转 —— 用户要的是「自动向左横屏、向右横屏、竖屏」，
    // 不需要先手动点一下开关。想固定住再按锁定按钮。
    ScreenOrientation.followDevice();
    _init();
  }

  Future<void> _init() async {
    _rate = await SettingsStore.instance.playbackSpeed();

    // 先问一次系统媒体音量，拿到就用它当初始音量。
    // 播放器自己的系数固定拉满 —— 音量完全交给系统，
    // 免得「系统 60% × 播放器 60%」两道衰减相乘，怎么划都嫌小。
    final sys = await SystemVolume.getPercent();
    if (sys != null) {
      _sysVolume = true;
      _volume = sys;
      _lastVolume = sys <= 0 ? 60 : sys;
    }

    try {
      await _player.setRate(_rate);
      await _player.setVolume(_sysVolume ? 100 : _volume);
    } catch (_) {}

    _subs.add(_player.stream.position.listen((p) {
      if (!_seeking && mounted) setState(() => _position = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted && e.isNotEmpty) setState(() => _error = e);
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (done && mounted) {
        _saveProgress();
        _next();
      }
    }));

    await _open(_index);
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    if (_sysVolume) {
      // 每 2 秒跟系统音量对一次：用户按了手机侧面音量键时这边能跟上
      _volPollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _syncVolumeFromSystem());
    }
  }

  /// 把 `_volume` 写进系统媒体音量；通道不可用时退回播放器系数。
  void _pushVolume() {
    if (_sysVolume) {
      SystemVolume.setPercent(_volume);
    } else {
      _player.setVolume(_volume);
    }
  }

  /// 拖动过程中的去抖写入（拖动结束会直接 `_pushVolume` 兜一次）。
  void _pushVolumeSoon() {
    _volPushTimer?.cancel();
    _volPushTimer = Timer(const Duration(milliseconds: 80), _pushVolume);
  }

  /// 反向同步：读系统音量，跟自己记的不一样就更新 UI。
  /// 正在拖动时不读（否则会把用户刚拖到的值覆盖回去）。
  Future<void> _syncVolumeFromSystem() async {
    if (_volPushTimer?.isActive ?? false) return;
    final v = await SystemVolume.getPercent();
    if (!mounted || v == null) return;
    if ((v - _volume).abs() < 1) return;
    setState(() {
      _volume = v;
      if (v > 0) _lastVolume = v;
    });
  }

  /// 打开某一集：先按本地记录的时间点续播，再开始播放
  Future<void> _open(int i) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    _index = i;
    final item = _current;
    if (mounted) setState(() => _error = null);

    var start = Duration.zero;
    try {
      final p = await AppDb.instance.getProgress(item.path);
      if (p != null && p.positionMs > 10000 && (p.durationMs == 0 || p.positionMs < p.durationMs - 15000)) {
        start = Duration(milliseconds: p.positionMs);
      }
    } catch (_) {}

    await _player.open(
      Media(client.urlFor(item.path), httpHeaders: client.headers),
      play: true,
    );
    // 恢复进度与倍速
    if (start > Duration.zero) {
      await Future.delayed(const Duration(milliseconds: 400));
      await _player.seek(start);
    }
    await _player.setRate(_rate);
    if (mounted) {
      // 触发一次首页「最近浏览」
      setState(() {});
    }
  }

  Future<void> _saveProgress() async {
    if (_duration.inMilliseconds <= 0) return;
    try {
      // 「设置 → 保存浏览记录」关掉后不再写入进度
      if (!await SettingsStore.instance.saveViewHistory()) return;
      await AppDb.instance.saveProgress(_current.path, _position.inMilliseconds, _duration.inMilliseconds);
    } catch (_) {}
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _playing) setState(() => _uiVisible = false);
    });
  }

  void _toggleUi() {
    // 锁定状态下点屏幕什么都不做 —— 用户要的正是「锁定后点击屏幕不出现菜单」。
    // 解锁走长按，或点那个常驻的小锁图标。
    if (_locked) return;
    setState(() => _uiVisible = !_uiVisible);
    if (_uiVisible) _scheduleHide();
  }

  void _next() {
    if (_index < widget.playlist.length - 1) {
      _open(_index + 1);
    } else {
      _toast('已经是最后一个了');
    }
  }

  void _prev() {
    if (_index > 0) {
      _open(_index - 1);
    } else {
      _player.seek(Duration.zero);
    }
  }

  /// 锁定 / 解锁屏幕方向。
  ///
  /// 锁定走原生 `SCREEN_ORIENTATION_LOCKED`（冻结在当前朝向），
  /// 解锁就是把允许方向重新放开成「竖屏 + 两个横屏」。
  /// 为什么不像 v1.3.0 那样用 `setPreferredOrientations([单个方向])` 来锁：
  /// Dart 侧根本分不清当前是左横屏还是右横屏，猜错就是画面倒转 180°。
  /// 详见 `core/screen_orientation.dart` 顶部的说明。
  Future<void> _toggleLock() async {
    final next = !_locked;
    // MediaQuery 必须在 await 之前读 —— 之后 context 可能已经不可用。
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (next) {
      await ScreenOrientation.lockHere(landscape: isLandscape);
    } else {
      await ScreenOrientation.followDevice();
    }
    if (!mounted) return;
    setState(() {
      _locked = next;
      // 锁定的瞬间就把控制栏收掉，免得它悬在那儿挡住画面，
      // 也免得用户以为「锁定了怎么按钮还在」。
      _uiVisible = !next;
    });
    if (!next) _scheduleHide();
    _toast(next ? '已锁定：点屏幕不再呼出控制栏，长按可解锁' : '已解锁：跟随手机方向自动翻转');
  }

  /// 点一下静音、再点一下取消静音。
  ///
  /// v1.5.0 按用户要求把底栏那条音量滑块换成了这个按键：
  /// 竖屏时底部挤了七个按钮还要塞一条 90px 的滑条，音量图标被挤得看不见。
  /// 调音量本身没丢 —— 右半屏上下滑还是能调（那是播放器通用手势，留着更顺手）。
  void _toggleMute() {
    setState(() {
      if (_muted) {
        _volume = _lastVolume <= 0 ? 60 : _lastVolume;
      } else {
        _lastVolume = _volume;
        _volume = 0;
      }
    });
    _pushVolume();
    // v1.6.0：用户要求把点静音时弹出的那两条提示（「已静音」/「已取消静音」）
    // 都去掉 —— 图标本身已经变了，再弹一条反而挡画面。
  }

  /// 下载当前视频到「设置 → 下载目录」
  Future<void> _download() async {
    final client = ref.read(davClientProvider);
    if (client == null || !mounted) return;
    await Downloader.withUi(
      context,
      client.urlFor(_current.path),
      _current.name,
      headers: client.headers,
    );
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _volPushTimer?.cancel();
    _volPollTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _saveProgress();
    _player.dispose();
    // 把方向还给整个 App：其余页面全是竖屏布局，横着退出去会很难看。
    // 顺带也把可能的「锁定」状态清掉 —— followDevice/restorePortrait 都是
    // setPreferredOrientations，会把原生的 SCREEN_ORIENTATION_LOCKED 覆盖掉。
    ScreenOrientation.restorePortrait();
    super.dispose();
  }

  // ------------------------------------------------------------ 手势

  void _onHorizontalUpdate(DragUpdateDetails d) {
    final total = _duration.inMilliseconds;
    if (total <= 0) return;
    setState(() {
      _seeking = true;
      if (_seekTarget == Duration.zero) _seekTarget = _position;
      final deltaMs = (d.primaryDelta ?? 0) / 3 * 1000;
      final v = _seekTarget.inMilliseconds + deltaMs.toInt();
      _seekTarget = Duration(milliseconds: v.clamp(0, total));
    });
    _hideTimer?.cancel();
  }

  void _onHorizontalEnd(DragEndDetails d) {
    if (_seeking) {
      _player.seek(_seekTarget);
      setState(() {
        _position = _seekTarget;
        _seeking = false;
        _seekTarget = Duration.zero;
      });
      _scheduleHide();
    }
  }

  void _onVerticalUpdate(DragUpdateDetails d, bool rightSide, double screenHeight) {
    if (_duration.inMilliseconds <= 0) return;
    // primaryDelta > 0 表示手指往下走（屏幕坐标系 y 向下），取负号之后
    // 就变成「上滑为正、下滑为负」。
    final delta = -(d.primaryDelta ?? 0) / (screenHeight * 0.6);
    setState(() {
      if (rightSide) {
        // 右半屏：上滑变大声。这是所有播放器的习惯，保持一致。
        _volume = (_volume + delta * 100).clamp(0, 100);
        // 顺手记下「最近一次非零音量」，取消静音时还原到这儿
        if (_volume > 0) _lastVolume = _volume;
        _pushVolumeSoon();
      } else {
        // 左半屏：上滑变亮。
        // v1.3.0 这里是 `_dim + delta`，也就是上滑反而更暗 —— 用户明确要求反过来。
        // `_dim` 是「黑色遮罩的不透明度」，越大越暗，所以变亮要**减**。
        _dim = (_dim - delta * 0.7).clamp(0, 0.7);
      }
    });
  }

  /// 快进 / 快退 10 秒。
  /// 双击屏幕左右半边和底栏那两个按钮都走这里，省得两处各写一份边界判断
  /// （超头和超尾各要 clamp 一次，写两遍迟早有一遍会漏）。
  void _seekBy({bool forward = false}) {
    final step = const Duration(seconds: 10);
    final t = forward ? _position + step : _position - step;
    if (t < Duration.zero) {
      _player.seek(Duration.zero);
    } else if (_duration > Duration.zero && t > _duration) {
      _player.seek(_duration);
    } else {
      _player.seek(t);
    }
  }

  Future<void> _onDoubleTapDown(TapDownDetails d, double width) async {
    final x = d.localPosition.dx;
    if (x < width * 0.4) {
      _seekBy();
      _toast('◀ 快退 10 秒');
    } else if (x > width * 0.6) {
      _seekBy(forward: true);
      _toast('快进 10 秒 ▶');
    } else {
      _playing ? _player.pause() : _player.play();
    }
  }

  Future<void> _showSpeedSheet() async {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    final r = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('播放速度', style: TextStyle(fontWeight: FontWeight.w600))),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: speeds
                    .map((s) => ListTile(
                          dense: true,
                          title: Text('${s.toStringAsFixed(s == s.roundToDouble() ? 1 : 2)}×'),
                          trailing: _rate == s ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(context, s),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (r != null) {
      await _player.setRate(r);
      await SettingsStore.instance.setPlaybackSpeed(r);
      // 关闭倍速面板后播放器可能已经被销毁（比如直接返回了）
      if (!mounted) return;
      setState(() => _rate = r);
    }
  }

  void _showEpisodeSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.playlist.length,
          itemBuilder: (context, i) => ListTile(
            dense: true,
            leading: Icon(i == _index ? Icons.play_arrow : Icons.movie_outlined, size: 20),
            title: Text(widget.playlist[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(parentOf(widget.playlist[i].path).replaceFirst('media/', ''), style: const TextStyle(fontSize: 11.5)),
            selected: i == _index,
            onTap: () {
              Navigator.pop(context);
              _open(i);
            },
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleUi,
          onDoubleTapDown: (d) => _onDoubleTapDown(d, constraints.maxWidth),
          // 长按 = 锁定 / 解锁。v1.3.0 这里是「按住临时 2 倍速」，
          // v1.4.0 按用户要求换成了锁定 —— 倍速还有菜单里的 0.5×~3.0× 可选。
          // 只在 Start 里切一次：End 也会触发，两个都写就来回切两下等于没切。
          onLongPressStart: (_) => _toggleLock(),
          onHorizontalDragStart: (_) => _hideTimer?.cancel(),
          onHorizontalDragUpdate: _onHorizontalUpdate,
          onHorizontalDragEnd: _onHorizontalEnd,
          onVerticalDragStart: (d) => _hideTimer?.cancel(),
          onVerticalDragUpdate: (d) => _onVerticalUpdate(d, d.localPosition.dx > constraints.maxWidth / 2, constraints.maxHeight),
          onVerticalDragEnd: (_) {
            // 松手立刻把最终音量落下去，不等去抖那 80ms
            _volPushTimer?.cancel();
            _pushVolume();
            _scheduleHide();
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: Video(
                    controller: _controller,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              // 亮度遮罩（左半屏上下滑动的效果）
              if (_dim > 0) Positioned.fill(child: IgnorePointer(child: Container(color: Colors.black.withValues(alpha: _dim)))),

              if (_buffering && _error == null) const Center(child: CircularProgressIndicator(color: Colors.white70)),

              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white70, size: 42),
                        const SizedBox(height: 12),
                        const Text('这个文件播不了 / 服务器不支持在线播放', style: TextStyle(color: Colors.white70)),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        const SizedBox(height: 16),
                        FilledButton.icon(onPressed: _download, icon: const Icon(Icons.download), label: const Text('先下载到本地')),
                      ],
                    ),
                  ),
                ),

              // 锁定后控制栏全收，只留这么一个小锁。
              // 点它比「先长按再猜」直观得多，而且它是独立按钮、
              // 不会被外层 onTap 吞掉，所以不算「点屏幕呼出菜单」。
              if (_locked)
                Positioned(
                  top: 76,
                  left: 14,
                  child: SafeArea(
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _toggleLock,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lock, color: Colors.white, size: 16),
                              SizedBox(width: 6),
                              Text('已锁定', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              if (_seeking) _seekPreview(constraints),
              if (_uiVisible && !_locked) ...[
                _topBar(),
                _bottomBar(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _seekPreview(BoxConstraints c) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatDuration(_seekTarget.inMilliseconds), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
              Text('/ ${formatDuration(_duration.inMilliseconds)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      );

  Widget _topBar() => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          child: Container(
            color: Colors.black.withValues(alpha: 0.35),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).pop()),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_current.name, style: const TextStyle(color: Colors.white, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('${_index + 1}/${widget.playlist.length} · ${parentOf(_current.path).replaceFirst('media/', '')}',
                          style: const TextStyle(color: Colors.white60, fontSize: 11)),
                    ],
                  ),
                ),
                if (_uiVisible)
                  IconButton(
                    tooltip: '播放列表',
                    icon: const Icon(Icons.list, color: Colors.white),
                    onPressed: _showEpisodeSheet,
                  ),
                IconButton(
                  tooltip: '下载到本地',
                  icon: const Icon(Icons.download_outlined, color: Colors.white),
                  onPressed: _download,
                ),
                // v1.3.0 这里是「切横屏 / 竖屏」，v1.4.0 改成锁定按钮：
                // 横竖屏现在跟着手机自动走，这里只负责「定住不动」。
                IconButton(
                  tooltip: _locked ? '已锁定方向，点击解锁' : '锁定方向（点屏幕不再呼出控制栏）',
                  icon: Icon(_locked ? Icons.lock : Icons.lock_open, color: Colors.white),
                  onPressed: _toggleLock,
                ),
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar() => Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          child: Container(
            color: Colors.black.withValues(alpha: 0.4),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(formatDuration(_position.inMilliseconds), style: const TextStyle(color: Colors.white, fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _duration.inMilliseconds == 0
                            ? 0
                            : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0, 1).toDouble(),
                        onChanged: (v) {
                          setState(() {
                            _seeking = true;
                            _seekTarget = Duration(milliseconds: (v * _duration.inMilliseconds).round());
                          });
                        },
                        onChangeEnd: (v) {
                          final t = Duration(milliseconds: (v * _duration.inMilliseconds).round());
                          _player.seek(t);
                          setState(() {
                            _position = t;
                            _seeking = false;
                          });
                        },
                      ),
                    ),
                    Text(formatDuration(_duration.inMilliseconds), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                ),
                // 七个按钮排成一行，**左右严格对称**：
                //   倍速 · 上一集 · 快退 10 · 播放/暂停 · 快进 10 · 下一集 · 静音
                // 「倍速」和「静音」一个在最左、一个在最右，尺寸完全一样，
                // 所以整排看起来是对称的（v1.4.0 时倍速是带图标的 TextButton、
                // 音量那边是图标 + 90px 滑条，两边宽度差一大截，歪得厉害）。
                //
                // 宽度用 LayoutBuilder 按可用空间均分，不再写死：
                // 竖屏窄机上 7 个 48px 是放不下的（336 > 可用宽度），
                // 写死就会溢出成黄黑斜纹。这里按 (可用宽 / 7) 算，并夹在 34~52 之间 ——
                // 34 是手指还能点准的下限，52 是避免平板上一排按钮散得太开。
                LayoutBuilder(
                  builder: (context, c) {
                    final bw = ((c.maxWidth - 4) / 7).clamp(34.0, 52.0);
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _barButton(
                          width: bw,
                          tooltip: '播放速度',
                          onTap: _showSpeedSheet,
                          child: Text(
                            '${_rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 1 : 2)}×',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: '上一集',
                          onTap: _prev,
                          child: const Icon(Icons.skip_previous, color: Colors.white, size: 24),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: '快退 10 秒（也可以双击屏幕左半边）',
                          onTap: _seekBy,
                          child: const Icon(Icons.replay_10, color: Colors.white, size: 24),
                        ),
                        // 播放/暂停是这一排的视觉中心，图标给大一号
                        _barButton(
                          width: bw,
                          tooltip: _playing ? '暂停' : '播放',
                          onTap: () => _playing ? _player.pause() : _player.play(),
                          child: Icon(
                            _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: '快进 10 秒（也可以双击屏幕右半边）',
                          onTap: () => _seekBy(forward: true),
                          child: const Icon(Icons.forward_10, color: Colors.white, size: 24),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: '下一集',
                          onTap: _next,
                          child: const Icon(Icons.skip_next, color: Colors.white, size: 24),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: _muted ? '取消静音' : '静音',
                          onTap: _toggleMute,
                          child: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 24),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );

  /// 底栏通用小按钮。
  ///
  /// 为什么不用 `IconButton`：它自带 48×48 的**最小点击区**约束，
  /// 塞进比 48 窄的 SizedBox 里会被自己的约束顶开、照样溢出。
  /// 自己用 InkWell + SizedBox 搭一个反而最好控制，顺带能塞任意 child
  /// （倍速键要显示文字、播放键要放大图标，都不是纯图标按钮）。
  Widget _barButton({
    required double width,
    required String tooltip,
    required VoidCallback onTap,
    required Widget child,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(width / 2),
          child: SizedBox(
            width: width,
            height: 42,
            child: Center(child: child),
          ),
        ),
      );
}
