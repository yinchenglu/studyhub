import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/pdf_view_page.dart';
import '../home/login_page.dart';
import 'note_edit_page.dart';
import 'note_export.dart';
import 'note_read_page.dart';

/// 笔记：按服务器 notes 目录浏览，支持新建目录 / 新建笔记 / 上传图片 / 改名 / 删除
///
/// v1.2.0 起：
///   * 长按可以进入「多选模式」，一次选一篇或多篇（也可以选整个目录），
///     然后导出成 PDF / HTML / Markdown（可以每篇一个文件，也可以合并成一份）
///   * 目录里的 .pdf 文件也能直接预览
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => NotesPageState();
}

class NotesPageState extends ConsumerState<NotesPage> {
  /// 当前所在子目录（相对 notes），空串表示根
  String _sub = '';
  bool _loading = false;
  String? _error;
  List<DavEntry> _entries = const [];
  bool _flatAll = false; // 平铺显示全部笔记

  /// 多选模式
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 从别的菜单切进来 / 再次点「笔记」时调用：回到根目录并刷新
  Future<void> reload() async {
    if (_sub.isNotEmpty || _flatAll || _selecting) {
      setState(() {
        _sub = '';
        _flatAll = false;
        _selecting = false;
        _selected.clear();
      });
    }
    await _load();
  }

  /// 手机返回键：优先退出多选 / 返回上级目录；已经在本页根目录时返回 false，交给外层处理
  bool handleBack() {
    if (_selecting) {
      _exitSelect();
      return true;
    }
    if (_flatAll) {
      setState(() => _flatAll = false);
      _load();
      return true;
    }
    if (_sub.isNotEmpty) {
      _goUp();
      return true;
    }
    return false;
  }

