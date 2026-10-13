// 分层 / 汇总 / 交互 / 传染动力学 的统计核心 —— 纯 Dart，零依赖。
//
// 和 stats.dart 的分工：
//   stats.dart      基础分布（正态 / 卡方 / t / Fisher）与格式化
//   stats_hier.dart 建在它上面的流行病学方法：
//                     · Mantel-Haenszel 合并 OR / RR（含 Robins-Breslow-Greenland 方差）
//                     · Breslow-Day 齐性检验（判断各层 OR 是否一致）
//                     · 加法交互 RERI / 归因比例 API / 协同指数 S
//                     · 泊松精确可信区间（实时再生指数 Rt 用）
//                     · Cori 法实时再生指数
//
// 为什么单独一个文件：这四个方法互相之间要复用（分层分析和交互作用用的是
// 同一套 MH 引擎），而且病例对照 / 队列 / 分层 / 交互四个页面都要调。
// 放一处，改一处，四个页面一起生效。
//
// 所有公式都按公卫教材口径，注释里写清出处，方便以后核对。

import 'dart:math' as math;

import 'stats.dart';

// ===========================================================================
// 1. 单个分层（一个四格表）
// ===========================================================================

/// 一个分层里的四格表。
///
/// 字段含义随研究类型变（这一点必须由 UI 明确告诉用户）：
///   队列 / 食物中毒：a 暴露组发病、b 暴露组未发病、c 非暴露组发病、d 非暴露组未发病
///   病例对照：      a 病例组暴露、b 病例组非暴露、c 对照组暴露、d 对照组非暴露
class Stratum {
  final int a, b, c, d;
  const Stratum(this.a, this.b, this.c, this.d);

  /// 该层总人数
  int get n => a + b + c + d;

  /// 该层是否还能算（至少要有暴露/非暴露各一边有数，否则比值无意义）
  bool get usable => n > 0 && (a + b) > 0 && (c + d) > 0;

  /// 该层的粗 OR = ad / bc
  double get orCrude {
    if (b == 0 || c == 0) {
      // 0 格子的经典处理：分子分母各加 0.5（Haldane 修正），
      // 否则 ad/bc 直接是 Infinity / NaN，后面所有层的合并都会被它带崩
      final a2 = a + 0.5, b2 = b + 0.5, c2 = c + 0.5, d2 = d + 0.5;
      return (a2 * d2) / (b2 * c2);
    }
    return (a * d) / (b * c);
  }

  /// 该层的粗 RR（只有队列 / 食物中毒口径才有意义）
  double get rrCrude {
    final r1 = a + b, r0 = c + d;
    if (r1 == 0 || r0 == 0 || c == 0) return double.nan;
    final p1 = a / r1, p0 = c / r0;
    if (p0 == 0) return double.nan;
    return p1 / p0;
  }

  /// 该层 OR 的 95%CI（Woolf 法：Var(lnOR) = 1/a + 1/b + 1/c + 1/d）
  (double, double) get orCi {
    if (b == 0 || c == 0 || a == 0 || d == 0) {
      final a2 = a + 0.5, b2 = b + 0.5, c2 = c + 0.5, d2 = d + 0.5;
      final lnOr = math.log((a2 * d2) / (b2 * c2));
      final se = math.sqrt(1 / a2 + 1 / b2 + 1 / c2 + 1 / d2);
      return (math.exp(lnOr - 1.96 * se), math.exp(lnOr + 1.96 * se));
    }
    final lnOr = math.log((a * d) / (b * c));
    final se = math.sqrt(1 / a + 1 / b + 1 / c + 1 / d);
    return (math.exp(lnOr - 1.96 * se), math.exp(lnOr + 1.96 * se));
  }
}

// ===========================================================================
// 2. Mantel-Haenszel 合并估计
// ===========================================================================

/// 分层分析的完整结果。
class MhResult {
  /// 参与合并的层数（usable 的那些）
  final int k;

  /// 被跳过的层数（四格表不完整）
  final int skipped;

  /// MH 合并 OR（病例对照用）
  final double orMh;

  /// MH 合并 OR 的 95%CI（Robins-Breslow-Greenland 方差）
  final double orLo, orHi;

  /// MH 合并 RR（队列用）
  final double rrMh;
  final double rrLo, rrHi;

  /// 把各层直接相加得到的「粗」估计 —— 用来和校正后的比，看有没有混杂
  final double orCrude, rrCrude;

