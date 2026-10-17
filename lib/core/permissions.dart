import 'dart:io';

import 'package:flutter/services.dart';
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

/// v2.0.0+35：精准打开本 App 的「所有文件访问」系统设置页。
///
/// 为什么不用 permission_handler 自己跳：`Permission.manageExternalStorage.request()`
/// 在很多 ROM 上只返回 denied、**不跳转任何页面**，用户根本没机会授权 ——
/// 表现就是「设置 → 下载目录」怎么改都提示写不进去。
/// 这里走原生 Intent（`ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` + package uri），
/// 直达本 App 的开关。返回是否成功跳转。
Future<bool> openAllFilesAccessPage() async {
  if (!Platform.isAndroid) return false;
  try {
    const ch = MethodChannel('studyhub/files');
    return await ch.invokeMethod<bool>('openAllFilesAccess') ?? false;
  } catch (_) {
    return false;
  }
}

/// v2.0.0+35：确保能写公共目录 —— 申请不到就跳系统页，用户回来后复查。
///
/// 流程：先常规申请（低版本会弹系统对话框）→ 申请不下来（Android 11+ 的常态，
/// request() 只返回 denied 不跳页）→ 原生 Intent 直达本 App 的
/// 「所有文件访问」开关 → 调用方应弹一个「开好后点我已开启」的确认框，
/// 点了之后再次调用本函数（或 ensureStoragePermission）复查。
/// 返回 true = 有权限了。
Future<bool> ensureAllFilesAccessWithUi() async {
  if (!Platform.isAndroid) return true;
  if (await ensureStoragePermission()) return true;

  // 申请不下来 → 跳系统页。跳完用户还没点授权，这里直接复查意义不大，
  // 交给调用方在用户确认后复查；这里先返回 false。
  final jumped = await openAllFilesAccessPage();
  if (!jumped) await openAppSettings();
  return false;
}
