import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 一个「一层层点进去」的文件夹选择弹窗。
///
/// 用法：
/// ```dart
/// final picked = await showDialog<String>(
///   context: context,
///   builder: (_) => FolderPicker(initial: '/storage/emulated/0'),
/// );
/// ```
/// 点「用这个文件夹」时 pop 出当前绝对路径；「取消」pop 出 null。
///
/// ── 为什么不用系统 SAF 的目录选择器（`ACTION_OPEN_DOCUMENT_TREE`）──────
/// 它返回的是 `content://` 的 tree URI，而整个 App 里所有落盘的东西
/// （下载、笔记附件、录音录像）都是拿 dart:io 的 `File(path)` 在写，
/// 换成 SAF 等于把每条写入路径都重写一遍。这里的做法选出来就是普通路径，
/// 跟现有代码无缝接上。
///
/// 读不到的目录（权限不足 / 路径不存在）不崩，只是在列表位置显示原因 ——
/// 安卓 11 以后「下载」这类公共目录要靠「所有文件访问」权限，没授权时
/// 这里一定会报错，得让用户看得懂而不是白屏。
///
/// v1.6.0 从 `settings_page.dart` 里挪出来变成公共组件：
/// 下载目录和「录音录像保存位置」都要用它，两处各写一份必然会走样。
class FolderPicker extends StatefulWidget {
  /// 打开时先停在哪个目录。
  final String initial;

  /// 弹窗标题。
  final String title;

  /// 确认按钮的文字。
  final String confirmText;

  const FolderPicker({
    super.key,
    required this.initial,
    this.title = '选一个文件夹',
    this.confirmText = '用这个文件夹',
  });

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  late String _path;
  List<String> _subs = const [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _path = widget.initial;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = Directory(_path);
      if (!await d.exists()) {
        if (!mounted) return;
        setState(() {
          _subs = const [];
          _loading = false;
          _err = '这个目录不存在：\n$_path';
        });
        return;
      }
      final names = <String>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory) names.add(p.basename(e.path));
      }
      names.sort();
      if (!mounted) return;
      setState(() {
        _subs = names;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '读不了这个目录（多半是没有「所有文件访问」权限）：\n$e';
      });
    }
  }

  void _enter(String name) {
    _path = p.join(_path, name);
    _load();
  }

  void _up() {
    final parent = p.dirname(_path);
    if (parent == _path) return; // 已经到根了
    _path = parent;
    _load();
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文件夹名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await Directory(p.join(_path, name)).create(recursive: true);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('建不了：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        // 竖屏时别顶到键盘/状态栏：取屏幕高的一半
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _up,
                  icon: const Icon(Icons.arrow_upward, size: 20),
                  tooltip: '上一层',
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(_path, maxLines: 2, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _err != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(_err!,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12.5, color: scheme.error)),
                          ),
                        )
                      : _subs.isEmpty
                          ? Center(
                              child: Text('这里没有子文件夹',
                                  style: TextStyle(
                                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
                            )
                          : ListView.builder(
                              itemCount: _subs.length,
                              itemBuilder: (_, i) => ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder_rounded,
                                    size: 20, color: Color(0xFF7F77DD)),
                                title: Text(_subs[i],
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () => _enter(_subs[i]),
                              ),
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _newFolder, child: const Text('新建文件夹')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _path),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