  /// Breslow-Day 齐性检验（针对 OR）
  final double bdChi2;
  final int bdDf;
  final double bdP;

  /// 各层的 OR（用于展示）
  final List<double> layerOr;

  const MhResult({
    required this.k,
    required this.skipped,
    required this.orMh,
    required this.orLo,
    required this.orHi,
    required this.rrMh,
    required this.rrLo,
    required this.rrHi,
    required this.orCrude,
    required this.rrCrude,
    required this.bdChi2,
    required this.bdDf,
    required this.bdP,
    required this.layerOr,
  });

  /// 有没有明显的混杂：粗估计和校正估计差得比较远。
  ///
  /// 判据用「相对变化 > 10%」—— 这是流行病学里约定俗成的门槛
  /// （Rothman: 一般认为 OR 变化超过 10% 就说明存在混杂）。
  bool get confounding {
    if (!orCrude.isFinite || !orMh.isFinite || orMh == 0) return false;
    return ((orCrude - orMh).abs() / orMh) > 0.10;
  }

  /// 各层 OR 是否一致（齐性）
  bool get homogeneous => bdP >= 0.05;
}

/// 分层合并（Mantel-Haenszel）。
///
/// 公式出处：Rothman, Greenland & Lash《Modern Epidemiology》第 3 版 第 15 章。
///
/// 只有 OR 和 RR 都算了：病例对照只能报 OR，队列两种都能报，
/// 具体展示哪个由页面决定（这里一并算出来，省得调用方再走一趟）。
MhResult mhAnalyze(List<Stratum> strata) {
  final used = <Stratum>[];
  var skipped = 0;
  for (final s in strata) {
    if (s.usable) {
      used.add(s);
    } else {
      skipped++;
    }
  }

  if (used.isEmpty) {
    return const MhResult(
      k: 0, skipped: 0,
      orMh: double.nan, orLo: double.nan, orHi: double.nan,
      rrMh: double.nan, rrLo: double.nan, rrHi: double.nan,
      orCrude: double.nan, rrCrude: double.nan,
      bdChi2: double.nan, bdDf: 0, bdP: double.nan,
      layerOr: <double>[],
    );
  }

  // ---- 粗估计：先把各层相加成一个总表 ----
  var ta = 0, tb = 0, tc = 0, td = 0;
  for (final s in used) {
    ta += s.a; tb += s.b; tc += s.c; td += s.d;
  }
  final total = Stratum(ta, tb, tc, td);

  // ---- MH 合并 OR ----
  //   OR_MH = Σ(aᵢdᵢ/nᵢ) / Σ(bᵢcᵢ/nᵢ)
  var p = 0.0; // Σ a d / n
  var q = 0.0; // Σ b c / n
  // Robins-Breslow-Greenland 方差需要的四个和
  var r1 = 0.0, r2 = 0.0, r3 = 0.0, r4 = 0.0;
  for (final s in used) {
    final n = s.n.toDouble();
    final ad = s.a * s.d.toDouble();
    final bc = s.b * s.c.toDouble();
    p += ad / n;
    q += bc / n;
    r1 += (s.a + s.d) * ad / (n * n);
    r2 += (s.a + s.d) * bc / (n * n);
    r3 += (s.b + s.c) * ad / (n * n);
    r4 += (s.b + s.c) * bc / (n * n);
  }

  double orMh = double.nan, orLo = double.nan, orHi = double.nan;
  if (p > 0 && q > 0) {
    orMh = p / q;
    final v = 0.5 *
        (r1 / (p * p) + r2 / (p * q) + r3 / (p * q) + r4 / (q * q));
    if (v > 0) {
      final se = math.sqrt(v);
      final ln = math.log(orMh);
      orLo = math.exp(ln - 1.96 * se);
      orHi = math.exp(ln + 1.96 * se);
    }
  }

  // ---- MH 合并 RR ----
  //   RR_MH = Σ[aᵢ(cᵢ+dᵢ)/nᵢ] / Σ[cᵢ(aᵢ+bᵢ)/nᵢ]
  //   Var(ln RR_MH) = [Σ n1ᵢn0ᵢm1ᵢ/nᵢ² − Σ aᵢcᵢ/nᵢ] / (R·S)   (Greenland-Robins)
  var rrR = 0.0, rrS = 0.0, rrNum = 0.0;
  for (final s in used) {
    final n = s.n.toDouble();
    final n1 = (s.a + s.b).toDouble(); // 暴露组人数
    final n0 = (s.c + s.d).toDouble(); // 非暴露组人数
    final m1 = (s.a + s.c).toDouble(); // 发病总数
    rrR += s.a * n0 / n;
    rrS += s.c * n1 / n;
    rrNum += (n1 * n0 * m1) / (n * n) - (s.a * s.c) / n;
  }
  double rrMh = double.nan, rrLo = double.nan, rrHi = double.nan;
  if (rrR > 0 && rrS > 0) {
    rrMh = rrR / rrS;
    final v = rrNum / (rrR * rrS);
    if (v > 0) {
      final se = math.sqrt(v);
      final ln = math.log(rrMh);
      rrLo = math.exp(ln - 1.96 * se);
      rrHi = math.exp(ln + 1.96 * se);
    }
  }

  // ---- Breslow-Day 齐性检验 ----
  final bd = _breslowDay(used, orMh);

  return MhResult(
    k: used.length,
    skipped: skipped,
    orMh: orMh, orLo: orLo, orHi: orHi,
    rrMh: rrMh, rrLo: rrLo, rrHi: rrHi,
    orCrude: total.orCrude, rrCrude: total.rrCrude,
    bdChi2: bd.$1, bdDf: bd.$2, bdP: bd.$3,
    layerOr: used.map((s) => s.orCrude).toList(),
  );
}

