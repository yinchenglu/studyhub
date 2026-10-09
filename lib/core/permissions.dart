import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// 存储权限：下载文件到自定义目录时需要。
///
/// Android 11+ 想写「下载」等公共目录需要「所有文件访问权限」，
/// Android 10 及以下用普通的读写存储权限。两条路都试一遍。
Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;

  // Android 11+：所有文件访问权限
  try {
    if (await Permission.manageExternalStorage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
  } catch (_) {
    // 低版本系统没有这个权限项，忽略
  }

  // Android 10 及以下
  try {
    if (await Permission.storage.isGranted) return true;
    final r = await Permission.storage.request();
    if (r.isGranted) return true;
  } catch (_) {}

  return false;
}

/// 权限被永久拒绝时，引导用户去系统设置里手动打开
Future<void> openPermissionSettings() => openAppSettings();
