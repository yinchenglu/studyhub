import '../data/models/models.dart';
import 'natural_sort.dart';

/// 列表排序方式（笔记页 / 媒体库共用）
///
/// 两个命名上的坑，都踩过：
///   1. `label` 不能叫 `name` —— 枚举自带 `Enum.name` 实例 getter，
///      静态成员和实例成员同名在 Dart 里是编译错误。
///   2. 枚举成员也不能叫 `name` / `index` / `values`（同上原因），
///      所以这里用 byName / byTime / bySize。
enum SortKey {
  byName('名称'),
  byTime('修改时间'),
  bySize('大小');

  final String label;
  const SortKey(this.label);
}

/// 一次排序选择：按什么排 + 升序还是降序
class SortPref {
  final SortKey key;
  final bool asc;

  const SortPref({this.key = SortKey.byName, this.asc = true});

  /// 菜单上显示的当前状态
  String get label => '${key.label}${asc ? ' ↑' : ' ↓'}';

  /// 换一个排序键。
  /// 换到「名称」默认升序（A→Z 符合直觉），
  /// 换到「时间 / 大小」默认降序（新的、大的排前面更有用）。
  SortPref withKey(SortKey k) =>
      SortPref(key: k, asc: k == SortKey.byName);

  SortPref toggled() => SortPref(key: key, asc: !asc);
}

/// 给目录/文件列表排序。
///
/// 约定：**目录永远排在文件前面**。这是文件管理器的通用习惯；
/// 不这样做的話，「按大小排序」时目录会按大小散落在文件中间，找目录很累。
/// 所以先按「是不是目录」分组，组内再按选定键排。
///
/// v1.8.0：按名称排序换成了 [naturalCompare]（见 core/natural_sort.dart）。
/// 用户原话是「你的默认按照名称排序的方式，跟电脑的怎么不一样」，
/// 原来这里是一句 `a.name.toLowerCase().compareTo(b.name.toLowerCase())`，
/// 纯字典序，跟 Windows 资源管理器差两处：
///   ① 数字按字符比 → `第10章` 排在 `第2章` 前面（电脑上是 2 在 10 前）；
///   ② 中文按 Unicode 码点比（≈ 部首笔画序），电脑上按**拼音**排。
/// 现在两个都对上了。
List<DavEntry> sortEntries(List<DavEntry> list, SortPref pref) {
  final out = List<DavEntry>.from(list);
  out.sort((a, b) {
    // v1.9.0：用户要求"首页/索引类 md 自动排第一个"。
    // 用「文件名以『数字. 』开头」作为信号：
    //   1.首页.md  → 排第 1
    //   1.  → 自动认成「第 1 个」也行
    //   0.0 之类也算
    //
    // v1.9.0+28：再加一档「索引类文件名」——有些笔记库（第三方导入的）
    // 索引文件不叫「1.xxx.md」，而是 index.md / README.md / 总目录.md 之类。
    // 分三级：
    //   2 = 「数字.」前缀       → 最顶
    //   1 = index / 目录 / 首页 / README / Home 类 → 次顶
    //   0 = 其它
    // 无论哪一级，都**排在文件夹前面**（用户明确要求）。
    final aPin = _pinRank(a.name);
    final bPin = _pinRank(b.name);
    if (aPin != bPin) return bPin - aPin;
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int c;
    switch (pref.key) {
      case SortKey.byName:
        c = naturalCompare(a.name, b.name);
        break;
      case SortKey.byTime:
        final x = a.modified?.millisecondsSinceEpoch ?? 0;
        final y = b.modified?.millisecondsSinceEpoch ?? 0;
        c = x.compareTo(y);
        break;
      case SortKey.bySize:
        c = a.size.compareTo(b.size);
        break;
    }
    // 完全相等时用名字兜底，保证排序结果稳定（否则每次刷新顺序会跳）
    if (c == 0) c = a.name.compareTo(b.name);
    return pref.asc ? c : -c;
  });
  return out;
}

/// v1.9.0：检测文件名是否以「数字.」开头 —— 「1.首页.md」/「01. 索引.md」都中。
/// 用于笔记列表里把索引/首页类 md 顶到第一位。
///
/// v2.0.0+35：用户反馈「没有实现」。排查发现标准半角「数字.」是能中的，
/// 失效的是这些变体命名：
///   * 全角点「１．首页.md」/「1．首页.md」
///   * 顿号「1、首页.md」
///   * 「数字 + 空格」开头（01 前言.md）—— 这个不加，误伤太大（「2024 报告.md」）
/// 现在全角点 / 顿号也认。半角/全角数字都支持。
bool _isPinnedName(String name) {
  // [.．、] = 半角点 / 全角点 / 顿号；\s? 允许点后带一个空格
  final m = RegExp(r'^[\d０-９]+\s?[.．、]\s?').firstMatch(name);
  return m != null;
}

/// v1.9.0+28：置顶档位。
///   2 = 「数字.」前缀（最强的「我是第 1 篇」信号）
///   1 = 常见索引文件名（index / README / 目录 / 首页 / 大纲 / Home / Contents）
///   0 = 普通文件
int _pinRank(String name) {
  if (_isPinnedName(name)) return 2;
  final base = name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '').trim().toLowerCase();
  const keys = <String>[
    'index', 'readme', 'home', 'contents', 'summary', 'toc',
    '目录', '总目录', '索引', '首页', '大纲', '简介', '说明',
  ];
  for (final k in keys) {
    if (base == k || base.endsWith('·$k') || base.endsWith('-$k') || base.endsWith('_$k')) {
      return 1;
    }
  }
  // 「xxx总目录」「xxx目录」也算
  if (base.endsWith('目录') || base.endsWith('索引')) return 1;
  return 0;
}
