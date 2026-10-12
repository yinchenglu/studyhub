// 统计分布与检验工具 —— 纯 Dart，零依赖。
//
// 为什么单独放一个文件、而不塞进工具页：
// 公卫那套工具（病例对照 / 队列 / 食物中毒 / logistic 回归 / 样本量）
// 全都要算 P 值、置信区间，这些算法重复用、且必须互相一致。
// 放一处，改一处，所有工具一起生效。
//
// 涉及的分布：
//   * 标准正态：CDF / 分位数（估样本量、算 CI、把 z 换成 P）
//   * 卡方：上尾概率（2×2 表的关联性检验）
//   * 学生 t：双尾 / 单尾（均数比较、回归系数的显著性）
//   * 不完全贝塔 / 不完全伽马：上面两个分布的地基
//   * Fisher 精确检验：小样本 2×2 表（卡方不可靠时用它）
//
// 所有数值算法都是 Numerical Recipes 那套经典实现，
// 精度足够公卫现场用（1e-7 量级），而且**不引任何第三方包**
// —— 这个项目对依赖极其敏感，能自己算的一律自己算。

import 'dart:math' as math;

const double _kSqrt2 = 1.4142135623730951;

// ===========================================================================
// 1. 标准正态
// ===========================================================================

/// 误差函数 erf(x)，Abramowitz & Stegun 7.1.26，绝对误差约 1.5e-7。
double _erf(double x) {
  final sign = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  const p = 0.3275911;
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  final t = 1.0 / (1.0 + p * ax);
  final y = 1.0 -
      (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-ax * ax);
  return sign * y;
}

/// 标准正态分布函数 Φ(z) = P(Z ≤ z)
double normCdf(double z) => 0.5 * (1 + _erf(z / _kSqrt2));

/// 标准正态上尾概率 P(Z > z)
double normUpper(double z) => 1 - normCdf(z);

/// 双尾 P 值：P(|Z| > |z|)
double normTwoTail(double z) => 2 * normUpper(z.abs());

/// 标准正态分位数 Φ⁻¹(p)。Acklam 有理逼近，精度约 1.15e-9。
///
/// p 必须是 (0,1) 开区间；越界直接夹住，免得调用方拿到 NaN 还以为是算法错了。
double normInv(double p) {
  if (p <= 0) return double.negativeInfinity;
  if (p >= 1) return double.infinity;

  const a = <double>[
    -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
    1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00,
  ];
  const b = <double>[
    -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
    6.680131188771972e+01, -1.328068155288572e+01,
  ];
  const c = <double>[
    -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
    -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00,
  ];
  const d = <double>[
    7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
    3.754408661907416e+00,
  ];
  const pLow = 0.02425;
  const pHigh = 1 - pLow;

  double x;
  if (p < pLow) {
    final q = math.sqrt(-2 * math.log(p));
    x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  } else if (p <= pHigh) {
    final q = p - 0.5;
    final r = q * q;
    x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) *
        q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
  } else {
    final q = math.sqrt(-2 * math.log(1 - p));
    x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  }

  // 一步 Halley 修正，把误差压到接近机器精度
  final e = normCdf(x) - p;
  final u = e * 2.5066282746310002 * math.exp(x * x / 2);
  return x - u / (1 + x * u / 2);
}

// ===========================================================================
// 2. 伽马函数与不完全伽马（卡方分布的地基）
// ===========================================================================

const List<double> _kLanczos = <double>[
  76.18009172947146, -86.50532032941677, 24.01409824083091,
  -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5,
];

/// ln Γ(x)
double gammaLn(double x) {
  var y = x;
  var tmp = x + 5.5;
  tmp -= (x + 0.5) * math.log(tmp);
  var ser = 1.000000000190015;
  for (var j = 0; j < 6; j++) {
    y += 1;
    ser += _kLanczos[j] / y;
  }
  return -tmp + math.log(2.5066282746310005 * ser / x);
}

/// 正则化不完全伽马上尾 Q(a,x) = 1 - P(a,x)
double gammaQ(double a, double x) {
  if (x <= 0) return 1;
  if (x < a + 1) {
    // 级数展开求下尾 P，再用 1-P
    var ap = a;
    var sum = 1.0 / a;
    var del = sum;
    for (var n = 1; n <= 500; n++) {
      ap += 1;
      del *= x / ap;
      sum += del;
      if (del.abs() < sum.abs() * 1e-15) break;
    }
    return 1 - sum * math.exp(-x + a * math.log(x) - gammaLn(a));
  }
  // 连分数求上尾 Q
  const tiny = 1e-300;
  var b = x + 1 - a;
  var c = 1 / tiny;
  var d = 1 / b;
  var h = d;
  for (var i = 1; i <= 500; i++) {
    final an = -i * (i - a);
    b += 2;
    d = an * d + b;
    if (d.abs() < tiny) d = tiny;
    c = b + an / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final del = d * c;
    h *= del;
    if ((del - 1).abs() < 1e-15) break;
  }
  return math.exp(-x + a * math.log(x) - gammaLn(a)) * h;
}

/// 卡方分布上尾概率 P(χ² > x)，df 自由度
double chi2Upper(double x, int df) {
  if (df <= 0) return double.nan;
  if (x <= 0) return 1;
  return gammaQ(df / 2, x / 2);
}

