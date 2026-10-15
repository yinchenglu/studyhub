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
// ImageByteFormat 同理：条码「保存 / 分享」要把预览截成 PNG 得用它。
import 'dart:ui' show FontFeature, ImageByteFormat;

import 'package:flutter/material.dart';
// RenderRepaintBoundary 在 rendering 里，widgets/material 不保证导出它
// （tool_pages_ext.dart 的二维码页也是单独 import 的）
import 'package:flutter/rendering.dart';
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

/// 求 EAN / UPC 的校验位。
///
/// 规则就一句 GS1 原文：**从右往左数，紧邻校验位的那一位乘 3，再交替乘 1**。
/// 这一句对三种长度都成立（右起第 1、3、5… 位 ×3）：
///   12 位前缀（EAN-13）、7 位前缀（EAN-8）、11 位前缀（UPC-A）。
///
/// ★ v1.5.0 修的真 bug：原来写的是「左起奇数位 ×1、偶数位 ×3」，
///   这条**只在 12 位前缀上**和 GS1 规则等价，7 位 / 11 位前缀一用就奇偶反了：
///     · EAN-8 '1234567' 正确校验位是 0（→ '12345670'），旧写法算出 8
///       —— 输 7 位时会静默生成一个**扫不出来的条码**；
///     · UPC-A '03600029145' 正确是 2，旧写法算出 8，而算完还要丢给
///       encodeEan13 再校验一次 → 必然失败 —— 于是**用户输合法的 12 位 UPC-A
///       会被判「校验位不对」**，输 11 位则拿到一个错的校验位。
///   经典例子 9638507 → 4 两种写法碰巧一样（66 和 86 同余 mod 10），
///   所以这个坑藏得很深，是网页版的独立测试拿公开算例扫出来的。
int _eanCheckDigit(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    final d = int.parse(digits[i]);
    final fromRight = digits.length - i; // 最右一位是 1
    sum += fromRight.isOdd ? d * 3 : d;
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

  /// 圈住「条码预览」那一块，「保存 / 分享」要靠它截图。
  /// 没有它 toImage 抓到的是整个屏幕。
  final _boundary = GlobalKey();

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
            RepaintBoundary(
              key: _boundary,
              child: Container(
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
            ),
            const SizedBox(height: 8),
            Text(
              '模块数 ${r.bits.length} · 格式 $_fmtName\n'
              '扫不出来时，把手机屏幕调亮、别贴膜反光，或者把「加粗」打开。',
              style: TextStyle(fontSize: 11.5, height: 1.65, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            // v1.6.0：原来这里只有一颗「复制条码内容」，
            // 用户要求拆成「保存」和「分享」两颗。
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveBarcode,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('保存'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _shareBarcode,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('分享'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 把条码预览整块截成 PNG 字节。截不出来返回 null。
  ///
  /// 返回 `List<int>?` 而不是 `Uint8List?`：这个文件没 import `dart:typed_data`，
  /// 用 `List<int>`（Uint8List 本来就是它的子类型）就完全绕开了「符号从哪来」的问题，
  /// 而 `saveToDownload` 收的也正是 `List<int>`。
  Future<List<int>?> _barcodePng() async {
    final b = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return null;
    final img = await b.toImage(pixelRatio: 3);
    final data = await img.toByteData(format: ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// 「保存」：安静地存到下载目录，不拉分享面板。
  Future<void> _saveBarcode() async {
    try {
      final bytes = await _barcodePng();
      if (bytes == null || !mounted) return;
      final f = await saveToDownload(
          '条码_${DateTime.now().millisecondsSinceEpoch}.png', bytes);
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败，检查存储权限');
        return;
      }
      toast(context, '已保存到 ${f.path}');
    } catch (e) {
      if (mounted) toast(context, '保存失败：$e');
    }
  }

  /// 「分享」：分享得先有文件，所以还是先落盘再拉分享面板。
  Future<void> _shareBarcode() async {
    try {
      final bytes = await _barcodePng();
      if (bytes == null || !mounted) return;
      final f = await saveToDownload(
          '条码_${DateTime.now().millisecondsSinceEpoch}.png', bytes);
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败，检查存储权限');
        return;
      }
      await shareFiles(context, [f], text: _input.text.trim());
    } catch (e) {
      if (mounted) toast(context, '保存失败：$e');
    }
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
///
/// ── v1.8.0 用户第 8 条：「进一步美化，换一下比较方正的字体」────────
/// 这一次动的是**观感**，功能性东西一个没删。三件事：
///
///   1. **真的做成「翻页」牌。** 每半小时 / 每小时两块牌子，
///      深灰渐变圆角卡片 + 描边 + 投影，正中间一道横向切缝 ——
///      这道缝是翻页钟最醒目、也最容易被认出来的特征（原来只是两串白字
///      飘在黑底上，说它是「翻页时钟」有点名不副实）。
///      缝画在数字**之上**：落在卡片底色上几乎看不见，压过白色笔画时
///      立刻显出「上下两半」的味道。
///   2. **换字体。** 打包了两款数字方正的显示体（OFL 授权，可随包分发）：
///        · FlipSquare = Chakra Petch Bold —— 方块感最强，转角平直
///        · FlipTall   = Bebas Neue       —— 瘦高条，老式出发牌那种味道
///      「方正」这事各人标准不同，所以**做成按钮现场切换**（连系统字体
///      一共三档），替用户猜不如让他自己挑。
///   3. 几处小润色：时间背后一圈几乎看不见的径向光晕（纯黑纯白对比太硬）、
///      冒号跟秒闪烁（秒关了也看得出表在走）、日期与星期之间加个圆点分隔。
///
/// ⚠️ 字体只通过 `TextStyle.fontFamily` 显式引用，**没有**全局替换 UI 字体，
///    中文那两行日期照旧走系统字体（打包的两款都只有拉丁字形）。
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

  /// 时钟可选字体（v1.8.0 新增）。`null` = 系统默认字体。
  ///
  /// 顺序就是右上角「字体」按钮的点击循环顺序 —— 第一项是默认值，
  /// 也就是用户进来看到的那一款。放 FlipSquare（方块感最强的那款）打头，
  /// 因为第 8 条要求的就是「比较方正」。
  static const List<String?> _fontFamilies = <String?>[
    'FlipSquare', // Chakra Petch Bold
    'FlipTall', // Bebas Neue
    null, // 系统字体（v1.7.0 及以前的样子）
  ];
  static const List<String> _fontLabels = <String>['方形', '窄高', '系统'];
  int _fontIdx = 0;
  String? get _fontFamily => _fontFamilies[_fontIdx];

  String get _hourText {
    var h = _now.hour;
    if (!_use24h) {
      h = h % 12;
      if (h == 0) h = 12;
    }
    return h.toString().padLeft(2, '0');
  }

  String get _minuteText => _now.minute.toString().padLeft(2, '0');

  String get _secondText => _now.second.toString().padLeft(2, '0');

  String get _ampm => _now.hour < 12 ? '上午' : '下午';

  @override
  Widget build(BuildContext context) {
    final lunar = solarToLunar(_now);
    final term = solarTermOf(_now);

    final dateLine = '${_now.year} 年 ${_now.month} 月 ${_now.day} 日';
    final weekLine = '星期${weekdayCn(_now)}';
    final lunarLine = '农历 ${lunar.ganZhi}【${lunar.zodiac}】年 '
        '${lunar.monthName}${lunar.dayName}'
        '${term == null ? '' : '  ·  $term'}';

    // 背景全黑，字全白 —— 当桌面钟用最省电也最好看
    final fg = _dim ? const Color(0xFF6E6E6E) : Colors.white;

    Widget body = Container(
      color: Colors.black,
      child: Stack(
        children: [
          // ---- 时间背后一圈极淡的径向光晕（v1.8.0 新增）----
          // 纯黑底压纯白字，对比太硬，看着「生」。补一层几乎察觉不到的光晕
          // 把中间托一下，整幅画面会润很多。它是**静态**渐变、不随秒重绘，
          // 所以不额外费电 —— 省电是这个页面一半的意义。
          // 调暗模式（夜间床头用）下直接不画。
          if (!_dim)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.85,
                    colors: <Color>[Color(0x1A3B6FE0), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ---- 主时间：两块翻页牌 + 冒号 + 小秒 ----
                // v1.6.0：用户要求「时间的字体加粗加大」（w200→w700、132→176）。
                // v1.8.0：字号 176 保持不变，改成装进翻页牌里。
                // 外面这层 FittedBox(scaleDown) **必须留着** ——
                // 加了牌的左右内边距后整体更宽，窄屏上全靠它兜底自动缩，
                // 不然会横向溢出（横屏手机上尤其容易撞上）。
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _flipCard(_hourText, fg),
                        _colon(fg),
                        _flipCard(_minuteText, fg),
                        // 秒那一列一直挂着（即使秒关了也要留位置给「上午/下午」），
                        // 只是关掉秒时不再多留那段间距。
                        if (_showSecond) const SizedBox(width: 16),
                        _secondCol(fg),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                // ---- 公历日期 · 星期 ----
                // v1.8.0：原来日期和星期挤在一句话里用空格隔开，这里拆成
                // 「日期 · 星期」，中间用一个小圆点，层次清楚一点。
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(dateLine,
                        style: TextStyle(
                            color: fg.withValues(alpha: 0.92),
                            fontSize: 22,
                            letterSpacing: 1.5)),
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: fg.withValues(alpha: 0.35),
                      ),
                    ),
                    Text(weekLine,
                        style: TextStyle(
                            color: fg.withValues(alpha: 0.92),
                            fontSize: 22,
                            letterSpacing: 1.5)),
                  ],
                ),
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
                // 字体切换（v1.8.0 新增，对应第 8 条「换一下比较方正的字体」）。
                // 点一下换下一款、循环。长按能看见当前是哪一款。
                // 「方正」各人标准不同，做成可切比替用户猜稳。
                _iconBtn(
                    Icons.text_fields,
                    '字体：${_fontLabels[_fontIdx]}（点一下换下一款）',
                    () => setState(
                        () => _fontIdx = (_fontIdx + 1) % _fontFamilies.length)),
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

  // ---------------- v1.8.0 新增的三个零件 ----------------

  /// 一块「翻页牌」。
  ///
  /// 见类注释：正中间那道横向切缝是翻页钟最醒目的特征。缝画在数字**之上** ——
  /// 落在卡片底色上几乎看不见，压过白色笔画时立刻显出「上下两半」的味道。
  ///
  /// 配色写死不跟主题：这个页面本来就是「黑底白字当桌面钟」，
  /// 跟着浅色主题走会变成一坨白，整页的意义就没了。
  Widget _flipCard(String text, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // 上浅下深：模拟「上半张牌迎着光、下半张落在阴影里」
            colors: _dim
                ? const <Color>[Color(0xFF1C1C1C), Color(0xFF0B0B0B)]
                : const <Color>[Color(0xFF2C323C), Color(0xFF0E1116)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x8C000000),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Text(
              text,
              style: TextStyle(
                color: fg,
                fontFamily: _fontFamily,
                fontSize: 176,
                height: 1.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            // 翻页缝。用 Positioned.fill 让它铺满整块牌，所以这条线正好落在
            // 「牌的竖直中线」上 —— 也是数字高度的一半，切得齐。
            Positioned.fill(
              child: Center(
                child: Container(
                  height: 2.5,
                  width: double.infinity,
                  color: const Color(0xE6000000),
                ),
              ),
            ),
          ],
        ),
      );

  /// 中间的冒号：跟着秒闪烁。
  ///
  /// 为什么要闪：这是个**静止**的大钟，秒一关掉（`_showSecond = false`）
  /// 就完全看不出它还在走，跟一张截图没区别。偶数秒亮、奇数秒压暗，
  /// 瞟一眼就知道表是活的。
  ///
  /// 底下那句 `bottom: 26` 和 [_secondCol] 用的是同一个数 ——
  /// 两者都以「牌的底边」为基准，这样冒号才会落在数字的竖直中线上。
  Widget _colon(Color fg) => Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: SizedBox(
          width: 34,
          child: Center(
            child: Text(
              ':',
              style: TextStyle(
                color: _now.second.isEven ? fg : fg.withValues(alpha: 0.14),
                fontFamily: _fontFamily,
                fontSize: 132,
                height: 1.0,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );

  /// 秒那一列：小字秒 + （12 小时制时）上午/下午。
  ///
  /// `bottom: 26` 与 [_colon] 对齐，让秒贴着牌的底边而不是飘在中间。
  Widget _secondCol(Color fg) => Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 秒刻意做小：不至于喧宾夺主，又能看出表在走
            if (_showSecond)
              Text(
                _secondText,
                style: TextStyle(
                  color: fg.withValues(alpha: 0.8),
                  fontFamily: _fontFamily,
                  fontSize: 44,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            if (!_use24h)
              Text(_ampm,
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 15)),
          ],
        ),
      );

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 19),
        color: Colors.white54,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );
}
