import 'dart:math' as math;
// FontFeature 是 dart:ui 的类。material.dart 不一定把它带出来，
// 显式 import 一次最稳（同一元素重复导入不冲突）。
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tool_pages.dart';

// ===========================================================================
// v1.5.0 新增工具（第一批）
//
// 这一批全都是「纯本地逻辑」：不联网、不申请权限、不引第三方包。
// 项目对依赖极其敏感（历史上几次云端构建翻车都是加包引起的），
// 所以凡是能自己算的都自己算，pubspec 保持零变更。
//
//   * AdvCalcPage            高级计算器（直接敲公式）
//   * CidrCalcPage           CIDR 子网计算（IPv4 + IPv6）
//   * CoordinateConvertPage  地图坐标转换（WGS84 / GCJ02 / BD09）
// ===========================================================================

/// 结果表格里的一行（左标签、右值）
class _Kv {
  final String k;
  final String v;
  const _Kv(this.k, this.v);
}

/// 统一样式的结果表（各工具复用）
class _KvTable extends StatelessWidget {
  final List<_Kv> rows;
  /// 可复制的那几行（按标签匹配，点一下复制值）
  final Set<String> copyable;
  const _KvTable({required this.rows, this.copyable = const <String>{}});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            InkWell(
              onTap: copyable.contains(rows[i].k)
                  ? () {
                      Clipboard.setData(ClipboardData(text: rows[i].v));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已复制 ${rows[i].v}'), duration: const Duration(seconds: 1)),
                      );
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(rows[i].k,
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: SelectableText(
                        rows[i].v,
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                      ),
                    ),
                    if (copyable.contains(rows[i].k))
                      Icon(Icons.copy_rounded, size: 15, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 1. 高级计算器
// ===========================================================================

/// 高级计算器：不是点按式，而是像草稿纸一样直接敲公式。
///
/// 支持的写法：
///   四则 + - * / %、幂 ^、括号、阶乘 !
///   函数 sin cos tan asin acos atan log ln sqrt abs exp floor ceil round cbrt
///   常量 pi（或 π） e
///   隐式乘法：2(3+4)、3pi、2sin(30)
/// 角度 / 弧度可切换（默认角度 —— 工程上算角度更常见）。
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
  final List<String> _history = [];

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

  void _recalc() {
    final text = _input.text.trim();
    if (text.isEmpty) {
      if (_result.isEmpty && _error == null) return;
      setState(() {
        _result = '';
        _error = null;
      });
      return;
    }
    try {
      final v = _ExprEval(text, degrees: _degrees).run();
      setState(() {
        _result = _fmtNum(v);
        _error = null;
      });
    } catch (e) {
      setState(() {
        _result = '';
        _error = e is FormatException ? e.message : '算式有误';
      });
    }
  }

  /// 把一个按钮上的文本插到光标处（而不是简单追加到末尾）
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

  void _useResult() {
    if (_result.isEmpty) return;
    _input.text = _result;
    _input.selection = TextSelection.collapsed(offset: _result.length);
  }

  void _pushHistory() {
    if (_result.isEmpty || _input.text.trim().isEmpty) return;
    final line = '${_input.text.trim()} = $_result';
    if (_history.isNotEmpty && _history.first == line) return;
    setState(() {
      _history.insert(0, line);
      if (_history.length > 30) _history.removeLast();
    });
  }

  static const _keys = <List<String>>[
    ['sin(', 'cos(', 'tan(', 'π'],
    ['(', ')', '^', '√('],
    ['7', '8', '9', '÷'],
    ['4', '5', '6', '×'],
    ['1', '2', '3', '−'],
    ['0', '.', '!', '+'],
    ['log(', 'ln(', '%', 'e'],
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '高级计算器',
      subtitle: '直接敲公式，支持函数、括号、幂、阶乘',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          // 输入框 + 结果
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _input,
                    autofocus: false,
                    keyboardType: TextInputType.text,
                    style: const TextStyle(fontSize: 19, fontFeatures: [FontFeature.tabularFigures()]),
                    decoration: const InputDecoration(
                      hintText: '例如 2*(3+4)^2 或 sin(30)+log(100)',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _error != null
                            ? Text(_error!,
                                style: TextStyle(fontSize: 12.5, color: scheme.error))
                            : Text(
                                _result.isEmpty ? ' ' : '= $_result',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.primary,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                      ),
                      TextButton.icon(
                        onPressed: _useResult,
                        icon: const Icon(Icons.north_west, size: 15),
                        label: const Text('用结果', style: TextStyle(fontSize: 12.5)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SegmentedButton<bool>(
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
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _pushHistory,
                icon: const Icon(Icons.save_alt, size: 15),
                label: const Text('记一笔', style: TextStyle(fontSize: 12.5)),
              ),
              TextButton(
                onPressed: () {
                  _input.clear();
                  setState(() => _history.clear());
                },
                child: const Text('清空', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 键盘
          for (final row in _keys) ...[
            Row(
              children: [
                for (final k in row) ...[
                  Expanded(child: _keyBtn(scheme, k)),
                  const SizedBox(width: 7),
                ],
              ],
            ),
            const SizedBox(height: 7),
          ],
          Row(
            children: [
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: _backspace,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.backspace_outlined, size: 19),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                flex: 6,
                child: FilledButton(
                  onPressed: _pushHistory,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  child: const Text('='),
                ),
              ),
            ],
          ),

          if (_history.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('历史',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final h in _history)
                    ListTile(
                      dense: true,
                      title: Text(h, style: const TextStyle(fontSize: 13)),
                      trailing: const Icon(Icons.north_west, size: 15),
                      onTap: () {
                        final i = h.lastIndexOf(' = ');
                        final expr = i > 0 ? h.substring(0, i) : h;
                        _input.text = expr;
                        _input.selection =
                            TextSelection.collapsed(offset: expr.length);
                      },
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _keyBtn(ColorScheme scheme, String label) {
    final t = label
        .replaceAll('÷', '/')
        .replaceAll('×', '*')
        .replaceAll('−', '-')
        .replaceAll('√(', 'sqrt(');
    return SizedBox(
      height: 46,
      child: OutlinedButton(
        onPressed: () => _insert(t),
        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
        child: Text(label, style: const TextStyle(fontSize: 15)),
      ),
    );
  }
}

/// 数字格式化：整数不带小数点，小数最多 12 位有效数字
String _fmtNum(double v) {
  if (v.isNaN) return '结果不是一个数';
  if (v.isInfinite) return v.isNegative ? '-∞' : '∞';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsPrecision(12);
  if (s.contains('.') && !s.contains('e') && !s.contains('E')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// 表达式求值（递归下降）。
///
/// 为什么自己写而不找现成的包：加一个依赖就有一次构建翻车的风险，
/// 而这个文法的规模（四则 + 函数 + 幂 + 括号）几十行就够。
class _ExprEval {
  final String s;
  final bool degrees;
  int _i = 0;

  _ExprEval(this.s, {required this.degrees});

  double run() {
    final v = _expr();
    _ws();
    if (_i < s.length) throw FormatException('这里看不懂：${s.substring(_i)}');
    return v;
  }

  void _ws() {
    while (_i < s.length && (s[_i] == ' ' || s[_i] == '\t' || s[_i] == '\n')) {
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

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 48 && u <= 57;
  }

  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }

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
      } else if (_i < s.length && (s[_i] == '(' || _isAlpha(s[_i]) || s[_i] == 'π')) {
        // 隐式乘法：2(3+4)、3pi、2sin(30)
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
    // 科学计数法 1e3 / 2.5E-2
    if (_i < s.length && (s[_i] == 'e' || s[_i] == 'E')) {
      final save = _i;
      _i++;
      if (_i < s.length && (s[_i] == '+' || s[_i] == '-')) _i++;
      if (_i < s.length && _isDigit(s[_i])) {
        while (_i < s.length && _isDigit(s[_i])) {
          _i++;
        }
      } else {
        _i = save; // 后面不是数字，说明这个 e 是常量 e，退回去
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
    while (_i < s.length && (_isAlpha(s[_i]) || _isDigit(s[_i]))) {
      _i++;
    }
    final name = s.substring(start, _i).toLowerCase();
    if (name == 'pi') return math.pi;
    if (name == 'e') return math.e;
    _ws();
    if (!_eat('(')) throw FormatException('“$name”后面需要跟一对括号，比如 $name(30)');
    final v = _expr();
    if (!_eat(')')) throw const FormatException('少了一个右括号');
    return _func(name, v);
  }

  double _func(String n, double v) {
    switch (n) {
      case 'sin':
        return math.sin(_toRad(v));
      case 'cos':
        return math.cos(_toRad(v));
      case 'tan':
        return math.tan(_toRad(v));
      case 'asin':
        return _fromRad(math.asin(v));
      case 'acos':
        return _fromRad(math.acos(v));
      case 'atan':
        return _fromRad(math.atan(v));
      case 'log':
        return math.log(v) / math.ln10;
      case 'ln':
        return math.log(v);
      case 'sqrt':
        return math.sqrt(v);
      case 'abs':
        return v.abs();
      case 'exp':
        return math.exp(v);
      case 'floor':
        return v.floorToDouble();
      case 'ceil':
        return v.ceilToDouble();
      case 'round':
        return v.roundToDouble();
      case 'cbrt':
        return v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
      default:
        throw FormatException('没有这个函数：$n');
    }
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
      if (r.isInfinite) return r; // 170! 以上就溢出了，直接返回
    }
    return r;
  }
}

// ===========================================================================
// 2. CIDR 子网计算（IPv4 + IPv6）
// ===========================================================================

/// CIDR 子网掩码计算：输入 192.168.1.10/24 或 2001:db8::1/48，
/// 给出网络号、广播地址、可用范围、主机数、地址类型。
class CidrCalcPage extends StatefulWidget {
  const CidrCalcPage({super.key});

  @override
  State<CidrCalcPage> createState() => _CidrCalcPageState();
}

class _CidrCalcPageState extends State<CidrCalcPage> {
  final _input = TextEditingController(text: '192.168.1.10/24');
  List<_Kv> _rows = const [];
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _calc() {
    final t = _input.text.trim();
    if (t.isEmpty) {
      setState(() {
        _rows = const [];
        _error = null;
      });
      return;
    }
    try {
      setState(() {
        _rows = _cidrCalc(t);
        _error = null;
      });
    } catch (e) {
      setState(() {
        _rows = const [];
        _error = e is FormatException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: 'CIDR 子网计算',
      subtitle: 'IPv4 与 IPv6 都支持',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          TextField(
            controller: _input,
            onChanged: (_) => _calc(),
            decoration: InputDecoration(
              labelText: '地址 / 前缀长度',
              hintText: '例如 192.168.1.10/24 或 2001:db8::1/48',
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _input.clear();
                  _calc();
                },
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in const [
                '192.168.1.10/24',
                '10.0.0.0/8',
                '172.16.5.5/12',
                '2001:db8::1/48',
                'fe80::1/64',
              ])
                ActionChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _input.text = s;
                    _calc();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: scheme.errorContainer.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 9),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            )
          else if (_rows.isNotEmpty)
            _KvTable(rows: _rows, copyable: const {'网络地址', '广播地址', '可用范围', '子网掩码', '反掩码'}),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(
                '说明：\n'
                '• 支持缩写写法（IPv6 的 :: 、省略的前缀位数默认按主机算 /32、/128）\n'
                '• IPv4 的 /31 与 /32 按 RFC 3021 处理，不像传统教材那样减 2\n'
                '• 复制：点表格里有复制图标的行',
                style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 算出 CIDR 的各项数值。IPv4 与 IPv6 自动分流。
List<_Kv> _cidrCalc(String raw) {
  var t = raw.trim();
  String ipPart;
  String? prefixPart;
  final slash = t.indexOf('/');
  if (slash >= 0) {
    ipPart = t.substring(0, slash).trim();
    prefixPart = t.substring(slash + 1).trim();
  } else {
    ipPart = t;
    prefixPart = null;
  }
  if (ipPart.isEmpty) throw const FormatException('请填写 IP 地址');

  final isV6 = ipPart.contains(':');
  final maxBits = isV6 ? 128 : 32;
  var bits = maxBits;
  if (prefixPart != null && prefixPart.isNotEmpty) {
    final n = int.tryParse(prefixPart);
    // 这条不能写 const：字符串里有 $prefixPart 插值，const 要求编译期常量
    if (n == null) throw FormatException('“/$prefixPart”里的前缀长度不是数字');
    bits = n;
  }
  if (bits < 0 || bits > maxBits) {
    throw FormatException('${isV6 ? 'IPv6' : 'IPv4'} 的前缀长度要在 0~$maxBits 之间');
  }

  if (isV6) return _cidrV6(ipPart, bits);
  return _cidrV4(ipPart, bits);
}

List<_Kv> _cidrV4(String ip, int bits) {
  final parts = ip.split('.');
  if (parts.length != 4) throw const FormatException('IPv4 要写成 4 段，例如 192.168.1.10');
  var v = 0;
  for (final p in parts) {
    final b = int.tryParse(p);
    if (b == null || b < 0 || b > 255) throw FormatException('“$p”不是合法的 0~255');
    v = (v << 8) | b;
  }
  const all = 0xFFFFFFFF;
  final mask = bits == 0 ? 0 : ((all << (32 - bits)) & all);
  final network = v & mask;
  final broadcast = network | (~mask & all);
  final total = _ipow(32 - bits);

  String hosts;
  if (bits == 32) {
    hosts = '1（单主机）';
  } else if (bits == 31) {
    hosts = '2（点对点链路，RFC 3021）';
  } else {
    final h = total - 2;
    hosts = h <= 0 ? '0' : _group(h);
    hosts = '$hosts（去掉网络号与广播地址）';
  }

  final firstHost = bits >= 31 ? network : network + 1;
  final lastHost = bits >= 31 ? broadcast : broadcast - 1;

  return [
    _Kv('输入', ip),
    _Kv('地址族', 'IPv4'),
    _Kv('前缀长度', '/$bits'),
    _Kv('网络地址', '${_v4(network)}/${bits}'),
    _Kv('广播地址', _v4(broadcast)),
    _Kv('子网掩码', _v4(mask)),
    _Kv('反掩码', _v4(~mask & all)),
    _Kv('可用范围', bits >= 31 ? _v4(network) : '${_v4(firstHost)} ~ ${_v4(lastHost)}'),
    _Kv('总地址数', _group(total)),
    _Kv('可用主机数', hosts),
    _Kv('地址类型', _v4Type(network)),
  ];
}

List<_Kv> _cidrV6(String ip, int bits) {
  final v = _parseV6(ip);
  final network = v & _v6Mask(bits);
  final last = network | _v6HostMask(bits);
  final total = BigInt.one << (128 - bits);

  return [
    _Kv('输入', ip),
    _Kv('地址族', 'IPv6'),
    _Kv('前缀长度', '/$bits'),
    _Kv('完整展开', _v6Full(network)),
    _Kv('网络地址', '${_v6Str(network)}/$bits'),
    _Kv('末地址', _v6Str(last)),
    _Kv('地址范围', '${_v6Str(network)} ~ ${_v6Str(last)}'),
    _Kv('总地址数', '2^${128 - bits} = ${_groupBig(total)}'),
    _Kv('地址类型', _v6Type(network)),
  ];
}

/// 2 的 e 次方。Dart 的 int 在移动端是 64 位，2^32 放得下，不会溢出。
int _ipow(int e) => 1 << e;

BigInt _v6Mask(int bits) {
  if (bits == 0) return BigInt.zero;
  return ((BigInt.one << bits) - BigInt.one) << (128 - bits);
}

BigInt _v6HostMask(int bits) {
  if (bits == 128) return BigInt.zero;
  return (BigInt.one << (128 - bits)) - BigInt.one;
}

String _v4(int v) => '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';

String _v4Type(int network) {
  final a = (network >> 24) & 0xFF;
  final b = (network >> 16) & 0xFF;
  if (a == 10) return '私有地址（10.0.0.0/8）';
  if (a == 172 && b >= 16 && b <= 31) return '私有地址（172.16.0.0/12）';
  if (a == 192 && b == 168) return '私有地址（192.168.0.0/16）';
  if (a == 127) return '环回地址（127.0.0.0/8）';
  if (a == 169 && b == 254) return '链路本地（169.254.0.0/16）';
  if (a >= 224 && a <= 239) return '组播地址（224.0.0.0/4）';
  if (a >= 240) return '保留地址（240.0.0.0/4）';
  if (a == 100 && b >= 64 && b <= 127) return '运营商级 NAT（100.64.0.0/10）';
  return '公网地址';
}

String _v6Type(BigInt network) {
  final f = (network >> 120).toInt() & 0xFF;
  if (network == BigInt.zero) return '未指定地址（::）';
  if (network == BigInt.one) return '环回地址（::1）';
  if ((f & 0xFE) == 0xFC) return '唯一本地地址（fc00::/7）';
  if (f == 0xFE && ((network >> 112).toInt() & 0xFF) >= 0x80) return '链路本地（fe80::/10）';
  if (f == 0xFF) return '组播地址（ff00::/8）';
  if (f == 0x20) return '全球单播（2000::/3）';
  return '其他';
}

/// 解析 IPv6（支持 :: 缩写）
BigInt _parseV6(String ip) {
  final s = ip.trim();
  if (s.contains('.')) throw const FormatException('暂不支持 IPv4 内嵌的 IPv6 写法');
  final doubleColon = s.split('::');
  if (doubleColon.length > 2) throw const FormatException('“::”最多只能出现一次');
  final left = doubleColon[0].isEmpty ? <String>[] : doubleColon[0].split(':');
  final right = doubleColon.length == 2
      ? (doubleColon[1].isEmpty ? <String>[] : doubleColon[1].split(':'))
      : <String>[];

  List<String> all;
  if (doubleColon.length == 2) {
    final fill = 8 - left.length - right.length;
    if (fill < 0) throw const FormatException('IPv6 最多 8 段');
    all = [...left, ...List<String>.filled(fill, '0'), ...right];
  } else {
    all = left;
    if (all.length != 8) throw const FormatException('不写“::”时必须写满 8 段');
  }

  var v = BigInt.zero;
  for (final seg in all) {
    if (seg.isEmpty) throw const FormatException('出现了空字段，检查一下冒号');
    if (seg.length > 4) throw FormatException('“$seg”超过 4 位十六进制');
    final g = int.tryParse(seg, radix: 16);
    if (g == null) throw FormatException('“$seg”不是合法的十六进制');
    v = (v << 16) | BigInt.from(g);
  }
  return v;
}

/// IPv6 压缩写法（把最长的连续 0 段缩成 ::）
String _v6Str(BigInt v) {
  final segs = <int>[];
  var x = v;
  for (var i = 0; i < 8; i++) {
    segs.insert(0, (x & BigInt.from(0xFFFF)).toInt());
    x = x >> 16;
  }
  var bestStart = -1, bestLen = 0;
  var curStart = -1, curLen = 0;
  for (var i = 0; i < 8; i++) {
    if (segs[i] == 0) {
      if (curStart < 0) {
        curStart = i;
        curLen = 0;
      }
      curLen++;
      if (curLen > bestLen) {
        bestLen = curLen;
        bestStart = curStart;
      }
    } else {
      curStart = -1;
      curLen = 0;
    }
  }
  if (bestLen < 2) {
    return segs.map((e) => e.toRadixString(16)).join(':');
  }
  final head = segs.sublist(0, bestStart).map((e) => e.toRadixString(16)).join(':');
  final tail = segs.sublist(bestStart + bestLen).map((e) => e.toRadixString(16)).join(':');
  return '$head::$tail';
}

/// IPv6 完整展开（每段 4 位）
String _v6Full(BigInt v) {
  final segs = <String>[];
  var x = v;
  for (var i = 0; i < 8; i++) {
    segs.insert(0, (x & BigInt.from(0xFFFF)).toInt().toRadixString(16).padLeft(4, '0'));
    x = x >> 16;
  }
  return segs.join(':');
}

/// 千分位
String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _groupBig(BigInt n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

// ===========================================================================
// 3. 地图坐标转换（WGS84 / GCJ02 / BD09）
// ===========================================================================

/// 地图坐标转换：GPS 原始坐标(WGS84)、国测局火星坐标(GCJ02)、
/// 百度坐标(BD09) 三者互转。
///
/// 离线算法，不调任何接口 —— 出差没网也能用。
class CoordinateConvertPage extends StatefulWidget {
  const CoordinateConvertPage({super.key});

  @override
  State<CoordinateConvertPage> createState() => _CoordinateConvertPageState();
}

class _CoordinateConvertPageState extends State<CoordinateConvertPage> {
  final _lat = TextEditingController(text: '39.908692');
  final _lon = TextEditingController(text: '116.397477');
  double? _latV;
  double? _lonV;
  String? _error;

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  void _pick() {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    if (lat == null || lon == null) {
      _error = '纬度 / 经度得是数字';
      return;
    }
    if (!lat.isFinite || !lon.isFinite) {
      _error = '纬度 / 经度不是有限数';
      return;
    }
    if (lat.abs() > 90 || lon.abs() > 180) {
      _error = '纬度范围 -90~90，经度范围 -180~180';
      return;
    }
    _error = null;
  }

  /// 复制一行的值
  void _copy(BuildContext context, String label, double lat, double lon) {
    final text = '$lat,$lon';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 $label：$text'), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '地图坐标转换',
      subtitle: 'WGS84 / 火星坐标 / 百度坐标 互转',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: '纬度',
                    hintText: '39.908692',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _lon,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: '经度',
                    hintText: '116.397477',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => setState(_pick),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('换算'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in const [
                ['天安门', '39.908692', '116.397477'],
                ['东方明珠', '31.239666', '121.499809'],
                ['广州塔', '23.106600', '113.324500'],
              ])
                ActionChip(
                  label: Text(p[0], style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _lat.text = p[1];
                    _lon.text = p[2];
                    setState(_pick);
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: scheme.errorContainer.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!, style: const TextStyle(fontSize: 13)),
              ),
            )
          else
            _resultBlock(context),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(
                '说明：\n'
                '• WGS84：GPS / 国际标准（Google 海外、OSM 用它）\n'
                '• GCJ02：国测局「火星坐标」（高德、腾讯、Google 中国区）\n'
                '• BD09：百度坐标（在 GCJ02 上又做了一次偏移）\n'
                '• 在中国大陆以外，三者基本重合，偏差可忽略\n'
                '• 点任意一行可复制「纬度,经度」',
                style: TextStyle(fontSize: 11.5, height: 1.75, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultBlock(BuildContext context) {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    if (lat == null || lon == null) {
      return const SizedBox.shrink();
    }
    final wgs = _Coord.wgs84(lat, lon);
    final gcj = _CoordTransform.wgs84ToGcj02(wgs);
    final bd = _CoordTransform.gcj02ToBd09(gcj);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _coordCard(context, 'WGS84（GPS 原始）', wgs, '标准坐标'),
        const SizedBox(height: 8),
        _coordCard(context, 'GCJ02（火星坐标）', gcj, '高德 / 腾讯 / Google 中国'),
        const SizedBox(height: 8),
        _coordCard(context, 'BD09（百度坐标）', bd, '百度地图'),
      ],
    );
  }

  Widget _coordCard(BuildContext context, String title, _Coord c, String note) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _copy(context, title, c.lat, c.lon),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Icon(Icons.copy_rounded, size: 15, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                '${c.lat.toStringAsFixed(6)}, ${c.lon.toStringAsFixed(6)}',
                style: TextStyle(
                  fontSize: 15,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 3),
              Text(note, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一对经纬度
class _Coord {
  final double lat;
  final double lon;
  const _Coord(this.lat, this.lon);
  static _Coord wgs84(double lat, double lon) => _Coord(lat, lon);
}

/// 坐标系互转（都是离线公式）
class _CoordTransform {
  static const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
  static const double _ee = 0.00669342162296594323; // 第一偏心率平方

  /// 中国大陆粗略范围判断（这个范围外不做偏移）
  static bool outOfChina(double lat, double lon) {
    return !(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55);
  }

  static double _transLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double _transLon(double x, double y) {
    var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
  }

  /// WGS84 → GCJ02
  static _Coord wgs84ToGcj02(_Coord c) {
    if (outOfChina(c.lat, c.lon)) return c;
    var dLat = _transLat(c.lon - 105.0, c.lat - 35.0);
    var dLon = _transLon(c.lon - 105.0, c.lat - 35.0);
    final radLat = c.lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return _Coord(c.lat + dLat, c.lon + dLon);
  }

  /// GCJ02 → WGS84（用一次反算 + 一次迭代，精度到厘米级）
  static _Coord gcj02ToWgs84(_Coord c) {
    if (outOfChina(c.lat, c.lon)) return c;
    final g = wgs84ToGcj02(c);
    final dLat = g.lat - c.lat;
    final dLon = g.lon - c.lon;
    var lat = c.lat - dLat;
    var lon = c.lon - dLon;
    // 再迭代一轮，抵消非线性误差
    final again = wgs84ToGcj02(_Coord(lat, lon));
    lat -= again.lat - c.lat;
    lon -= again.lon - c.lon;
    return _Coord(lat, lon);
  }

  static const double _xPi = math.pi * 3000.0 / 180.0;

  /// GCJ02 → BD09
  static _Coord gcj02ToBd09(_Coord c) {
    final z = math.sqrt(c.lon * c.lon + c.lat * c.lat) + 0.00002 * math.sin(c.lat * _xPi);
    final theta = math.atan2(c.lat, c.lon) + 0.000003 * math.cos(c.lon * _xPi);
    return _Coord(z * math.sin(theta) + 0.006, z * math.cos(theta) + 0.0065);
  }

  /// BD09 → GCJ02
  static _Coord bd09ToGcj02(_Coord c) {
    final x = c.lon - 0.0065;
    final y = c.lat - 0.006;
    final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * _xPi);
    final theta = math.atan2(y, x) - 0.000003 * math.cos(x * _xPi);
    return _Coord(z * math.sin(theta), z * math.cos(theta));
  }
}
