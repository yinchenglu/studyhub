import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/stats.dart';
import '../../core/stats_hier.dart';
import 'tool_pages.dart';

// ===========================================================================
// 公卫小工具 第三批（v1.6.0）
//
//   ① 杀虫剂流量计算   —— 现场配药时设备该开多大流量
//   ② 实时再生指数 Rt  —— 逐日估传染速度
//   ③ 分层分析         —— 多个四格表合并（Mantel-Haenszel）+ 齐性检验
//   ④ 交互作用         —— 两因素加法/乘法交互（RERI / API / S）
//
// 这四个和 ph.dart / ph2.dart 一样，都是「离线、纯 Dart、不联网」的工具，
// 数学部分全部在 core/stats_hier.dart 里，这个文件只管界面。
//
// 关于 UI 小组件：`_Field` / `_Tbl` / `_Note` 和 ph.dart 里的同名东西
// 是各自文件私有的（Dart 的下划线私有是「按文件」而不是「按类」），
// 所以不会冲突，也允许这里的排版按自己的需要长。
// ===========================================================================

// ===========================================================================
// 公共小部件
// ===========================================================================

/// 一个带标签的数字输入框。
class _Field extends StatelessWidget {
  final String label;
  final TextEditingController c;
  final VoidCallback onChanged;
  final bool allowDecimal;
  final String? suffix;

  const _Field({
    required this.label,
    required this.c,
    required this.onChanged,
    this.allowDecimal = true,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(
          decimal: allowDecimal, signed: allowDecimal),
      inputFormatters: [
        if (!allowDecimal) FilteringTextInputFormatter.digitsOnly,
      ],
      onChanged: (_) => onChanged(),
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
    );
  }
}

/// 结果表的一行。`hi` 为真时加粗高亮（关键指标）。
class _Row3 {
  final String name;
  final String value;
  final String? note;
  final bool hi;
  const _Row3(this.name, this.value, [this.note, this.hi = false]);
}

