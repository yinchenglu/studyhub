import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/db.dart';
import '../../providers/providers.dart';

/// 长按菜单里的「收藏 / 取消收藏」（v1.7.0 用户第 6 条）。
///
/// 笔记和视频、文件和文件夹，四处入口共用这一份 ——
/// 各写各的最容易出的问题就是「笔记里加了、视频里忘了加」，
/// 或者两边的 `kind` 取值不一致，首页分组时漏掉一类。
///
/// [isNote]：笔记还是视频（决定收藏后归到首页哪一组）
/// [isFolder]：收藏的是一整个文件夹还是单个文件
Future<void> toggleFavorite(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String title,
  required bool isNote,
  bool isFolder = false,
}) async {
  final db = AppDb.instance;
  bool already;
  try {
    already = await db.isFavorite(path);
    if (already) {
      await db.removeFavorite(path);
    } else {
      // kind 的四种取值见 FavoriteItem 的注释 —— 把「是不是目录」
      // 编进这个字段，就不用给 favorite 表加列了
      final kind = isFolder ? (isNote ? 'noteDir' : 'mediaDir') : (isNote ? 'note' : 'media');
      await db.addFavorite(path, kind, title);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('收藏失败：$e')));
    }
    return;
  }
  ref.invalidate(favoriteProvider);
  ref.invalidate(isFavoriteProvider(path));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(already ? '已取消收藏' : '已收藏 · 首页「我的收藏」里能快速打开'),
    duration: const Duration(seconds: 2),
  ));
}

/// 长按菜单里那一行的图标（已收藏 = 实心星，未收藏 = 空心星）
IconData favoriteIcon(bool on) => on ? Icons.star : Icons.star_border;
