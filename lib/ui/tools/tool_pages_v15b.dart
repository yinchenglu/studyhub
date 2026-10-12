// v1.5.0 新增工具（第三批）—— 条码生成器 + 翻页时钟。
//
//   * BarcodePage    条码生成器：Code128 / Code39 / EAN-13 / EAN-8 / UPC-A
//   * FlipClockPage  翻页时钟：默认横屏、大字号时间、秒小字、公历+农历+星期+节气
//
// 条码表都是**核对过的**，不是凭记忆写的：
//   Code128 的 107 个符号宽度表逐条比对过 lindell/JsBarcode 的 constants.js，107/107 一致；
//   Code39 的 44 个字符宽度表同样逐条比对，44/44 一致；
//   EAN/UPC 的 L/G/R 三个 10 元素数组、起始位 101、中间位 01010、首位奇偶结构表，
//   也全部与参考实现一致。
// 以后要动这几张表，务必重新跑一遍对照 —— 编码错一位，扫出来就是另一串数字。

import 'dart:async';
// FontFeature 是 dart:ui 的类。material.dart 不一定把它带出来
// （tool_pages_v15.dart 里就吃过这个亏），显式 import 一次最稳。
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lunar.dart';
import 'tool_pages.dart';

// ===========================================================================
// 1. 条码编码
// ===========================================================================

/// Code128 的 107 个符号，每个用「条/空交替的 6 段宽度」表示。
/// 下标 0~102 是数据符号，103/104/105 是 StartA/B/C，106 是 Stop。
const List<String> _kCode128 = <String>[
  '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
  '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
  '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
  '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
  '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
  '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
  '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
  '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
  '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
  '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
  '114131', '311141', '411131', '211412', '211214', '211232', '2331112',
];

/// Code39 的 44 个字符，用 9 段「窄(n) / 宽(w)」表示（条空交替、条开头）
const Map<String, String> _kCode39 = <String, String>{
  '0': 'nnnwwnwnn', '1': 'wnnwnnnnw', '2': 'nnwwnnnnw', '3': 'wnwwnnnnn',
  '4': 'nnnwwnnnw', '5': 'wnnwwnnnn', '6': 'nnwwwnnnn', '7': 'nnnwnnwnw',
  '8': 'wnnwnnwnn', '9': 'nnwwnnwnn', 'A': 'wnnnnwnnw', 'B': 'nnwnnwnnw',
  'C': 'wnwnnwnnn', 'D': 'nnnnwwnnw', 'E': 'wnnnwwnnn', 'F': 'nnwnwwnnn',
  'G': 'nnnnnwwnw', 'H': 'wnnnnwwnn', 'I': 'nnwnnwwnn', 'J': 'nnnnwwwnn',
  'K': 'wnnnnnnww', 'L': 'nnwnnnnww', 'M': 'wnwnnnnwn', 'N': 'nnnnwnnww',
  'O': 'wnnnwnnwn', 'P': 'nnwnwnnwn', 'Q': 'nnnnnnwww', 'R': 'wnnnnnwwn',
  'S': 'nnwnnnwwn', 'T': 'nnnnwnwwn', 'U': 'wwnnnnnnw', 'V': 'nwwnnnnnw',
  'W': 'wwwnnnnnn', 'X': 'nwnnwnnnw', 'Y': 'wwnnwnnnn', 'Z': 'nwwnwnnnn',
  // 注意 `r'$'`：这个键就是美元符号本身，必须用原始字符串，
  // 写成 '$' 会被 Dart 当成「插值开始」直接编译报错（check_apis 的裸 $ 规则抓到）
  '-': 'nwnnnnwnw', '.': 'wwnnnnwnn', ' ': 'nwwnnnwnn', r'$': 'nwnwnwnnn',
  '/': 'nwnwnnnwn', '+': 'nwnnnwnwn', '%': 'nnnwnwnwn', '*': 'nwnnwnwnn',
};

