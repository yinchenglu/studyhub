import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/local/settings_store.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

/// 视频播放页：nplayer 风格
/// · 双击左右两侧：快退 / 快进 10 秒
/// · 左右滑动：拖进度（松手才跳，带预览时间）
/// · 右半屏上下滑：音量；左半屏上下滑：画面亮度（调暗）
/// · 长按：临时 2 倍速；倍速菜单 0.5× ~ 3.0×
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
  double _volume = 60;
  double _dim = 0; // 画面亮度：0 最亮，0.7 最暗
  bool _uiVisible = true;
  bool _landscape = false;
  bool _longPressFast = false;
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
    _init();
  }

  Future<void> _init() async {
    _rate = await SettingsStore.instance.playbackSpeed();
    try {
      await _player.setRate(_rate);
      await _player.setVolume(_volume);
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

  Future<void> _toggleFullscreen() async {
    setState(() => _landscape = !_landscape);
    if (_landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// 下载当前视频到本地（离线看）
  Future<void> _download() async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final file = await CacheManager.instance.downloadedFile(_current.path);
    if (await file.exists()) {
      _toast('已经在本地了：${file.path}');
      return;
    }
    final controller = showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text('下载 ${_current.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
          content: const SizedBox(
            height: 70,
            child: Center(child: Text('正在下载，请保持网络连接…', style: TextStyle(fontSize: 13))),
          ),
        ),
      ),
    );
    try {
      await client.download(_current.path, file.path, onProgress: (a, b) {});
      if (mounted) Navigator.of(context).pop();
      _toast('已下载，离线也能看');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('下载失败：$e');
    }
    unawaited(controller);
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _saveProgress();
    _player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    final delta = -(d.primaryDelta ?? 0) / (screenHeight * 0.6);
    setState(() {
      if (rightSide) {
        _volume = (_volume + delta * 100).clamp(0, 100);
        _player.setVolume(_volume);
      } else {
        _dim = (_dim + delta * 0.7).clamp(0, 0.7);
      }
    });
  }

  Future<void> _onDoubleTapDown(TapDownDetails d, double width) async {
    final x = d.localPosition.dx;
    final step = const Duration(seconds: 10);
    if (x < width * 0.4) {
      final t = _position - step;
      await _player.seek(t < Duration.zero ? Duration.zero : t);
      _toast('◀ 快退 10 秒');
    } else if (x > width * 0.6) {
      final t = _position + step;
      await _player.seek(t > _duration ? _duration : t);
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
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleUi,
          onDoubleTapDown: (d) => _onDoubleTapDown(d, constraints.maxWidth),
          onLongPressStart: (_) async {
            _longPressFast = true;
            await _player.setRate(2.0);
            if (mounted) setState(() {});
          },
          onLongPressEnd: (_) async {
            _longPressFast = false;
            await _player.setRate(_rate);
            if (mounted) setState(() {});
          },
          onHorizontalDragStart: (_) => _hideTimer?.cancel(),
          onHorizontalDragUpdate: _onHorizontalUpdate,
          onHorizontalDragEnd: _onHorizontalEnd,
          onVerticalDragStart: (d) => _hideTimer?.cancel(),
          onVerticalDragUpdate: (d) => _onVerticalUpdate(d, d.localPosition.dx > constraints.maxWidth / 2, constraints.maxHeight),
          onVerticalDragEnd: (_) => _scheduleHide(),
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
              if (_dim > 0) Positioned.fill(child: IgnorePointer(child: Container(color: Colors.black.withOpacity(_dim)))),

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

              if (_longPressFast)
                const Positioned(top: 70, right: 20, child: _Badge(text: '2.0× 快进中')),

              if (_seeking) _seekPreview(constraints),
              if (_uiVisible) ...[
                _topBar(),
                _centerControls(),
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
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(12)),
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
            color: Colors.black.withOpacity(0.35),
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
                IconButton(
                  tooltip: '横屏 / 竖屏',
                  icon: Icon(_landscape ? Icons.screen_lock_portrait_outlined : Icons.screen_lock_landscape_outlined, color: Colors.white),
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ),
        ),
      );

  Widget _centerControls() => Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 42,
              icon: const Icon(Icons.replay_10, color: Colors.white),
              onPressed: () {
                final t = _position - const Duration(seconds: 10);
                _player.seek(t < Duration.zero ? Duration.zero : t);
              },
            ),
            const SizedBox(width: 28),
            IconButton(
              iconSize: 64,
              icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white),
              onPressed: () => _playing ? _player.pause() : _player.play(),
            ),
            const SizedBox(width: 28),
            IconButton(
              iconSize: 42,
              icon: const Icon(Icons.forward_10, color: Colors.white),
              onPressed: () {
                final t = _position + const Duration(seconds: 10);
                _player.seek(t > _duration ? _duration : t);
              },
            ),
          ],
        ),
      );

  Widget _bottomBar() => Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          child: Container(
            color: Colors.black.withOpacity(0.4),
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
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _showSpeedSheet,
                      icon: const Icon(Icons.speed, size: 18, color: Colors.white),
                      label: Text('${_rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 1 : 2)}×', style: const TextStyle(color: Colors.white)),
                    ),
                    IconButton(
                      tooltip: '上一集',
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: _prev,
                    ),
                    IconButton(
                      tooltip: '下一集',
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: _next,
                    ),
                    const Spacer(),
                    Icon(
                      _volume == 0 ? Icons.volume_off : _volume < 50 ? Icons.volume_down : Icons.volume_up,
                      color: Colors.white70,
                      size: 18,
                    ),
                    SizedBox(
                      width: 90,
                      child: Slider(
                        value: _volume,
                        min: 0,
                        max: 100,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          _player.setVolume(v);
                        },
                      ),
                    ),
                  ],
                ),
                if (_uiVisible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '双击左右快进快退 · 左右滑拖进度 · 右半屏上下滑音量 · 左半屏上下滑亮度 · 长按 2 倍速',
                      style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
      );
}