class _Tbl extends StatelessWidget {
  final List<_Row3> rows;
  const _Tbl({required this.rows});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        rows[i].name,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          fontWeight: rows[i].hi ? FontWeight.w700 : FontWeight.normal,
                          color: rows[i].hi ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            rows[i].value,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: rows[i].hi ? FontWeight.w700 : FontWeight.w500,
                              color: rows[i].hi ? scheme.primary : scheme.onSurface,
                            ),
                          ),
                          if (rows[i].note != null)
                            Text(
                              rows[i].note!,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 10.5, color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (i != rows.length - 1)
                Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一条解释性提示。`**加粗**` 会渲染成加粗。
class _Note extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Note(this.text, {this.icon = Icons.info_outline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = text.split('**');
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(
        text: parts[i],
        style: TextStyle(fontWeight: i.isOdd ? FontWeight.w700 : FontWeight.normal),
      ));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
                children: spans,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// ① 杀虫剂流量计算
// ===========================================================================

/// 消杀作业里最常被问的一个数：「我这台喷雾器，阀门该开到多少？」
///
/// 现场口径：
///   需要流量(ml/s) = 目标用药量(ml/m²) × 喷幅(m) × 行进速度(m/s)
/// 因为「每秒扫过的面积」= 喷幅 × 速度，乘上单位面积用药量就是每秒要喷掉的药量。
class SprayFlowPage extends StatefulWidget {
  const SprayFlowPage({super.key});

  @override
  State<SprayFlowPage> createState() => _SprayFlowPageState();
}

class _SprayFlowPageState extends State<SprayFlowPage> {
  // 默认值就是用户点名的：喷幅 5 米、目标用药量 1 ml/m²、行进速度 1 米/秒
  final _dose = TextEditingController(text: '1');
  final _swath = TextEditingController(text: '5');
  final _speed = TextEditingController(text: '1');
  /// 反算用：设备实际能达到的流量（ml/min）
  final _equipMlMin = TextEditingController(text: '');

  @override
  void initState() {
    super.initState();
    for (final c in [_dose, _swath, _speed, _equipMlMin]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_dose, _swath, _speed, _equipMlMin]) {
      c.dispose();
    }
    super.dispose();
  }

  static double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final dose = _d(_dose);
    final swath = _d(_swath);
    final speed = _d(_speed);
    final ok = dose > 0 && swath > 0 && speed > 0;
    final r = ok ? sprayFlow(doseMlPerM2: dose, swathM: swath, speedMps: speed) : null;

    // 反算：设备流量固定时，应该走多快
    final equip = _d(_equipMlMin);
    final backSpeed = (equip > 0 && dose > 0 && swath > 0)
        ? (equip / 60) / (dose * swath)
        : double.nan;

    return ToolScaffold(
      title: '杀虫剂流量计算',
      subtitle: '设备该开多大流量 · ml/s · ml/min · L/ha',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Note('按「目标用药量 × 喷幅 × 行进速度」算 —— 这是消杀现场最通用的一套口径。'
              '**单位别搞混**：用药量填 ml/m²，喷幅填米，速度填米/秒。'),
          const SizedBox(height: 14),

          const ToolSection('作业参数'),
          Row(children: [
            Expanded(
              child: _Field(
                  label: '目标用药量', c: _dose, onChanged: _refresh, suffix: 'ml/m²'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Field(label: '喷幅', c: _swath, onChanged: _refresh, suffix: 'm'),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _Field(
                  label: '行进速度', c: _speed, onChanged: _refresh, suffix: 'm/s'),
            ),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox()),
          ]),
          const SizedBox(height: 6),
          const _Note('喷幅是「一次走过能喷到多宽」，不是喷头个数；'
              '行进速度是人推着机器走的实际速度，不是标称档位。'
              '**两个都建议现场实测一次**（一般 1 m/s 就是人正常步速）。'),

          if (r != null) ...[
            const SizedBox(height: 16),
            ToolSection('设备应该设置的流量'),
            _Tbl(rows: [
              _Row3('流量（ml/s）', fmtNum(r.mlPerSec, 2), '每秒喷出多少毫升', true),
              _Row3('流量（ml/min）', fmtNum(r.mlPerMin, 1), '流量计 / 阀门刻度一般看这个', true),
              _Row3('流量（L/h）', fmtNum(r.lPerHour, 2), '配药、估耗药量用'),
              _Row3('处理面积（m²/min）', fmtNum(r.m2PerMin, 1), '每分钟喷过多大地方'),
              _Row3('处理面积（m²/s）', fmtNum(r.m2PerSec, 2)),
              _Row3('处理面积（ha/min）', fmtNum(r.haPerMin, 4), '1 公顷 = 10000 m²'),
              _Row3('用药量（L/ha）', fmtNum(r.lPerHa, 2), '每公顷要用多少升药液'),
            ]),
            const SizedBox(height: 10),
            _Note('一桶 16 L 药液大约能喷 **${fmtNum(16000 / r.mlPerMin, 1)} 分钟**，'
                '覆盖 **${fmtNum(16000 / dose, 0)} m²**'
                '（≈ ${fmtNum(16000 / dose / 10000, 3)} 公顷）。'),

            const SizedBox(height: 16),
            ToolSection('反过来算：设备流量固定时该走多快'),
            Row(children: [
              Expanded(
                child: _Field(
                    label: '设备实际流量', c: _equipMlMin, onChanged: _refresh, suffix: 'ml/min'),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SizedBox()),
            ]),
            const SizedBox(height: 10),
            if (backSpeed.isFinite && backSpeed > 0)
              _Tbl(rows: [
                _Row3('应该走的速度', '${fmtNum(backSpeed, 2)} m/s',
                    '≈ ${fmtNum(backSpeed * 60, 1)} m/min', true),
                _Row3('换算成步速', '${fmtNum(backSpeed * 3.6, 2)} km/h'),
              ])
            else
              const _Note('填上设备实际能达到的流量（ml/min），就能反算出应该走多快 —— '
                  '现场调不了阀门的时候，用走速来控制用药量。'),
          ] else ...[
            const SizedBox(height: 16),
            const _Note('三个参数都要大于 0 才算得出来。', icon: Icons.error_outline),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// ② 实时再生指数 Rt
// ===========================================================================

/// 实时再生指数（effective reproduction number）。
///
/// 用的是 **Cori 法**（EpiEstim 那一套，也是现在各级疾控最常用的口径）：
///     Rt = 当天新增 / Σ(序列间隔权重 × 前几天的病例数)
/// 直觉：今天的病例是前几天那些病例传出来的，分母就是「按传染力加权的
/// 历史病例数」，一比就是「平均一个人传给了几个人」。
///
/// 判读：Rt > 1 表示疫情在扩大，< 1 在收敛，= 1 是平台期。
class RtPage extends StatefulWidget {
  const RtPage({super.key});

  @override
  State<RtPage> createState() => _RtPageState();
}

class _RtPageState extends State<RtPage> {
  final _data = TextEditingController(
      text: '12,15,18,22,26,31,35,40,44,47,52,55,58,60,63,65,66,68,70,71');
  final _siMean = TextEditingController(text: '7');
  final _siSd = TextEditingController(text: '3');
  final _window = TextEditingController(text: '7');

  @override
  void initState() {
    super.initState();
    for (final c in [_data, _siMean, _siSd, _window]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_data, _siMean, _siSd, _window]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 把用户粘的文本解析成一串非负整数。
  ///
  /// 容忍中文逗号、换行、空格、制表符 —— 从 Excel 里复制出来的东西
  /// 各种分隔符都有，只认英文逗号会让人以为工具坏了。
  List<int> _parse(String s) {
    final out = <int>[];
    for (final piece in s.split(RegExp(r'[^0-9.\-]+'))) {
      final t = piece.trim();
      if (t.isEmpty) continue;
      final v = double.tryParse(t);
      if (v == null) continue;
      out.add(v < 0 ? 0 : v.round());
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cases = _parse(_data.text);
    final siMean = double.tryParse(_siMean.text.trim()) ?? 7;
    final siSd = double.tryParse(_siSd.text.trim()) ?? 3;
    final win = int.tryParse(_window.text.trim()) ?? 7;

    final pts = (cases.length >= 2 && siMean > 0 && siSd > 0 && win >= 1)
        ? estimateRt(cases, serialMean: siMean, serialSd: siSd, window: win)
        : const <RtPoint>[];
    final valid = pts.where((p) => p.available).toList();
    final last = valid.isEmpty ? null : valid.last;

    return ToolScaffold(
      title: '实时再生指数 Rt',
      subtitle: 'Cori 法逐日估计 · 含 95% 可信区间',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Note('Rt 是「现在一个病人平均能传染几个人」：**> 1 疫情在扩大，< 1 在收敛**。\n'
              '算法是 Cori 法（EpiEstim 口径）：今天的病例 ✕ 序列间隔权重 → 推出每代传播数；'
              '可信区间按当天的病例数服从泊松分布推出来（不是拍脑袋的正负号）。'),
          const SizedBox(height: 14),

          const ToolSection('每日新增病例（从早到晚）'),
          TextField(
            controller: _data,
            maxLines: 4,
            minLines: 3,
            keyboardType: TextInputType.multiline,
            onChanged: (_) => _refresh(),
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: const InputDecoration(
              hintText: '例如：12,15,18,22,26,31 ……（也可以一行一个，或直接从 Excel 粘一列）',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.all(10),
            ),
          ),
          const SizedBox(height: 6),
          Text('共解析到 ${cases.length} 天的数据',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),

          const SizedBox(height: 14),
          const ToolSection('参数'),
          Row(children: [
            Expanded(
              child: _Field(
                  label: '序列间隔均值', c: _siMean, onChanged: _refresh, suffix: '天'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Field(label: '序列间隔标准差', c: _siSd, onChanged: _refresh),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _Field(label: '滑动窗口', c: _window, onChanged: _refresh, suffix: '天'),
            ),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox()),
          ]),
          const SizedBox(height: 6),
          const _Note('**序列间隔**是「A 发病到被 A 传染的 B 发病」的平均天数，'
              '多数呼吸道传染病取 5~8 天，默认 7 天。'
              '不知道就用默认值 —— 它主要影响曲线的**水平**，不影响涨跌方向。'),

          if (last != null) ...[
            const SizedBox(height: 16),
            ToolSection('最新一天的估计'),
            _Tbl(rows: [
              _Row3('Rt（第 ${last.day} 天）', fmtNum(last.rt, 2),
                  '95%CI ${fmtCi(last.lo, last.hi, 2)}', true),
              _Row3('当天新增', '${last.cases} 例'),
              _Row3('近 7 天日均', fmtNum(last.ma7, 1), '例/天'),
              _Row3('判读', _rtText(last.rt), _intervalText(last)),
            ]),
            const SizedBox(height: 10),
            _Note(rtTrendText(pts)),
            const SizedBox(height: 16),
            ToolSection('逐日 Rt（最近 ${math.min(14, pts.length)} 天）'),
            _RtChart(points: pts, scheme: scheme),
            const SizedBox(height: 12),
            _Tbl(rows: [
              for (final p in pts.length > 14 ? pts.sublist(pts.length - 14) : pts)
                _Row3(
                  '第 ${p.day} 天',
                  p.available ? fmtNum(p.rt, 2) : '—',
                  p.available
                      ? '新增 ${p.cases} · CI ${fmtCi(p.lo, p.hi, 1)}'
                      : '新增 ${p.cases}（前几天数据不够）',
                ),
            ]),
          ] else ...[
            const SizedBox(height: 16),
            const _Note('至少要 2 天数据、而且参数都填对才估得出来。'
                '天数太少时前几天会显示「—」，因为分母凑不齐。',
                icon: Icons.error_outline),
          ],

          const SizedBox(height: 16),
          const _Note('**这个数不能当结论用**：Rt 对序列间隔、报告及时性、'
              '假期漏报都很敏感，而且越靠近今天越不稳（最近几天的数还在补报）。'
              '实务上看**趋势**而不是某一天的点值 —— 连续一周都在 1 以上就是明确信号。'),
        ],
      ),
    );
  }

  static String _rtText(double rt) {
    if (!rt.isFinite) return '—';
    if (rt > 1.2) return '明显在扩大';
    if (rt > 1.0) return '略大于 1，疫情缓慢扩大';
    if (rt >= 0.8) return '略小于 1，疫情在收敛';
    return '明显在收敛';
  }

  static String _intervalText(RtPoint p) {
    if (!p.hi.isFinite) return '';
    if (p.lo > 1) return '可信区间整体 > 1，扩大有统计学意义';
    if (p.hi < 1) return '可信区间整体 < 1，收敛有统计学意义';
    return '可信区间跨过 1，目前看不出方向';
  }
}

/// 逐日 Rt 的柱状图。
///
/// 有意做成「一根柱子一个小方块」而不是 CustomPaint 折线：
/// 这个图只是给人看趋势的，柱子对「哪些天超过 1」这件事反而更直观，
/// 而且不用担心坐标轴刻度画歪。超过 1 画红、低于 1 画绿（国内习惯）。
class _RtChart extends StatelessWidget {
  final List<RtPoint> points;
  final ColorScheme scheme;
  const _RtChart({required this.points, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final show = points.length > 14 ? points.sublist(points.length - 14) : points;
    const maxRt = 3.0; // 超过 3 的都按顶格画
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final p in show)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (p.available)
                          Text(
                            fmtNum(p.rt, 1),
                            style: TextStyle(fontSize: 8, color: scheme.onSurfaceVariant),
                          ),
                        const SizedBox(height: 2),
                        Container(
                          height: p.available
                              ? (p.rt.clamp(0.0, maxRt) / maxRt) * 84
                              : 2,
                          decoration: BoxDecoration(
                            // 涨红跌绿（国内习惯）：Rt > 1 = 疫情在涨
                            color: !p.available
                                ? scheme.outlineVariant
                                : (p.rt > 1
                                    ? const Color(0xFFD93025)
                                    : const Color(0xFF1E8E3E)),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3)),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text('${p.day}',
                            style: TextStyle(fontSize: 8, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text('柱子：红 = Rt > 1（扩大），绿 = Rt < 1（收敛）；顶格是 Rt = 3。横轴是第几天。',
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

// ===========================================================================
// ③ 分层分析（Mantel-Haenszel）
// ===========================================================================

/// 一个分层的输入行。
class _StratumRow {
  final TextEditingController name;
  final TextEditingController a, b, c, d;
  _StratumRow({
    String n = '',
    String va = '30',
    String vb = '20',
    String vc = '10',
    String vd = '40',
  })  : name = TextEditingController(text: n),
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

/// 多个四格表合起来分析。
///
/// 应用场景很常见：把调查对象按年龄段、地区、性别分成几层，
/// 每层各自有一张四格表。这时候有两种问法：
///   ① 各层方向不一致 → 说明存在**效应修饰（交互）**，不该硬合并；
///   ② 各层方向一致但和粗算的不一样 → 说明存在**混杂**，合并后的值才可信。
/// Breslow-Day 检验回答①，粗算 vs 合并的对比回答②。
class StratifiedPage extends StatefulWidget {
  const StratifiedPage({super.key});

  @override
  State<StratifiedPage> createState() => _StratifiedPageState();
}

class _StratifiedPageState extends State<StratifiedPage> {
  /// true = 队列口径（暴露组/非暴露组 × 发病/未发病）
  /// false = 病例对照口径（病例组/对照组 × 暴露/非暴露）
  bool _cohort = true;

  late List<_StratumRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = <_StratumRow>[
      _StratumRow(n: '第 1 层', va: '40', vb: '160', vc: '15', vd: '185'),
    ];
    _bindAll();
  }

  void _bindAll() {
    for (final r in _rows) {
      for (final c in [r.name, r.a, r.b, r.c, r.d]) {
        c.addListener(_refresh);
      }
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _add() {
    setState(() {
      final r = _StratumRow(
        n: '第 ${_rows.length + 1} 层',
        va: '30',
        vb: '120',
        vc: '12',
        vd: '140',
      );
      for (final c in [r.name, r.a, r.b, r.c, r.d]) {
        c.addListener(_refresh);
      }
      _rows.add(r);
    });
  }

  void _del(int i) {
    setState(() {
      final r = _rows.removeAt(i);
      r.dispose();
    });
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  static int _i(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final strata = <Stratum>[
      for (final r in _rows) Stratum(_i(r.a), _i(r.b), _i(r.c), _i(r.d)),
    ];
    final r = mhAnalyze(strata);
    final has = r.k > 0;

    final aLabel = _cohort ? '暴露组·发病' : '病例组·暴露';
    final bLabel = _cohort ? '暴露组·未发病' : '病例组·非暴露';
    final cLabel = _cohort ? '非暴露·发病' : '对照组·暴露';
    final dLabel = _cohort ? '非暴露·未发病' : '对照组·非暴露';

    return ToolScaffold(
      title: '分层分析',
      subtitle: 'Mantel-Haenszel 合并 · Breslow-Day 齐性检验',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Note('把调查对象按某个特征（年龄、地区、性别…）分成几层，每层一张四格表，'
              '再用 **Mantel-Haenszel 法**合并成一个总估计。\n'
              '为什么要分层：只要各层内混进了别的因素，直接把所有人数加在一起算出来的'
              '估计就可能是错的 —— 分层能把这种**混杂**摘出去。'),
          const SizedBox(height: 12),

          // 口径
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('队列口径'),
                selected: _cohort,
                onSelected: (_) => setState(() => _cohort = true),
              ),
              ChoiceChip(
                label: const Text('病例对照口径'),
                selected: !_cohort,
                onSelected: (_) => setState(() => _cohort = false),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _cohort
                ? '队列口径：每层填「暴露组发病/未发病、非暴露组发病/未发病」，OR 和 RR 都能算。'
                : '病例对照口径：每层填「病例组暴露/非暴露、对照组暴露/非暴露」，只能算 OR。',
            style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),

          const SizedBox(height: 14),
          ToolSection('各层的四格表（${_rows.length} 层）'),
          for (var i = 0; i < _rows.length; i++) ...[
            _layerCard(context, i, aLabel, bLabel, cLabel, dLabel, strata[i]),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加一层'),
                ),
              ),
              if (_rows.length > 1) ...[
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => _del(_rows.length - 1),
                  icon: const Icon(Icons.remove, size: 18),
                  label: const Text('删最后一层'),
                ),
              ],
            ],
          ),

          if (has) ...[
            const SizedBox(height: 18),
            ToolSection('汇总分析'),
            _Tbl(rows: [
              _Row3('合并 OR（M-H）', fmtNum(r.orMh, 3),
                  r.orHi.isFinite
                      ? '95%CI ${fmtCi(r.orLo, r.orHi, 3)}'
                      : '各层有 0 格子，可信区间算不出来',
                  true),
              if (_cohort)
                _Row3('合并 RR（M-H）', fmtNum(r.rrMh, 3),
                    r.rrHi.isFinite ? '95%CI ${fmtCi(r.rrLo, r.rrHi, 3)}' : null,
                    true),
              _Row3('粗 OR（直接相加）', fmtNum(r.orCrude, 3), '不做分层直接算的那个'),
              if (_cohort)
                _Row3('粗 RR（直接相加）', fmtNum(r.rrCrude, 3)),
              _Row3('参与合并的层数', '${r.k} 层',
                  r.skipped > 0 ? '另有 ${r.skipped} 层四格表不完整，已跳过' : null),
            ]),

            const SizedBox(height: 12),
            const ToolSection('混杂判断（粗估计 vs 合并估计）'),
            _Tbl(rows: [
              _Row3('变化幅度',
                  r.confounding
                      ? '${fmtNum(((r.orCrude - r.orMh).abs() / (r.orMh == 0 ? 1 : r.orMh)) * 100, 1)}%'
                      : '${fmtNum(((r.orCrude - r.orMh).abs() / (r.orMh == 0 ? 1 : r.orMh)) * 100, 1)}%'),
              _Row3('结论', r.confounding ? '存在明显混杂' : '未见明显混杂',
                  r.confounding
                      ? '分层后的合并 OR 才是可信的估计值'
                      : '粗估计和合并估计接近，分层没有改变结论',
                  true),
            ]),

            const SizedBox(height: 12),
            const ToolSection('齐性检验（Breslow-Day）'),
            _Tbl(rows: [
              _Row3('χ²', fmtNum(r.bdChi2, 3), 'df = ${r.bdDf}'),
              _Row3('P 值', fmtP(r.bdP)),
              _Row3('结论', r.homogeneous ? '各层 OR 基本一致' : '各层 OR 明显不一致',
                  r.homogeneous
                      ? '可以放心合并；如果同时存在混杂，用合并值代替粗值'
                      : '说明有**效应修饰（交互）**，此时合并成一个数会掩盖真实差异 —— '
                          '应该分层报告，并去看「交互作用」那个工具',
                  true),
            ]),
          ] else ...[
            const SizedBox(height: 16),
            const _Note('至少要有 1 层的四格表填完整才算得出来。', icon: Icons.error_outline),
          ],

          const SizedBox(height: 16),
          const _Note('**为什么粗 OR 和合并 OR 会不一样**：粗算把各层的人混在一起，'
              '如果某层人数特别多、而那一层本身暴露率又高（比如老年组），'
              '它的权重就会把整体结果带偏。MH 法按每层的信息量加权，'
              '等于让每一层「各投一票」，这才是分层的意义。'),
        ],
      ),
    );
  }

  Widget _layerCard(
    BuildContext context,
    int i,
    String al,
    String bl,
    String cl,
    String dl,
    Stratum s,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final or = s.orCrude;
    final ci = s.orCi;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rows[i].name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '这一层的名字',
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '删掉这一层',
                  visualDensity: VisualDensity.compact,
                  onPressed: _rows.length > 1 ? () => _del(i) : null,
                  icon: const Icon(Icons.delete_outline, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: _Field(label: al, c: _rows[i].a, onChanged: _refresh, allowDecimal: false)),
              const SizedBox(width: 8),
              Expanded(child: _Field(label: bl, c: _rows[i].b, onChanged: _refresh, allowDecimal: false)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _Field(label: cl, c: _rows[i].c, onChanged: _refresh, allowDecimal: false)),
              const SizedBox(width: 8),
              Expanded(child: _Field(label: dl, c: _rows[i].d, onChanged: _refresh, allowDecimal: false)),
            ]),
            const SizedBox(height: 8),
            Text(
              s.usable
                  ? '这一层的 OR = ${fmtNum(or, 3)}'
                      '${ci.$1.isFinite ? '（95%CI ${fmtCi(ci.$1, ci.$2, 2)}）' : ''}'
                  : '这一层还没填完整',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// ④ 交互作用
// ===========================================================================

/// 两因素交互作用（effect modification / interaction）。
///
/// 加法尺度看 RERI，乘法尺度看 OR 的比值 —— 两个尺度可以不一致，
/// 报告里一般都要说清楚是哪个尺度上的交互。
class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});

  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> {
  final _nameA = TextEditingController(text: '因素 A');
  final _nameB = TextEditingController(text: '因素 B');

  // 每组：病例数 / 非病例（对照）数
  final _a11 = TextEditingController(text: '60'); final _n11 = TextEditingController(text: '100');
  final _a10 = TextEditingController(text: '30'); final _n10 = TextEditingController(text: '100');
  final _a01 = TextEditingController(text: '25'); final _n01 = TextEditingController(text: '100');
  final _a00 = TextEditingController(text: '10'); final _n00 = TextEditingController(text: '100');

  @override
  void initState() {
    super.initState();
    for (final c in [
      _nameA, _nameB, _a11, _n11, _a10, _n10, _a01, _n01, _a00, _n00,
    ]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _nameA, _nameB, _a11, _n11, _a10, _n10, _a01, _n01, _a00, _n00,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static int _i(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final A = _nameA.text.trim().isEmpty ? '因素 A' : _nameA.text.trim();
    final B = _nameB.text.trim().isEmpty ? '因素 B' : _nameB.text.trim();

    final a11 = _i(_a11), n11 = _i(_n11);
    final a10 = _i(_a10), n10 = _i(_n10);
    final a01 = _i(_a01), n01 = _i(_n01);
    final a00 = _i(_a00), n00 = _i(_n00);

    final ok = n11 > a11 && n10 > a10 && n01 > a01 && n00 > a00 &&
        a00 > 0 && a11 > 0 && a10 > 0 && a01 > 0;
    final r = ok
        ? analyzeInteraction(InteractionInput(
            a11: a11, n11: n11, a10: a10, n10: n10,
            a01: a01, n01: n01, a00: a00, n00: n00,
          ))
        : null;

    return ToolScaffold(
      title: '交互作用',
      subtitle: 'RERI · 归因比例 API · 协同指数 S',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Note('看两个因素**一起出现**时，作用是不是比「各自作用相加」还大。\n'
              '把调查对象按两个因素的暴露情况分成 4 组，每组填病例数和非病例数，'
              '以「两个都不暴露」那一组为参照算 OR。'),
          const SizedBox(height: 12),

          Row(children: [
            Expanded(child: TextField(
              controller: _nameA,
              onChanged: (_) => _refresh(),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  labelText: '因素 A 的名字', isDense: true, border: OutlineInputBorder()),
            )),
            const SizedBox(width: 10),
            Expanded(child: TextField(
              controller: _nameB,
              onChanged: (_) => _refresh(),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  labelText: '因素 B 的名字', isDense: true, border: OutlineInputBorder()),
            )),
          ]),

          const SizedBox(height: 14),
          ToolSection('四组数据（病例数 / 非病例数）'),
          _group(context, '$A ＋ $B ＋（两个都有）', _a11, _n11, r?.or11),
          const SizedBox(height: 8),
          _group(context, '$A ＋ $B －（只有 $A）', _a10, _n10, r?.or10),
          const SizedBox(height: 8),
          _group(context, '$A － $B ＋（只有 $B）', _a01, _n01, r?.or01),
          const SizedBox(height: 8),
          _group(context, '$A － $B －（都没有·参照组）', _a00, _n00, 1.0),

          if (r != null) ...[
            const SizedBox(height: 18),
            ToolSection('三个 OR'),
            _Tbl(rows: [
              _Row3('OR（$A＋$B＋）', fmtNum(r.or11, 3), '两个因素都有', true),
              _Row3('OR（$A＋$B－）', fmtNum(r.or10, 3), '只有 $A'),
              _Row3('OR（$A－$B＋）', fmtNum(r.or01, 3), '只有 $B'),
            ]),

            const SizedBox(height: 12),
            ToolSection('加法交互（关注的尺度）'),
            _Tbl(rows: [
              _Row3('RERI / ICR', fmtNum(r.reri, 3),
                  '= OR11 − OR10 − OR01 + 1', true),
              _Row3('归因比例 API', fmtNum(r.api, 3), '交互占总效应的比例'),
              _Row3('协同指数 S', fmtNum(r.s, 3), '> 1 协同 · < 1 拮抗'),
              _Row3('判读', r.additiveType, _additiveNote(r), true),
            ]),

            const SizedBox(height: 12),
            ToolSection('乘法交互'),
            _Tbl(rows: [
              _Row3('OR11 / (OR10 × OR01)', fmtNum(r.multRatio, 3),
                  '> 1 协同 · < 1 拮抗', true),
              _Row3('判读', r.multiplicativeType),
            ]),

            const SizedBox(height: 12),
            _Note(_summary(r, A, B)),
          ] else ...[
            const SizedBox(height: 16),
            const _Note('每组的病例数都要大于 0、且小于该组总人数，四个组都填全才算得出来。',
                icon: Icons.error_outline),
          ],

          const SizedBox(height: 16),
          const _Note('**加法交互和乘法交互是两回事**，结论可以相反 —— '
              '公共卫生上通常更看重加法尺度（它对应「有多少病例本可以避免」）。\n'
              '这里 RERI 给的是点估计：它的可信区间要用 delta 法或 bootstrap，'
              '需要专门软件，本工具不硬猜。要出正式结论请再用 R / Epi Info 复核一遍。'),
        ],
      ),
    );
  }

  Widget _group(
    BuildContext context,
    String title,
    TextEditingController cases,
    TextEditingController total,
    double? or,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _Field(label: '病例数', c: cases, onChanged: _refresh, allowDecimal: false)),
              const SizedBox(width: 8),
              Expanded(child: _Field(label: '非病例数', c: total, onChanged: _refresh, allowDecimal: false)),
            ]),
            const SizedBox(height: 6),
            Text(
              or == null ? '' : 'OR = ${fmtNum(or, 3)}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _additiveNote(InteractionResult r) {
    if (!r.reri.isFinite) return '';
    if (r.reri > 0) {
      return '两个因素同时存在时，发病风险的超额部分**大于**两者单独之和 —— '
          '这种协同在防制上有意义：掐掉一个因素，收益会超过它单独的作用。';
    }
    if (r.reri < 0) {
      return '两个因素同时存在时，超额风险反而比两者单独之和**更小** —— 属于拮抗。';
    }
    return '两个因素各自独立起作用，没有加法交互。';
  }

  static String _summary(InteractionResult r, String A, String B) {
    final mul = r.multRatio;
    final add = r.reri;
    final same = (add > 0 && mul > 1) || (add < 0 && mul < 1) || (add == 0 && (mul - 1).abs() < 0.05);
    if (same) {
      return '**加法尺度和乘法尺度结论一致**：$A 与 $B 之间'
          '${add > 0 ? '存在协同交互' : (add < 0 ? '存在拮抗交互' : '没有明显交互')}。';
    }
    return '**两个尺度结论不一致**：加法尺度上'
        '${add > 0 ? '表现为协同' : (add < 0 ? '表现为拮抗' : '看不出交互')}，'
        '乘法尺度上${mul > 1 ? '表现为协同' : (mul < 1 ? '表现为拮抗' : '看不出交互')}。'
        '这在实际数据里很常见，报告时要写明用的是哪个尺度。';
  }
}