/// EAN / UPC 的左奇数(L)、左偶数(G)、右(R) 三种 7 位编码
const List<String> _kEanL = <String>[
  '0001101', '0011001', '0010011', '0111101', '0100011',
  '0110001', '0101111', '0111011', '0110111', '0001011',
];
const List<String> _kEanG = <String>[
  '0100111', '0110011', '0011011', '0100001', '0011101',
  '0111001', '0000101', '0010001', '0001001', '0010111',
];
const List<String> _kEanR = <String>[
  '1110010', '1100110', '1101100', '1000010', '1011100',
  '1001110', '1010000', '1000100', '1001000', '1110100',
];

/// EAN-13 左半区 6 位的奇偶结构，由首位数字决定
const List<String> _kEan13Structure = <String>[
  'LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG',
  'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL',
];

const String _kEanStart = '101';       // 两侧起始/结束位
const String _kEanMiddle = '01010';    // 中间分隔位

/// 条码编码结果
class BarcodeResult {
  final String bits;          // 模块序列，'1' 是黑条
  final String human;         // 条码下面那行字
  final String? error;        // 不为空就是没法生成
  final List<int> guard;      // 需要画得更长的模块下标（EAN 的起始/中间/结束位）

  const BarcodeResult({
    this.bits = '',
    this.human = '',
    this.error,
    this.guard = const <int>[],
  });

  bool get ok => error == null && bits.isNotEmpty;
}

String _rep(String c, int n) => List<String>.filled(n, c).join();

/// 把「6 段宽度」展开成 0/1 模块串（第 0 段一定是黑条）
String _widthsToBits(String widths) {
  final sb = StringBuffer();
  for (var i = 0; i < widths.length; i++) {
    final n = int.parse(widths[i]);
    sb.write(_rep(i.isEven ? '1' : '0', n));
  }
  return sb.toString();
}

/// Code128 单个符号的模块串
String _c128Symbol(int v) => _widthsToBits(_kCode128[v]);

/// 生成 Code128。mode: 0 自动 / 1 强制 B / 2 强制 C
BarcodeResult encodeCode128(String data, int mode) {
  if (data.isEmpty) return const BarcodeResult(error: '请输入要编码的内容');
  if (data.length > 48) {
    return const BarcodeResult(error: '内容太长了，条码会宽到扫不出来（建议 48 字符以内）');
  }

  final allDigits = RegExp(r'^\d+$').hasMatch(data);
  // 自动模式下，纯数字且长度为偶数才用 C 集（C 集一次编两个数字，最短）
  var useC = mode == 2 || (mode == 0 && allDigits && data.length.isEven);

  if (useC && !allDigits) {
    return const BarcodeResult(error: 'Code128C 只能编数字，请换成 B 集或自动');
  }
  if (useC && data.length.isOdd) {
    return const BarcodeResult(error: 'Code128C 要求数字个数是偶数');
  }
  if (!useC) {
    for (final r in data.runes) {
      if (r < 32 || r > 126) {
        return const BarcodeResult(error: 'Code128B 只支持键盘上能打出来的字符（ASCII 32~126）');
      }
    }
  }

  final values = <int>[];
  final start = useC ? 105 : 104;
  values.add(start);

  if (useC) {
    for (var i = 0; i < data.length; i += 2) {
      values.add(int.parse(data.substring(i, i + 2)));
    }
  } else {
    for (final r in data.runes) {
      values.add(r - 32);
    }
  }

  // 校验位：起始符 + Σ(数据值 × 位置)，位置从 1 开始
  var sum = start;
  for (var i = 1; i < values.length; i++) {
    sum += values[i] * i;
  }
  values.add(sum % 103);
  values.add(106);      // Stop

  final sb = StringBuffer();
  for (final v in values) {
    sb.write(_c128Symbol(v));
  }
  return BarcodeResult(bits: sb.toString(), human: data);
}