  void _goUp() {
    setState(() => _sub = parentOf(_sub));
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) {
      setState(() {
        _error = null;
        _entries = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      late final List<DavEntry> list;
      if (_flatAll) {
        final notes = await repo.allNotes();
        list = notes
            .map((n) => DavEntry(path: n.path, isDir: false, size: n.size, modified: n.modified))
            .toList();
      } else {
        list = await repo.listDir(_sub);
      }
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
        // 选中的条目可能已经被删了，顺手清掉
        final alive = list.map((e) => e.path).toSet();
        _selected.removeWhere((p) => !alive.contains(p));
        if (_selected.isEmpty && _selecting) _selecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------- 多选

  void _enterSelect(DavEntry e) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(e.path);
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(DavEntry e) {
    setState(() {
      if (!_selected.remove(e.path)) _selected.add(e.path);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _selectAll() {
    setState(() {
      final all = _entries.map((e) => e.path).toSet();
      if (_selected.length == all.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  List<DavEntry> get _pickedEntries =>
      _entries.where((e) => _selected.contains(e.path)).toList();

  /// 选中的可导出笔记数（目录算 1 项，导出时递归展开）
  int get _pickedExportable =>
      _pickedEntries.where((e) => e.isDir || FileTypes.isReadableText(e.name)).length;

  // ------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功后自动拉一次内容（App 启动时往往还没登录，那时列表是空的）
    ref.listen(accountProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (next && prev != next) _load();
    });

    return Scaffold(
      appBar: _selecting ? _selectAppBar(scheme) : _normalAppBar(logged, scheme),
      body: !logged
          ? _NeedLogin(
              onLogin: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LoginPage()))
                  .then((_) => _load()))
          : RefreshIndicator(onRefresh: _load, child: _buildBody()),
      bottomNavigationBar: _selecting ? _selectBar(scheme) : null,
    );
  }

  PreferredSizeWidget _normalAppBar(bool logged, ColorScheme scheme) => AppBar(
        automaticallyImplyLeading: false,
        leading: _sub.isNotEmpty
            ? IconButton(
                tooltip: '返回上级目录',
                onPressed: _goUp,
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('笔记'),
            if (logged)
              Text(
                _flatAll ? '全部笔记（平铺）' : '/${AppDirs.notes}${_sub.isEmpty ? '' : '/$_sub'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _flatAll ? '按目录浏览' : '平铺全部',
            onPressed: () {
              setState(() => _flatAll = !_flatAll);
              _load();
            },
            icon: Icon(_flatAll ? Icons.folder_outlined : Icons.view_list_outlined),
          ),
          if (logged && _entries.isNotEmpty)
            IconButton(
              tooltip: '批量选择',
              onPressed: () => setState(() => _selecting = true),
              icon: const Icon(Icons.checklist_rtl),
            ),
          if (logged)
            PopupMenuButton<String>(
              icon: const Icon(Icons.add),
              onSelected: (v) async {
                if (v == 'dir') await _createDir();
                if (v == 'note') await _createNote();
                if (v == 'image') await _uploadImage();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'dir',
                    child: ListTile(
                        leading: Icon(Icons.create_new_folder_outlined), title: Text('新建目录'), dense: true)),
                PopupMenuItem(
                    value: 'note',
                    child: ListTile(
                        leading: Icon(Icons.note_add_outlined), title: Text('新建笔记'), dense: true)),
                PopupMenuItem(
                    value: 'image',
                    child: ListTile(
                        leading: Icon(Icons.image_outlined), title: Text('上传图片'), dense: true)),
              ],
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      );

  PreferredSizeWidget _selectAppBar(ColorScheme scheme) => AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(tooltip: '退出多选', onPressed: _exitSelect, icon: const Icon(Icons.close)),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: _selectAll,
            child: Text(
              _selected.length == _entries.length && _entries.isNotEmpty ? '取消全选' : '全选',
            ),
          ),
        ],
      );

  Widget _selectBar(ColorScheme scheme) {
    final enabled = _selected.isNotEmpty;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
        ),
        child: Row(
          children: [
            Expanded(
              child: _barButton(
                icon: Icons.ios_share,
                label: '导出',
                sub: _pickedExportable > 0 ? '$_pickedExportable 项' : null,
                onTap: enabled ? _export : null,
                highlight: true,
              ),
            ),
            Expanded(
              child: _barButton(
                icon: Icons.drive_file_rename_outline,
                label: '重命名',
                onTap: _selected.length == 1
                    ? () => _rename(_pickedEntries.first)
                    : null,
              ),
            ),
            Expanded(
              child: _barButton(
                icon: Icons.delete_outline,
                label: '删除',
                onTap: enabled ? _deleteMany : null,
                danger: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barButton({
    required IconData icon,
    required String label,
    String? sub,
    VoidCallback? onTap,
    bool danger = false,
    bool highlight = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final off = onTap == null;
    final color = off
        ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
        : danger
            ? scheme.error
            : highlight
                ? scheme.primary
                : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(
              sub == null ? label : '$label $sub',
              style: TextStyle(fontSize: 11.5, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.6)),
          ),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    if (_entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 90),
          Icon(Icons.folder_open_outlined, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _flatAll ? '还没有任何笔记' : '这个目录是空的',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text('点右上角 + 新建笔记或目录',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: EdgeInsets.only(bottom: _selecting ? 16 : 24),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, i) {
        final e = _entries[i];
        final isMd = FileTypes.isMarkdown(e.name);
        final isPdf = FileTypes.isPdf(e.name);
        final isImg = FileTypes.isImage(e.name);
        final isTxt = !e.isDir && FileTypes.isReadableText(e.name);
        final checked = _selected.contains(e.path);

        final iconColor = e.isDir
            ? const Color(0xFF185FA5)
            : isImg
                ? const Color(0xFF1D9E75)
                : isPdf
                    ? const Color(0xFFD4537E)
                    : const Color(0xFF7F77DD);

        return ListTile(
          leading: SizedBox(
            width: 38,
            height: 38,
            child: _selecting
                ? Checkbox(
                    value: checked,
                    onChanged: (_) => _toggle(e),
                    visualDensity: VisualDensity.compact,
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      e.isDir
                          ? Icons.folder_rounded
                          : isImg
                              ? Icons.image_outlined
                              : isPdf
                                  ? Icons.picture_as_pdf_outlined
                                  : Icons.article_outlined,
                      size: 20,
                      color: iconColor,
                    ),
                  ),
          ),
          title: Text(
            e.isDir ? e.name : (isMd ? titleFromFileName(e.name) : e.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (e.isDir) '文件夹',
              if (!e.isDir) formatBytes(e.size),
              if (e.modified != null) formatTime(e.modified),
              if (isPdf) '可预览',
              if (_flatAll && e.path.contains('/'))
                parentOf(e.path).replaceFirst('${AppDirs.notes}/', ''),
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: _selecting
              ? null
              : (isTxt || isPdf || isImg || e.isDir
                  ? const Icon(Icons.chevron_right, size: 18)
                  : null),
          onTap: () async {
            if (_selecting) {
              _toggle(e);
              return;
            }
            if (e.isDir) {
              setState(() {
                _sub = e.path.substring(AppDirs.notes.length + 1);
                _flatAll = false;
              });
              await _load();
            } else if (isMd) {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path)));
              await _load();
            } else if (isPdf) {
              await _openPdf(e);
            } else if (isImg) {
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path, imageOnly: true)));
            } else if (isTxt) {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path, plain: true)));
            } else {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('这个文件类型暂不支持预览')));
            }
          },
          onLongPress: () {
            if (_selecting) {
              _toggle(e);
            } else if (e.isDir) {
              // 目录：先弹菜单，里面有「加入多选 / 整个目录导出」
              _showDirActions(e);
            } else {
              // 文件：长按直接进入多选（就是这样选一篇或多篇笔记的）
              _enterSelect(e);
            }
          },
        );
      },
    );
  }

  /// 预览目录里的 PDF
  Future<void> _openPdf(DavEntry e) async {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewPage.network(
        title: e.name,
        url: repo.resolveUrl(e.path, baseName(e.path)),
        headers: repo.authHeaders,
      ),
    ));
  }

  // ------------------------------------------------------------- 操作

  /// 打开导出面板
  Future<void> _export() async {
    final picked = _pickedEntries;
    if (picked.isEmpty) return;
    if (_pickedExportable == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选中的都是图片之类的文件，暂时只能导出笔记文本')),
      );
      return;
    }
    await showNoteExportSheet(context, picked);
    if (mounted) _exitSelect();
  }

  Future<void> _rename(DavEntry e) async {
    final name = await _askText('重命名', '新名称', initial: e.name);
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      await repo.renameEntry(e.path, joinPath(parentOf(e.path), name.trim()));
      if (mounted) _exitSelect();
      await _load();
    } catch (err) {
      _toast('重命名失败：$err');
    }
  }

  Future<void> _deleteMany() async {
    final picked = _pickedEntries;
    if (picked.isEmpty) return;
    final dirs = picked.where((e) => e.isDir).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除选中的 ${picked.length} 项？'),
        content: Text(
          '${picked.length - dirs} 个文件'
          '${dirs > 0 ? '、$dirs 个目录（目录里所有内容一起删）' : ''}'
          '会被永久删除，无法恢复。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    var failed = 0;
    for (final e in picked) {
      try {
        await repo.deleteEntry(e.path);
      } catch (_) {
        failed++;
      }
    }
    if (mounted) _exitSelect();
    await _load();
    if (failed > 0) _toast('有 $failed 项删除失败');
  }

  /// 目录的长按菜单
  void _showDirActions(DavEntry e) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                      child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rtl),
              title: const Text('加入多选'),
              subtitle: const Text('可以连同别的目录 / 笔记一起导出'),
              onTap: () {
                Navigator.pop(context);
                _enterSelect(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出这个目录里的笔记'),
              subtitle: const Text('里面的笔记会一起导出成一份'),
              onTap: () {
                Navigator.pop(context);
                showNoteExportSheet(context, [e]);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                _rename(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteOne(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteOne(DavEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除「${e.name}」？'),
        content: const Text('目录里所有文件都会被删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      await repo.deleteEntry(e.path);
      await _load();
    } catch (err) {
      _toast('删除失败：$err');
    }
  }

  Future<void> _createDir() async {
    final name = await _askText('新建目录', '目录名（会建在当前目录下）');
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      await repo.createDir(_sub, name.trim());
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已创建目录 $name')));
      }
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  Future<void> _createNote() async {
    final name = await _askText('新建笔记', '笔记标题（自动加 .md）');
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      final path = await repo.createNote(_sub, name.trim());
      await _load();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteEditPage(path: path)));
      await _load();
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _uploadImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (x == null) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    setState(() => _loading = true);
    try {
      final rel = await repo.uploadImage(_sub, x.path, baseName(x.path));
      await _load();
      _toast('已存到 $rel，笔记里写 ![]($rel) 就能引用');
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _askText(String title, String hint, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c, autofocus: true, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('确定')),
        ],
      ),
    );
    return r;
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
}

class _NeedLogin extends StatelessWidget {
  final VoidCallback onLogin;
  const _NeedLogin({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('还没有连接服务器'),
          const SizedBox(height: 4),
          const Text('笔记都存在你的 WebDAV 上', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onLogin, child: const Text('去连接')),
        ],
      ),
    );
  }
}