/// Breslow-Day 检验：各层 OR 是否同质。
///
/// 思路：假设各层真的共用同一个 OR（就用 MH 合并出来的那个 ψ），
/// 那么每一层在**固定边际**下，a 的期望值 E 是唯一确定的 ——
/// 解方程 a·d = ψ·b·c 得一个一元二次方程（d、b、c 都能用 a 和边际表示）。
/// 然后统计量 Σ(a−E)²/Var 近似 χ²(k−1)。
///
/// 返回 (χ², df, P)。
(double, int, double) _breslowDay(List<Stratum> used, double psi) {
  if (used.length < 2 || !psi.isFinite || psi <= 0) {
    return (double.nan, 0, double.nan);
  }
  var chi2 = 0.0;
  for (final s in used) {
    final n1 = (s.a + s.b).toDouble(); // 第一行合计
    final n0 = (s.c + s.d).toDouble(); // 第二行合计
    final m1 = (s.a + s.c).toDouble(); // 第一列合计
    // 解 (1−ψ)x² + (n0 − m1 + ψ(n1 + m1))x − ψ·n1·m1 = 0
    final A = 1 - psi;
    final B = n0 - m1 + psi * (n1 + m1);
    final C = -psi * n1 * m1;
    double e;
    if (A.abs() < 1e-12) {
      // ψ = 1 时退化成一次方程
      e = -C / B;
    } else {
      final disc = B * B - 4 * A * C;
      if (disc < 0) continue; // 这一层解不出期望值，跳过（不污染统计量）
      final sq = math.sqrt(disc);
      final x1 = (-B + sq) / (2 * A);
      final x2 = (-B - sq) / (2 * A);
      // 取落在合法区间里的那个根
      final lo = math.max(0.0, m1 - n0);
      final hi = math.min(n1, m1);
      final cands = <double>[x1, x2].where((v) => v >= lo - 1e-9 && v <= hi + 1e-9).toList();
      if (cands.isEmpty) {
        e = (lo + hi) / 2; // 数值兜底：取区间中点
      } else {
        // 两个根都在区间里时取使 OR 更接近 ψ 的那个（离观测更合理的那个）
        e = cands.first;
      }
    }
    if (!e.isFinite) continue;
    final bb = n1 - e;
    final cc = m1 - e;
    final dd = n0 - m1 + e;
    if (e <= 0 || bb <= 0 || cc <= 0 || dd <= 0) continue;
    final varE = 1 / (1 / e + 1 / bb + 1 / cc + 1 / dd);
    if (!varE.isFinite || varE <= 0) continue;
    final d = s.a - e;
    chi2 += d * d / varE;
  }
  if (!chi2.isFinite) return (double.nan, 0, double.nan);
  final df = used.length - 1;
  return (chi2, df, chi2Upper(chi2, df));
}

// ===========================================================================
// 3. 交互作用（加法 / 乘法）
// ===========================================================================

