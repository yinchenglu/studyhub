import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/local/db.dart';
import 'permissions.dart';
import 'utils.dart';

/// 落盘目标目录：优先手机「下载」目录（要先拿到存储权限），
/// 拿不到权限就退回应用专属目录 —— 保证一定写得进去，不会静默失败。
///
/// 放在这里而不是各页面里，是为了让「写入」和「判断文件是否已下载」
/// 用的是同一个目录，标记不会对不上。
Future<Directory?> downloadTargetDir() async {
  try {
    if (Platform.isAndroid) {
      final ok = await ensureStoragePermission();
      return ok
          ? await CacheManager.instance.downloadDir
          : Directory(await CacheManager.appPrivateDownloadPath());
    }
    return await CacheManager.instance.downloadDir;
  } catch (_) {
    try {
      return Directory(await CacheManager.appPrivateDownloadPath());
    } catch (_) {
      return null;
    }
  }
}

/// 统一的下载工具。
/// 所有「下载到本地」都走这里：落到设置里的下载目录，并处理存储权限与进度提示。
class Downloader {
  Downloader._();

  /// 去掉文件名里不能用于文件的字符
  static String safeName(String name) {
    var n = name.trim();
    if (n.isEmpty) n = 'download_${DateTime.now().millisecondsSinceEpoch}';
    return n.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_');
  }

  /// 直接下载到下载目录，返回落盘的文件
  static Future<File> toDownloadDir(
    String url,
    String fileName, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await CacheManager.instance.downloadDir;
    final file = File(p.join(dir.path, safeName(fileName)));
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 30),
      followRedirects: true,
    ));
    await dio.download(
      url,
      file.path,
      options: Options(headers: headers),
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
      deleteOnError: true,
    );
    return file;
  }

  /// 带界面的下载：申请权限 → 显示进度 → 提示结果。返回保存的文件（失败为 null）
  static Future<File?> withUi(
    BuildContext context,
    String url,
    String fileName, {
    Map<String, String>? headers,
    String? title,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final label = title ?? fileName;

    // 1. 权限（Android 写公共目录需要）
    if (Platform.isAndroid) {
      final granted = await ensureStoragePermission();
      if (!granted) {
        if (!context.mounted) return null;
        final go = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('没有存储权限'),
            content: const Text('保存到「下载」这类公共目录，需要「所有文件访问」权限。\n\n'
                '可以到系统设置里手动打开；也可以到「设置 → 下载目录」改成应用专属目录（不需要权限）。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('去设置')),
            ],
          ),
        );
        if (go == true) await openPermissionSettings();
        return null;
      }
    }

    // 2. 进度
    final progress = ValueNotifier<({int received, int total})>((received: 0, total: 0));
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('下载 $label', maxLines: 1, overflow: TextOverflow.ellipsis),
          content: ValueListenableBuilder<({int received, int total})>(
            valueListenable: progress,
            builder: (_, v, __) {
              final ratio = v.total > 0 ? v.received / v.total : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: ratio),
                  const SizedBox(height: 10),
                  Text(
                    v.total > 0
                        ? '${formatBytes(v.received)} / ${formatBytes(v.total)}（${(ratio! * 100).toStringAsFixed(0)}%）'
                        : '已接收 ${formatBytes(v.received)}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ));

    try {
      final f = await toDownloadDir(url, fileName, headers: headers, onProgress: (a, b) {
        progress.value = (received: a, total: b);
      });
      _popDialog(context);
      messenger.showSnackBar(SnackBar(content: Text('已保存到 ${f.path}')));
      return f;
    } catch (e) {
      _popDialog(context);
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e')));
      return null;
    } finally {
      progress.dispose();
    }
  }

  static void _popDialog(BuildContext context) {
    try {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    } catch (_) {}
  }
}
