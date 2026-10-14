import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';

/// 选文件夹的两个对话框（v1.7.0 新增，用户要求「本地文件夹、服务器文件夹
/// 都要有一个选择按钮」）。
///
/// 为什么不引 file_picker：pubspec 里已经写明，这台机器的依赖树
/// （share_plus 12.x × device_info_plus 12.x × syncfusion）经不起再引新包，
/// file_picker 本来就不在树里，而且加了就要重新趟一遍版本求解。
/// 自己写两个浏览器反而完全可控 —— 一个走 dart:io 列本机目录，
/// 一个走 WebDAV 列服务器目录，两边交互长得一样，用户只用学一次。
///
/// 两个函数都是「选中返回路径、取消返回 null」，调用方不用区分过程。

/// 本机目录浏览器，返回绝对路径。
Future<String?> pickLocalDir(BuildContext context, {String? start}) async {
  // 没权限的话 Directory.list 会直接抛，不如先问一句，提示也更好懂
  final ok = await ensureStoragePermission();
  if (!ok) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有存储权限，先去系统设置给「文件和媒体」权限')),
      );
    }
    return null;
  }

  var cur = (start ?? '').trim();
  if (cur.isEmpty) {
    cur = Platform.isAndroid ? '/storage/emulated/0' : Directory.current.path;
  }
  // 传进来的可能是刚手打一半的路径、或者早就被删掉的目录 ——
  // 逐级往上退到一个真实存在的目录，别让对话框一开就是报错。
  var dir = Directory(cur);
  while (!await dir.exists() && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  if (!await dir.exists()) dir = Directory(Directory.current.path);

  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (_) => _LocalDirDialog(initial: dir.path),
  );
}

/// 服务器目录浏览器，返回**相对资料根目录**的路径（不带首尾斜杠）。
Future<String?> pickRemoteDir(BuildContext context, WebDavClient client,
    {String? start}) async {
  final cur = (start ?? '')
      .trim()
      .replaceAll(RegExp(r'^/+'), '')
      .replaceAll(RegExp(r'/+$'), '');
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (_) => _RemoteDirDialog(client: client, initial: cur),
  );
}

// ------------------------------------------------------------------ 本机

class _LocalDirDialog extends StatefulWidget {
  final String initial;
  const _LocalDirDialog({required this.initial});

  @override
  State<_LocalDirDialog> createState() => _LocalDirDialogState();
}

class _LocalDirDialogState extends State<_LocalDirDialog> {
  late String _path = widget.initial;
  List<String> _dirs = const [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String p) async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final list = <String>[];
      await for (final e in Directory(p).list(followLinks: false)) {
        if (e is! Directory) continue;
        final n = e.path.split(Platform.pathSeparator).last;
        // 隐藏目录一律不列：既躲开 android/data 这类没权限的坑，
        // 也免得用户误选到某个 App 的内部目录
        if (n.startsWith('.')) continue;
        list.add(e.path);
      }
      list.sort();
      if (!mounted) return;
      setState(() {
        _path = p;
        _dirs = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _path = p;
        _dirs = const [];
        _loading = false;
        _err = '读不了这个目录：$e';
      });
    }
  }

  bool get _canUp => Directory(_path).parent.path != _path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('选择本地文件夹', style: TextStyle(fontSize: 15)),
      contentPadding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      content: SizedBox(
        width: 340,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                _path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, height: 1.35, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 4),
            if (_canUp)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.drive_file_move_outline, size: 18),
                title: const Text('上一级', style: TextStyle(fontSize: 13)),
                onTap: () => _load(Directory(_path).parent.path),
              ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(_err!,
                    style: const TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? const Center(
                          child: Text('这个目录下面没有子文件夹',
                              style: TextStyle(fontSize: 12.5)))
                      : ListView.builder(
                          itemCount: _dirs.length,
                          itemBuilder: (_, i) {
                            final d = _dirs[i];
                            final n = d.split(Platform.pathSeparator).last;
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: const Icon(Icons.folder_outlined, size: 18),
                              title: Text(n, style: const TextStyle(fontSize: 13)),
                              onTap: () => _load(d),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_path),
          child: const Text('选定此文件夹'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 服务器

class _RemoteDirDialog extends StatefulWidget {
  final WebDavClient client;
  final String initial;
  const _RemoteDirDialog({required this.client, required this.initial});

  @override
  State<_RemoteDirDialog> createState() => _RemoteDirDialogState();
}

class _RemoteDirDialogState extends State<_RemoteDirDialog> {
  late String _path = widget.initial;
  List<DavEntry> _dirs = const [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String p) async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final all = await widget.client.list(p, depth: 1);
      final dirs = all.where((e) => e.isDir).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _path = p;
        _dirs = dirs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _path = p;
        _dirs = const [];
        _loading = false;
        _err = '读不了这个服务器目录：$e';
      });
    }
  }

  String get _parent {
    final t = _path.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i <= 0 ? '' : t.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('选择服务器文件夹', style: TextStyle(fontSize: 15)),
      contentPadding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      content: SizedBox(
        width: 340,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                _path.isEmpty ? '（资料库根目录）' : _path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, height: 1.35, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 4),
            if (_path.isNotEmpty)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.drive_file_move_outline, size: 18),
                title: const Text('上一级', style: TextStyle(fontSize: 13)),
                onTap: () => _load(_parent),
              ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(_err!,
                    style: const TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? const Center(
                          child: Text('这个目录下面没有子文件夹',
                              style: TextStyle(fontSize: 12.5)))
                      : ListView.builder(
                          itemCount: _dirs.length,
                          itemBuilder: (_, i) {
                            final d = _dirs[i];
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: const Icon(Icons.folder_outlined, size: 18),
                              title: Text(d.name, style: const TextStyle(fontSize: 13)),
                              onTap: () => _load(d.path),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_path),
          child: const Text('选定此文件夹'),
        ),
      ],
    );
  }
}