/// 卡方分布下尾（= 累积分布）
double chi2Cdf(double x, int df) => 1 - chi2Upper(x, df);

// ===========================================================================
// 3. 不完全贝塔与学生 t
// ===========================================================================

double _betacf(double a, double b, double x) {
  const tiny = 1e-300;
  final qab = a + b;
  final qap = a + 1;
  final qam = a - 1;
  var c = 1.0;
  var d = 1 - qab * x / qap;
  if (d.abs() < tiny) d = tiny;
  d = 1 / d;
  var h = d;
  for (var m = 1; m <= 300; m++) {
    final m2 = 2 * m;
    var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
    d = 1 + aa * d;
    if (d.abs() < tiny) d = tiny;
    c = 1 + aa / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    h *= d * c;
    aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
    d = 1 + aa * d;
    if (d.abs() < tiny) d = tiny;
    c = 1 + aa / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final del = d * c;
    h *= del;
    if ((del - 1).abs() < 1e-15) break;
  }
  return h;
}

/// 正则化不完全贝塔函数 I_x(a,b)
double betai(double a, double b, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final bt = math.exp(gammaLn(a + b) -
      gammaLn(a) -
      gammaLn(b) +
      a * math.log(x) +
      b * math.log(1 - x));
  if (x < (a + 1) / (a + b + 2)) return bt * _betacf(a, b, x) / a;
  return 1 - bt * _betacf(b, a, 1 - x) / b;
}

/// 学生 t 分布双尾 P 值 P(|T| > |t|)，df 自由度
double tTwoTail(double t, double df) {
  if (df <= 0) return double.nan;
  final x = df / (df + t * t);
  return betai(df / 2, 0.5, x);
}

/// 学生 t 分布单尾 P 值 P(T > t)
double tUpper(double t, double df) =>
    t >= 0 ? tTwoTail(t, df) / 2 : 1 - tTwoTail(t, df) / 2;

// ===========================================================================
// 4. Fisher 精确检验（2×2 表，小样本用）
// ===========================================================================

/// Fisher 精确检验的两尾 P 值。
///
/// 四格表 a b / c d。用超几何分布，把「概率 ≤ 观测概率」的所有表加起来。
/// 样本量小（任一格 < 5）或卡方期望频数 < 5 时，卡方不可靠，必须用它。
double fisherTwoTail(int a, int b, int c, int d) {
  if (a < 0 || b < 0 || c < 0 || d < 0) return double.nan;
  final r1 = a + b;
  final r2 = c + d;
  final c1 = a + c;
  final n = r1 + r2;
  if (n == 0) return double.nan;

  // 注意 toDouble()：Dart 不会把 int 隐式转成 double，
  // gammaLn 的参数是 double，直接传 k+1（int）编译不过。
  double lnFact(int k) => gammaLn((k + 1).toDouble());
  final lnDenom = lnFact(r1) + lnFact(r2) + lnFact(c1) + lnFact(n - c1) - lnFact(n);

  double prob(int x) {
    final y = r1 - x;
    final z = c1 - x;
    final w = r2 - z;
    if (y < 0 || z < 0 || w < 0) return 0;
    return math.exp(lnDenom -
        (lnFact(x) + lnFact(y) + lnFact(z) + lnFact(w)));
  }

  final pObs = prob(a);
  var total = 0.0;
  final lo = math.max(0, c1 - r2);
  final hi = math.min(r1, c1);
  for (var x = lo; x <= hi; x++) {
    final p = prob(x);
    // 加一点容差，避免浮点误差把和观测概率相等的表漏掉
    if (p <= pObs * (1 + 1e-9)) total += p;
  }
  return total.clamp(0.0, 1.0);
}

// ===========================================================================
// 5. 常用统计量
// ===========================================================================

/// 均数
double mean(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// 样本标准差（n-1 分母）；样本 < 2 返回 0
double sd(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = mean(xs);
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

/// 线性插值法分位数（与 Excel PERCENTILE.INC 一致），p 取 0~1
double percentile(List<double> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final v = List<double>.from(xs)..sort();
  if (v.length == 1) return v.first;
  final rank = (v.length - 1) * p.clamp(0.0, 1.0);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return v[lo];
  return v[lo] + (v[hi] - v[lo]) * (rank - lo);
}

/// 把 P 值格式化成给人看的样子。
///
/// 公卫报告里 P 只写到三位有效小数，小于 0.001 一律写「<0.001」，
/// 直接把 3.2e-17 甩出来没人看得懂。
String fmtP(double p) {
  if (p.isNaN) return '—';
  if (p < 0.001) return '<0.001';
  return p.toStringAsFixed(3);
}

/// 保留 n 位小数的通用格式化，NaN/Infinity 显示成「—」
String fmtNum(double? v, [int digits = 2]) {
  if (v == null || v.isNaN || v.isInfinite) return '—';
  return v.toStringAsFixed(digits);
}

/// 把 95% 可信区间写成「下限 ~ 上限」
String fmtCi(double lo, double hi, [int digits = 2]) =>
    '${fmtNum(lo, digits)} ~ ${fmtNum(hi, digits)}';
