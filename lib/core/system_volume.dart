import 'package:flutter/services.dart';

/// 系统媒体音量（Android）。
///
/// 为什么需要它：media_kit 的 `Player.setVolume(v)` 是**乘在系统音量之上**的系数。
/// 手机媒体音量只有 30% 时，播放器系数调到 100% 也还是 30% 的响度 ——
/// 用户必须先按手机侧面的音量键把系统音量顶上去，在 App 里怎么划都到不了最大。
/// 用户 v1.6.0 第 1 条明确要求「不按音量键也能把音量开到最大」，
/// 所以这里直接读写 `AudioManager.STREAM_MUSIC`。
///
/// 原生实现在 `android_custom/MainActivity.kt` 的 `studyhub/audio` 通道：
///   * `getMusicVolume()` → 0~100 的百分比（double），通道不可用时返回 null
///   * `setMusicVolume(percent: int)` → bool
///
/// 注意：**通道不可用时必须能优雅退化**（比如在非 Android 平台跑、或原生没编进去）。
/// 所有方法都吞掉异常并返回 null / false，调用方据此决定是否退回 `setVolume`。
class SystemVolume {
  SystemVolume._();

  static const MethodChannel _ch = MethodChannel('studyhub/audio');

  /// 读当前媒体音量，返回 0~100 的百分比；拿不到返回 null。
  static Future<double?> getPercent() async {
    try {
      final v = await _ch.invokeMethod<num>('getMusicVolume');
      if (v == null) return null;
      return v.toDouble().clamp(0.0, 100.0);
    } catch (_) {
      return null;
    }
  }

  /// 把媒体音量设成 0~100 的百分比。成功返回 true。
  static Future<bool> setPercent(double percent) async {
    try {
      final ok = await _ch.invokeMethod<bool>('setMusicVolume', <String, dynamic>{
        'percent': percent.round().clamp(0, 100),
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