/// 四组暴露组合的原始数据。
///
/// 用「病例对照」口径（最常用）：每组给「病例数 / 对照数」。
/// 队列口径也一样能用 —— 把「对照数」换成「非发病数」，算出来的 OR 含义相同。
class InteractionInput {
  /// A+B+（双暴露）病例数 / 非病例数
  final int a11, n11;
  /// A+B−（只有 A）
  final int a10, n10;
  /// A−B+（只有 B）
  final int a01, n01;
  /// A−B−（双不暴露，参照组）
  final int a00, n00;
  const InteractionInput({
    required this.a11, required this.n11,
    required this.a10, required this.n10,
    required this.a01, required this.n01,
    required this.a00, required this.n00,
  });
}

/// 交互作用分析结果。
class InteractionResult {
  final double or11, or10, or01;
  /// 加法交互：相对超额危险度 RERI = OR11 − OR10 − OR01 + 1
  final double reri;
  /// 归因比例 API = RERI / OR11
  final double api;
  /// 协同指数 S = (OR11−1) / ((OR10−1)+(OR01−1))
  final double s;
  /// 乘法交互比 = OR11 / (OR10 · OR01)
  final double multRatio;

  const InteractionResult({
    required this.or11, required this.or10, required this.or01,
    required this.reri, required this.api, required this.s,
    required this.multRatio,
  });

  /// 加法交互的类型
  String get additiveType {
    if (!reri.isFinite) return '—';
    if (reri > 0) return '协同（正交互）';
    if (reri < 0) return '拮抗（负交互）';
    return '无加法交互';
  }

  /// 乘法交互的类型
  String get multiplicativeType {
    if (!multRatio.isFinite) return '—';
    if (multRatio > 1.05) return '协同（正交互）';
    if (multRatio < 0.95) return '拮抗（负交互）';
    return '基本无乘法交互';
  }
}

/// 算 OR（带 0 格子修正）。
double _or(int cases, int n, int refCases, int refN) {
  final b = n - cases;
  final refD = refN - refCases;
  if (cases == 0 || b == 0 || refCases == 0 || refD == 0) {
    // 有 0 格子就 Haldane 修正（各加 0.5），否则 OR 会变成 0 或无穷，
    // RERI 那边一减就全乱了
    final c = cases + 0.5, bb = b + 0.5, rc = refCases + 0.5, rd = refD + 0.5;
    return (c * rd) / (bb * rc);
  }
  return (cases * refD) / (b * refCases);
}

/// 交互作用指标。以 A−B− 为参照组计算三个 OR。
///
/// RERI（Relative Excess Risk due to Interaction）是加法交互的标准指标，
/// 学术上也叫 ICR（interaction contrast）。判读：
///   RERI > 0 两因素协同、< 0 拮抗、= 0 无加法交互。
/// API = RERI / OR11 是「归因于交互的比例」；
/// S 是协同指数（Rothman 的 synergy index），> 1 协同、< 1 拮抗。
///
/// 说明：RERI 的可信区间需要 delta 法或 bootstrap，这里只给点估计 +
/// 乘法交互比 —— 报告里一般也确实先看点估计定方向。页面上写清楚了。
InteractionResult analyzeInteraction(InteractionInput x) {
  final or11 = _or(x.a11, x.n11, x.a00, x.n00);
  final or10 = _or(x.a10, x.n10, x.a00, x.n00);
  final or01 = _or(x.a01, x.n01, x.a00, x.n00);
  final reri = or11 - or10 - or01 + 1;
  final api = or11 == 0 ? double.nan : reri / or11;
  final denom = (or10 - 1) + (or01 - 1);
  final s = denom == 0 ? double.nan : (or11 - 1) / denom;
  final multHit = or10 * or01;
  final multRatio = multHit == 0 ? double.nan : or11 / multHit;
  return InteractionResult(
    or11: or11, or10: or10, or01: or01,
    reri: reri, api: api, s: s, multRatio: multRatio,
  );
}

// ===========================================================================
// 4. 泊松精确可信区间
// ===========================================================================

/// 卡方分布分位数（二分法求根）。
///
/// 为什么不写解析近似（Wilson-Hilferty 那套）：df 在这里都是 2k 这种小值，
/// 近似式在最需要它的地方（k 很小）误差最大；而 chi2Cdf 本身已经有现成的，
/// 二分 200 次也就微秒级，稳。
double chi2Inv(double p, int df) {
  if (df <= 0) return double.nan;
  if (p <= 0) return 0;
  if (p >= 1) return double.infinity;
  var lo = 0.0;
  var hi = math.max(50.0, df * 4.0);
  // 先把上界撑到足够大
  var guard = 0;
  while (chi2Cdf(hi, df) < p && guard < 100) {
    hi *= 1.6;
    guard++;
  }
  for (var i = 0; i < 200; i++) {
    final mid = (lo + hi) / 2;
    if (chi2Cdf(mid, df) < p) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lo + hi) / 2;
}

