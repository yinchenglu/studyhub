// ===========================================================================
// 高级计算（v2.3.2 整页重做）
//
// 按用户发的卡西欧 fx 系列计算器截图分析落地。截图里能落地的功能全做了：
//   * 三种显示模式：正常（智能）/ 数学（结果化成分数）/ 小数（强制小数）
//   * 角度 / 弧度切换（截图右上角「角度」）
//   * 三角 / 反三角 / 双曲（hyp 键把 sin/cos/tan 切成 sinh/cosh/tanh）
//   * SOLVE（解方程）、d/dx（数值导数）、∫dx（定积分）、Σ（求和）
//     —— 截图里这四个是复合键，这里做成弹窗式：弹一个对话框填
//       「函数式 + 参数」，算完结果进 Ans 和历史。比在计算器屏幕上摸
//       变量直观得多（图形界面优先）。
//   * nPr / nCr / GCD / LCM / FACT / Abs / mod
//   * x²、x³、xʸ、√、³√、x⁻¹、10ˣ、eˣ、Log、Ln
//   * π / e / Ans / EXP / Ran# / RanInt
//   * AC / 退格 / 历史 / 复制结果
//
// 截图里**没做**的：MATRIX / VECTOR / CMPLX / STAT / DIST / 进制(CONV)。
//   * 进制转换在「单位换算」里已有独立入口（v2.3.0 加的第 8 类）；
//   * 矩阵 / 向量 / 复数 / 统计需要整套模式切换 + 各自的编辑器，
//     先不做，以后需要再单独加页；
//   * SHIFT / ALPHA 没做：那是卡西欧「一键两用」的省键设计，
//     App 屏幕够大，直接把第二功能全部平铺出来。
// ===========================================================================
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tool_pages.dart'; // ToolScaffold

// ============================================================ 显示模式 / 求解器类型

enum _DispMode { normal, math, decimal }

enum _SolverKind {
  solve('SOLVE · 解方程', '解方程', 'f(x) = 0，可带等号', 'x^2-3x+2=0', '初值 x₀',
      null, '从初值出发牛顿迭代找根；没解出来就换个初值再试。'),
  ddx('d/dx · 数值导数', '数值导数', 'f(x)', 'x^3+2x', '求导点 x =', null,
      '在 x = 该点处算 f\'(x)。'),
  integral('∫dx · 定积分', '定积分', 'f(x)', 'sin(x)', '下限 a', '上限 b',
      'Simpson 法 1000 段。sin/cos 按上面的角度 / 弧度设置。'),
  sum('Σ · 求和', '求和', 'f(i)', '1/i', 'i 起点', 'i 终点',
      'i 从起点到终点逐个取整数，累加 f(i)。');

  final String key;
  final String title;
  final String exprLabel;
  final String exprHint;
  final String aLabel;
  final String? bLabel;
  final String help;
  const _SolverKind(this.key, this.title, this.exprLabel, this.exprHint,
      this.aLabel, this.bLabel, this.help);
}

// ============================================================ 主页面

class AdvCalcPage extends StatefulWidget {
  const AdvCalcPage({super.key});

  @override
  State<AdvCalcPage> createState() => _AdvCalcPageState();
}

class _AdvCalcPageState extends State<AdvCalcPage> {
  final _input = TextEditingController();
  String _result = '';
  String? _error;
  bool _degrees = true;
  bool _hyp = false; // sin → sinh
  _DispMode _mode = _DispMode.normal;

