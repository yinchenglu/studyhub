import 'package:intl/intl.dart';

import 'constants.dart';

/// 把字节数变成人能读的大小
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

/// 毫秒 → 01:23 / 1:02:03
String formatDuration(int ms) {
  if (ms <= 0) return '--:--';
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final two = (int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatTime(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  if (now.difference(t).inDays == 0) return '今天 ${DateFormat('HH:mm').format(t)}';
  if (now.difference(t).inDays == 1) return '昨天 ${DateFormat('HH:mm').format(t)}';
  if (t.year == now.year) return DateFormat('MM-dd HH:mm').format(t);
  return DateFormat('yyyy-MM-dd').format(t);
}

/// 取路径最后一段作为文件名
String baseName(String path) {
  final p = path.replaceAll('\\', '/');
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

/// 取父目录（相对路径），根目录返回空串
String parentOf(String path) {
  final p = path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
  final i = p.lastIndexOf('/');
  return i < 0 ? '' : p.substring(0, i);
}

String joinPath(String a, String b) {
  final x = a.replaceAll(RegExp(r'^/+|/+$'), '');
  final y = b.replaceAll(RegExp(r'^/+|/+$'), '');
  if (x.isEmpty) return y;
  if (y.isEmpty) return x;
  return '$x/$y';
}

/// 去掉 markdown 扩展名，作为笔记标题
String titleFromFileName(String name) {
  final n = baseName(name);
  return n.toLowerCase().endsWith('.md') ? n.substring(0, n.length - 3) : n;
}

/// 图片/视频的图标
bool isMediaPlayable(String name) => FileTypes.isPlayable(name);

/// 简单的稳定 hash，用于本地缓存文件名
int stableHash(String s) {
  int h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}