/// 观测到 [k] 次事件时，泊松均值的精确 95% 可信区间（Garwood 法）。
///
///   下限 = χ²_{0.025}(2k) / 2      （k = 0 时下限就是 0）
///   上限 = χ²_{0.975}(2k+2) / 2
///
/// 实时再生指数要拿它把「当天病例数的抽样误差」传成 Rt 的区间。
(double, double) poissonCi(int k, [double level = 0.95]) {
  if (k < 0) return (double.nan, double.nan);
  final alpha = 1 - level;
  final lo = k == 0 ? 0.0 : chi2Inv(alpha / 2, 2 * k) / 2;
  final hi = k == 0
      ? chi2Inv(1 - alpha / 2, 2) / 2
      : chi2Inv(1 - alpha / 2, 2 * k + 2) / 2;
  return (lo, hi);
}

// ===========================================================================
// 5. 实时再生指数 Rt（Cori 法）
// ===========================================================================

/// 把「序列间隔」离散成一个权重序列。
///
/// 序列间隔（serial interval）用伽马分布近似，均值 [mean]、标准差 [sd]。
/// 形状参数 shape = (μ/σ)²，率参数 rate = μ/σ²，这是矩估计的标准做法。
/// 最后做归一化 —— 权重必须是概率，加起来等于 1。
///
/// 长度封顶 365 天：μ + 4σ 在 σ 填得很大时能到几百万，
/// 不封顶会直接把界面卡死（真实场景里序列间隔不会有半年以上），
/// 所以这里取 [10, 365] 之间的值。
List<double> serialIntervalWeights(double mean, double sd) {
  if (mean <= 0 || sd <= 0) return const <double>[1.0];
  final shape = (mean / sd) * (mean / sd);
  final rate = mean / (sd * sd);
  final len = math.min(365, math.max(10, (mean + 4 * sd).round()));
  final raw = <double>[];
  var sum = 0.0;
  for (var s = 1; s <= len; s++) {
    // 伽马 pdf 的对数形式，避免直接算 gammaln 之外的溢出
    final lp = shape * math.log(rate) +
        (shape - 1) * math.log(s.toDouble()) -
        rate * s -
        gammaLn(shape);
    final w = lp < -700 ? 0.0 : math.exp(lp);
    raw.add(w);
    sum += w;
  }
  if (sum <= 0) return const <double>[1.0];
  return raw.map((v) => v / sum).toList();
}

/// 一天的 Rt 结果。
class RtPoint {
  /// 第几天（第 1 天 = 序列里第一条数据的日期）
  final int day;
  /// 当天的原始新增数
  final int cases;
  /// 最近 7 天的新增数移动平均（给画图/看趋势用）
  final double ma7;
  /// Rt
  final double rt;
  final double lo, hi;

  const RtPoint({
    required this.day,
    required this.cases,
    required this.ma7,
    required this.rt,
    required this.lo,
    required this.hi,
  });

  bool get available => rt.isFinite;
}

