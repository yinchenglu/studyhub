// 公卫数据工具（第一批）—— 全离线、零新增依赖。
//
// 对应需求 1(9)：把「消杀计算器」归到「公卫数据」这个类别下，并补齐一批
// 类似 Epi Info 里 StatCalc 的工具。
//
// 本文件的页面：
//   * EpiStatsPage        公共卫生统计（率与 95%CI / 样本量估算 / 百分位数）
//   * CaseControlPage     病例对照研究（OR + 95%CI + χ² + P + Fisher）
//   * CohortPage          队列研究（RR + AR + AR% + PAR + χ² + P）
//   * FoodPoisoningPage   食物中毒分析（多种食物的食用组 / 未食用组发病率对比）
//
// 所有统计都走 lib/core/stats.dart，与后面的 logistic 回归共用同一套分布函数，
// 保证同一个 P 值在不同工具里算出来一模一样。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/stats.dart';
import 'tool_pages.dart';

// ===========================================================================
// 公共小部件
// ===========================================================================

/// 只让用户输非负整数（频数）
final List<TextInputFormatter> _intOnly = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
];

/// 允许小数与负号（率、均数这些）
final List<TextInputFormatter> _decOnly = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
];

/// 一个带标签的小输入框
class _Num extends StatelessWidget {
  final String label;
  final TextEditingController c;
  final VoidCallback onChanged;
  final bool decimal;
  final String? hint;

  const _Num({
    required this.label,
    required this.c,
    required this.onChanged,
    this.decimal = false,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 3),
        TextField(
          controller: c,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          inputFormatters: decimal ? _decOnly : _intOnly,
          onChanged: (_) => onChanged(),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          ),
        ),
      ],
    );
  }
}

/// 结果表里的一行
class _Row {
  final String k;
  final String v;
  final String? note;
  const _Row(this.k, this.v, [this.note]);
}

/// 统一风格的结果卡片；`hi` 里的行加粗高亮（关键指标）
class _ResultTable extends StatelessWidget {
  final List<_Row> rows;
  final Set<String> hi;
  final String? title;

