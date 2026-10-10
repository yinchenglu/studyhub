import '../data/models/models.dart';

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
List<DavEntry> sortEntries(List<DavEntry> list, SortPref pref) {
  final out = List<DavEntry>.from(list);
  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int c;
    switch (pref.key) {
      case SortKey.byName:
        c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
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
