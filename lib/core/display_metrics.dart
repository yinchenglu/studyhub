import 'dart:math' as math;

import 'package:flutter/services.dart';

/// 读手机屏幕的**真实物理 DPI**（每英寸多少物理像素）。
///
/// ── 为什么要绕到原生去读 ──────────────────────────────
/// 尺子要显示成真实尺寸，就得知道「1 逻辑像素 = 多少英寸」。
/// 看起来很简单的换算是这样的：
///
///     1 逻辑像素 = dpr 个物理像素        （dpr 是 Flutter 给的 devicePixelRatio）
///     1 个物理像素 = 1 / 物理DPI 英寸     （物理DPI 才是面板真实密度）
///     ⇒ 1 逻辑像素 = dpr / 物理DPI 英寸
///
/// 第一项 Flutter 能直接给，第二项给不了 —— 这就是要读原生的原因。
///
/// 常见的错误做法是认死「1 英寸 = 160 逻辑像素，所以 lpcm = 160/2.54 = 63」。
/// 它的来源是 Android 把 `density` 定义成 `densityDpi / 160`，
/// 而 `densityDpi` 是厂商从 240/320/420/480 这些**档位**里挑的标称值，
/// 跟面板真实密度不是一回事。一块真实 6.7 吋 1080x2400 的屏物理密度约 393，
/// 厂商很可能填 420 —— 按标称值算出来的尺子整套偏小 6.9%，
/// 量 30 cm 要差出 2 cm。只有 `DisplayMetrics.xdpi / ydpi` 是驱动上报的真实值。
///
/// ── 返回 null 的情形 ─────────────────────────────────
/// iOS / 桌面 / 读不到 channel / 机型乱报了一个离谱的值 —— 一律返回 null，
/// 由调用方回退到 160/2.54（也就是 Flutter 自己那套近似）。
/// **这个函数永远不抛异常** —— 量尺子这件事不值得让整个页面崩掉。
Future<double?> readPhysicalDpi() async {
  try {
    const ch = MethodChannel('studyhub/display');
    final r = await ch.invokeMethod<Map<Object?, Object?>>('physicalDpi');
    if (r == null) return null;
    final x = (r['xdpi'] as num?)?.toDouble();
    final y = (r['ydpi'] as num?)?.toDouble();
    if (x == null || y == null) return null;
    if (!x.isFinite || !y.isFinite) return null;
    // 合理区间：真机不会低于 100 dpi（那是 1985 年的显示器），
    // 也不会高于 1200 dpi（索尼那台 4K 手机约 806）。落区间外就是乱报。
    if (x < 100 || x > 1200 || y < 100 || y > 1200) return null;
    // 某些面板 x / y 略有差异（次像素排列导致），取几何平均当等效 DPI。
    return math.sqrt(x * y);
  } catch (_) {
    return null;
  }
}

/// Flutter 那套「1 英寸 = 160 逻辑像素」的近似值，每厘米多少逻辑像素。
/// 约等于 62.99。原生 DPI 拿不到时就用它兜底。
const double kFallbackLpcm = 160 / 2.54;

/// 由真实物理 DPI 算出「1 厘米 = 多少逻辑像素」。
///
///     1 逻辑像素 = dpr / physicalDpi 英寸
///     ⇒ 1 英寸    = physicalDpi / dpr 逻辑像素
///     ⇒ 1 厘米    = physicalDpi / dpr / 2.54 逻辑像素
///
/// [dpr] 直接传 `MediaQuery.devicePixelRatio`。
/// 参数不合法（<=0）时返回 [kFallbackLpcm]，不会返回 0 或 NaN ——
/// 因为 0 会导致 `CustomPaint` 的尺寸为 0，尺子直接消失，用户会以为坏了。
double lpcmFromDpi(double physicalDpi, double dpr) {
  if (!physicalDpi.isFinite || !dpr.isFinite) return kFallbackLpcm;
  if (physicalDpi <= 0 || dpr <= 0) return kFallbackLpcm;
  final perInch = physicalDpi / dpr; // 每英寸的逻辑像素数
  if (perInch < 60 || perInch > 600) return kFallbackLpcm;
  return perInch / 2.54;
}