  double _ans = 0;
  double? _lastValue;
  final List<String> _history = [];
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_recalc);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Map<String, double> get _vars => <String, double>{'ans': _ans};

  void _recalc() {
    final text = _input.text.trim();
    if (text.isEmpty) {
      _lastValue = null;
      if (_result.isEmpty && _error == null) return;
      setState(() {
        _result = '';
        _error = null;
      });
      return;
    }
    try {
      final v = AdvExpr(text, degrees: _degrees, vars: _vars).run();
      _lastValue = v;
      setState(() {
        _result = _fmtNum(v, _mode);
        _error = null;
      });
    } catch (e) {
      _lastValue = null;
      setState(() {
        _result = '';
        _error = e is FormatException ? e.message : '算式有误';
      });
    }
  }

  /// 把一段文本插到光标处
  void _insert(String t) {
    final sel = _input.selection;
    final text = _input.text;
    if (sel.isValid && sel.start >= 0 && sel.end <= text.length) {
      final next = text.replaceRange(sel.start, sel.end, t);
      _input.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: sel.start + t.length),
      );
    } else {
      _input.text = text + t;
    }
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _backspace() {
    final sel = _input.selection;
    final text = _input.text;
    if (text.isEmpty) return;
    if (sel.isValid && sel.start >= 0 && sel.end > sel.start) {
      _input.text = text.replaceRange(sel.start, sel.end, '');
    } else if (sel.isValid && sel.start > 0) {
      _input.text = text.replaceRange(sel.start - 1, sel.start, '');
    } else {
      _input.text = text.substring(0, text.length - 1);
    }
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  /// 「=」：把当前结果定为 Ans、记历史
  void _commit() {
    final v = _lastValue;
    if (v == null || _input.text.trim().isEmpty) return;
    _ans = v;
    final line = '${_input.text.trim()} = $_result';
    setState(() {
      if (_history.isEmpty || _history.first != line) {
        _history.insert(0, line);
        if (_history.length > 40) _history.removeLast();
      }
    });
  }

  // ============================================================ 求解器（SOLVE / d/dx / ∫dx / Σ）

  Future<void> _solverDialog(_SolverKind kind) async {
    final ctrlF = TextEditingController(
        text: kind == _SolverKind.solve ? 'x^2-3x+2=0' : 'x^2');
    final ctrlA =
        TextEditingController(text: kind == _SolverKind.solve ? '1' : '0');
    final ctrlB = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(kind.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrlF,
              autofocus: true,
              decoration: InputDecoration(
                labelText: kind.exprLabel,
                hintText: kind.exprHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrlA,
                  keyboardType: const TextInputType.numberWithOptions(
                      signed: true, decimal: true),
                  decoration: InputDecoration(
                      labelText: kind.aLabel,
                      border: const OutlineInputBorder()),
                ),
              ),
              if (kind.bLabel != null) const SizedBox(width: 10),
              if (kind.bLabel != null)
                Expanded(
                  child: TextField(
                    controller: ctrlB,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    decoration: InputDecoration(
                        labelText: kind.bLabel!,
                        border: const OutlineInputBorder()),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(kind.help,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('计算')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final f = ctrlF.text.trim();
      if (f.isEmpty) throw const FormatException('函数式不能为空');
      final a = double.tryParse(ctrlA.text.trim());
      final b = double.tryParse(ctrlB.text.trim());
      double res;
      String tag;
      switch (kind) {
        case _SolverKind.solve:
          if (a == null) throw const FormatException('请填初值 x₀');
          final r = _solveEquation(f, a);
          if (r == null) throw const FormatException('没找到解（换个初值再试试）');
          res = r;
          tag = 'SOLVE($f, x₀=$a)';
          break;
        case _SolverKind.ddx:
          if (a == null) throw const FormatException('请填求导点 x =');
          final g = _fnOf(f);
          final h = 1e-5 * math.max(1.0, a.abs());
          res = (g(a + h) - g(a - h)) / (2 * h);
          tag = 'd/dx($f) | x=$a';
          break;
        case _SolverKind.integral:
          if (a == null || b == null) {
            throw const FormatException('请填积分下限 a 和上限 b');
          }
          res = _simpson(_fnOf(f), a, b, 1000);
          tag = '∫($f)dx, [$a, $b]';
          break;
        case _SolverKind.sum:
          if (a == null || b == null) {
            throw const FormatException('请填 i 的起点和终点');
          }
          if ((b - a).abs() > 1000000) throw const FormatException('求和范围太大了');
          final g = _fnOf(f);
          var s = 0.0;
          final i0 = a.round(), i1 = b.round();
          for (var i = i0; i <= i1; i++) {
            s += g(i.toDouble());
          }
          res = s;
          tag = 'Σ($f), i=$a..$b';
          break;
      }
      if (!mounted) return;
      setState(() {
        _ans = res;
        _error = null;
        _result = _fmtNum(res, _mode);
        if (_history.isEmpty || _history.first != tag) {
          _history.insert(0, tag);
          if (_history.length > 40) _history.removeLast();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is FormatException ? e.message : '算不出来：$e';
        _result = '';
      });
    }
  }

  /// 把字符串包成 f(x) 函数。等式转成「左边 − 右边」。
  double Function(double) _fnOf(String text) {
    final eq = text.split('=');
    if (eq.length == 1) {
      return (x) => AdvExpr(eq[0], degrees: _degrees,
          vars: {'x': x, 'ans': _ans}).run();
    }
    if (eq.length == 2) {
      return (x) {
        final l = AdvExpr(eq[0], degrees: _degrees,
            vars: {'x': x, 'ans': _ans}).run();
        final r = AdvExpr(eq[1], degrees: _degrees,
            vars: {'x': x, 'ans': _ans}).run();
        return l - r;
      };
    }
    throw const FormatException('等号最多一个');
  }

  /// 解方程 f(x)=0：牛顿法，失败自动换初值再来。
  double? _solveEquation(String text, double x0) {
    final f = _fnOf(text);
    for (final guess in [x0, 1.0, -1.0, 0.5, 2.0, 3.0, 10.0, -10.0, 100.0]) {
      var x = guess;
      var converged = false;
      for (var it = 0; it < 100; it++) {
        final fx = f(x);
        if (fx.isNaN || fx.isInfinite) break;
        if (fx.abs() < 1e-10) {
          converged = true;
          break;
        }
        final h = 1e-6 * math.max(1.0, x.abs());
        final d = (f(x + h) - f(x - h)) / (2 * h);
        if (d == 0 || d.isNaN || d.isInfinite) break;
        final nx = x - fx / d;
        if (nx.isNaN || nx.isInfinite) break;
        if ((nx - x).abs() < 1e-12) {
          x = nx;
          converged = f(x).abs() < 1e-6;
          break;
        }
        x = nx;
      }
      if (converged) return x;
    }
    return null;
  }

  static double _simpson(double Function(double) f, double a, double b, int n) {
    if (a == b) return 0;
    if (n.isOdd) n++;
    final h = (b - a) / n;
    var s = f(a) + f(b);
    for (var i = 1; i < n; i++) {
      s += f(a + i * h) * (i.isOdd ? 4 : 2);
    }
    return s * h / 3;
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), duration: const Duration(seconds: 1)));
  }

  // ============================================================ 键盘定义
  //
  // 每行 6 个键。`ins` = 插入文本；`tap` = 特殊逻辑（优先于 ins）；
  // `sub` = 键帽下方的小字注（仿截图）。

  List<_Key> _row1() => [
        _Key('SOLVE', sub: '解方程', tap: () => _solverDialog(_SolverKind.solve)),
        _Key('d/dx', sub: '导数', tap: () => _solverDialog(_SolverKind.ddx)),
        _Key('∫dx', sub: '积分', tap: () => _solverDialog(_SolverKind.integral)),
        _Key('Σ', sub: '求和', tap: () => _solverDialog(_SolverKind.sum)),
        _Key('nPr', ins: 'nPr(', sub: '排列'),
        _Key('nCr', ins: 'nCr(', sub: '组合'),
      ];

  List<_Key> _row2() => [
        _Key('hyp',
            sub: _hyp ? '双曲:开' : '双曲',
            tap: () => setState(() => _hyp = !_hyp),
            active: _hyp),
        _Key(_hyp ? 'sinh' : 'sin',
            ins: _hyp ? 'sinh(' : 'sin('),
        _Key(_hyp ? 'cosh' : 'cos',
            ins: _hyp ? 'cosh(' : 'cos('),
        _Key(_hyp ? 'tanh' : 'tan',
            ins: _hyp ? 'tanh(' : 'tan('),
        _Key('x!', ins: '!', sub: '阶乘'),
        _Key('Abs', ins: 'abs(', sub: '绝对值'),
      ];

  List<_Key> _row3() => [
        _Key('Log', ins: 'log(', sub: '以10为底'),
        _Key('Ln', ins: 'ln(', sub: '以e为底'),
        _Key('10ˣ', ins: '10^', sub: '十的幂'),
        _Key('eˣ', ins: 'e^', sub: 'e的幂'),
        _Key('GCD', ins: 'gcd(', sub: '最大公因'),
        _Key('LCM', ins: 'lcm(', sub: '最小公倍'),
      ];

  List<_Key> _row4() => [
        _Key('x²', ins: '^2'),
        _Key('x³', ins: '^3'),
        _Key('xʸ', ins: '^', sub: '幂'),
        _Key('√', ins: 'sqrt(', sub: '平方根'),
        _Key('³√', ins: 'cbrt(', sub: '立方根'),
        _Key('x⁻¹', ins: '^(-1)', sub: '倒数'),
      ];

  List<_Key> _row5() => [
        _Key('7', ins: '7'),
        _Key('8', ins: '8'),
        _Key('9', ins: '9'),
        _Key('÷', ins: '/'),
        _Key('AC',
            tap: () {
              _input.clear();
              setState(() {
                _result = '';
                _error = null;
              });
            },
            danger: true),
        _Key('⌫', tap: _backspace, danger: true),
      ];

  List<_Key> _row6() => [
        _Key('4', ins: '4'),
        _Key('5', ins: '5'),
        _Key('6', ins: '6'),
        _Key('×', ins: '*'),
        _Key('(', ins: '('),
        _Key(')', ins: ')'),
      ];

  List<_Key> _row7() => [
        _Key('1', ins: '1'),
        _Key('2', ins: '2'),
        _Key('3', ins: '3'),
        _Key('−', ins: '-'),
        _Key('mod', ins: ' mod ', sub: '取余'),
        _Key('%', ins: '%', sub: '百分比'),
      ];

  List<_Key> _row8() => [
        _Key('0', ins: '0'),
        _Key('.', ins: '.'),
        _Key('EXP', ins: 'E', sub: '科学计数'),
        _Key('+', ins: '+'),
        _Key('Ans', ins: 'Ans', sub: '上次结果'),
        _Key('=', tap: _commit, primary: true),
      ];

  List<_Key> _row9() => [
        _Key('π', ins: 'pi'),
        _Key('e', ins: 'e'),
        _Key('Ran#', ins: 'ran()', sub: '0~1随机'),
        _Key('RanInt', ins: 'RanInt(1,6)', sub: '整数随机'),
        _Key('复制',
            tap: () {
              if (_result.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: _result));
                _snack('已复制结果');
              }
            }),
        _Key(_showHistory ? '收起' : '历史',
            tap: () => setState(() => _showHistory = !_showHistory),
            active: _showHistory),
      ];

  // ============================================================ UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = [
      _row1(), _row2(), _row3(), _row4(),
      _row5(), _row6(), _row7(), _row8(), _row9(),
    ];
    return ToolScaffold(
      title: '高级计算',
      subtitle: '科学计算器 · ${_degrees ? '角度' : '弧度'} · ${_modeLabel}',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
        children: [
          // ---------- 显示区 ----------
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _input,
                    keyboardType: TextInputType.text,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()]),
                    decoration: const InputDecoration(
                      hintText: '0',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 34,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _error != null
                          ? Text(_error!,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 12.5, color: scheme.error))
                          : Text(
                              _result.isEmpty ? '' : '= $_result',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // ---------- 模式行 ----------
          Row(
            children: [
              Expanded(
                child: SegmentedButton<_DispMode>(
                  segments: const [
                    ButtonSegment(value: _DispMode.normal, label: Text('正常')),
                    ButtonSegment(value: _DispMode.math, label: Text('数学')),
                    ButtonSegment(value: _DispMode.decimal, label: Text('小数')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) {
                    setState(() => _mode = s.first);
                    _recalc();
                  },
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('角度')),
                    ButtonSegment(value: false, label: Text('弧度')),
                  ],
                  selected: {_degrees},
                  onSelectionChanged: (s) {
                    setState(() => _degrees = s.first);
                    _recalc();
                  },
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ---------- 键盘 ----------
          for (final row in rows) ...[
            Row(
              children: [
                for (final k in row) ...[
                  Expanded(child: _keyBtn(scheme, k)),
                  const SizedBox(width: 5),
                ],
              ],
            ),
            const SizedBox(height: 5),
          ],

          // ---------- 历史 ----------
          if (_showHistory && _history.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              Text('历史',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _history.clear()),
                child: const Text('清空', style: TextStyle(fontSize: 12.5)),
              ),
            ]),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final h in _history.take(20))
                    ListTile(
                      dense: true,
                      title: Text(h,
                          style: const TextStyle(fontSize: 12.5)),
                      trailing:
                          const Icon(Icons.north_west, size: 15),
                      onTap: () {
                        // 历史条目分两种：普通算式（含 " = "）和求解器记录
                        final i = h.lastIndexOf(' = ');
                        final expr = i > 0 ? h.substring(0, i) : h;
                        _input.text = expr;
                        _input.selection = TextSelection.collapsed(
                            offset: expr.length);
                      },
                    ),
                ],
              ),
            ),
          ],

          // ---------- 功能说明 ----------
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('支持的写法',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(
                    '直接敲公式：2(3+4)^2、sin(30)+log(100)、5!、7 mod 3、'
                    'nPr(5,2)、nCr(10,3)、gcd(12,18)、lcm(4,6)、'
                    'RanInt(1,6)、Ans×2、x² 直接写 ^2。\n'
                    'SOLVE / d/dx / ∫dx / Σ 点键后弹窗填函数和参数；'
                    '「数学」模式会把 0.5 显示成 1/2 这类分数。',
                    style: TextStyle(
                        fontSize: 11.5, height: 1.55,
                        color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _modeLabel => switch (_mode) {
        _DispMode.normal => '正常',
        _DispMode.math => '数学',
        _DispMode.decimal => '小数',
      };

  Widget _keyBtn(ColorScheme scheme, _Key k) {
    final bg = k.danger
        ? scheme.errorContainer.withValues(alpha: 0.55)
        : k.primary
            ? scheme.primaryContainer
            : k.active
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final fg = k.danger
        ? scheme.onErrorContainer
        : k.primary
            ? scheme.onPrimaryContainer
            : k.active
                ? scheme.onSecondaryContainer
                : scheme.onSurface;
    return Semantics(
      button: true,
      label: k.label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: k.tap ?? () => _insert(k.ins ?? ''),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            alignment: Alignment.center,
            child: k.sub == null
                ? Text(k.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: k.label.length > 3 ? 12.5 : 16,
                        fontWeight: FontWeight.w600,
                        color: fg))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(k.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                      Text(k.sub!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 8.5,
                              height: 1.2,
                              color: fg.withValues(alpha: 0.65))),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Key {
  final String label;
  final String? ins;
  final VoidCallback? tap;
  final String? sub;
  final bool danger;
  final bool primary;
  final bool active;
  const _Key(this.label, {this.ins, this.tap, this.sub,
      this.danger = false, this.primary = false, this.active = false});
}

// ============================================================ 结果格式化

/// 正常：整数直显，小数去尾零；数学：尝试分数；小数：强制小数。
String _fmtNum(double v, _DispMode mode) {
  if (v.isNaN) return '结果不是一个数';
  if (v.isInfinite) return v.isNegative ? '-∞' : '∞';

  if (mode == _DispMode.math) {
    final frac = _toFraction(v);
    if (frac != null) return frac;
  }

  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsPrecision(12);
  if (s.contains('.') && !s.contains('e') && !s.contains('E')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// 连分数逼近把小数转分数。分母 ≤ 9999 且误差 < 1e-9 才认。
String? _toFraction(double v) {
  if (v == v.roundToDouble() || v.abs() > 1e7) return null;
  var sign = 1;
  var x = v;
  if (x < 0) {
    sign = -1;
    x = -x;
  }
  var h1 = 1, h0 = 0, k1 = 0, k0 = 1;
  var b = x;
  for (var i = 0; i < 30; i++) {
    final a = b.floorToDouble();
    final h2 = (a.toInt() * h1 + h0);
    final k2 = (a.toInt() * k1 + k0);
    if (k2 > 9999) break;
    h0 = h1; h1 = h2;
    k0 = k1; k1 = k2;
    final approx = h1 / k1;
    if ((approx - x).abs() < 1e-9) {
      if (k1 == 1) return null; // 整数，不用分数
      return '${sign * h1}/$k1';
    }
    final frac = b - a;
    if (frac < 1e-12) break;
    b = 1 / frac;
  }
  return null;
}

// ============================================================ 表达式求值引擎
//
// 递归下降。文法：
//   expr   := term (('+'|'-') term)*
//   term   := unary (('*'|'/'|'%'|'mod'|隐式乘) unary)*
//   unary  := ('-'|'+') unary | power
//   power  := postfix ('^' unary)?          （右结合：2^3^2 = 2^(3^2)）
//   postfix:= primary ('!')*
//   primary:= number | π | name | '(' expr ')' | '√' primary
//
/// 变量走 [vars]（x、ans）。函数支持多参数（逗号分隔）。
class AdvExpr {
  final String s;
  final bool degrees;
  final Map<String, double> vars;
  int _i = 0;

  AdvExpr(this.s, {required this.degrees, this.vars = const {}});

  double run() {
    final v = _expr();
    _ws();
    if (_i < s.length) throw FormatException('这里看不懂：${s.substring(_i)}');
    return v;
  }

  void _ws() {
    while (_i < s.length &&
        (s[_i] == ' ' || s[_i] == '\t' || s[_i] == '\n')) {
      _i++;
    }
  }

  bool _eat(String t) {
    _ws();
    if (s.startsWith(t, _i)) {
      _i += t.length;
      return true;
    }
    return false;
  }

  /// 吃掉一个「单词」关键字（mod），要求后面不是字母数字
  bool _eatWord(String t) {
    _ws();
    if (!s.startsWith(t, _i)) return false;
    final end = _i + t.length;
    if (end < s.length && _isAlnum(s[end])) return false;
    _i = end;
    return true;
  }

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 48 && u <= 57;
  }

  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }

  static bool _isAlnum(String c) => _isDigit(c) || _isAlpha(c);

  double _expr() {
    var v = _term();
    while (true) {
      _ws();
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        break;
      }
    }
    return v;
  }

  double _term() {
    var v = _unary();
    while (true) {
      _ws();
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        v /= _unary();
      } else if (_eat('%')) {
        v %= _unary();
      } else if (_eatWord('mod')) {
        // Dart 的 % 对正除数本来就返回非负余数（(-7) % 3 == 2），
        // 跟计算器的 mod 语义一致
        v %= _unary();
      } else if (_i < s.length &&
          (s[_i] == '(' || _isAlpha(s[_i]) || s[_i] == 'π' || s[_i] == '√')) {
        // 隐式乘法：2(3+4)、3pi、2sin(30)、2√9
        v *= _unary();
      } else {
        break;
      }
    }
    return v;
  }

  double _unary() {
    _ws();
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  double _power() {
    final base = _postfix();
    _ws();
    if (_eat('^')) {
      final e = _unary(); // 右结合：2^3^2 = 2^(3^2)
      return math.pow(base, e).toDouble();
    }
    return base;
  }

  double _postfix() {
    var v = _primary();
    while (true) {
      _ws();
      if (_eat('!')) {
        v = _fact(v);
      } else {
        break;
      }
    }
    return v;
  }

  double _primary() {
    _ws();
    if (_i >= s.length) throw const FormatException('算式还没写完');
    final c = s[_i];
    if (c == 'π') {
      _i++;
      return math.pi;
    }
    if (c == '(') {
      _i++;
      final v = _expr();
      if (!_eat(')')) throw const FormatException('少了一个右括号');
      return v;
    }
    if (_isDigit(c) || c == '.') return _number();
    if (_isAlpha(c)) return _name();
    if (c == '√') {
      _i++;
      final v = _primary();
      return math.sqrt(v);
    }
    throw FormatException('不认识的字符：$c');
  }

  double _number() {
    _ws();
    final start = _i;
    while (_i < s.length && (_isDigit(s[_i]) || s[_i] == '.')) {
      _i++;
    }
    // 科学计数法 1E3 / 2.5E-2（EXP 键插入的就是 E）
    if (_i < s.length && (s[_i] == 'e' || s[_i] == 'E')) {
      final save = _i;
      _i++;
      if (_i < s.length && (s[_i] == '+' || s[_i] == '-')) _i++;
      if (_i < s.length && _isDigit(s[_i])) {
        while (_i < s.length && _isDigit(s[_i])) {
          _i++;
        }
      } else {
        _i = save; // 后面不是数字，这个 e 是常量 e，退回去
      }
    }
    final t = s.substring(start, _i);
    final v = double.tryParse(t);
    if (v == null) throw FormatException('数字写错了：$t');
    return v;
  }

  double _name() {
    _ws();
    final start = _i;
    while (_i < s.length && (_isAlnum(s[_i]))) {
      _i++;
    }
    final name = s.substring(start, _i).toLowerCase();
    if (name.isEmpty) throw const FormatException('这里看不懂');
    // 变量（x / ans）
    final varVal = vars[name];
    if (varVal != null) return varVal;
    if (name == 'pi') return math.pi;
    if (name == 'e') return math.e;
    _ws();
    if (!_eat('(')) {
      throw FormatException('“$name”后面需要一对括号，比如 $name(30)');
    }
    final args = <double>[_expr()];
    while (true) {
      _ws();
      if (_eat(',')) {
        args.add(_expr());
      } else {
        break;
      }
    }
    if (!_eat(')')) throw const FormatException('少了一个右括号');
    return _func(name, args);
  }

  double _func(String n, List<double> a) {
    double arg(int i) {
      if (i >= a.length) throw FormatException('$n 需要第 ${i + 1} 个参数');
      return a[i];
    }

    switch (n) {
      case 'sin':
        return math.sin(_toRad(arg(0)));
      case 'cos':
        return math.cos(_toRad(arg(0)));
      case 'tan':
        return math.tan(_toRad(arg(0)));
      case 'asin':
        return _fromRad(math.asin(arg(0)));
      case 'acos':
        return _fromRad(math.acos(arg(0)));
      case 'atan':
        return _fromRad(math.atan(arg(0)));
      case 'sinh':
        return _sinh(arg(0));
      case 'cosh':
        return _cosh(arg(0));
      case 'tanh':
        return _tanh(arg(0));
      case 'asinh':
        return math.log(arg(0) + math.sqrt(arg(0) * arg(0) + 1));
      case 'acosh':
        return math.log(arg(0) + math.sqrt(arg(0) * arg(0) - 1));
      case 'atanh':
        return 0.5 * math.log((1 + arg(0)) / (1 - arg(0)));
      case 'log':
        return math.log(arg(0)) / math.ln10;
      case 'ln':
        return math.log(arg(0));
      case 'sqrt':
        return math.sqrt(arg(0));
      case 'cbrt':
        final v = arg(0);
        return v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
      case 'abs':
        return arg(0).abs();
      case 'exp':
        return math.exp(arg(0));
      case 'floor':
        return arg(0).floorToDouble();
      case 'ceil':
        return arg(0).ceilToDouble();
      case 'round':
        return arg(0).roundToDouble();
      case 'min':
        return math.min(arg(0), arg(1));
      case 'max':
        return math.max(arg(0), arg(1));
      case 'fact':
        return _fact(arg(0));
      case 'npr':
        return _nPr(arg(0).round(), arg(1).round());
      case 'ncr':
        return _nCr(arg(0).round(), arg(1).round());
      case 'gcd':
        return _gcd(arg(0).round(), arg(1).round()).toDouble();
      case 'lcm':
        final x = arg(0).round(), y = arg(1).round();
        if (x == 0 || y == 0) return 0;
        return (x ~/ _gcd(x, y) * y).abs().toDouble();
      case 'randint':
        final lo = arg(0).round(), hi = arg(1).round();
        final lo2 = math.min(lo, hi), hi2 = math.max(lo, hi);
        return (lo2 + math.Random().nextInt(hi2 - lo2 + 1)).toDouble();
      case 'ran':
        return math.Random().nextDouble();
      default:
        throw FormatException('没有这个函数：$n');
    }
  }

  double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
  double _cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;
  double _tanh(double x) {
    final e2 = math.exp(2 * x);
    return (e2 - 1) / (e2 + 1);
  }

  double _toRad(double v) => degrees ? v * math.pi / 180.0 : v;
  double _fromRad(double v) => degrees ? v * 180.0 / math.pi : v;

  double _fact(double v) {
    if (v < 0 || v != v.roundToDouble()) {
      throw const FormatException('阶乘只支持非负整数');
    }
    var r = 1.0;
    final n = v.toInt();
    for (var k = 2; k <= n; k++) {
      r *= k;
      if (r.isInfinite) return r; // 170! 以上溢出，直接返回
    }
    return r;
  }

  double _nPr(int n, int r) {
    if (n < 0 || r < 0 || r > n) throw const FormatException('nPr 需要 0 ≤ r ≤ n');
    var res = 1.0;
    for (var k = 0; k < r; k++) {
      res *= (n - k);
    }
    return res;
  }

  double _nCr(int n, int r) {
    if (n < 0 || r < 0 || r > n) throw const FormatException('nCr 需要 0 ≤ r ≤ n');
    final rr = math.min(r, n - r);
    var res = 1.0;
    for (var k = 1; k <= rr; k++) {
      res = res * (n - rr + k) / k;
    }
    return res.roundToDouble();
  }

  int _gcd(int a, int b) {
    a = a.abs();
    b = b.abs();
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a;
  }
}
