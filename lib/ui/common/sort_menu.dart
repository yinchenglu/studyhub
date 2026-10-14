import 'package:flutter/material.dart';

import '../../core/sort_utils.dart';

/// 排序按钮（笔记页 / 媒体库共用）。
///
/// 交互：点开是一张菜单，三种排序键各一行，当前选中的那行打勾；
/// 最下面一行是「升序 / 降序」切换。
/// 之所以不用「点一下换一个键」的循环按钮 —— 三种键循环三下才能回到原地，
/// 而且看不出当前是按什么排的。菜单能一眼看清状态。
class SortButton extends StatelessWidget {
  final SortPref value;
  final ValueChanged<SortPref> onChanged;

  const SortButton({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '排序：${value.label}',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == 'asc') {
          onChanged(SortPref(key: value.key, asc: true));
        } else if (v == 'desc') {
          onChanged(SortPref(key: value.key, asc: false));
        } else {
          onChanged(value.withKey(SortKey.values.firstWhere((k) => k.name == v)));
        }
      },
      itemBuilder: (_) => [
        // v1.7.0：用户要求「排序里面的内容压缩一下行距」。
        // PopupMenuItem 默认高 48，这里全部压到 38；图标 18→17、正文 14→13.5。
        // 分组小标题再矮一点（32）。整张菜单从 ~290 高降到 ~215。
        const PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text('按什么排', style: TextStyle(fontSize: 11.5)),
        ),
        for (final k in SortKey.values)
          PopupMenuItem<String>(
            value: k.name,
            height: 38,
            child: Row(
              children: [
                Icon(
                  value.key == k ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 17,
                  color: value.key == k ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(k.label, style: const TextStyle(fontSize: 13.5)),
              ],
            ),
          ),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text('顺序', style: TextStyle(fontSize: 11.5)),
        ),
        PopupMenuItem<String>(
          value: 'asc',
          height: 38,
          child: Row(
            children: [
              Icon(
                value.asc ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 17,
                color: value.asc ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              const Text('升序 ↑', style: TextStyle(fontSize: 13.5)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'desc',
          height: 38,
          child: Row(
            children: [
              Icon(
                !value.asc ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 17,
                color: !value.asc ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              const Text('降序 ↓', style: TextStyle(fontSize: 13.5)),
            ],
          ),
        ),
      ],
    );
  }
}
