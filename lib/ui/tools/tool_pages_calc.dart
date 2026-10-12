import 'package:flutter/material.dart';

import 'tool_pages.dart';

/// 消杀计算器（消毒药品配比）
///
/// 来源：用户电脑上一直在用的 `消杀计算器.html`，v1.4.0 原样搬进 App。
/// 三种药剂的算法逐条对着原 html 核过，没有自己改动公式：
///
///   **84 消毒液** —— 原液浓度 %、目标浓度 mg/L、配药量 L
///     目标浓度先换成百分比：目标百分比 = 目标 mg/L ÷ 1000
///     需要原液 ml = 目标百分比 × 配药量 L × 100 ÷ 原液浓度 %
///     需要水   ml = 配药量 L × 1000 − 需要原液 ml
///     验算：5% 原液配 10 L 的 500 mg/L → 原液 10 ml、水 9990 ml ✓
///
///   **消毒片** —— 每片有效含量 mg、目标浓度 mg/L、配药量 L
///     需要片数 = ⌈目标浓度 × 配药量 ÷ 每片含量⌉（向上取整，药片没法掰半片）
///     验算：500 mg/片配 10 L 的 500 mg/L → 10 片 ✓
///
///   **消毒粉剂** —— 粉剂有效浓度 %、目标浓度 mg/L、配药量 L
///     需要粉剂 g = 目标浓度 × 配药量 ÷ (有效浓度 % × 10)
///     验算：60% 粉剂配 10 L 的 500 mg/L → 8.3 g（原版 toFixed(0) 显示 8 g）
///
/// 相对原 html 的两处改进（都是显示层面的，公式没动）：
///   * 原版要按「计算」才出结果，这里**边输边算**，少点一下；
///   * 原版 84 液那条水量的减法在极端输入下会算出负数，这里会明确提示
///     「原液本身就比配药量还多」，而不是甩一个 −3000ml 出来。
class DisinfectCalcPage extends StatefulWidget {
  const DisinfectCalcPage({super.key});

  @override
  State<DisinfectCalcPage> createState() => _DisinfectCalcPageState();
}

/// 三种药剂
enum _Reagent { liquid84, tablet, powder }

class _DisinfectCalcPageState extends State<DisinfectCalcPage> {
  _Reagent _tab = _Reagent.liquid84;

  // 84 消毒液：原液浓度 % / 目标浓度 mg/L / 配药量 L
  final _c84 = TextEditingController();
  final _t84 = TextEditingController();
  final _v84 = TextEditingController();

  // 消毒片：每片有效含量 mg / 目标浓度 mg/L / 配药量 L
  final _mgTablet = TextEditingController();
  final _tTablet = TextEditingController();
  final _vTablet = TextEditingController();

  // 粉剂：有效浓度 % / 目标浓度 mg/L / 配药量 L
  final _cPowder = TextEditingController();
  final _tPowder = TextEditingController();
  final _vPowder = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 边输边算：任何一格变了就重画一次结果
    for (final c in [_c84, _t84, _v84, _mgTablet, _tTablet, _vTablet, _cPowder, _tPowder, _vPowder]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_c84, _t84, _v84, _mgTablet, _tTablet, _vTablet, _cPowder, _tPowder, _vPowder]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 只接受正数。空串 / 非数字 / 0 都当「还没填」
  double? _num(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return (v == null || v <= 0) ? null : v;
  }

  /// 84 消毒液：返回 (原液 ml, 水 ml)；水为负表示输入不合理
  (double, double)? get _res84 {
    final c = _num(_c84);
    final t = _num(_t84);
    final v = _num(_v84);
    if (c == null || t == null || v == null) return null;
    final pure = (t / 1000) * v * 100 / c;
    return (pure, v * 1000 - pure);
  }

  /// 消毒片：需要多少片（向上取整）
  int? get _resTablet {
    final mg = _num(_mgTablet);
    final t = _num(_tTablet);
    final v = _num(_vTablet);
    if (mg == null || t == null || v == null) return null;
    return (t * v / mg).ceil();
  }

  /// 粉剂：需要多少克
  double? get _resPowder {
    final c = _num(_cPowder);
    final t = _num(_tPowder);
    final v = _num(_vPowder);
    if (c == null || t == null || v == null) return null;
    return (t * v) / (c * 10);
  }

