import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../providers/providers.dart';

/// 笔记编辑页：Markdown 编辑 + 工具栏 + 保存回服务器
class NoteEditPage extends ConsumerStatefulWidget {
  final String path;
  const NoteEditPage({super.key, required this.path});

  @override
  ConsumerState<NoteEditPage> createState() => _NoteEditPageState();
}

class _NoteEditPageState extends ConsumerState<NoteEditPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _loading = true;
  bool _saving = false;
  bool _preview = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _ctrl.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) {
      setState(() {
        _error = '未登录';
        _loading = false;
      });
      return;
    }
    try {
      final c = await repo.readNote(widget.path);
      if (!mounted) return;
      _ctrl.text = c;
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 在当前光标位置插入文本
  void _insert(String text, {int back = 0}) {
    final sel = _ctrl.selection;
    final start = sel.start < 0 ? _ctrl.text.length : sel.start;
    final end = sel.end < 0 ? _ctrl.text.length : sel.end;
    final newText = _ctrl.text.replaceRange(start, end, text);
    _ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length - back),
    );
    _focus.requestFocus();
  }

  void _wrapSelection(String left, String right) {
    final sel = _ctrl.selection;
    if (sel.start < 0 || sel.end <= sel.start) {
      _insert('$left$right', back: right.length);
      return;
    }
    final t = _ctrl.text;
    final selected = t.substring(sel.start, sel.end);
    _ctrl.value = TextEditingValue(
      text: t.replaceRange(sel.start, sel.end, '$left$selected$right'),
      selection: TextSelection.collapsed(offset: sel.end + left.length + right.length),
    );
  }

  /// 当前笔记相对 notes 的目录（'' 表示 notes 根目录）
  String _noteDirSub() {
    final dir = parentOf(widget.path); // notes 或 notes/子目录
    if (dir == AppDirs.notes) return '';
    if (dir.startsWith('${AppDirs.notes}/')) return dir.substring(AppDirs.notes.length + 1);
    return '';
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('从相册选'), onTap: () => Navigator.pop(context, ImageSource.gallery)),
            ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('拍照'), onTap: () => Navigator.pop(context, ImageSource.camera)),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x = await picker.pickImage(source: source, imageQuality: 92);
    if (x == null) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    // 挑图 / 拍照期间页面可能已经被销毁（返回键、切菜单）
    if (!mounted) return;

    setState(() => _saving = true);
    try {
      // 图片统一存到「当前笔记目录 / image」下，markdown 里引用 image/xxx.png
      final rel = await repo.uploadImage(_noteDirSub(), x.path, baseName(x.path));
      final alt = baseName(rel).split('.').first;
      _insert('\n![$alt]($rel)\n');
      _toast('图片已存到 image 目录，已插入引用 ![]($rel)');
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save({bool pop = false}) async {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    setState(() => _saving = true);
    try {
      await repo.saveNote(widget.path, _ctrl.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      _toast('已保存到服务器');
      if (pop && mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final r = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('还没保存'),
            content: const Text('要保存再退出吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(context, 'no'), child: const Text('不保存')),
              FilledButton(onPressed: () => Navigator.pop(context, 'yes'), child: const Text('保存并退出')),
            ],
          ),
        );
        if (r == 'no' && mounted) {
          Navigator.of(context).pop();
        } else if (r == 'yes') {
          await _save(pop: true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(titleFromFileName(widget.path), overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: '预览',
              onPressed: () => setState(() => _preview = !_preview),
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
            ),
            IconButton(
              tooltip: '保存',
              onPressed: _saving ? null : () => _save(),
              icon: _saving
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_dirty ? Icons.save : Icons.save_outlined, color: _dirty ? scheme.primary : null),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)))
                : Column(
                    children: [
                      Expanded(
                        child: _preview
                            ? _PreviewPane(text: _ctrl.text, notePath: widget.path)
                            : Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: TextField(
                                  controller: _ctrl,
                                  focusNode: _focus,
                                  maxLines: null,
                                  expands: true,
                                  textAlignVertical: TextAlignVertical.top,
                                  style: const TextStyle(fontSize: 15, height: 1.7, fontFamily: 'monospace'),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    filled: false,
                                    hintText: '在这里写 markdown…\n\n# 一级标题\n- 列表\n**加粗**\n![](图片名.png)',
                                  ),
                                ),
                              ),
                      ),
                      _toolbar(scheme),
                    ],
                  ),
      ),
    );
  }

  Widget _toolbar(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _tb(Icons.title, '标题', () => _insert('\n## 小标题\n')),
              _tb(Icons.format_bold, '加粗', () => _wrapSelection('**', '**')),
              _tb(Icons.format_italic, '斜体', () => _wrapSelection('*', '*')),
              _tb(Icons.format_list_bulleted, '列表', () => _insert('\n- 条目')),
              _tb(Icons.format_list_numbered, '编号', () => _insert('\n1. 条目')),
              _tb(Icons.check_box_outlined, '待办', () => _insert('\n- [ ] 待办')),
              _tb(Icons.format_quote, '引用', () => _insert('\n> 引用\n')),
              _tb(Icons.code, '代码', () => _insert('\n```\n代码\n```\n')),
              _tb(Icons.table_chart_outlined, '表格', () => _insert('\n| 列1 | 列2 |\n| --- | --- |\n| 内容 | 内容 |\n')),
              _tb(Icons.link, '链接', () => _insert('[标题](https://)')),
              _tb(Icons.image_outlined, '插图', _pickImage),
              _tb(Icons.horizontal_rule, '分割线', () => _insert('\n---\n')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tb(IconData icon, String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Icon(icon, size: 20),
            ),
          ),
        ),
      );
}

/// 简单的预览（复用阅读页的渲染规则）
class _PreviewPane extends ConsumerWidget {
  final String text;
  final String notePath;
  const _PreviewPane({required this.text, required this.notePath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return const SizedBox.shrink();
    return Container(
      alignment: Alignment.topLeft,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Text(
          text.isEmpty ? '（空）' : text,
          style: const TextStyle(fontSize: 14.5, height: 1.7),
        ),
      ),
    );
  }
}

/// 复制到剪贴板的小工具（工具页也用）
Future<void> copyText(String s) => Clipboard.setData(ClipboardData(text: s));
