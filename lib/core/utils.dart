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

/// 抠出名字开头的序号。
///
/// 服务器上手工整理的小工具 / 分类常常带序号前缀，写法五花八门：
///   `01_单位换算`、`2.日期计算`、`3 时间戳`、`0101 血压计`
/// 这里只认「开头那串数字」，分隔符是什么不管。
/// 没有数字前缀就返回 null（调用方据此把它排到带序号的那批后面）。
///
/// v1.7.0：用户要求「服务器小工具目录自动识别名称前面的数字来排序」。
int? leadingNumber(String raw) {
  final m = RegExp(r'^\s*(\d{1,4})').firstMatch(raw);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 去掉名字开头的「序号 + 分隔符」，拿来显示。
///
/// `01_单位换算` → `单位换算`、`2. 日期计算` → `日期计算`、`3 时间戳` → `时间戳`。
/// 注意：**数字后面必须紧跟分隔符或空白才算序号**，所以
/// `3D 打印` 不会被误伤成 `D 打印`，`2024年度总结` 也不会被剥掉年份。
/// 如果剥完什么都不剩（名字本身就叫「01」），那就原样返回，别给个空标题。
///
/// v1.7.0：用户要求「显示名称的时候不显示前面的数字和空格」。
String stripLeadingNumber(String raw) {
  final s = raw.replaceFirst(RegExp(r'^\s*\d{1,4}[\s_.\-、,)]+'), '');
  final cut = s.trim();
  if (cut.isEmpty) return raw.trim();
  return cut;
}

/// 给带序号的名字排序：序号小的在前，没序号的垫底（再按名字比）。
///
/// 两个都带序号就比数值（`2` 排在 `10` 前面，这是字符串比较做不到的）；
/// 只有一边带序号，带序号的那边优先 —— 用户既然编了号，就是想让它们成组。
int compareByLeadingNumber(String a, String b) {
  final na = leadingNumber(a);
  final nb = leadingNumber(b);
  if (na != null && nb != null) {
    if (na != nb) return na.compareTo(nb);
  } else if (na != null) {
    return -1;
  } else if (nb != null) {
    return 1;
  }
  return a.toLowerCase().compareTo(b.toLowerCase());
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