  const _ResultTable({required this.rows, this.hi = const <String>{}, this.title});

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
                    width: 104,
                    child: Text(rows[i].k,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          rows[i].v,
                          style: TextStyle(
                            fontSize: hi.contains(rows[i].k) ? 15 : 13.5,
                            height: 1.35,
                            fontWeight:
                                hi.contains(rows[i].k) ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                        if (rows[i].note != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(rows[i].note!,
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

/// 一条解释性提示
class _Hint extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Hint(this.text, {this.icon = Icons.info_outline});

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
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 11.5, height: 1.65, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// 2×2 表的统一分析
// ===========================================================================

/// 四格表的分析结果。字段按公卫习惯命名：
///   a 暴露组发病、b 暴露组未发病、c 非暴露组发病、d 非暴露组未发病
class TwoByTwoResult {
  final int a, b, c, d;
  final int n;
  final double ie, i0;          // 暴露组 / 非暴露组发病率
  final double it;              // 总发病率
  final double rr, rrLo, rrHi;
  final double or_, orLo, orHi;
  final double ar, arPct;       // 归因危险度 / 归因危险度百分比
  final double par, parPct;     // 人群归因危险度 / 百分比
  final double nnt;             // 需暴露多少人才能多出 1 例
  final double chi2, chi2Yates;
  final double pChi2, pChi2Yates, pFisher;
  final double minExpected;
  final bool useFisher;

  const TwoByTwoResult({
    required this.a, required this.b, required this.c, required this.d,
    required this.n, required this.ie, required this.i0, required this.it,
    required this.rr, required this.rrLo, required this.rrHi,
    required this.or_, required this.orLo, required this.orHi,
    required this.ar, required this.arPct, required this.par, required this.parPct,
    required this.nnt, required this.chi2, required this.chi2Yates,
    required this.pChi2, required this.pChi2Yates, required this.pFisher,
    required this.minExpected, required this.useFisher,
  });
}

/// 分析一个 2×2 表。任何分母为 0 的情况都用 `double.nan` 表示「算不出来」，
/// UI 层统一显示成「—」，不让用户看到 NaN 或 Infinity。
TwoByTwoResult analyze2x2(int a, int b, int c, int d) {
  final n = a + b + c + d;
  final r1 = a + b;           // 暴露组人数
  final r2 = c + d;           // 非暴露组人数
  final c1 = a + c;           // 发病总人数
  final c2 = b + d;           // 未发病总人数

  final ie = r1 > 0 ? a / r1 : double.nan;
  final i0 = r2 > 0 ? c / r2 : double.nan;
  final it = n > 0 ? c1 / n : double.nan;

  // ---- 关联强度 ----
  // OR 用 Haldane 校正（每格 +0.5）只在**算 CI** 时用；
  // 点估计本身还是原始值，避免报告里出现「加了 0.5 的怪数」。
  final orRaw = (b * c) > 0 ? (a * d) / (b * c) : double.nan;
  final rrRaw = (i0 > 0 && ie.isFinite) ? ie / i0 : double.nan;

  // RR 的 95%CI —— Katz 对数法
  double rrLo = double.nan, rrHi = double.nan;
  if (rrRaw.isFinite && rrRaw > 0 && a > 0 && c > 0 && r1 > 0 && r2 > 0) {
    final se = math.sqrt(1 / a - 1 / r1 + 1 / c - 1 / r2);
    rrLo = math.exp(math.log(rrRaw) - 1.96 * se);
    rrHi = math.exp(math.log(rrRaw) + 1.96 * se);
  }

  // OR 的 95%CI —— Woolf 对数法；有 0 格时用 Haldane 校正（各格 +0.5）
  double orLo = double.nan, orHi = double.nan;
  {
    var aa = a.toDouble(), bb = b.toDouble(), cc = c.toDouble(), dd = d.toDouble();
    if (aa == 0 || bb == 0 || cc == 0 || dd == 0) {
      aa += 0.5;
      bb += 0.5;
      cc += 0.5;
      dd += 0.5;
    }
    final se = math.sqrt(1 / aa + 1 / bb + 1 / cc + 1 / dd);
    final lnOr = math.log(aa * dd / (bb * cc));
    orLo = math.exp(lnOr - 1.96 * se);
    orHi = math.exp(lnOr + 1.96 * se);
  }

  // ---- 归因 ----
  final ar = (ie.isFinite && i0.isFinite) ? ie - i0 : double.nan;
  final arPct = (ar.isFinite && ie > 0) ? ar / ie * 100 : double.nan;
  final par = (it.isFinite && i0.isFinite) ? it - i0 : double.nan;
  final parPct = (par.isFinite && it > 0) ? par / it * 100 : double.nan;
  final nnt = (ar.isFinite && ar > 0) ? 1 / ar : double.nan;

  // ---- 卡方 ----
  double chi2 = double.nan, chi2Y = double.nan;
  if (r1 > 0 && r2 > 0 && c1 > 0 && c2 > 0) {
    final adbc = (a * d - b * c).toDouble();
    chi2 = n * adbc * adbc / (r1 * r2 * c1 * c2);
    final y = adbc.abs() - n / 2;
    chi2Y = n * y * y / (r1 * r2 * c1 * c2);
  }

  final pChi2 = chi2.isFinite ? chi2Upper(chi2, 1) : double.nan;
  final pChi2Y = chi2Y.isFinite ? chi2Upper(chi2Y, 1) : double.nan;
  final pFisher = fisherTwoTail(a, b, c, d);

  // 最小期望频数 < 5 时卡方不可靠，改用 Fisher 精确检验
  double minExp = double.nan;
  if (n > 0) {
    minExp = [r1 * c1 / n, r1 * c2 / n, r2 * c1 / n, r2 * c2 / n]
        .reduce((x, y) => x < y ? x : y);
  }

  return TwoByTwoResult(
    a: a, b: b, c: c, d: d, n: n,
    ie: ie, i0: i0, it: it,
    rr: rrRaw, rrLo: rrLo, rrHi: rrHi,
    or_: orRaw, orLo: orLo, orHi: orHi,
    ar: ar, arPct: arPct, par: par, parPct: parPct, nnt: nnt,
    chi2: chi2, chi2Yates: chi2Y, pChi2: pChi2, pChi2Yates: pChi2Y, pFisher: pFisher,
    minExpected: minExp,
    useFisher: minExp.isFinite && minExp < 5,
  );
}

/// 把 2×2 结果渲染成一组表格行（病例对照 / 队列 / 食物中毒共用）
List<_Row> twoByTwoRows(TwoByTwoResult r, {required bool cohort}) {
  final rows = <_Row>[
    _Row('暴露组发病率', '${fmtNum(r.ie * 100, 2)}%',
        '${r.a} / ${r.a + r.b}'),
    _Row('非暴露组发病率', '${fmtNum(r.i0 * 100, 2)}%',
        '${r.c} / ${r.c + r.d}'),
  ];

  if (cohort) {
    rows.add(_Row('相对危险度 RR', fmtNum(r.rr, 3),
        r.rrHi.isFinite ? '95%CI ${fmtCi(r.rrLo, r.rrHi, 3)}' : '（发病率有 0，算不出区间）'));
  }
  rows.add(_Row('比值比 OR', fmtNum(r.or_, 3),
      r.orHi.isFinite ? '95%CI ${fmtCi(r.orLo, r.orHi, 3)}' : null));

  if (cohort) {
    rows.add(_Row('归因危险度 AR', '${fmtNum(r.ar * 100, 2)}%',
        '暴露组比非暴露组多出的绝对风险'));
    rows.add(_Row('AR%', '${fmtNum(r.arPct, 1)}%', '危险因素导致的发病占比'));
    rows.add(_Row('人群归因危险度 PAR', '${fmtNum(r.par * 100, 2)}%',
        'PAR% = ${fmtNum(r.parPct, 1)}%'));
    rows.add(_Row('NNT', r.nnt.isFinite ? fmtNum(r.nnt, 1) : '—',
        '需暴露多少人，才会多出 1 例'));
  }

  rows.add(_Row('χ²（Pearson）', fmtNum(r.chi2, 3), 'P = ${fmtP(r.pChi2)}'));
  rows.add(_Row('χ²（校正）', fmtNum(r.chi2Yates, 3), 'P = ${fmtP(r.pChi2Yates)}'));
  rows.add(_Row('Fisher 精确检验', 'P = ${fmtP(r.pFisher)}',
      '最小期望频数 ${fmtNum(r.minExpected, 2)}'));
  rows.add(_Row('合计', '${r.n} 例',
      '暴露 ${r.a + r.b} / 非暴露 ${r.c + r.d}'));
  return rows;
}

// ===========================================================================
// 1. 公共卫生统计（率与 CI / 样本量 / 百分位数）
// ===========================================================================

class EpiStatsPage extends StatefulWidget {
  const EpiStatsPage({super.key});

  @override
  State<EpiStatsPage> createState() => _EpiStatsPageState();
}

class _EpiStatsPageState extends State<EpiStatsPage> {
  // 率与置信区间
  final _pos = TextEditingController();
  final _tot = TextEditingController();

  // 样本量估算
  final _expP = TextEditingController(text: '50');
  final _margin = TextEditingController(text: '5');
  final _conf = TextEditingController(text: '95');
  final _popu = TextEditingController();

  // 百分位数
  final _data = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_pos, _tot, _expP, _margin, _conf, _popu, _data]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_pos, _tot, _expP, _margin, _conf, _popu, _data]) {
      c.dispose();
    }
    super.dispose();
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  /// 率的 95% 置信区间。
  ///
  /// 用 **Wilson 计分法**，不用课本上那个正态近似。原因：
  /// 公卫现场经常遇到「10 个人里 1 个阳性」这种极端比例，
  /// 正态近似会算出负的下限（比如 −3.2%），没法写进报告；
  /// Wilson 法在 p 接近 0 / 1、样本量小时都还正常，现在也是 WHO 推荐的做法。
  List<_Row> get _propRows {
    final x = int.tryParse(_pos.text.trim());
    final n = int.tryParse(_tot.text.trim());
    if (x == null || n == null || n <= 0 || x < 0 || x > n) return const <_Row>[];

    final p = x / n;
    final z = 1.96;
    final z2 = z * z;
    final denom = 1 + z2 / n;
    final center = (p + z2 / (2 * n)) / denom;
    final half = z *
        math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) /
        denom;

    return <_Row>[
      _Row('阳性率', '${fmtNum(p * 100, 2)}%', '$x / $n'),
      _Row('95%CI（Wilson）', fmtCi(center - half, center + half, 4)),
      _Row('95%CI（百分数）',
          '${fmtNum((center - half) * 100, 2)}% ~ ${fmtNum((center + half) * 100, 2)}%'),
      _Row('标准误 SE', fmtNum(math.sqrt(p * (1 - p) / n), 4)),
      _Row('分母 n', '$n', '阴性 ${n - x} 例'),
    ];
  }

  /// 估计总体率所需的样本量（简单随机抽样）
  List<_Row> get _sampleRows {
    final p = _d(_expP) / 100;
    final d = _d(_margin) / 100;
    final conf = _d(_conf);
    if (p <= 0 || p >= 1 || d <= 0 || conf <= 0 || conf >= 100) return const <_Row>[];

    final z = _zFor(conf);
    var n = z * z * p * (1 - p) / (d * d);
    final nCeil = n.ceil();

    final rows = <_Row>[
      _Row('所需样本量', '$nCeil 人',
          '预期率 ${fmtNum(p * 100, 2)}%，允许误差 ±${fmtNum(d * 100, 2)}%，'
          '置信水平 ${fmtNum(conf, 1)}%'),
      _Row('Z 值', fmtNum(z, 4), '双侧 ${fmtNum(conf, 1)}% 对应的标准正态分位数'),
    ];

    // 已知总体规模时，按有限总体做校正
    final nPop = int.tryParse(_popu.text.trim());
    if (nPop != null && nPop > 0) {
      final adj = (nCeil * nPop / (nCeil + nPop - 1)).ceil();
      rows.add(_Row('有限总体校正', '$adj 人',
          '总体只有 $nPop 人时的实际需要量（比 $nCeil 小）'));
    }
    rows.add(_Row('提示', '按简单随机抽样估算',
        '整群抽样 / 分层抽样需要再乘设计效应（一般 1.5~2）'));
    return rows;
  }

  double _zFor(double conf) {
    // 双侧置信水平 → 分位数。常用值直接给，其余走 normInv。
    //
    // 这里**故意不用 map**，尤其是不能用 const map：Dart 规定常量 map 的 key
    // 不能是重写了 == / hashCode 的类，而 double 恰好重写了，于是
    //   const <double, double>{95: 1.96}
    // 会直接编译报错 const_map_key_not_primitive_equality（run #19 就死在这）。
    // 就算去掉 const 也没必要——五个值用 if 还更快，且顺带避开浮点相等的坑：
    // 置信水平是用户从下拉框选的整数，双等号比较是安全的。
    if (conf == 80) return 1.2816;
    if (conf == 90) return 1.6449;
    if (conf == 95) return 1.9600;
    if (conf == 99) return 2.5758;
    if (conf == 99.9) return 3.2905;
    return normInv(1 - (1 - conf / 100) / 2);
  }

  List<_Row> get _pctRows {
    final xs = _data.text
        .split(RegExp(r'[\s,，、;；]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    if (xs.isEmpty) return const <_Row>[];
    final m = mean(xs);
    final s = sd(xs);
    final se = xs.length > 1 ? s / math.sqrt(xs.length) : double.nan;
    // 均数的 95%CI 用 t 分布（小样本必须用 t，用 z 会偏窄）
    final tv = xs.length > 1 ? _tCrit(0.95, xs.length - 1) : double.nan;

    return <_Row>[
      _Row('n', '${xs.length}'),
      _Row('均数', fmtNum(m, 3)),
      _Row('标准差', fmtNum(s, 3)),
      _Row('标准误', fmtNum(se, 3)),
      _Row('均数 95%CI',
          tv.isFinite ? fmtCi(m - tv * se, m + tv * se, 3) : '—',
          '按 t 分布（自由度 ${xs.length - 1}）'),
      _Row('P2.5', fmtNum(percentile(xs, 0.025), 3)),
      _Row('P25', fmtNum(percentile(xs, 0.25), 3)),
      _Row('P50（中位数）', fmtNum(percentile(xs, 0.5), 3)),
      _Row('P75', fmtNum(percentile(xs, 0.75), 3)),
      _Row('P97.5', fmtNum(percentile(xs, 0.975), 3)),
      _Row('最小 / 最大',
          '${fmtNum(xs.reduce(math.min), 3)} / ${fmtNum(xs.reduce(math.max), 3)}'),
    ];
  }

  /// t 分布双侧临界值：先给常用值，其余用二分法反解。
  double _tCrit(double conf, int df) {
    if (df <= 0) return double.nan;
    final alpha = 1 - conf;
    // 二分：要找 t 使双尾 P = alpha
    var lo = 0.0, hi = 200.0;
    for (var i = 0; i < 80; i++) {
      final mid = (lo + hi) / 2;
      if (tTwoTail(mid, df.toDouble()) > alpha) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  @override
  Widget build(BuildContext context) {
    final prop = _propRows;
    final sample = _sampleRows;
    final pct = _pctRows;

    return ToolScaffold(
      title: '公共卫生统计',
      subtitle: '率与置信区间 · 样本量估算 · 百分位数',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const ToolSection('① 率与 95% 置信区间'),
          Row(children: [
            Expanded(
                child: _Num(label: '阳性数', c: _pos, onChanged: _refresh, hint: '如 12')),
            const SizedBox(width: 10),
            Expanded(
                child: _Num(label: '受检总数', c: _tot, onChanged: _refresh, hint: '如 200')),
          ]),
          const SizedBox(height: 10),
          if (prop.isNotEmpty) _ResultTable(rows: prop, hi: const {'阳性率'}),
          const SizedBox(height: 6),
          const _Hint('用的是 Wilson 计分法。比例很极端（比如 10 个人里 1 个阳性）时，'
              '正态近似会算出负数下限，Wilson 法不会，WHO 也是这么推荐的。'),

          const ToolSection('② 样本量估算（估计总体率）'),
          Row(children: [
            Expanded(
                child: _Num(label: '预期率 %', c: _expP, onChanged: _refresh, decimal: true)),
            const SizedBox(width: 8),
            Expanded(
                child: _Num(label: '允许误差 ±%', c: _margin, onChanged: _refresh, decimal: true)),
            const SizedBox(width: 8),
            Expanded(
                child: _Num(label: '置信水平 %', c: _conf, onChanged: _refresh, decimal: true)),
          ]),
          const SizedBox(height: 10),
          _Num(label: '总体规模（可空，填了做有限总体校正）',
              c: _popu, onChanged: _refresh, hint: '不填按无限总体'),
          const SizedBox(height: 10),
          if (sample.isNotEmpty) _ResultTable(rows: sample, hi: const {'所需样本量'}),

          const ToolSection('③ 一组数据的描述与百分位数'),
          TextField(
            controller: _data,
            onChanged: (_) => _refresh(),
            maxLines: 4,
            minLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: '把数据粘进来，空格 / 逗号 / 换行分开都行，例如：\n'
                  '12 15 9 18 22 7 30',
              hintStyle: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          if (pct.isNotEmpty) _ResultTable(rows: pct, hi: const {'均数'}),
        ],
      ),
    );
  }
}

// ===========================================================================
// 2. 病例对照研究
// ===========================================================================

/// 输入口径严格按公卫教材：
///   病例组里「有暴露史」a、「无暴露史」b
///   对照组里「有暴露史」c、「无暴露史」d
/// 输出以 OR 为核心（病例对照研究算不出发病率，只能算 OR）。
class CaseControlPage extends StatefulWidget {
  const CaseControlPage({super.key});

  @override
  State<CaseControlPage> createState() => _CaseControlPageState();
}

class _CaseControlPageState extends State<CaseControlPage> {
  final _a = TextEditingController(text: '30');   // 病例·暴露
  final _b = TextEditingController(text: '20');   // 病例·非暴露
  final _c = TextEditingController(text: '10');   // 对照·暴露
  final _d = TextEditingController(text: '40');   // 对照·非暴露

  @override
  void initState() {
    super.initState();
    for (final c in [_a, _b, _c, _d]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_a, _b, _c, _d]) {
      c.dispose();
    }
    super.dispose();
  }

  int _i(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final a = _i(_a), b = _i(_b), c = _i(_c), d = _i(_d);
    final has = (a + b + c + d) > 0;
    final r = analyze2x2(a, b, c, d);
    final rows = <_Row>[
      _Row('暴露率（病例组）', '${fmtNum(a + b > 0 ? a / (a + b) * 100 : double.nan, 2)}%',
          '$a / ${a + b}'),
      _Row('暴露率（对照组）', '${fmtNum(c + d > 0 ? c / (c + d) * 100 : double.nan, 2)}%',
          '$c / ${c + d}'),
      _Row('比值比 OR', fmtNum(r.or_, 3),
          r.orHi.isFinite ? '95%CI ${fmtCi(r.orLo, r.orHi, 3)}' : null),
      _Row('χ²（Pearson）', fmtNum(r.chi2, 3), 'P = ${fmtP(r.pChi2)}'),
      _Row('χ²（校正）', fmtNum(r.chi2Yates, 3), 'P = ${fmtP(r.pChi2Yates)}'),
      _Row('Fisher 精确检验', 'P = ${fmtP(r.pFisher)}',
          '最小期望频数 ${fmtNum(r.minExpected, 2)}'),
      _Row('OR 的判读', _orText(r.or_, r.orLo, r.orHi)),
    ];

    return ToolScaffold(
      title: '病例对照研究',
      subtitle: 'OR · 95% 可信区间 · 卡方 · P 值',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Hint('填的是「人数」。病例组、对照组各分「有暴露史 / 无暴露史」两栏。\n'
              '病例对照研究是从「病」往回找「因」，算不出发病率，所以核心指标是 OR（比值比）。'),
          const SizedBox(height: 14),
          const ToolSection('病例组'),
          Row(children: [
            Expanded(child: _Num(label: '有暴露史 a', c: _a, onChanged: _refresh)),
            const SizedBox(width: 10),
            Expanded(child: _Num(label: '无暴露史 b', c: _b, onChanged: _refresh)),
          ]),
          const SizedBox(height: 12),
          const ToolSection('对照组'),
          Row(children: [
            Expanded(child: _Num(label: '有暴露史 c', c: _c, onChanged: _refresh)),
            const SizedBox(width: 10),
            Expanded(child: _Num(label: '无暴露史 d', c: _d, onChanged: _refresh)),
          ]),
          const SizedBox(height: 14),
          if (has) _ResultTable(rows: rows, hi: const {'比值比 OR'}),
          if (has) const SizedBox(height: 10),
          if (has)
            Text(
              a * d >= b * c
                  ? 'OR > 1：提示该暴露因素可能增加发病风险。'
                  : 'OR < 1：提示该暴露因素可能是保护因素（或病例组暴露本就少）。',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          if (has && r.useFisher) ...[
            const SizedBox(height: 10),
            _Hint('最小期望频数只有 ${fmtNum(r.minExpected, 2)}（<5），'
                '卡方检验在这里不可靠，请以 **Fisher 精确检验** 的 P 值为准。',
                icon: Icons.warning_amber_outlined),
          ],
        ],
      ),
    );
  }

  String _orText(double or_, double lo, double hi) {
    if (!or_.isFinite) return '—';
    final s = or_ > 1 ? '风险增加' : (or_ < 1 ? '风险降低' : '无关联');
    if (!hi.isFinite || !lo.isFinite) return s;
    // 区间跨过 1 → 差异没有统计学意义
    final sig = (lo > 1) || (hi < 1);
    return '$s；95%CI ${sig ? "不含 1，差异有统计学意义" : "含 1，差异无统计学意义"}';
  }
}

// ===========================================================================
// 3. 队列研究
// ===========================================================================

/// 队列研究：从「因」看「果」，能直接算发病率，所以核心指标是 RR。
class CohortPage extends StatefulWidget {
  const CohortPage({super.key});

  @override
  State<CohortPage> createState() => _CohortPageState();
}

class _CohortPageState extends State<CohortPage> {
  final _a = TextEditingController(text: '40');
  final _b = TextEditingController(text: '160');
  final _c = TextEditingController(text: '15');
  final _d = TextEditingController(text: '185');

  @override
  void initState() {
    super.initState();
    for (final c in [_a, _b, _c, _d]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_a, _b, _c, _d]) {
      c.dispose();
    }
    super.dispose();
  }

  int _i(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final a = _i(_a), b = _i(_b), c = _i(_c), d = _i(_d);
    final r = analyze2x2(a, b, c, d);
    final has = r.n > 0;
    final rows = twoByTwoRows(r, cohort: true);

    return ToolScaffold(
      title: '队列研究',
      subtitle: 'RR · AR · PAR · 卡方 · P 值',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Hint('暴露组、非暴露组各分「发病 / 未发病」两栏，填人数。\n'
              '队列研究是从「因」看到「果」，能直接算两组发病率，所以核心指标是 RR（相对危险度）。'),
          const SizedBox(height: 14),
          const ToolSection('暴露组'),
          Row(children: [
            Expanded(child: _Num(label: '发病 a', c: _a, onChanged: _refresh)),
            const SizedBox(width: 10),
            Expanded(child: _Num(label: '未发病 b', c: _b, onChanged: _refresh)),
          ]),
          const SizedBox(height: 12),
          const ToolSection('非暴露组'),
          Row(children: [
            Expanded(child: _Num(label: '发病 c', c: _c, onChanged: _refresh)),
            const SizedBox(width: 10),
            Expanded(child: _Num(label: '未发病 d', c: _d, onChanged: _refresh)),
          ]),
          const SizedBox(height: 14),
          if (has) _ResultTable(rows: rows, hi: const {'相对危险度 RR'}),
          if (has && r.useFisher) ...[
            const SizedBox(height: 10),
            _Hint('最小期望频数只有 ${fmtNum(r.minExpected, 2)}（<5），'
                '请以 **Fisher 精确检验** 的 P 值为准。',
                icon: Icons.warning_amber_outlined),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 4. 食物中毒分析
// ===========================================================================

/// 一次食物中毒调查里，往往要同时分析好几样可疑食物。
/// 这个页面就是「一对多」的 2×2 表：每样食物一行，各算一遍 RR 与卡方，
/// 最后按 RR 从大到小排 —— 排最前面的那几样就是最可疑的。
class FoodPoisoningPage extends StatefulWidget {
  const FoodPoisoningPage({super.key});

  @override
  State<FoodPoisoningPage> createState() => _FoodPoisoningPageState();
}

class _FoodItem {
  final TextEditingController name;
  final TextEditingController a;   // 食用·发病
  final TextEditingController b;   // 食用·未发病
  final TextEditingController c;   // 未食用·发病
  final TextEditingController d;   // 未食用·未发病
  _FoodItem({String n = '', String va = '', String vb = '', String vc = '', String vd = ''})
      : name = TextEditingController(text: n),
        a = TextEditingController(text: va),
        b = TextEditingController(text: vb),
        c = TextEditingController(text: vc),
        d = TextEditingController(text: vd);

  void dispose() {
    name.dispose();
    a.dispose();
    b.dispose();
    c.dispose();
    d.dispose();
  }
}

class _FoodPoisoningPageState extends State<FoodPoisoningPage> {
  final List<_FoodItem> _items = <_FoodItem>[];

  @override
  void initState() {
    super.initState();
    _add('凉拌菜');
    _add('卤味');
    _add('');
  }

  void _add([String name = '']) {
    final it = _FoodItem(n: name);
    for (final c in [it.name, it.a, it.b, it.c, it.d]) {
      c.addListener(_refresh);
    }
    _items.add(it);
  }

  void _remove(int i) {
    final it = _items.removeAt(i);
    it.dispose();
    setState(() {});
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final it in _items) {
      it.dispose();
    }
    super.dispose();
  }

  int _i(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 逐项分析，只保留填了数的
    final analyzed = <(_FoodItem, TwoByTwoResult)>[];
    for (final it in _items) {
      final r = analyze2x2(_i(it.a), _i(it.b), _i(it.c), _i(it.d));
      if (r.n > 0) analyzed.add((it, r));
    }
    // 按 RR 从大到小排：RR 越大越可疑。算不出 RR 的排最后。
    analyzed.sort((x, y) {
      final rx = x.$2.rr.isFinite ? x.$2.rr : -1.0;
      final ry = y.$2.rr.isFinite ? y.$2.rr : -1.0;
      return ry.compareTo(rx);
    });

    final totalCases = analyzed.isEmpty ? 0 : analyzed.first.$2.c + analyzed.first.$2.a;

    return ToolScaffold(
      title: '食物中毒分析',
      subtitle: '逐项食物算 RR，按可疑程度排序',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Hint('每样可疑食物填四格人数：吃过 / 没吃过的里面，各有几人发病、几人没发病。\n'
              '结果按 RR 从大到小排，**排最前面的最可疑**。'),

          if (analyzed.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ResultTable(
              title: '分析结果（按 RR 降序）',
              rows: [
                for (final (it, r) in analyzed)
                  _Row(
                    it.name.text.trim().isEmpty ? '（未命名）' : it.name.text.trim(),
                    'RR ${fmtNum(r.rr, 2)}   χ² ${fmtNum(r.chi2, 2)}   P ${fmtP(r.pChi2)}',
                    '食用组 ${r.a}/${r.a + r.b}（${fmtNum(r.ie * 100, 1)}%）  ·  '
                    '未食用组 ${r.c}/${r.c + r.d}（${fmtNum(r.i0 * 100, 1)}%）',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('总病例数（按第一项估算）：$totalCases 例',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],

          const ToolSection('逐项录入'),
          for (var i = 0; i < _items.length; i++) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _items[i].name,
                            onChanged: (_) => _refresh(),
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: UnderlineInputBorder(),
                              hintText: '食物名，如：凉拌猪耳',
                              hintStyle: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删掉这一项',
                          onPressed: () => _remove(i),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      SizedBox(
                        width: 56,
                        child: Text('发病',
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant)),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text('未发病',
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      SizedBox(
                        width: 56,
                        child: Text('吃过',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                      SizedBox(
                        width: 56,
                        child: _mini(_items[i].a),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(width: 56, child: _mini(_items[i].b)),
                    ]),
                    const SizedBox(height: 6),
                    Row(children: [
                      SizedBox(
                        width: 56,
                        child: Text('没吃',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                      SizedBox(width: 56, child: _mini(_items[i].c)),
                      const SizedBox(width: 8),
                      SizedBox(width: 56, child: _mini(_items[i].d)),
                    ]),
                  ],
                ),
              ),
            ),
          ],
          OutlinedButton.icon(
            onPressed: () => setState(() => _add()),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('再加一样食物'),
          ),
        ],
      ),
    );
  }

  Widget _mini(TextEditingController c) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: _intOnly,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        ),
      );
}
