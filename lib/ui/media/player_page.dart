import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 播放模式（v1.7.0，用户点名这四种）。
///
/// 只存在内存里、不落盘 —— 用户没要求记住，而且「上次是随机」这种事
/// 下次打开反而让人困惑（以为是顺序的，结果跳着放）。
enum PlayMode { sequential, shuffle, repeatOne, repeatAll }

String playModeName(PlayMode m) => switch (m) {
      PlayMode.sequential => '默认顺序播放',
      PlayMode.shuffle => '随机播放',
      PlayMode.repeatOne => '单个循环播放',
      PlayMode.repeatAll => '全目录循环播放',
    };

IconData playModeIcon(PlayMode m) => switch (m) {
      PlayMode.sequential => Icons.playlist_play,
      PlayMode.shuffle => Icons.shuffle,
      PlayMode.repeatOne => Icons.repeat_one,
      PlayMode.repeatAll => Icons.repeat,
    };

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
/// · 播放模式菜单（v1.7.0）：默认顺序 / 随机 / 单个循环 / 全目录循环
/// · 全屏（v1.7.0）：切沉浸式，把状态栏和导航栏收掉
/// · 双指捏合缩放画面（v1.7.0），按返回键恢复原始大小
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
  // v1.9.0：锁定后「已锁定」徽标定时自动隐藏。触屏能再呼出。
  bool _lockBadgeVisible = false;

  /// 控制栏要不要「几秒后自动隐藏」（v1.8.0）。
  /// 默认 false：菜单一直显示，只有点全屏、或点画面空白处才收起。
  /// 用户在「设置 → 自动隐藏菜单」里可以打开，打开后才是老行为。
  bool _autoHideUi = false;

  /// 屏幕方向是否被钉死（v1.4.0 起替代了 v1.3.0 那个手动的横/竖屏开关）。
  /// 锁定时：不跟随重力翻转，并且点击屏幕不再呼出控制栏。
  bool _locked = false;

  String? _error;

  // ---- 播放错误的「虚警」过滤（v1.8.0）----
  //
  // media_kit / mpv 在**能继续播**的情况下也会往 error 流里丢东西：
  // 某个轨道探测失败、内嵌字幕流 404、HLS 分片重试、容器尾部有多余数据……
  // 这些都不影响播放，但直接弹遮罩就会出现用户报的那句
  // 「提示播放不了、其实画面在正常播」。
  //
  // 做法：错误先**挂起**，记下此刻的播放位置；2 秒后回看播放位置有没有
  // 往前走 —— 走了就说明是虚警，直接丢掉；没走才真的把遮罩弹出来。
  String? _pendingError;
  Timer? _errProbeTimer;
  Duration _errAnchor = Duration.zero;

  /// 播放模式（v1.7.0 新增）。见 PlayMode 的注释。
  PlayMode _playMode = PlayMode.sequential;

  /// 沉浸式全屏（v1.7.0 新增）：true 时收掉系统状态栏和导航栏。
  bool _fullscreen = false;

  // ---- 双指缩放（v1.7.0 新增）----
  //
  // 为什么用 `Listener` 而不是给外层 GestureDetector 加 `onScaleUpdate`：
  // 外层已经挂了单击 / 双击 / 横滑 / 竖滑四个识别器（切 UI、快进快退、
  // 拖进度、音量亮度）。再塞一个 scale 识别器会跟它们抢手势竞技场 ——
  // 单指滑动很可能被判给 scale，把「右半屏上下滑调音量」整条弄坏。
  // Listener 是**被动**的、不进竞技场，只数自己收到几根手指，
  // 所以绝对抢不走别人的手势。这是这里唯一安全的做法。
  final Map<int, Offset> _pointers = {};
  double _pinchStartDist = 0;
  double _pinchStartZoom = 1;

  /// 当前缩放倍数，1.0 = 原始大小。
  double _zoom = 1;

  static const double _minZoom = 1.0;
  static const double _maxZoom = 4.0;

  // 拖进度预览
  bool _seeking = false;
  Duration _seekTarget = Duration.zero;

  Timer? _hideTimer;
  Timer? _saveTimer;
  Timer? _lockBadgeTimer;
  final List<StreamSubscription> _subs = [];

  /// 当前视频的宽高（v1.8.0）。media_kit 的 `stream.width/height` 是 `Stream<int?>`，
  /// 拿不到时存 0，`_maybeAutoLandscape` 会跳过。
  int _vidW = 0;
  int _vidH = 0;

  /// 当前这一集是不是已经被我们自动切成横屏了 —— 只在**状态真的变了**的时候
  /// 才调一次原生方法，否则每来一个 width/height 事件都要 setRequestedOrientation，
  /// 系统会反复重建 Activity，画面会闪。
  bool _autoLandscape = false;

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
    // v1.8.0：控制栏默认常显（false）。读设置要在 `_scheduleHide()` 之前，
    // 否则第一次进播放页会拿着默认值把菜单藏掉。
    _autoHideUi = await SettingsStore.instance.autoHidePlayerUi();

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
      if (!mounted) return;
      // 画面其实在往前走 → 不管之前弹没弹过错误遮罩，都判定为「能播」，
      // 把遮罩收掉。用户报的「提示播不了、其实在正常播」就靠这条兜底。
      if (_error != null && p > _errAnchor + const Duration(milliseconds: 600)) {
        setState(() => _error = null);
      }
      if (!_seeking) setState(() => _position = p);
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
      if (mounted && e.isNotEmpty) _onPlayerError(e);
    }));

    // v1.8.0：横屏视频默认横屏（见 _maybeAutoLandscape）。
    // 这两个流在 open() 之前会先来一轮 null，所以判据里必须排除 <= 0。
    _subs.add(_player.stream.width.listen((w) {
      _vidW = w ?? 0;
      _maybeAutoLandscape();
    }));
    _subs.add(_player.stream.height.listen((h) {
      _vidH = h ?? 0;
      _maybeAutoLandscape();
    }));

    _subs.add(_player.stream.completed.listen((done) {
      if (done && mounted) {
        _saveProgress();
        // v1.7.0：原来不管什么模式都无脑 _next()，现在交给播放模式决定
        _onCompleted();
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
    // v1.8.0：换集要把上一集的宽高清掉，否则新视频还没报尺寸时
    // `_maybeAutoLandscape` 会拿旧值去比，横竖屏判断错一次（画面会抖一下）。
    _vidW = 0;
    _vidH = 0;
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
    // v1.8.0：默认**不自动隐藏**。控制栏一直挂着，只有点全屏或点画面空白处
    // 才会收起。用户在「设置 → 自动隐藏菜单」打开后才走下面这条 3.5 秒计时。
    if (!_autoHideUi) return;
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _playing) setState(() => _uiVisible = false);
    });
  }

  /// 收到播放器错误的统一入口。
  ///
  /// 关键点：media_kit 对「不影响播放的小毛病」也会报 error，
  /// 所以不能收到就弹遮罩。先挂起，等 2 秒看画面有没有真的在走，
  /// 走了就是虚警（丢掉），没走才把遮罩弹出来。
  void _onPlayerError(String e) {
    _pendingError = e;
    _errAnchor = _position;
    _errProbeTimer?.cancel();
    // 只有「连位置都不动」才需要等满 2 秒去确认；已经在播的直接快速判定。
    final delay = (_playing && _duration > Duration.zero)
        ? const Duration(milliseconds: 900)
        : const Duration(seconds: 2);
    _errProbeTimer = Timer(delay, () {
      if (!mounted) return;
      // 位置往前走了 = 真的在播 → 这条错误是虚警，静默丢掉
      if (_position > _errAnchor + const Duration(milliseconds: 400)) {
        _pendingError = null;
        return;
      }
      final msg = _pendingError;
      _pendingError = null;
      if (msg != null) setState(() => _error = msg);
    });
  }

  void _toggleUi() {
    // v1.9.0：锁定状态下点屏幕把「已锁定」徽标重新呼出（3 秒再隐藏），
    // 仍然不显示控制栏 —— 这正是用户要的「锁定后点击屏幕不出现菜单」。
    if (_locked) {
      _showLockBadge();
      return;
    }
    setState(() => _uiVisible = !_uiVisible);
    if (_uiVisible) _scheduleHide();
  }

  void _next() {
    // v1.7.0：随机模式下「下一集」也走随机；全目录循环模式到末尾绕回开头
    if (_playMode == PlayMode.shuffle && widget.playlist.length > 1) {
      _open(_randomOther());
      return;
    }
    if (_index < widget.playlist.length - 1) {
      _open(_index + 1);
    } else if (_playMode == PlayMode.repeatAll) {
      _open(0);
    } else {
      _toast('已经是最后一个了');
    }
  }

  /// 随机挑一个**不是当前这一集**的下标。
  ///
  /// 特意排除当前集：随机到同一集在用户看来就是「按了没反应」，
  /// 会以为随机坏了。
  int _randomOther() {
    final n = widget.playlist.length;
    if (n <= 1) return _index;
    final rnd = math.Random();
    var i = _index;
    while (i == _index) {
      i = rnd.nextInt(n);
    }
    return i;
  }

  /// 一集播完了该干什么 —— 由播放模式决定（v1.7.0 新增）。
  ///
  /// 这里刻意用 if 链而不是 switch：Dart 的 `case` 体共享作用域，
  /// 而且这个文件的既有风格就是 if 链，少一类语法坑。
  void _onCompleted() {
    if (_playMode == PlayMode.repeatOne) {
      // 不换集，同一集重头再来
      _player.seek(Duration.zero);
      _player.play();
      return;
    }
    if (_playMode == PlayMode.shuffle) {
      if (widget.playlist.length <= 1) {
        _player.seek(Duration.zero);
        _player.play();
      } else {
        _open(_randomOther());
      }
      return;
    }
    if (_playMode == PlayMode.repeatAll) {
      _open((_index + 1) % widget.playlist.length);
      return;
    }
    // 默认顺序播放：放完最后一个是真停，并说明一下，免得以为卡住了
    if (_index < widget.playlist.length - 1) {
      _open(_index + 1);
    } else {
      _toast('已经是最后一个了');
    }
  }

  /// 播放模式菜单（v1.7.0）。写法与倍速菜单保持一致。
  ///
  /// ★ v1.8.0 修「横屏时最后一项『全目录循环播放』被遮住看不见」：
  ///   根因不在我们这段代码，而在 `showModalBottomSheet` 的默认布局 ——
  ///   `isScrollControlled` 为 false 时，底部弹窗的**高度上限是屏幕高度的 9/16**
  ///   （`_ModalBottomSheetLayout` 里的 `maxHeight * 9.0 / 16.0`）。
  ///   竖屏 800dp 高时上限 450dp，装得下；横屏只剩约 360dp 高，
  ///   上限掉到 202dp，而「标题 + 4 个 ListTile」差不多 276dp ——
  ///   于是第 4 项直接被裁掉，而且因为原来是 `Column` 不是滚动列表，
  ///   连「滚一下」的机会都没有。
  ///
  ///   修法两条一起上：
  ///     1. `isScrollControlled: true` —— 解除 9/16 上限，弹窗可以用满屏高；
  ///     2. 内容换成 `SingleChildScrollView` —— 万一屏幕再矮（分屏、小屏横屏）
  ///        也能滚，不至于又白改一遍。
  ///   顺带把每项压紧一点（dense + visualDensity），横屏里更好点。
  Future<void> _showPlayModeSheet() async {
    _hideTimer?.cancel();
    final picked = await showModalBottomSheet<PlayMode>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('播放模式',
                    style: TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              for (final m in PlayMode.values)
                ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  leading: Icon(playModeIcon(m),
                      color: m == _playMode ? Colors.lightBlueAccent : Colors.white70),
                  title: Text(playModeName(m),
                      style: TextStyle(
                          fontSize: 14,
                          color: m == _playMode ? Colors.lightBlueAccent : Colors.white)),
                  trailing: m == _playMode
                      ? const Icon(Icons.check, color: Colors.lightBlueAccent, size: 20)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(m),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      // v1.8.0 按用户要求：**去掉切换后的提示**。
      // 模式图标就在底栏上亮着（非默认顺序时是浅蓝），弹窗里也打了勾，
      // 再来一条 SnackBar 纯属噪音，还会挡住画面。
      setState(() => _playMode = picked);
    }
    _scheduleHide();
  }

  /// 全屏（v1.7.0 新增）：切沉浸式，把系统状态栏和导航栏收掉。
  ///
  /// 播放页本来就是整屏黑底，所以「全屏」真正能看到的差别就是把系统栏收掉。
  /// 退出页面时会还原成 edgeToEdge（见 dispose），不会把整个 App 带成沉浸式。
  ///
  /// v1.8.0 按用户要求：**点全屏的瞬间就把控制栏一起收掉** ——
  /// 原来点完全屏，控制栏还悬在那儿等 3.5 秒才自己消失，
  /// 正好挡住刚铺满的画面。想再叫出来点一下屏幕就行。
  void _toggleFullscreen() {
    final next = !_fullscreen;
    setState(() {
      _fullscreen = next;
      if (next) _uiVisible = false;
    });
    SystemChrome.setEnabledSystemUIMode(
      next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    // 进全屏就把定时器掐掉（否则 3.5 秒后又白白 setState 一次）；
    // 退全屏才重新计时，让控制栏正常待一会儿。
    if (next) {
      _hideTimer?.cancel();
    } else {
      _uiVisible = true;
      _scheduleHide();
    }
  }

  // ------------------------------------------------------------ 双指缩放

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) _baselinePinch();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length != 2 || _pinchStartDist <= 0) return;
    final pts = _pointers.values.toList();
    final d = (pts[0] - pts[1]).distance;
    if (d <= 0) return;
    // 必须 toDouble()：num.clamp 的静态返回类型是 num，直接赋给 double 会编译错
    final z = (_pinchStartZoom * d / _pinchStartDist)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    if ((z - _zoom).abs() < 0.01) return;
    setState(() => _zoom = z);
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    // 手指数变了就重新取基准，否则下一轮捏合会拿上一轮的距离去比，画面会跳一下
    if (_pointers.length == 2) {
      _baselinePinch();
    } else {
      _pinchStartDist = 0;
    }
  }

  void _baselinePinch() {
    final pts = _pointers.values.toList();
    if (pts.length < 2) {
      _pinchStartDist = 0;
      return;
    }
    _pinchStartDist = (pts[0] - pts[1]).distance;
    _pinchStartZoom = _zoom;
  }

  /// 回到原始大小。返回键走的就是这里（见 build 里的 PopScope）。
  void _resetZoom() {
    if (_zoom == 1) return;
    setState(() => _zoom = 1);
    _toast('已恢复原始大小');
  }

  void _prev() {
    if (_index > 0) {
      _open(_index - 1);
    } else {
      _player.seek(Duration.zero);
    }
  }

  /// v1.8.0 按用户要求：**横屏视频（宽 > 高）默认横屏**。
  ///
  /// 判据用 media_kit 暴露的 `stream.width` / `stream.height`（都是 `Stream<int?>`）。
  /// 两个值都到位才判断 —— 刚 `open()` 时会先来一轮 null，
  /// 过早（拿 0 去比）判断会误判成「竖屏视频」，于是什么都不做。
  ///
  /// 走原生 `SCREEN_ORIENTATION_SENSOR_LANDSCAPE` 而不是 Flutter 的
  /// `setPreferredOrientations([landscapeLeft, landscapeRight])`：
  /// 后者在 Android 上映射到 `USER_*` 系列，会尊重系统里的「自动旋转」开关，
  /// 用户关掉之后就不转了 —— v1.5.0 在 followDevice 上正好踩过这个坑
  /// （详见 core/screen_orientation.dart 顶部）。
  ///
  /// 想回竖屏：点右上角「锁定」→ 再点一次「解锁」，就回到跟随手机方向。
  void _maybeAutoLandscape() {
    if (_vidW <= 0 || _vidH <= 0) return;
    final want = _vidW > _vidH;
    if (want == _autoLandscape) return;
    _autoLandscape = want;
    if (want) {
      ScreenOrientation.lockLandscape();
    } else {
      // 上一集是横屏、这集是竖屏 —— 得把方向放开，不然会一直卡在横屏
      ScreenOrientation.followDevice();
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
    if (next) {
      // v1.9.0：锁定时显示「已锁定」徽标，3 秒后自动隐藏，触屏再呼出
      _showLockBadge();
    } else {
      _lockBadgeTimer?.cancel();
      setState(() => _lockBadgeVisible = false);
    }
    if (!next) _scheduleHide();
    _toast(next ? '已锁定：点屏幕不再呼出控制栏，长按可解锁' : '已解锁：跟随手机方向自动翻转');
  }

  /// v1.9.0：「已锁定」徽标 3 秒自动隐藏，触屏再呼出
  void _showLockBadge() {
    _lockBadgeTimer?.cancel();
    setState(() => _lockBadgeVisible = true);
    _lockBadgeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _lockBadgeVisible = false);
    });
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
    _errProbeTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _saveProgress();
    _player.dispose();
    // 把方向还给整个 App：其余页面全是竖屏布局，横着退出去会很难看。
    // 顺带也把可能的「锁定」状态清掉 —— followDevice/restorePortrait 都是
    // setPreferredOrientations，会把原生的 SCREEN_ORIENTATION_LOCKED 覆盖掉。
    ScreenOrientation.restorePortrait();
    // v1.7.0：全屏是「沉浸式」，退出播放页必须还原成 edgeToEdge，
    // 否则整个 App 都会一直没状态栏 —— 这个坑很容易漏，别忘了。
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
    // v1.7.0：按返回键先「恢复原始大小」，只有没缩放的时候才真的退出页面。
    // 用动态 canPop（和 download_site_page 一个套路），不要自己拦 pop 再手动退 ——
    // 那样会丢掉系统返回手势的动画。
    return PopScope(
      canPop: _zoom <= 1.001,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _resetZoom();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => Listener(
          // 双指捏合缩放走这个**被动**监听，不进手势竞技场（见 _pointers 的注释）
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
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
                  child: Transform.scale(
                    // 双指缩放只缩画面，**不缩控制栏** ——
                    // 控制栏跟着放大会把按钮推出屏幕外，反而没法用了。
                    scale: _zoom,
                    child: Video(
                      controller: _controller,
                      fit: BoxFit.contain,
                      controls: NoVideoControls,
                    ),
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

              // v1.9.0：锁定后「已锁定」徽标默认 3 秒后自动隐藏，触屏可再呼出
              if (_locked && _lockBadgeVisible)
                Positioned(
                  top: 76,
                  left: 14,
                  child: SafeArea(
                    child: AnimatedOpacity(
                      opacity: _lockBadgeVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
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
          // v1.8.0：控制栏自己**吃掉**落在它身上的点击。
          // 外层 GestureDetector 的 onTap 是「点画面空白处收起菜单」，
          // 不拦的话点顶栏的标题区域也会把菜单收掉 —— 用户要的是
          // 「只有点菜单**外面**才隐藏」。按钮/滑块是更深的识别器，照常生效。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
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
        ),
      );

  Widget _bottomBar() => Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          // 同上：底栏自己吃掉点击，免得点进度条旁边的空白把菜单收掉
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
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
                // 七个按钮排成一行（v1.7.0 换了内容，个数没变）：
                //   倍速 · 播放模式 · 上一集 · 播放/暂停 · 下一集 · 全屏 · 静音
                //
                // v1.7.0 按用户要求：快退 10 / 快进 10 这两个键**去掉了** ——
                // 双击左右半屏本来就能干同样的事（`_onDoubleTapDown`），留着只是占宽度。
                // 空出来的两个位置给了「播放模式」（紧跟倍速，用户点名）
                // 和「全屏」（紧挨静音之前，用户点名）。
                //
                // 宽度仍按可用空间均分并夹在 34~52 之间：竖屏窄机上
                // 7 个 48px 是放不下的（336 > 可用宽度），写死就会溢出成黄黑斜纹。
                LayoutBuilder(
                  builder: (context, c) {
                    final bw = ((c.maxWidth - 4) / 7).clamp(34.0, 52.0).toDouble();
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
                          tooltip: '播放模式：${playModeName(_playMode)}',
                          onTap: _showPlayModeSheet,
                          child: Icon(
                            playModeIcon(_playMode),
                            // 不是默认顺序播放时点亮一下，扫一眼就知道现在什么模式
                            color: _playMode == PlayMode.sequential
                                ? Colors.white
                                : Colors.lightBlueAccent,
                            size: 24,
                          ),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: '上一集',
                          onTap: _prev,
                          child: const Icon(Icons.skip_previous, color: Colors.white, size: 24),
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
                          tooltip: '下一集',
                          onTap: _next,
                          child: const Icon(Icons.skip_next, color: Colors.white, size: 24),
                        ),
                        _barButton(
                          width: bw,
                          tooltip: _fullscreen ? '退出全屏' : '全屏',
                          onTap: _toggleFullscreen,
                          child: Icon(
                            _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            color: Colors.white,
                            size: 24,
                          ),
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
