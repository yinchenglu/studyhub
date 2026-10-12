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
/// ── 自动跟随为什么不用原生 ─────────────────────────────
/// 反过来，允许「竖屏 + 左横屏 + 右横屏」时，Android 侧会落到
/// `SCREEN_ORIENTATION_USER`：**由系统的传感器逻辑决定左右**，
/// 它的映射天生自洽。我们自己算反而容易错。
///
/// 两侧合起来：**跟随交给 Flutter，锁定交给原生**，各用最不容易出错的那条路。
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
  /// 同时也承担**解锁**的职责：先前的 `SCREEN_ORIENTATION_LOCKED` 会被
  /// 这里新的 `SCREEN_ORIENTATION_USER` 覆盖掉。
  static Future<void> followDevice() async {
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
}
