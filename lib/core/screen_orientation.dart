import 'package:flutter/services.dart';

/// 播放器 / 图片预览用的屏幕方向控制。
///
/// ── 为什么「锁定」要走原生 ─────────────────────────────
/// Flutter 只有 [SystemChrome.setPreferredOrientations]，它接受的是
/// **一个允许方向的集合**，表达不了「就停在这一刻这个方向」——
/// 因为它压根不知道当前是左横屏还是右横屏：
///   * `MediaQuery.orientation` 只区分竖 / 横，不区分左右；
///   * 靠加速度计自己算左右横屏，要依赖传感器三轴的正负号约定，
///     一旦符号搞反，锁出来就是**画面倒转 180°**，比不锁还糟。
/// 所以这里直接用 Android 自己的 `SCREEN_ORIENTATION_LOCKED`，
/// 官方定义就一句话：「Screen is locked to its current rotation, whatever that is.」
/// —— 交给系统去记「当前是哪个方向」，我们不需要知道，也就不会算错。
///
/// ── 自动跟随：v1.5.0 起也走原生 ─────────────────────────
/// 原来这里是「跟随交给 Flutter、锁定交给原生」，理由是 Flutter 的三方向集合
/// 正好对应 Android 的 `SCREEN_ORIENTATION_USER`，映射天生自洽。
/// **但 USER 是「用户当前首选方向」，会尊重系统里的「自动旋转」开关** ——
/// 用户关掉自动旋转之后，视频就不会跟着手机转了（真机上被反馈过）。
/// 现在跟随也交给原生的 `SCREEN_ORIENTATION_SENSOR`（忽略用户的旋转锁），
/// Flutter 那条路只留作原生方法不可用时的降级。
///
/// 两侧合起来：**锁定和跟随都交给原生**，各用语义最准的那个常量。
class ScreenOrientation {
  ScreenOrientation._();

  /// 和 `MainActivity.kt` 里的 `CHANNEL` 必须一致（原本只用来读物理 DPI）。
  static const MethodChannel _ch = MethodChannel('studyhub/display');

  /// 自动模式允许的方向：竖屏 + 左横屏 + 右横屏。
  ///
  /// 故意**不含** `portraitDown` —— 倒着拿手机时画面跟着翻过来只会让人烦躁
  /// （而且 Android 上这个组合正好映射到 `SCREEN_ORIENTATION_USER`，
  /// 也就是「竖屏 + 两个横屏」，和手机的普通自动旋转行为一致）。
  static const List<DeviceOrientation> autoSet = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 打开「跟随手机方向自动翻转」。
  ///
  /// ★ v1.5.0 修的真 bug：这条**必须优先走原生** `SCREEN_ORIENTATION_SENSOR`。
  ///
  /// Flutter 的 `setPreferredOrientations(autoSet)` 在 Android 侧映射到
  /// `SCREEN_ORIENTATION_USER`，而 USER 的定义是「用户当前的首选方向」——
  /// **用户在系统里关掉「自动旋转」后，它就不转了**。
  /// 现实里绝大多数人常年关着自动旋转，于是「视频跟着手机横竖屏切换」
  /// 看起来就跟没做一样（用户反馈的正是这句）。
  ///
  /// `SCREEN_ORIENTATION_SENSOR` 的官方说明是「即使用户锁定基于传感器的旋转，
  /// 系统仍可使用传感器」，这才是我们要的语义。
  ///
  /// 同时也承担**解锁**的职责：先前的 `SCREEN_ORIENTATION_LOCKED` 会被覆盖掉。
  static Future<void> followDevice() async {
    try {
      final ok = await _ch.invokeMethod<bool>('followOrientation');
      if (ok == true) return;
    } catch (_) {
      // 原生侧没有这个方法（非 Android、或 MainActivity 没跟上），走下面的降级。
    }
    try {
      await SystemChrome.setPreferredOrientations(autoSet);
    } catch (_) {
      // 理论上不会失败；真失败了也只是「方向没变」，不该连累播放。
    }
  }

  /// 把屏幕钉死在**当前**朝向。
  ///
  /// [landscape] 只用于原生方法不可用时的降级（见下），正常路径用不到。
  static Future<void> lockHere({required bool landscape}) async {
    try {
      final ok = await _ch.invokeMethod<bool>('lockOrientation');
      if (ok == true) return;
    } catch (_) {
      // 原生侧没有这个方法（非 Android 平台、或 MainActivity 没跟上），
      // 落到下面的降级分支。
    }
    // 降级：至少把方向收窄到「当前所在的那一族」。
    // 代价是横屏时左右还能翻 —— 但总好过整个锁定功能直接失效。
    // 注意这里用 `portraitUp` 而不是 `portraitUp + portraitDown`：
    // 竖屏就老老实实一种，别倒过来。
    try {
      await SystemChrome.setPreferredOrientations(
        landscape
            ? const <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
    } catch (_) {
      // 同上，静默失败。
    }
  }

  /// 回到「只有竖屏」。离开播放器 / 图片预览时调用，把方向还给整个 App。
  static Future<void> restorePortrait() async {
    try {
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
    } catch (_) {}
  }

  /// v1.8.0 新增：切到横屏并**保持横屏**（左右都行）。
  ///
  /// 用途只有一处：播放器打开「宽 > 高」的横屏视频时，按用户要求默认横屏。
  /// 走原生 `SCREEN_ORIENTATION_SENSOR_LANDSCAPE` —— 左右两个横屏都允许，
  /// 手机往哪边转都不会出现画面倒转 180°。
  ///
  /// 降级分支用 `landscapeLeft + landscapeRight`：能转到横屏，
  /// 代价是在系统「自动旋转」关掉时可能不生效（和 followDevice 同一个道理）。
  static Future<void> lockLandscape() async {
    try {
      final ok = await _ch.invokeMethod<bool>('landscapeOrientation');
      if (ok == true) return;
    } catch (_) {
      // 原生侧没这个方法（非 Android 平台、或 MainActivity 没跟上），走降级。
    }
    try {
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
    } catch (_) {}
  }
}
