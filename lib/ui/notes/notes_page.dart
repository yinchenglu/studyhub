import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../home/login_page.dart';
import 'note_edit_page.dart';
import 'note_read_page.dart';

/// 笔记：按服务器 notes 目录浏览，支持新建目录 / 新建笔记 / 上传图片 / 改名 / 删除
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  /// 当前所在子目录（相对 notes），空串表示根
  String _sub = '';
  bool _loading = false;
  String? _error;
  List<DavEntry> _entries = const [];
  bool _flatAll = false; // 平铺显示全部笔记

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
      if (_flatAll) {
        final notes = await repo.allNotes();
        final list = notes
            .map((n) => DavEntry(path: n.path, isDir: false, size: n.size, modified: n.modified))
            .toList();
        setState(() {
          _entries = list;
          _loading = false;
        });
      } else {
        final entries = await repo.listDir(_sub);
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('笔记'),
            if (logged)
              Text(
                _flatAll ? '全部笔记（平铺）' : '/${AppDirs.notes}${_sub.isEmpty ? '' : '/$_sub'}',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
          if (logged)
            PopupMenuButton<String>(
              icon: const Icon(Icons.add),
              onSelected: (v) async {
                if (v == 'dir') await _createDir();
                if (v == 'note') await _createNote();
                if (v == 'image') await _uploadImage();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'dir', child: ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('新建目录'), dense: true)),
                PopupMenuItem(value: 'note', child: ListTile(leading: Icon(Icons.note_add_outlined), title: Text('新建笔记'), dense: true)),
                PopupMenuItem(value: 'image', child: ListTile(leading: Icon(Icons.image_outlined), title: Text('上传图片'), dense: true)),
              ],
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: !logged
          ? _NeedLogin(onLogin: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage())).then((_) => _load()))
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(),
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
            child: Text('点右上角 + 新建笔记或目录', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, i) {
        final e = _entries[i];
        final isMd = FileTypes.isMarkdown(e.name);
        final isImg = FileTypes.isImage(e.name);
        return ListTile(
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (e.isDir
                      ? const Color(0xFF185FA5)
                      : isImg
                          ? const Color(0xFF1D9E75)
                          : const Color(0xFF7F77DD))
                  .withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              e.isDir
                  ? Icons.folder_rounded
                  : isImg
                      ? Icons.image_outlined
                      : Icons.article_outlined,
              size: 20,
              color: e.isDir
                  ? const Color(0xFF185FA5)
                  : isImg
                      ? const Color(0xFF1D9E75)
                      : const Color(0xFF7F77DD),
            ),
          ),
          title: Text(e.isDir ? e.name : titleFromFileName(e.name), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (e.isDir) '文件夹',
              if (!e.isDir) formatBytes(e.size),
              if (e.modified != null) formatTime(e.modified),
              if (_flatAll && e.path.contains('/')) parentOf(e.path).replaceFirst('${AppDirs.notes}/', ''),
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () async {
            if (e.isDir) {
              setState(() {
                _sub = e.path.substring(AppDirs.notes.length + 1);
                _flatAll = false;
              });
              await _load();
            } else if (isMd) {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path)));
              await _load();
            } else if (isImg) {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path, imageOnly: true)));
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这个文件类型暂不支持预览')));
            }
          },
          onLongPress: () => _showActions(e),
        );
      },
    );
  }

  /// 长按操作菜单
  void _showActions(DavEntry e) {
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
                  Expanded(child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
            if (!e.isDir && FileTypes.isMarkdown(e.name))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => NoteEditPage(path: e.path)))
                      .then((_) => _load());
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
                _delete(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createDir() async {
    final name = await _askText('新建目录', '目录名（会建在当前目录下）');
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      await repo.createDir(_sub, name.trim());
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已创建目录 $name')));
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
      final name = await repo.uploadImage(_sub, x.path, baseName(x.path));
      await _load();
      _toast('已上传 $name（在笔记里写 ![]($name) 即可引用）');
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rename(DavEntry e) async {
    final name = await _askText('重命名', '新名称', initial: e.name);
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    try {
      await repo.renameEntry(e.path, joinPath(parentOf(e.path), name.trim()));
      await _load();
    } catch (err) {
      _toast('重命名失败：$err');
    }
  }

  Future<void> _delete(DavEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除「${e.name}」？'),
        content: Text(e.isDir ? '整个目录和里面的文件都会被删除，无法恢复。' : '文件会被删除，无法恢复。'),
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

  Future<String?> _askText(String title, String hint, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint)),
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
          Icon(Icons.cloud_off_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