  String _fmt(double v, {int digits = 1}) {
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ToolScaffold(
      title: '消杀计算器',
      subtitle: '按目标浓度算消毒液 / 片 / 粉的用量',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ---------------- 选药剂 ----------------
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _Reagent.values)
                ChoiceChip(
                  label: Text(_labelOf(e)),
                  selected: _tab == e,
                  onSelected: (_) => setState(() => _tab = e),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._fields(),
                  const SizedBox(height: 6),
                  _resultBox(scheme),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _reset,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('清空'),
                      ),
                      const Spacer(),
                      if (_resultText != null)
                        TextButton.icon(
                          onPressed: () => copyText(context, _resultText!),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('复制结果'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _notes(scheme),
        ],
      ),
    );
  }

  static String _labelOf(_Reagent r) => switch (r) {
        _Reagent.liquid84 => '84 消毒液',
        _Reagent.tablet => '消毒片',
        _Reagent.powder => '消毒粉剂',
      };

  List<Widget> _fields() => switch (_tab) {
        _Reagent.liquid84 => [
            _field(_c84, '原液浓度', '%', '瓶子上写的有效氯浓度，常见 5%'),
            _field(_t84, '目标浓度', 'mg/L', '要配到多少，普通消毒常见 500'),
            _field(_v84, '配药量', 'L', '一共要配多少升'),
          ],
        _Reagent.tablet => [
            _field(_mgTablet, '每片有效含量', 'mg/片', '如 500，看包装说明'),
            _field(_tTablet, '目标浓度', 'mg/L', '要配到多少，普通消毒常见 500'),
            _field(_vTablet, '配药量', 'L', '一共要配多少升'),
          ],
        _Reagent.powder => [
            _field(_cPowder, '粉剂有效浓度', '%', '如 60，看包装说明'),
            _field(_tPowder, '目标浓度', 'mg/L', '要配到多少，普通消毒常见 500'),
            _field(_vPowder, '配药量', 'L', '一共要配多少升'),
          ],
      };

  Widget _field(TextEditingController c, String label, String unit, String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '$label（$unit）',
            helperText: hint,
            helperMaxLines: 2,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  /// 结果文案；还没填全时为 null
  String? get _resultText {
    switch (_tab) {
      case _Reagent.liquid84:
        final r = _res84;
        if (r == null) return null;
        if (r.$2 < 0) return null;
        return '需要添加 ${_fmt(r.$1)}ml 84消毒液\n需要添加 ${r.$2.round()}ml 水';
      case _Reagent.tablet:
        final n = _resTablet;
        return n == null ? null : '需要添加 $n 片消毒片';
      case _Reagent.powder:
        final g = _resPowder;
        return g == null ? null : '需要添加 ${_fmt(g)}g 消毒粉剂';
    }
  }

  /// 84 液那条水量减出负数 = 输入不合理（原液比整桶药水还多）。
  /// 单独抽出来，省得在 build 里对 record 做空安全取值。
  bool get _tooConcentrated {
    if (_tab != _Reagent.liquid84) return false;
    final r = _res84;
    return r != null && r.$2 < 0;
  }

  Widget _resultBox(ColorScheme scheme) {
    final text = _resultText;

    if (_tooConcentrated) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '算出来的原液量比配药量还多 —— 检查一下原液浓度是不是填得太低了。',
                style: TextStyle(fontSize: 13, height: 1.5, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      );
    }

    if (text == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '把上面的格子填完，这里直接出结果',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: scheme.primary, width: 4)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16, height: 1.7, fontWeight: FontWeight.w500, color: scheme.onPrimaryContainer),
      ),
    );
  }

  void _reset() {
    for (final c in [_c84, _t84, _v84, _mgTablet, _tTablet, _vTablet, _cPowder, _tPowder, _vPowder]) {
      c.clear();
    }
  }

  Widget _notes(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 17, color: scheme.onSurfaceVariant),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                '三个页码对应三种药，换一种点上面的标签就行。\n'
                '常用目标浓度：普通物体表面 500 mg/L，餐具 / 果蔬 250 mg/L，'
                '污染物 1000~2000 mg/L（以产品说明为准）。\n'
                '配好的消毒液建议当天用完；原液别和洁厕灵混，会放出氯气。',
                style: TextStyle(fontSize: 11.5, height: 1.75, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
}
