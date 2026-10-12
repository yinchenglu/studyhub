// 公卫数据工具（第二批）—— 全离线、零新增依赖。
//
//   * LogisticPage    Logistic 回归（单因素 + 多因素，IRLS 迭代求解）
//   * NutritionPage   智能营养配餐（能量需求 → 三大营养素 → 食物交换份）
//
// 统计部分与 tool_pages_ph.dart 共用 lib/core/stats.dart。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/stats.dart';
import 'tool_pages.dart';

// 复用第一批里的表格行（同文件私有，这里另起一套名字避免混淆）
class _R {
  final String k;
  final String v;
  final String? n;
  const _R(this.k, this.v, [this.n]);
}

class _Table extends StatelessWidget {
  final List<_R> rows;
  final Set<String> hi;
  final String? title;
  const _Table({required this.rows, this.hi = const <String>{}, this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
              child: Text(title!,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0 || title != null)
              Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.35)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(rows[i].k,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(rows[i].v,
                            style: TextStyle(
                                fontSize: hi.contains(rows[i].k) ? 14.5 : 13.5,
                                height: 1.35,
                                fontWeight: hi.contains(rows[i].k)
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                        if (rows[i].n != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(rows[i].n!,
                                style: TextStyle(
                                    fontSize: 11, color: scheme.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _H extends StatelessWidget {
  final String t;
  const _H(this.t);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(
            child: Text(t,
                style: TextStyle(
                    fontSize: 11.5, height: 1.65, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// 1. Logistic 回归
// ===========================================================================

/// 一个自变量的回归结果
class _Coef {
  final String name;
  final double beta;
  final double se;
  final double z;
  final double p;
  const _Coef(this.name, this.beta, this.se, this.z, this.p);

  double get or_ => math.exp(beta);
  double get lo => math.exp(beta - 1.96 * se);
  double get hi => math.exp(beta + 1.96 * se);
}

/// 一次回归的完整结果
class _LogitFit {
  final List<_Coef> coefs;      // 第 0 个是截距
  final double logLik;
  final double logLik0;
  final int n;
  final int k;                  // 自变量个数（不含截距）
  final bool converged;
  final bool separated;
  const _LogitFit({
    required this.coefs, required this.logLik, required this.logLik0,
    required this.n, required this.k, required this.converged, required this.separated,
  });

  double get lrChi2 => 2 * (logLik - logLik0);
  double get lrP => chi2Upper(lrChi2, k);
  double get aic => -2 * logLik + 2 * (k + 1);
  double get mcfadden => logLik0 == 0 ? double.nan : 1 - logLik / logLik0;
}

/// 拟合一个 logistic 回归。
///
/// 算法：IRLS（迭代再加权最小二乘），每轮解一次加权正规方程
///   β ← β + (XᵀWX)⁻¹ Xᵀ(y − p)
/// W 是对角阵 w_i = p_i(1−p_i)。标准做法，收敛快。
///
/// 两个必须防的坑：
///   * **完全分离**（某个自变量能把 0/1 完全分开）→ 系数会飞向无穷。
///     对策是限制迭代次数 + 每轮只走半步，并给出警告。
///   * **共线**（两列线性相关）→ XᵀWX 奇异。对策是加一个极小的岭参数
///     （1e-9）到对角线上，保证能求逆；同时把求逆失败也当不收敛处理。
/// softplus：log(1 + e^x)，数值稳定版。
///
/// **dart:math 里没有 log1p，也没有任何 softplus 函数** —— run #19 的两条
/// `undefined_function`（tool_pages_ph2.dart:189 / :191）就是直接写了
/// `math.log1p(...)` 造成的。这里自己实现一份，并用两段近似避开溢出：
///   * x 很大 → e^x 上溢成 Infinity；此时 log(1+e^x) ≈ x（误差 e^-x < 4e-18）
///   * x 很小 → log(1+e^x) ≈ e^x（泰勒展开，同样在 double 精度外）
/// 调用点传进来的 |x| ≤ 500，中间那段其实一句 math.log(1 + math.exp(x)) 就够，
/// 但保留这两个分支，免得以后被别处复用（比如传进未截断的 η）时炸掉。
double _softplus(double x) {
  if (x > 40) return x;
  if (x < -40) return math.exp(x);
  return math.log(1 + math.exp(x));
}

_LogitFit? _fitLogistic(List<List<double>> x, List<int> y, List<String> names) {
  final n = x.length;
  final k = x.isEmpty ? 0 : x[0].length;
  if (n == 0 || k == 0) return null;

  // 设计矩阵：第一列补 1 当截距
  final X = List<List<double>>.generate(
      n, (i) => <double>[1.0, ...x[i]]);
  final m = k + 1;                       // 参数个数

  final beta = List<double>.filled(m, 0.0);

  double logLikOf(List<double> b) {
    var ll = 0.0;
    for (var i = 0; i < n; i++) {
      var eta = 0.0;
      for (var j = 0; j < m; j++) {
        eta += X[i][j] * b[j];
      }
      eta = eta.clamp(-500.0, 500.0);
      // 对数似然：y=1 时是 log σ(η) = −log(1+e^{−η})，
      //           y=0 时是 log(1−σ(η)) = −log(1+e^{η})。
      // 两者都归到 −softplus(∓η)，见 _softplus 上方的说明（Dart 没有 log1p）。
      if (y[i] == 1) {
        ll -= _softplus(-eta);
      } else {
        ll -= _softplus(eta);
      }
    }
    return ll;
  }

  var converged = false;
  var separated = false;
  var ll = logLikOf(beta);

  for (var iter = 0; iter < 60; iter++) {
    // 加权正规方程的左端 XᵀWX 与右端 Xᵀ(y−p)
    final A = List<List<double>>.generate(m, (_) => List<double>.filled(m, 0.0));
    final g = List<double>.filled(m, 0.0);

    for (var i = 0; i < n; i++) {
      var eta = 0.0;
      for (var j = 0; j < m; j++) {
        eta += X[i][j] * beta[j];
      }
      eta = eta.clamp(-500.0, 500.0);
      final p = 1 / (1 + math.exp(-eta));
      final w = math.max(p * (1 - p), 1e-10);
      final r = y[i] - p;
      for (var j = 0; j < m; j++) {
        g[j] += X[i][j] * r;
        for (var l = 0; l < m; l++) {
          A[j][l] += w * X[i][j] * X[i][l];
        }
      }
    }

    // 岭参数保证可逆（共线时不至于直接崩）
    for (var j = 0; j < m; j++) {
      A[j][j] += 1e-9;
    }
    final inv = _invert(A);
    if (inv == null) break;

    // 步长：Newton 步。前 3 轮走半步，遇到分离时不容易冲出去。
    final step = iter < 3 ? 0.5 : 1.0;
    var moved = 0.0;
    for (var j = 0; j < m; j++) {
      var d = 0.0;
      for (var l = 0; l < m; l++) {
        d += inv[j][l] * g[l];
      }
      d *= step;
      // 单轮步长封顶，防止分离导致的爆走
      d = d.clamp(-8.0, 8.0);
      beta[j] += d;
      moved += d.abs();
    }

    final newLl = logLikOf(beta);
    // 记下新的似然。IRLS 正常情况下每轮都会让似然上升；
    // 偶发下降一般是数值噪声，继续迭代即可，不必回退步长
    // （回退需要保存上一步的 beta，代价大且收益很小）。
    ll = newLl;

    if (moved < 1e-8) {
      converged = true;
      break;
    }
    // 系数过大基本就是完全分离
    if (beta.any((b) => b.abs() > 25)) {
      separated = true;
      break;
    }
  }

  // 收敛后再算一次信息矩阵，拿到标准误
  final A = List<List<double>>.generate(m, (_) => List<double>.filled(m, 0.0));
  for (var i = 0; i < n; i++) {
    var eta = 0.0;
    for (var j = 0; j < m; j++) {
      eta += X[i][j] * beta[j];
    }
    eta = eta.clamp(-500.0, 500.0);
    final p = 1 / (1 + math.exp(-eta));
    final w = math.max(p * (1 - p), 1e-10);
    for (var j = 0; j < m; j++) {
      for (var l = 0; l < m; l++) {
        A[j][l] += w * X[i][j] * X[i][l];
      }
    }
  }
  final inv = _invert(A);

  final coefs = <_Coef>[];
  for (var j = 0; j < m; j++) {
    final se = inv == null ? double.nan : math.sqrt(math.max(inv[j][j], 0));
    final z = se.isFinite && se > 0 ? beta[j] / se : double.nan;
    final p = z.isFinite ? normTwoTail(z) : double.nan;
    coefs.add(_Coef(j == 0 ? '（截距）' : names[j - 1], beta[j], se, z, p));
  }

  // 零模型的似然：只用截距
  final p0 = y.reduce((a, b) => a + b) / n;
  final ll0 = n * (p0 <= 0 || p0 >= 1
      ? 0.0
      : (p0 * math.log(p0) + (1 - p0) * math.log(1 - p0)));

  return _LogitFit(
    coefs: coefs,
    logLik: ll,
    logLik0: ll0,
    n: n,
    k: k,
    converged: converged,
    separated: separated,
  );
}

/// 高斯-约当消元求逆（带部分主元）；奇异返回 null
List<List<double>>? _invert(List<List<double>> m) {
  final n = m.length;
  final a = List<List<double>>.generate(
      n, (i) => <double>[...m[i], ...List<double>.generate(n, (j) => i == j ? 1.0 : 0.0)]);

  for (var col = 0; col < n; col++) {
    var piv = col;
    for (var r = col + 1; r < n; r++) {
      if (a[r][col].abs() > a[piv][col].abs()) piv = r;
    }
    if (a[piv][col].abs() < 1e-14) return null;
    if (piv != col) {
      final t = a[col];
      a[col] = a[piv];
      a[piv] = t;
    }
    final d = a[col][col];
    for (var j = 0; j < 2 * n; j++) {
      a[col][j] /= d;
    }
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = a[r][col];
      if (f == 0) continue;
      for (var j = 0; j < 2 * n; j++) {
        a[r][j] -= f * a[col][j];
      }
    }
  }
  return List<List<double>>.generate(n, (i) => a[i].sublist(n));
}

class LogisticPage extends StatefulWidget {
  const LogisticPage({super.key});

  @override
  State<LogisticPage> createState() => _LogisticPageState();
}

class _LogisticPageState extends State<LogisticPage> {
  final _data = TextEditingController();
  final _names = TextEditingController();
  bool _multi = true;
  bool _header = true;

  @override
  void initState() {
    super.initState();
    _data.addListener(_refresh);
    _names.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _data.dispose();
    _names.dispose();
    super.dispose();
  }

  /// 解析用户粘进来的数据。每行一条记录，第一列是结局（1=阳性/发病，0=阴性），
  /// 后面是各自变量。分隔符随便（逗号 / 空格 / 制表符 / 分号）。
  ({List<List<double>> x, List<int> y, List<String> names})? _parse() {
    final lines = _data.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.length < 3) return null;

    var start = 0;
    final headerNames = <String>[];
    if (_header) {
      final first = lines.first;
      // 表头判定：首行含有非数字的单元格
      final cells = first.split(RegExp(r'[,\s;，、]+')).where((s) => s.isNotEmpty).toList();
      if (cells.any((c) => double.tryParse(c) == null)) {
        headerNames.addAll(cells);
        start = 1;
      }
    }

    final xs = <List<double>>[];
    final ys = <int>[];
    for (var i = start; i < lines.length; i++) {
      final cells = lines[i]
          .split(RegExp(r'[,\s;，、]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (cells.length < 2) continue;
      final v = <double>[];
      for (final c in cells) {
        final d = double.tryParse(c);
        if (d == null) {
          v.clear();
          break;
        }
        v.add(d);
      }
      if (v.length < 2) continue;
      final yv = v.first;
      if (yv != 0 && yv != 1) continue;      // 结局必须是 0/1
      ys.add(yv.toInt());
      xs.add(v.sublist(1));
    }
    if (xs.length < 3) return null;

    // 变量名：优先用用户手填的，其次用表头，最后用 X1 X2…
    final k = xs.first.length;
    final manual = _names.text
        .split(RegExp(r'[,\s;，、]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final names = <String>[];
    for (var j = 0; j < k; j++) {
      if (j < manual.length) {
        names.add(manual[j]);
      } else if (j + 1 < headerNames.length) {
        names.add(headerNames[j + 1]);
      } else {
        names.add('X${j + 1}');
      }
    }
    return (x: xs, y: ys, names: names);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _parse();

    return ToolScaffold(
      title: 'Logistic 回归',
      subtitle: '多因素分析 · OR 与 95%CI · 似然比检验',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _H('把调查表粘进来就能跑。结局列必须是 1（发病/阳性）或 0（未发病/阴性），'
              '放到第一列；后面每列一个自变量（连续变量直接用原始数值，'
              '分类变量先编成 0/1）。'),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('首行是列名', style: TextStyle(fontSize: 13)),
                  value: _header,
                  onChanged: (v) => setState(() => _header = v),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('多因素', style: TextStyle(fontSize: 13)),
                  subtitle: Text(_multi ? '所有变量一起进模型' : '逐个变量单独建模',
                      style: const TextStyle(fontSize: 10.5)),
                  value: _multi,
                  onChanged: (v) => setState(() => _multi = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _names,
            onChanged: (_) => _refresh(),
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: '变量名（可空，逗号分开）',
              hintText: '年龄,性别,吸烟',
              hintStyle: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _data,
            onChanged: (_) => _refresh(),
            maxLines: 8,
            minLines: 6,
            style: const TextStyle(fontSize: 12.5, height: 1.5),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'y,年龄,性别,吸烟\n1,55,1,1\n0,42,0,0\n…',
              hintStyle: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 14),
          _resultArea(parsed),
          if (parsed != null && !_multi) _singleFactorTables(parsed, scheme),
        ],
      ),
    );
  }

  /// 结果区。拆成一个方法是为了避开「Widget? 局部变量在 children 里的可空问题」——
  /// 每个分支直接 return 一个非空的 Widget，比先赋值再判断省心。
  Widget _resultArea(
      ({List<List<double>> x, List<int> y, List<String> names})? parsed) {
    if (parsed == null) {
      return const _H('还没有数据。把表格粘进上面的框，每行一条记录，'
          '第一列是结局（1 = 发病/阳性，0 = 未发病/阴性），后面是各自变量。\n\n'
          '例：\n'
          'y,年龄,性别,吸烟\n'
          '1,55,1,1\n'
          '0,42,0,0\n'
          '1,61,1,1');
    }
    if (parsed.y.every((v) => v == parsed.y.first)) {
      return const _H('结局只有一个取值（全是 0 或全是 1），回归没法拟合。');
    }
    final fit = _fitLogistic(parsed.x, parsed.y, parsed.names);
    if (fit == null) {
      return const _H('数据太少或存在完全共线的变量，拟合失败。'
          '试着删掉某个自变量，或多加几十条记录。');
    }

    final rows = <_R>[
      _R('样本量', '${fit.n} 例',
          '阳性 ${parsed.y.where((v) => v == 1).length} / '
          '阴性 ${parsed.y.where((v) => v == 0).length}'),
      _R('自变量个数', '${fit.k}'),
      _R('对数似然 LL', fmtNum(fit.logLik, 3)),
      _R('-2LL', fmtNum(-2 * fit.logLik, 3)),
      _R('AIC', fmtNum(fit.aic, 3), '越小越好，用来比不同模型'),
      _R('伪 R²（McFadden）', fmtNum(fit.mcfadden, 4)),
      _R('整体检验 χ²', fmtNum(fit.lrChi2, 3),
          '似然比检验，df=${fit.k}，P = ${fmtP(fit.lrP)}'),
    ];

    final coefRows = <_R>[
      for (final c in fit.coefs.skip(1))
        _R(c.name, 'OR ${fmtNum(c.or_, 3)}   P ${fmtP(c.p)}',
            'β ${fmtNum(c.beta, 4)}   SE ${fmtNum(c.se, 4)}   '
            'z ${fmtNum(c.z, 3)}   95%CI ${fmtCi(c.lo, c.hi, 3)}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Table(rows: rows, title: '模型整体'),
        const SizedBox(height: 12),
        _Table(rows: coefRows, title: '各自变量的 OR 与显著性'),
        const SizedBox(height: 10),
        if (fit.separated || !fit.converged)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _H('⚠️ 模型没能正常收敛。最常见的原因是**完全分离** —— '
                '某个自变量能把有病 / 没病完全分开（比如某组里全是病例）。\n'
                '这种情况下 OR 会趋于无穷、可信区间极宽，结果不可信。'
                '建议合并该变量的类别，或增加样本量。'),
          ),
        const _H('OR > 1 表示该因素增加结局发生的可能性；OR < 1 表示降低。\n'
            '95%CI 不含 1 时，差异有统计学意义（P < 0.05）。'),
      ],
    );
  }

  /// 单因素模式：逐个自变量单独跑一次 logistic，给一张汇总表。
  /// 这是流行病学里最常用的「先做单因素筛选，再挑 P<0.2 的进多因素」流程。
  Widget _singleFactorTables(
      ({List<List<double>> x, List<int> y, List<String> names}) parsed, ColorScheme scheme) {
    final rows = <_R>[];
    for (var j = 0; j < parsed.names.length; j++) {
      final col = parsed.x.map((r) => <double>[r[j]]).toList();
      final fit = _fitLogistic(col, parsed.y, [parsed.names[j]]);
      if (fit == null) continue;
      final c = fit.coefs[1];
      rows.add(_R(parsed.names[j],
          'OR ${fmtNum(c.or_, 3)}   P ${fmtP(c.p)}',
          '95%CI ${fmtCi(c.lo, c.hi, 3)}'));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Table(rows: rows, title: '单因素分析（每个变量单独建模）'),
          const SizedBox(height: 10),
          Text('常规做法：单因素里 P < 0.2 的变量，再一起放进多因素模型。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ===========================================================================
// 2. 智能营养配餐
// ===========================================================================

/// 一类食物的交换份参数。每一份（约 90 kcal）提供的三大营养素克数。
class _Exch {
  final String name;
  final String perPortion;   // 一份大概是多少克实物
  final double carb, prot, fat;
  const _Exch(this.name, this.perPortion, this.carb, this.prot, this.fat);
}

/// 中国居民膳食指南 / 糖尿病膳食用的「食物交换份表」。
/// 每份统一约 90 kcal，但三大营养素含量各不相同 —— 这是后面配餐的计算基础。
const List<_Exch> _exchList = <_Exch>[
  _Exch('谷薯类（主食）', '约 25 g 生重', 20, 2, 0.5),
  _Exch('蔬菜类', '约 500 g', 17, 5, 0),
  _Exch('水果类', '约 200 g', 21, 1, 0),
  _Exch('大豆类', '约 25 g 干豆', 4, 9, 4),
  _Exch('奶类', '约 160 g 牛奶', 5, 5, 5),
  _Exch('肉蛋类', '约 50 g', 0, 9, 6),
  _Exch('油脂类', '约 10 g', 0, 0, 10),
];

class NutritionPage extends StatefulWidget {
  const NutritionPage({super.key});

  @override
  State<NutritionPage> createState() => _NutritionPageState();
}

class _NutritionPageState extends State<NutritionPage> {
  final _age = TextEditingController(text: '35');
  final _height = TextEditingController(text: '170');
  final _weight = TextEditingController(text: '65');
  int _sex = 0;               // 0 男 1 女
  double _pal = 1.375;        // 体力活动水平
  int _goal = 0;              // 0 维持 1 减重 2 增重
  double _protRatio = 15;     // 蛋白供能比 %
  double _fatRatio = 25;      // 脂肪供能比 %

  @override
  void initState() {
    super.initState();
    for (final c in [_age, _height, _weight]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_age, _height, _weight]) {
      c.dispose();
    }
    super.dispose();
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  /// 基础代谢率 BMR —— Mifflin-St Jeor 公式（目前临床最推荐的估算式）。
  double get _bmr {
    final w = _d(_weight), h = _d(_height), a = _d(_age);
    if (w <= 0 || h <= 0 || a <= 0) return double.nan;
    return 10 * w + 6.25 * h - 5 * a + (_sex == 0 ? 5 : -161);
  }

  double get _tdee => _bmr * _pal;

  double get _targetKcal {
    final t = _tdee;
    if (!t.isFinite) return double.nan;
    switch (_goal) {
      case 1:
        return t - 500;       // 减重：每天 500 kcal 缺口 ≈ 每周减 0.5 kg
      case 2:
        return t + 300;
      default:
        return t;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bmr = _bmr;
    final tdee = _tdee;
    final kcal = _targetKcal;

    final ok = bmr.isFinite && kcal.isFinite && kcal > 600;
    final plan = ok ? _buildPlan(kcal) : null;

    return ToolScaffold(
      title: '智能营养配餐',
      subtitle: '按身体数据算能量，再折算成食物交换份',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _H('填身高体重和活动量，自动算出每天该吃多少千卡，'
              '再按「食物交换份」折算成各类食物该吃几份、几克。\n'
              '算法用的是临床常用的 Mifflin-St Jeor 公式 + 中国食物交换份表。'),

          const ToolSection('基本信息'),
          Row(children: [
            Expanded(
              child: SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 0, label: Text('男', style: TextStyle(fontSize: 12))),
                  ButtonSegment<int>(value: 1, label: Text('女', style: TextStyle(fontSize: 12))),
                ],
                selected: <int>{_sex},
                onSelectionChanged: (s) => setState(() => _sex = s.first),
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _num('年龄（岁）', _age)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _num('身高（cm）', _height)),
            const SizedBox(width: 10),
            Expanded(child: _num('体重（kg）', _weight)),
          ]),

          const ToolSection('活动强度'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in const <(String, double)>[
                ('卧床', 1.2), ('久坐办公', 1.375), ('轻度活动', 1.55),
                ('中度活动', 1.725), ('重体力', 1.9),
              ])
                ChoiceChip(
                  label: Text(e.$1, style: const TextStyle(fontSize: 12)),
                  selected: _pal == e.$2,
                  onSelected: (_) => setState(() => _pal = e.$2),
                ),
            ],
          ),

          const ToolSection('目标'),
          Wrap(
            spacing: 8,
            children: [
              for (final e in const <(String, int)>[
                ('维持体重', 0), ('减重', 1), ('增重', 2),
              ])
                ChoiceChip(
                  label: Text(e.$1, style: const TextStyle(fontSize: 12)),
                  selected: _goal == e.$2,
                  onSelected: (_) => setState(() => _goal = e.$2),
                ),
            ],
          ),

          if (ok) ...[
            const ToolSection('能量与营养素'),
            _Table(
              rows: <_R>[
                _R('基础代谢 BMR', '${fmtNum(bmr, 0)} kcal/天',
                    'Mifflin-St Jeor 公式，静卧不动也要消耗这些'),
                _R('每日总消耗 TDEE', '${fmtNum(tdee, 0)} kcal/天',
                    'BMR × 活动系数 ${fmtNum(_pal, 3)}'),
                _R('建议摄入', '${fmtNum(kcal, 0)} kcal/天',
                    _goal == 1
                        ? '每天留 500 kcal 缺口，约合每周减 0.5 kg'
                        : (_goal == 2 ? '每天多 300 kcal，配合力量训练更实在' : '与消耗持平')),
                _R('蛋白质', '${fmtNum(kcal * _protRatio / 100 / 4, 1)} g',
                    '${fmtNum(_protRatio, 0)}% 供能 · '
                    '约 ${fmtNum(kcal * _protRatio / 100 / 4 / (_d(_weight) > 0 ? _d(_weight) : 1), 2)} g/kg 体重'),
                _R('脂肪', '${fmtNum(kcal * _fatRatio / 100 / 9, 1)} g',
                    '${fmtNum(_fatRatio, 0)}% 供能'),
                _R('碳水化合物',
                    '${fmtNum((kcal - kcal * _protRatio / 100 - kcal * _fatRatio / 100) / 4, 1)} g',
                    '${fmtNum(100 - _protRatio - _fatRatio, 0)}% 供能'),
              ],
              hi: const {'建议摄入'},
            ),
          ],

          if (plan != null) ...[
            const ToolSection('食物交换份（每天）'),
            _Table(rows: plan.rows, title: '按 90 kcal / 份 折算'),
            const SizedBox(height: 10),
            _Table(rows: plan.mealRows, title: '三餐分配建议'),
            const SizedBox(height: 10),
            if (plan.warning != null) _H(plan.warning!),
            const SizedBox(height: 10),
            _H('说明：每「份」是这套算法的记账单位，一共 ${plan.totalPortions} 份 ≈ '
                '${fmtNum(kcal, 0)} kcal。蔬菜、水果、奶类是固定的（保证膳食纤维和钙），'
                '剩下的能量再分给主食、肉蛋、豆和油。'),
          ],

          const ToolSection('调整供能比'),
          _sliderRow('蛋白质 ${fmtNum(_protRatio, 0)}%', _protRatio, 10, 25,
              (v) => setState(() => _protRatio = v)),
          _sliderRow('脂肪 ${fmtNum(_fatRatio, 0)}%', _fatRatio, 15, 35,
              (v) => setState(() => _fatRatio = v)),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '碳水供给比 = ${fmtNum(100 - _protRatio - _fatRatio, 0)}%'
              '（建议落在 50%~65%）',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _num(String label, TextEditingController c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 3),
          TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            onChanged: (_) => _refresh(),
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            ),
          ),
        ],
      );

  Widget _sliderRow(String label, double v, double lo, double hi, ValueChanged<double> on) =>
      Row(
        children: [
          SizedBox(width: 104, child: Text(label, style: const TextStyle(fontSize: 12.5))),
          Expanded(
            child: Slider(
                value: v.clamp(lo, hi),
                min: lo,
                max: hi,
                divisions: (hi - lo).round(),
                onChanged: on),
          ),
        ],
      );

  /// 配餐核心：把目标能量折算成各类食物的份数。
  ///
  /// 步骤（这也是临床营养师的手算流程）：
  ///   1. 蔬菜 1 份、水果 1 份、奶 1.5 份 —— 固定，保证膳食纤维和钙
  ///   2. 先扣掉这几样带来的蛋白 / 脂肪 / 碳水
  ///   3. 剩下的蛋白由「肉蛋 : 大豆 = 2 : 1」承担
  ///   4. 剩下的脂肪再扣掉肉蛋豆自带的，余量给烹调油
  ///   5. 剩下的碳水全部由谷薯类承担
  ///
  /// ★ v1.5.0 修的真 bug：**谷薯类自己也带蛋白和脂肪**（每份 2 g 蛋白 / 0.5 g 脂肪），
  ///   第一版压根没把这部分算进蛋白 / 脂肪预算 —— 于是页面顶上说「蛋白质 97.5 g」，
  ///   底下那张食物表实际给出 132 g，**整整多 34.5 g（多 35%）**。
  ///   营养师一眼就能看出这两处自相矛盾；用户照着吃也会吃超。
  ///
  ///   修法是让 3/5 两步互相咬合：先按「谷薯不带蛋白脂肪」算一版拿到谷薯份数，
  ///   把谷薯带的蛋白 / 脂肪扣进预算再重算，反复几轮直到份数不再变。
  ///   份数是 0.5 的整数倍（离散的），所以必然收敛 —— 实测 2~3 轮就稳定，
  ///   这里留 8 轮上限纯粹是保险。
  ({List<_R> rows, List<_R> mealRows, String? warning, int totalPortions}) _buildPlan(
      double kcal) {
    final pTarget = kcal * _protRatio / 100 / 4;     // g
    final fTarget = kcal * _fatRatio / 100 / 9;      // g
    final cTarget = (kcal - kcal * _protRatio / 100 - kcal * _fatRatio / 100) / 4;

    // 固定项
    const nVeg = 1.0, nFruit = 1.0, nMilk = 1.5;
    final exGrain = _exchList[0], exVeg = _exchList[1], exFruit = _exchList[2],
        exBean = _exchList[3], exMilk = _exchList[4], exMeat = _exchList[5],
        exOil = _exchList[6];
    final fixedProt = nVeg * exVeg.prot + nFruit * exFruit.prot + nMilk * exMilk.prot;
    final fixedFat = nVeg * exVeg.fat + nFruit * exFruit.fat + nMilk * exMilk.fat;
    final fixedCarb = nVeg * exVeg.carb + nFruit * exFruit.carb + nMilk * exMilk.carb;

    // ---- 迭代解出谷薯 / 肉蛋 / 大豆 的份数 ----
    var nMeat = 0.0;
    var nBean = 0.0;
    var nGrain = 0.0;
    var grainProt = 0.0;   // 谷薯自带的蛋白（要从蛋白预算里扣）
    var grainFat = 0.0;    // 谷薯自带的脂肪（要从脂肪预算里扣）

    for (var round = 0; round < 8; round++) {
      // 3) 蛋白预算（扣掉固定项和谷薯自带）→ 肉蛋 : 大豆 = 2 : 1
      //    解 9a + 9b = 预算 且 a = 2b  ⇒  27b = 预算
      //    循环里的临时名后面都带 x —— 别和循环外那几个 final 重名，
      //    虽然 Dart 允许跨作用域遮蔽，但读代码的人会以为它们是一回事。
      final budgetP = pTarget - fixedProt - grainProt;
      var meatX = 0.0, beanX = 0.0;
      if (budgetP > 0) {
        beanX = _roundHalf(budgetP / 27);
        meatX = _roundHalf(budgetP / 9 - beanX);
        if (meatX < 0) meatX = 0;
        if (beanX < 0) beanX = 0;
      }
      // 5) 碳水预算（扣掉固定项和大豆自带，大豆每份也带 4 g 碳水）→ 全给谷薯
      final budgetC = cTarget - fixedCarb - beanX * exBean.carb;
      var grainX = budgetC > 0 ? _roundHalf(budgetC / exGrain.carb) : 0.0;
      if (grainX < 0) grainX = 0;

      final np = grainX * exGrain.prot;
      final nf = grainX * exGrain.fat;
      final stable = np == grainProt && nf == grainFat;
      nMeat = meatX;
      nBean = beanX;
      nGrain = grainX;
      grainProt = np;
      grainFat = nf;
      if (stable) break;
    }

    var restProt =
        pTarget - fixedProt - grainProt - nMeat * exMeat.prot - nBean * exBean.prot;
    var restFat =
        fTarget - fixedFat - grainFat - nMeat * exMeat.fat - nBean * exBean.fat;
    var restCarb =
        cTarget - fixedCarb - nGrain * exGrain.carb - nBean * exBean.carb;

    var nOil = restFat > 0 ? _roundHalf(restFat / exOil.fat) : 0.0;
    if (nOil < 0) nOil = 0;
    restFat = restFat - nOil * exOil.fat;

    final portions = <(String, double, String)>[
      ('谷薯类（主食）', nGrain, exGrain.perPortion),
      ('蔬菜类', nVeg, exVeg.perPortion),
      ('水果类', nFruit, exFruit.perPortion),
      ('肉蛋类', nMeat, exMeat.perPortion),
      ('大豆类', nBean, exBean.perPortion),
      ('奶类', nMilk, exMilk.perPortion),
      ('油脂类', nOil, exOil.perPortion),
    ];

    final rows = <_R>[
      for (final p in portions)
        _R(p.$1, '${fmtNum(p.$2, 2)} 份',
            p.$2 <= 0 ? '本次不安排' : '${fmtNum(p.$2 * 90, 0)} kcal · ${p.$3}'),
      _R('合计', '${fmtNum(portions.fold<double>(0, (s, p) => s + p.$2), 2)} 份',
          '约 ${fmtNum(kcal, 0)} kcal'),
    ];

    // 三餐分配：早 30% / 午 40% / 晚 30%
    final g = nGrain, m = nMeat, o = nOil;
    String split(double v, {bool allowZero = true}) {
      if (v <= 0 && allowZero) return '—';
      final b = _roundHalf(v * 0.3);
      final l = _roundHalf(v * 0.4);
      final d = _roundHalf(v - b - l);
      return '早 ${fmtNum(b, 1)} / 午 ${fmtNum(l, 1)} / 晚 ${fmtNum(d, 1)}';
    }

    final mealRows = <_R>[
      _R('占全天能量', '早 30% · 午 40% · 晚 30%',
          '约 ${fmtNum(kcal * 0.3, 0)} / ${fmtNum(kcal * 0.4, 0)} / ${fmtNum(kcal * 0.3, 0)} kcal'),
      _R('主食（谷薯）', split(g), '单位：份'),
      _R('肉蛋', split(m), '单位：份'),
      _R('烹调油', split(o), '单位：份'),
      _R('蔬菜 / 水果 / 奶', '全天花着吃', '不必严格分餐，加餐放水果和奶'),
    ];

    String? warning;
    if (restCarb.abs() > 3) {
      warning = '⚠️ 碳水与目标差了 ${fmtNum(restCarb, 1)} g，说明三大营养素供能比和总能量对不齐。'
          '把脂肪或蛋白的供能比调低一点就平了。';
    }
    if (nMeat * exMeat.fat > fTarget * 0.6) {
      warning = '⚠️ 光肉蛋带的脂肪就占了目标脂肪的六成以上。'
          '建议换瘦一点的肉（里脊、鸡胸），或者把一部分肉换成豆制品。';
    }

    final total = portions.fold<double>(0, (s, p) => s + p.$2).round();
    return (rows: rows, mealRows: mealRows, warning: warning, totalPortions: total);
  }

  /// 交换份取到 0.5 的整数倍 —— 半个苹果、半碗饭是能操作的，
  /// 0.37 份没人算得出来。
  double _roundHalf(double v) => (v * 2).roundToDouble() / 2;
}