/// 生成 Code39（只用窄/宽两种宽度，宽 = 3 个模块）
BarcodeResult encodeCode39(String data) {
  final upper = data.toUpperCase();
  if (upper.isEmpty) return const BarcodeResult(error: '请输入要编码的内容');

  for (final ch in upper.split('')) {
    if (!_kCode39.containsKey(ch)) {
      return BarcodeResult(
          error: 'Code39 不支持字符「$ch」，只能用 0-9 A-Z 和 - . 空格 \$ / + %');
    }
  }

  // 首尾各一个星号做定界符；字符之间留 1 个模块的空
  final sb = StringBuffer();
  for (final ch in <String>['*', ...upper.split(''), '*']) {
    final w = _kCode39[ch]!;
    for (var i = 0; i < w.length; i++) {
      final n = w[i] == 'w' ? 3 : 1;
      sb.write(_rep(i.isEven ? '1' : '0', n));
    }
    sb.write('0');        // 字符间隔
  }
  return BarcodeResult(bits: sb.toString(), human: upper);
}

/// 求 EAN / UPC 的校验位：从左往右，奇数位 ×1、偶数位 ×3
int _eanCheckDigit(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    final d = int.parse(digits[i]);
    sum += (i.isEven) ? d : d * 3;
  }
  return (10 - sum % 10) % 10;
}

/// EAN-13：可以输 12 位（自动补校验位）或 13 位（校验位要自己是对的）
BarcodeResult encodeEan13(String raw) {
  var s = raw.replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return const BarcodeResult(error: '请输入 12 或 13 位数字');
  if (!RegExp(r'^\d+$').hasMatch(s)) {
    return const BarcodeResult(error: 'EAN-13 只能是数字');
  }
  if (s.length == 12) {
    s = s + _eanCheckDigit(s).toString();
  } else if (s.length != 13) {
    return BarcodeResult(error: 'EAN-13 要 12 或 13 位数字，现在输了 ${s.length} 位');
  } else {
    final expect = _eanCheckDigit(s.substring(0, 12)).toString();
    if (expect != s[12]) {
      return BarcodeResult(
          error: '校验位不对：12 位前缀 ${s.substring(0, 12)} 应该是 $expect，你填的是 ${s[12]}',
          human: s);
    }
  }

  final first = int.parse(s[0]);
  final structure = _kEan13Structure[first];

  final sb = StringBuffer(_kEanStart);
  for (var i = 0; i < 6; i++) {
    final d = int.parse(s[1 + i]);
    sb.write(structure[i] == 'L' ? _kEanL[d] : _kEanG[d]);
  }
  sb.write(_kEanMiddle);
  for (var i = 0; i < 6; i++) {
    sb.write(_kEanR[int.parse(s[7 + i])]);
  }
  sb.write(_kEanStart);

  final bits = sb.toString();
  return BarcodeResult(
    bits: bits,
    human: '${s[0]} ${s.substring(1, 7)} ${s.substring(7)}',
    // 起始 3 位、中间 5 位、结束 3 位画长一点（GB 标准要求）
    guard: <int>[
      0, 1, 2,
      for (var i = 45; i < 50; i++) i,
      bits.length - 3, bits.length - 2, bits.length - 1,
    ],
  );
}

/// EAN-8：输 7 位（补校验）或 8 位
BarcodeResult encodeEan8(String raw) {
  var s = raw.replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return const BarcodeResult(error: '请输入 7 或 8 位数字');
  if (!RegExp(r'^\d+$').hasMatch(s)) {
    return const BarcodeResult(error: 'EAN-8 只能是数字');
  }
  if (s.length == 7) {
    s = s + _eanCheckDigit(s).toString();
  } else if (s.length != 8) {
    return BarcodeResult(error: 'EAN-8 要 7 或 8 位数字，现在输了 ${s.length} 位');
  } else {
    final expect = _eanCheckDigit(s.substring(0, 7)).toString();
    if (expect != s[7]) {
      return BarcodeResult(
          error: '校验位不对：7 位前缀应该是 $expect，你填的是 ${s[7]}', human: s);
    }
  }

  final sb = StringBuffer(_kEanStart);
  for (var i = 0; i < 4; i++) {
    sb.write(_kEanL[int.parse(s[i])]);
  }
  sb.write(_kEanMiddle);
  for (var i = 4; i < 8; i++) {
    sb.write(_kEanR[int.parse(s[i])]);
  }
  sb.write(_kEanStart);

  final bits = sb.toString();
  return BarcodeResult(
    bits: bits,
    human: '${s.substring(0, 4)} ${s.substring(4)}',
    guard: <int>[
      0, 1, 2,
      for (var i = 31; i < 36; i++) i,
      bits.length - 3, bits.length - 2, bits.length - 1,
    ],
  );
}