/// 用 Cori 法逐日估 Rt。
///
///   Rt = I_t / Λ_t，Λ_t = Σ_{s=1..W} w_s · I_{t−s}
///
/// 其中 w 是序列间隔权重（窗口内重新归一化），W 是滑动窗口。
/// 直觉：今天的病例是前几天那些病例「传染出来」的，
/// 分母就是「按传染力加权的前几天病例数」，两者一比就是每代传播数。
///
/// 可信区间由分母固定、分子服从泊松分布推出来 —— 也就是把当天的
/// 病例数当成一次泊松观测，用精确区间除以 Λ_t。
///
/// [cases] 必须按时间从早到晚排列。
List<RtPoint> estimateRt(
  List<int> cases, {
  double serialMean = 7,
  double serialSd = 3,
  int window = 7,
}) {
  final w = serialIntervalWeights(serialMean, serialSd);
  final out = <RtPoint>[];
  final n = cases.length;
  for (var t = 0; t < n; t++) {
    // 7 天移动平均（不足 7 天就用已有的）
    final from = math.max(0, t - 6);
    var sumMa = 0;
    for (var i = from; i <= t; i++) {
      sumMa += cases[i];
    }
    final ma7 = sumMa / (t - from + 1);

    // Λ_t：只用窗口内、并且有数据的那些滞后
    var lam = 0.0;
    var wsum = 0.0;
    for (var s = 1; s <= window; s++) {
      final idx = t - s;
      if (idx < 0) break;
      final ws = s - 1 < w.length ? w[s - 1] : 0.0;
      lam += ws * cases[idx];
      wsum += ws;
    }
    if (wsum > 0 && lam > 0) {
      // 归一化：只用到了窗口内的一部分权重，得按实际用到的那些重新归一
      lam = lam / wsum;
    } else {
      lam = 0;
    }

    double rt = double.nan, lo = double.nan, hi = double.nan;
    if (lam > 0) {
      rt = cases[t] / lam;
      final ci = poissonCi(cases[t]);
      lo = ci.$1 / lam;
      hi = ci.$2 / lam;
    }
    out.add(RtPoint(
      day: t + 1,
      cases: cases[t],
      ma7: ma7,
      rt: rt,
      lo: lo,
      hi: hi,
    ));
  }
  return out;
}

/// 把 Rt 序列的趋势说成一句人话。
String rtTrendText(List<RtPoint> pts) {
  final valid = pts.where((p) => p.available).toList();
  if (valid.length < 2) return '数据太少，看不出趋势';
  // 取最后几天平均，和再往前几天比 —— 单点噪声太大
  final tail = valid.length >= 5
      ? valid.sublist(valid.length - 3)
      : valid.sublist(valid.length - 1);
  final prevFrom = math.max(0, valid.length - 7);
  final prevTo = math.max(1, valid.length - 3);
  if (prevTo <= prevFrom) return '数据太少，看不出趋势';
  final prev = valid.sublist(prevFrom, prevTo);
  var a = 0.0;
  for (final p in tail) {
    a += p.rt;
  }
  var b = 0.0;
  for (final p in prev) {
    b += p.rt;
  }
  a /= tail.length;
  b /= prev.length;
  final diff = a - b;
  if (diff > 0.08) return '近几天 Rt 在抬头（上升）';
  if (diff < -0.08) return '近几天 Rt 在回落（下降）';
  return '近几天 Rt 基本平稳';
}

// ===========================================================================
// 6. 杀虫剂流量计算
// ===========================================================================

/// 消杀作业时，喷药设备应该设置的流量。
///
/// 现场口径（消杀 / 爱国卫生运动里最常见的一套算法）：
///   单位面积用药量 = 目标用药量 (ml/m²)
///   每秒处理面积   = 喷幅 (m) × 行进速度 (m/s)
///   → 需要流量 (ml/s) = 目标用药量 × 喷幅 × 行进速度
///
/// 由此再换算成 ml/min、m²/min、L/ha。
class SprayFlowResult {
  /// 需要的流量 ml/s
  final double mlPerSec;
  /// ml/min
  final double mlPerMin;
  /// L/h（现场配药最常用，一桶多少升能喷多久靠它）
  final double lPerHour;
  /// 每秒处理面积 m²/s
  final double m2PerSec;
  /// 每分钟处理面积 m²/min
  final double m2PerMin;
  /// 每分钟处理面积折合公顷/分钟（1 ha = 10000 m²）
  final double haPerMin;
  /// 每公顷用药量（L/ha）= 目标用药量 × 10000 / 1000
  final double lPerHa;

  const SprayFlowResult({
    required this.mlPerSec,
    required this.mlPerMin,
    required this.lPerHour,
    required this.m2PerSec,
    required this.m2PerMin,
    required this.haPerMin,
    required this.lPerHa,
  });
}

SprayFlowResult sprayFlow({
  required double doseMlPerM2,
  required double swathM,
  required double speedMps,
}) {
  final m2s = swathM * speedMps;
  final mlS = doseMlPerM2 * m2s;
  return SprayFlowResult(
    mlPerSec: mlS,
    mlPerMin: mlS * 60,
    lPerHour: mlS * 3600 / 1000,
    m2PerSec: m2s,
    m2PerMin: m2s * 60,
    haPerMin: m2s * 60 / 10000,
    lPerHa: doseMlPerM2 * 10000 / 1000,
  );
}
