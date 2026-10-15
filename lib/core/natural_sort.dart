// 「和电脑一样」的名称排序（v1.8.0 新增）。
//
// ── 起因 ────────────────────────────────────────────────
// 用户：「你的默认按照名称排序的方式，跟电脑的怎么不一样。」
// 原来 `sort_utils.dart` 里排名称就是一句
//     a.name.toLowerCase().compareTo(b.name.toLowerCase())
// 也就是**纯字符串字典序**。它和 Windows 资源管理器差在两处，
// 而且两处都很容易被用户一眼看见：
//
//   ① **数字不按数值排。** '1' < '2' 是字符比较，所以
//      `第10章` 会排在 `第2章` **前面**（'1' < '2'），
//      `file2` 会跑到 `file10` 后面。电脑上是 1 / 2 / 10。
//      这是最常见的「不一样」。
//   ② **中文不按拼音排。** Dart 的 compareTo 比的是 UTF-16 码元，
//      汉字在 CJK 统一区里是按《康熙字典》部首-笔画顺序编码的，
//      跟拼音完全是两回事：
//          阿(a)  = U+963F
//          白(bai) = U+767D
//          码点序 → 白 在前；拼音序（电脑上）→ 阿 在前
//
// ── 办法 ────────────────────────────────────────────────
// 给每个名字算一个**排序键**，让「按字符比这个键」等价于
// 「按电脑的规矩比这个名字」：
//   * 数字段 → 去前导零后**定宽零填充**（'2' → '000000000002'），
//     定宽之后再按字符比，得到的就是按数值比；
//   * 拉丁字母 → 转小写；
//   * 汉字 → 查拼音表换成拼音，并且**整体排到所有 ASCII 之后**
//     （Windows 中文排序里「数字 < 字母 < 汉字」这个先后是定死的）；
//   * 其余字符原样。
//
// 键相同（'1' 与 '01'、'Apple' 与 'apple'）时再用原始串兜底比一次，
// 保证任意两个不同名字的比较结果**永不为 0**，排序结果才稳定 ——
// 否则同一个目录每次刷新顺序都可能跳。
//
// 这套算法先在 Python 里跑通 13 个用例才搬过来（`.workbuddy/test_natural_sort.py`），
// 因为本机没有 Flutter/Dart SDK，改错了要等云端构建才知道。
//
// ⚠️ HTML 版（`网页版小工具/`）里有一份**同逻辑的 JS 实现**，
//    改这里记得同步改那边，两边排序不一致用户会立刻发现。

import 'package:flutter/services.dart' show rootBundle;

/// 数字段的定宽。12 位足以放下文件名里任何数字；
/// 真超了就在 [naturalSortKey] 里截断（只影响超长数字之间的相对顺序）。
const int _numberWidth = 12;

/// 汉字在排序键里的前缀。
///
/// 取私用区起点 U+E000：它比所有 ASCII（0x00~0x7F）都大，
/// 于是「汉字排在数字和字母后面」这件事自动成立，不用额外写分支。
const String _hanMarker = '\uE000';

/// 汉字 → 拼音（无声调）查表。
///
/// 表来自 `assets/data/pinyin_sort.txt`（6763 个 GB2312 常用字，46 KB），
/// 由 `.workbuddy/gen_pinyin.py` 从 mozillazg/pinyin-data 生成。
/// 表外的生僻字自动退回码点序 —— 排得不够像电脑，但不会排错。
class PinyinTable {
  PinyinTable._();

  static Map<int, String>? _map;

  /// 表是否已就绪。
  static bool get ready => _map != null;

  /// 表里有几个字（没载入就是 0）。
  static int get size => _map?.length ?? 0;

  /// 从 assets 载入。**只在 `main()` 里调一次**。
  ///
  /// 任何失败都吞掉、绝不上抛：它只影响「排得像不像电脑」，
  /// 为它让整个 App 起不来完全不划算。
  static Future<void> init() async {
    if (_map != null) return;
    try {
      final raw = await rootBundle.loadString('assets/data/pinyin_sort.txt');
      final m = <int, String>{};
      for (final line in raw.split('\n')) {
        // 每条就是「一个汉字 + 拼音」，直接接在一起、中间不放分隔符。
        // 敢这么省是因为用到的汉字全在 BMP 里、恒占 1 个 UTF-16 码元，
        // 所以第 0 位一定是那个字，剩下的一定是拼音。
        if (line.length < 2) continue;
        m[line.codeUnitAt(0)] = line.substring(1);
      }
      _map = m.isEmpty ? null : m;
    } catch (_) {
      _map = null;
    }
  }

  /// 查一个码元对应的拼音；不是表里的汉字就返回 null。
  static String? of(int codeUnit) => _map?[codeUnit];
}

/// 算一个名字的排序键。规则见本文件顶部注释。
String naturalSortKey(String s) {
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);

    // ---- ① 数字段：按**数值**比，不是按字符比 ----
    if (c >= 0x30 && c <= 0x39) {
      var j = i;
      while (j < s.length) {
        final d = s.codeUnitAt(j);
        if (d < 0x30 || d > 0x39) break;
        j++;
      }
      var digits = s.substring(i, j);
      // 去掉前导零（至少留一位）：「007」要和「7」排在一起，
      // 不能因为多两个 0 就整段跑到前面去。
      var k = 0;
      while (k < digits.length - 1 && digits.codeUnitAt(k) == 0x30) {
        k++;
      }
      digits = digits.substring(k);
      if (digits.length > _numberWidth) {
        digits = digits.substring(0, _numberWidth);
      }
      sb.write(digits.padLeft(_numberWidth, '0'));
      i = j;
      continue;
    }

    // ---- ② 拉丁字母：不分大小写 ----
    if (c >= 0x41 && c <= 0x5A) {
      sb.writeCharCode(c + 0x20);
      i++;
      continue;
    }

    // ---- ③ 汉字：换成拼音，并整体排到所有 ASCII 之后 ----
    final py = PinyinTable.of(c);
    if (py != null) {
      sb.write(_hanMarker);
      sb.write(py);
      i++;
      continue;
    }

    // ---- ④ 其余字符（标点、非 ASCII 符号、表外生僻字…）原样保留 ----
    sb.writeCharCode(c);
    i++;
  }
  return sb.toString();
}

/// 自然排序比较器。返回 <0 / 0 / >0，语义同 [String.compareTo]。
int naturalCompare(String a, String b) {
  final c = naturalSortKey(a).compareTo(naturalSortKey(b));
  if (c != 0) return c;
  // 键相同（'1' 与 '01'、'Apple' 与 'apple'）时用原始串兜底，
  // 保证两个不同名字的比较结果永远不为 0 —— 排序才稳定。
  return a.compareTo(b);
}