/// UPC-A：12 位（或 11 位补校验）。本质就是首位为 0 的 EAN-13。
BarcodeResult encodeUpcA(String raw) {
  var s = raw.replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return const BarcodeResult(error: '请输入 11 或 12 位数字');
  if (!RegExp(r'^\d+$').hasMatch(s)) {
    return const BarcodeResult(error: 'UPC-A 只能是数字');
  }
  if (s.length == 11) {
    s = s + _eanCheckDigit(s).toString();
  } else if (s.length != 12) {
    return BarcodeResult(error: 'UPC-A 要 11 或 12 位数字，现在输了 ${s.length} 位');
  } else {
    final expect = _eanCheckDigit(s.substring(0, 11)).toString();
    if (expect != s[11]) {
      return BarcodeResult(
          error: '校验位不对：11 位前缀应该是 $expect，你填的是 ${s[11]}', human: s);
    }
  }

  // 补一个前导 0 就当 EAN-13 编
  final r = encodeEan13('0$s');
  if (!r.ok) return r;
  return BarcodeResult(
    bits: r.bits,
    human: '${s[0]} ${s.substring(1, 6)} ${s.substring(6, 11)} ${s[11]}',
    guard: r.guard,
  );
}

/// 条码绘制。黑条白底是硬要求（有些扫码头在深色背景下完全读不出来），
/// 所以这里**不跟随主题**，永远白底黑条。
class _BarcodePainter extends CustomPainter {
  final String bits;
  final List<int> guard;
  final bool showText;
  final String human;

  _BarcodePainter({
    required this.bits,
    required this.guard,
    required this.showText,
    required this.human,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bits.isEmpty) return;

    const quiet = 12.0;              // 两侧静区，按模块数算
    final totalModules = bits.length + quiet * 2;
    final moduleW = size.width / totalModules;
    final textH = showText ? 22.0 : 0.0;
    final barH = size.height - textH;
    final guardH = barH + (showText ? 10.0 : 0.0);   // 定界位往下多伸一点

    final paint = Paint()..color = const Color(0xFF000000);
    final guardSet = guard.toSet();

    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != '1') continue;
      final x = (quiet + i) * moduleW;
      final h = guardSet.contains(i) ? guardH : barH;
      canvas.drawRect(Rect.fromLTWH(x, 0, moduleW, h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BarcodePainter old) =>
      old.bits != bits || old.human != human || old.showText != showText;
}

// ===========================================================================
// 条码生成器页面
// ===========================================================================

class BarcodePage extends StatefulWidget {
  const BarcodePage({super.key});

  @override
  State<BarcodePage> createState() => _BarcodePageState();
}

class _BarcodePageState extends State<BarcodePage> {
  final _input = TextEditingController(text: '690123456789');
  int _fmt = 0;          // 0 Code128自动 1 Code128B 2 Code128C 3 Code39 4 EAN-13 5 EAN-8 6 UPC-A
  bool _showText = true;
  bool _highRes = false; // 高对比（更粗的条，防打印失真）

  @override
  void initState() {
    super.initState();
    _input.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  BarcodeResult get _result {
    final s = _input.text.trim();
    switch (_fmt) {
      case 3:
        return encodeCode39(s);
      case 4:
        return encodeEan13(s);
      case 5:
        return encodeEan8(s);
      case 6:
        return encodeUpcA(s);
      case 2:
        return encodeCode128(s, 2);
      case 1:
        return encodeCode128(s, 1);
      default:
        return encodeCode128(s, 0);
    }
  }

  String get _fmtName => const <String>[
        'Code128 自动', 'Code128-B', 'Code128-C', 'Code39',
        'EAN-13', 'EAN-8', 'UPC-A',
      ][_fmt];

  String get _fmtHint => const <String>[
        '什么都能编，最通用。纯数字且位数为偶数时自动用最短的 C 集',
        '英文、数字、符号都行（键盘上打得出来的）',
        '只编数字，且个数必须是偶数。同样的数字用 C 集最短',
        '只用 0-9 A-Z 和 - . 空格 \$ / + %，工业条码常用',
        '商品条码，13 位（输 12 位会自动补校验位）',
        '小包装商品条码，8 位（输 7 位会自动补校验位）',
        '北美商品条码，12 位（输 11 位会自动补校验位）',
      ][_fmt];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = _result;

    return ToolScaffold(
      title: '条码生成器',
      subtitle: 'Code128 / Code39 / EAN-13 / EAN-8 / UPC-A',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const ToolSection('格式'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 7; i++)
                ChoiceChip(
                  label: Text(
                    const <String>[
                      'Code128 自动', 'Code128-B', 'Code128-C', 'Code39',
                      'EAN-13', 'EAN-8', 'UPC-A',
                    ][i],
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: _fmt == i,
                  onSelected: (_) => setState(() => _fmt = i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_fmtHint,
              style: TextStyle(fontSize: 11.5, height: 1.6, color: scheme.onSurfaceVariant)),

          const ToolSection('内容'),
          TextField(
            controller: _input,
            onChanged: (_) => _refresh(),
            style: const TextStyle(fontSize: 14, letterSpacing: 0.5),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: _fmtName,
              hintText: _fmt >= 4 ? '比如 690123456789' : '比如 SH-2026-0001',
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => _input.clear(),
              ),
            ),
          ),

          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示文字', style: TextStyle(fontSize: 13)),
                  value: _showText,
                  onChanged: (v) => setState(() => _showText = v),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('加粗', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('打印后更容易扫', style: TextStyle(fontSize: 10.5)),
                  value: _highRes,
                  onChanged: (v) => setState(() => _highRes = v),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),
          if (r.error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 17, color: scheme.error),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(r.error!,
                        style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onErrorContainer)),
                  ),
                ],
              ),
            ),

          if (r.ok) ...[
            const ToolSection('条码预览'),
            Container(
              // 白底黑条：不跟随主题
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
              child: Column(
                children: [
                  SizedBox(
                    height: _highRes ? 150 : 110,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _BarcodePainter(
                        bits: r.bits,
                        guard: r.guard,
                        showText: _showText,
                        human: r.human,
                      ),
                    ),
                  ),
                  if (_showText)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 6),
                      child: Text(
                        r.human,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 14,
                          letterSpacing: 2.4,
                          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '模块数 ${r.bits.length} · 格式 $_fmtName\n'
              '扫不出来时，把手机屏幕调亮、别贴膜反光，或者把「加粗」打开。',
              style: TextStyle(fontSize: 11.5, height: 1.65, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: r.human));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制条码内容'), duration: Duration(seconds: 1)),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制条码内容'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 2. 翻页时钟
// ===========================================================================

/// 大屏翻页时钟。
///
/// 需求要点：
///   * 默认横屏显示（进入时强制横屏 + 全屏沉浸）
///   * 可翻转（点一下把整个表盘转 180°，躺着 / 支架反着放也能看）
///   * 完整公历日期 + 农历 + 星期
///   * 秒用小字
class FlipClockPage extends StatefulWidget {
  const FlipClockPage({super.key});

  @override
  State<FlipClockPage> createState() => _FlipClockPageState();
}

class _FlipClockPageState extends State<FlipClockPage> {
  Timer? _timer;
  DateTime _now = DateTime.now();
  bool _flipped = false;
  bool _showSecond = true;
  bool _use24h = true;
  bool _dim = false;

  @override
  void initState() {
    super.initState();
    _enterFullscreenLandscape();
    _tick();
    // 一秒一跳。用 periodic 而不是每分钟算一次，
    // 因为要显示秒；对电池的影响可以忽略（一个 setState 而已）。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
  }

  /// 进入时：强制横屏 + 隐藏状态栏和导航栏
  void _enterFullscreenLandscape() {
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 退出时恢复：竖屏 + 正常系统栏。
  /// 这一句不能漏 —— 漏了的话整个 App 会一直卡在横屏。
  void _restore() {
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _restore();
    super.dispose();
  }

  String get _timeText {
    var h = _now.hour;
    if (!_use24h) {
      h = h % 12;
      if (h == 0) h = 12;
    }
    return '${h.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
  }

  String get _secondText => _now.second.toString().padLeft(2, '0');

  String get _ampm => _now.hour < 12 ? '上午' : '下午';

  @override
  Widget build(BuildContext context) {
    final lunar = solarToLunar(_now);
    final term = solarTermOf(_now);

    final dateLine = '${_now.year} 年 ${_now.month} 月 ${_now.day} 日'
        '  星期${weekdayCn(_now)}';
    final lunarLine = '农历 ${lunar.ganZhi}【${lunar.zodiac}】年 '
        '${lunar.monthName}${lunar.dayName}'
        '${term == null ? '' : '  ·  $term'}';

    // 背景全黑，字全白 —— 当桌面钟用最省电也最好看
    final fg = _dim ? const Color(0xFF6E6E6E) : Colors.white;

    Widget body = Container(
      color: Colors.black,
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ---- 主时间 ----
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _timeText,
                      style: TextStyle(
                        color: fg,
                        fontSize: 132,
                        height: 1.0,
                        fontWeight: FontWeight.w200,
                        letterSpacing: 2,
                        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 秒刻意做小：不至于喧宾夺主，又能看出表在走
                          if (_showSecond)
                            Text(
                              _secondText,
                              style: TextStyle(
                                color: fg.withValues(alpha: 0.75),
                                fontSize: 34,
                                height: 1.0,
                                fontWeight: FontWeight.w300,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          if (!_use24h)
                            Text(_ampm,
                                style: TextStyle(
                                    color: fg.withValues(alpha: 0.6), fontSize: 15)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(dateLine,
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.92),
                        fontSize: 22,
                        letterSpacing: 1.5)),
                const SizedBox(height: 6),
                Text(lunarLine,
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.7),
                        fontSize: 17,
                        letterSpacing: 1.2)),
              ],
            ),
          ),

          // ---- 左上角：翻转 + 退出 ----
          Positioned(
            left: 10,
            top: 10,
            child: Row(
              children: [
                _iconBtn(Icons.screen_rotation, '翻转 180°',
                    () => setState(() => _flipped = !_flipped)),
                _iconBtn(Icons.close, '退出', () => Navigator.of(context).maybePop()),
              ],
            ),
          ),

          // ---- 右上角：一点设置 ----
          Positioned(
            right: 10,
            top: 10,
            child: Row(
              children: [
                _iconBtn(_showSecond ? Icons.timer : Icons.timer_off_outlined,
                    '秒', () => setState(() => _showSecond = !_showSecond)),
                _iconBtn(_use24h ? Icons.schedule : Icons.watch_later_outlined,
                    '12/24 小时', () => setState(() => _use24h = !_use24h)),
                _iconBtn(_dim ? Icons.brightness_low : Icons.brightness_high,
                    '夜间调暗', () => setState(() => _dim = !_dim)),
              ],
            ),
          ),
        ],
      ),
    );

    if (_flipped) {
      body = RotatedBox(quarterTurns: 2, child: body);
    }

    return Scaffold(backgroundColor: Colors.black, body: body);
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 19),
        color: Colors.white54,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );
}
