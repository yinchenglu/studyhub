import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/pdf_view_page.dart';
import '../media/image_viewer_page.dart';
import '../media/player_page.dart';
import 'server_files_page.dart';

/// 服务器下载站 —— 一个微型下载站。
///
/// 服务器 ${AppDirs.download} 目录就是「货架」：把想在手机上下载的文件放进去，
/// 这里就能浏览、预览、下载到手机本地、分享出去。
class DownloadSitePage extends ConsumerStatefulWidget {
  const DownloadSitePage({super.key});

  @override
  ConsumerState<DownloadSitePage> createState() => _DownloadSitePageState();
}

class _DownloadSitePageState extends ConsumerState<DownloadSitePage> {
  String _sub = '';
  List<DavEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _downloaded = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String get _dirPath => joinPath(AppDirs.download, _sub);

  Future<void> _load() async {
    final client = ref.read(davClientProvider);
    if (client == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await client.list(_dirPath, depth: 1);
      final dirs = entries.where((e) => e.isDir).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final files = entries.where((e) => !e.isDir).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _entries = [...dirs, ...files];
        _loading = false;
      });
      await _checkDownloaded(files);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 看看哪些文件已经在手机里了
  Future<void> _checkDownloaded(List<DavEntry> files) async {
    final got = <String>{};
    try {
      // 必须和真正落盘时用同一个目录，否则「已下载」标记会对不上
      final dir = await downloadTargetDir();
      if (dir != null) {
        for (final f in files) {
          if (File(p.join(dir.path, Downloader.safeName(baseName(f.path)))).existsSync()) {
            got.add(f.path);
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _downloaded
        ..clear()
        ..addAll(got);
    });
  }

  bool handleBack() {
    if (_sub.isNotEmpty) {
      setState(() => _sub = parentOf(_sub));
      _load();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logged = ref.watch(accountProvider).isLoggedIn;
    final files = _entries.where((e) => !e.isDir).toList();

    // 返回键：这个页面是从工具页 push 出来的独立路由，RootShell 的
    // PopScope 拦不到它 —— 系统返回键会直接 Navigator.pop()，一步退回
    // 工具主菜单，中间的目录层级全被跳过（用户报的就是这个）。
    //
    // 这里自己再套一层 PopScope，用**动态 canPop**：
    //   * 在子目录里 canPop = false → 系统返回事件被拦下，只回上一级；
    //   * 到了根目录 canPop = true → 不再拦截，交给 Navigator 正常 pop，
    //     一步退回工具主菜单。
    //
    // 注意别在这里写 Navigator.maybePop() 来「放行」：canPop 为 false 时
    // maybePop 会走 RoutePopDisposition.doNotPop 分支，把回调再叫一遍，
    // 直接死循环。用动态 canPop 才是官方推荐写法。
    return PopScope(
      canPop: _sub.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: _sub.isNotEmpty
              ? IconButton(
                  tooltip: '返回上级目录',
                  onPressed: () {
                    setState(() => _sub = parentOf(_sub));
                    _load();
                  },
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('服务器下载站'),
              Text(
                '/${AppDirs.download}${_sub.isEmpty ? '' : '/$_sub'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            // v1.9.0：服务器下载站加「新建文件夹 / 上传文件」入口
            if (logged)
              PopupMenuButton<String>(
                tooltip: '新建',
                onSelected: (v) async {
                  if (v == 'mkdir') await _createFolder();
                  if (v == 'upload') await _uploadFile();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'upload',
                    child: ListTile(
                        leading: Icon(Icons.upload_file_outlined),
                        title: Text('上传文件'),
                        dense: true),
                  ),
                  PopupMenuItem(
                    value: 'mkdir',
                    child: ListTile(
                        leading: Icon(Icons.create_new_folder_outlined),
                        title: Text('新建文件夹'),
                        dense: true),
                  ),
                ],
                icon: const Icon(Icons.add),
              ),
            if (files.isNotEmpty)
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'all') await _downloadAll(files);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'all',
                    child: ListTile(
                        leading: Icon(Icons.download_for_offline_outlined),
                        title: Text('全部下载到本地'),
                        dense: true),
                  ),
                ],
              ),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: !logged
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_outlined, size: 46, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      const Text('需要先连接你的 WebDAV 服务器'),
                      const SizedBox(height: 8),
                      Text(
                        '下载站的货架在服务器的 /${AppDirs.download} 目录。',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              )
            : RefreshIndicator(onRefresh: _load, child: _body(scheme)),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading && _entries.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 70),
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
          const SizedBox(height: 70),
          Icon(Icons.inbox_outlined, size: 46, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Center(child: Text('货架还是空的')),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 34),
            child: Text(
              '把想在手机上下载的文件放进服务器的「${AppDirs.download}」目录，'
              '这里就会列出来。\n\n'
              '比如课件 PDF、软件安装包、要分享给朋友的图片 —— 放进去，'
              '手机上点一下就下载到本地了。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.75, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    }

    final videoIndexes = <String, int>{};
    final videos = <MediaItem>[];
    for (final e in _entries) {
      if (e.isDir) continue;
      if (FileTypes.isPlayable(e.name)) {
        videoIndexes[e.path] = videos.length;
        videos.add(MediaItem(
          path: e.path,
          isVideo: FileTypes.isVideo(e.name),
          size: e.size,
          modified: e.modified,
        ));
      }
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 28),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 62),
      itemBuilder: (_, i) {
        final e = _entries[i];
        final ext = FileTypes.ext(e.name);
        final downloaded = _downloaded.contains(e.path);
        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _colorFor(ext, e.isDir).withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_iconFor(ext, e.isDir), color: _colorFor(ext, e.isDir), size: 21),
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            e.isDir
                ? '文件夹'
                : '${formatBytes(e.size)}${e.modified == null ? '' : ' · ${formatTime(e.modified)}'}'
                    '${downloaded ? ' · 已下载' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: e.isDir
              ? Icon(Icons.chevron_right, color: scheme.onSurfaceVariant)
              : IconButton(
                  tooltip: '下载',
                  icon: Icon(
                    downloaded ? Icons.download_done : Icons.download_outlined,
                    color: downloaded ? const Color(0xFF1D9E75) : null,
                  ),
                  onPressed: () => _downloadOne(e),
                ),
          onTap: () async {
            if (e.isDir) {
              setState(() => _sub = e.path.substring(AppDirs.download.length + 1));
              await _load();
              return;
            }
            if (FileTypes.isPdf(e.name)) {
              final client = ref.read(davClientProvider);
              if (client == null) return;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PdfViewPage.network(
                  title: e.name,
                  url: client.urlFor(e.path),
                  headers: client.headers,
                ),
              ));
              return;
            }
            if (FileTypes.isImage(e.name)) {
              final client = ref.read(davClientProvider);
              if (client == null) return;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ImageViewerPage(
                  images: [client.urlFor(e.path)],
                  headers: client.headers,
                  titles: [e.name],
                ),
              ));
              return;
            }
            if (FileTypes.isPlayable(e.name)) {
              final idx = videoIndexes[e.path] ?? 0;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlayerPage(playlist: videos, initialIndex: idx),
              ));
              return;
            }
            if (FileTypes.isReadableText(e.name)) {
              await Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => TextFilePage(path: e.path)));
              return;
            }
            await _downloadOne(e);
          },
          onLongPress: () => _sheet(e),
        );
      },
    );
  }

  Color _colorFor(String ext, bool isDir) {
    if (isDir) return const Color(0xFF185FA5);
    if (FileTypes.isPdf('x.$ext')) return const Color(0xFFD4537E);
    if (FileTypes.isImage('x.$ext')) return const Color(0xFF1D9E75);
    if (FileTypes.isVideo('x.$ext')) return const Color(0xFF7F77DD);
    if (FileTypes.isAudio('x.$ext')) return const Color(0xFFEF9F27);
    if (ext == 'apk') return const Color(0xFF34C759);
    if (ext == 'zip' || ext == 'rar' || ext == '7z') return const Color(0xFF8D6E63);
    return const Color(0xFF6B7280);
  }

  IconData _iconFor(String ext, bool isDir) {
    if (isDir) return Icons.folder_rounded;
    if (FileTypes.isPdf('x.$ext')) return Icons.picture_as_pdf_outlined;
    if (FileTypes.isImage('x.$ext')) return Icons.image_outlined;
    if (FileTypes.isVideo('x.$ext')) return Icons.movie_outlined;
    if (FileTypes.isAudio('x.$ext')) return Icons.music_note_outlined;
    if (ext == 'apk') return Icons.android;
    if (ext == 'zip' || ext == 'rar' || ext == '7z') return Icons.folder_zip_outlined;
    if (ext == 'doc' || ext == 'docx') return Icons.description_outlined;
    if (ext == 'xls' || ext == 'xlsx' || ext == 'csv') return Icons.table_chart_outlined;
    if (ext == 'ppt' || ext == 'pptx') return Icons.slideshow_outlined;
    return Icons.insert_drive_file_outlined;
  }

  void _sheet(DavEntry e) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
              // 通用：重命名 / 删除
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('重命名'),
                subtitle: const Text('在同一目录下改名'),
                onTap: () {
                  Navigator.pop(ctx);
                  _rename(e);
                },
              ),
              // 文件才能下载/分享/编辑/复制直链
              if (!e.isDir) ...[
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('下载到手机'),
                  subtitle: Text('${formatBytes(e.size)} · 存到下载目录'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _downloadOne(e);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('先下载再分享'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _downloadOne(e, share: true);
                  },
                ),
                if (FileTypes.isReadableText(e.name))
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('编辑文本'),
                    subtitle: const Text('直接改完保存到服务器'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _editTextFile(e);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('复制文件的直链'),
                  subtitle: const Text('可以在浏览器里打开（需要能连通你的服务器）'),
                  onTap: () {
                    Navigator.pop(ctx);
                    final client = ref.read(davClientProvider);
                    if (client == null) return;
                    Clipboard.setData(ClipboardData(text: client.urlFor(e.path)));
                    ScaffoldMessenger.of(ctx)
                        .showSnackBar(const SnackBar(content: Text('链接已复制')));
                  },
                ),
              ],
              // 删除（v1.9.0）
              const Divider(),
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('删除', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                subtitle: Text(e.isDir ? '文件夹及其内容会一起被删掉' : '无法恢复，请确认'),
                onTap: () {
                  Navigator.pop(ctx);
                  _delete(e);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v1.9.0：新建文件夹
  Future<void> _createFolder() async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final name = await _askName(ctx: context, title: '新建文件夹', hint: '文件夹名', initial: '新文件夹');
    if (name == null || name.isEmpty) return;
    final clean = name.replaceAll('/', '_').replaceAll('\\', '_').trim();
    if (clean.isEmpty) return;
    setState(() => _loading = true);
    try {
      await client.ensureDir(joinPath(_dirPath, clean));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已建「$clean」')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('建文件夹失败：$err')));
    } finally {
      await _load();
    }
  }

  /// v1.9.0：上传本地图片或视频到当前目录（用 image_picker）。
  /// 只支持图片/视频。文本/任意文件上传等 v1.9.1 加 share intent 方案。
  Future<void> _uploadFile() async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final picker = ImagePicker();
    // 让用户选「图库 / 拍摄视频」两个来源都行
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选图片'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('从相册选视频'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张照片'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    XFile? picked;
    try {
      // 简单区分：先 pickImage，再 pickVideo。这里只 pickImage 也行。
      picked = await picker.pickImage(source: source);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选图失败：$e')));
      return;
    }
    if (picked == null) return;
    final path = picked.path;
    if (path.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件路径不可用')));
      return;
    }
    final name = (picked.name.isNotEmpty ? picked.name : p.basename(path));
    final target = joinPath(_dirPath, name);
    setState(() => _loading = true);
    try {
      await client.writeFileStream(target, File(path));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已上传：$name')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('上传失败：$err')));
    } finally {
      await _load();
    }
  }

  /// v1.9.0：重命名（同一目录）
  Future<void> _rename(DavEntry e) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final stem = baseName(e.path);
    final newName = await _askName(ctx: context, title: '重命名', hint: '新名字', initial: stem);
    if (newName == null || newName.isEmpty || newName == stem) return;
    final clean = newName.replaceAll('/', '_').replaceAll('\\', '_').trim();
    if (clean.isEmpty) return;
    // 目标路径：保持在同一目录
    final dir = parentOf(e.path);
    final target = joinPath(dir, clean);
    setState(() => _loading = true);
    try {
      await client.move(e.path, target);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已改名：$clean')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('改名失败：$err')));
    } finally {
      await _load();
    }
  }

  /// v1.9.0：编辑文本文件（.md/.txt/.json/.csv 等）
  Future<void> _editTextFile(DavEntry e) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    String content;
    try {
      content = await client.readText(e.path);
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读不回来：$err')));
      return;
    }
    if (!mounted) return;
    final newContent = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => _TextEditorPage(title: e.name, initial: content),
    ));
    if (newContent == null || newContent == content) return;
    setState(() => _loading = true);
    try {
      await client.writeText(e.path, newContent);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存：${e.name}')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$err')));
    } finally {
      await _load();
    }
  }

  /// v1.9.0：删除（文件直接删，文件夹递归删：WebDAV 协议里服务端要逐个删子项）
  Future<void> _delete(DavEntry e) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除${e.isDir ? '文件夹' : '文件'}？'),
        content: Text(
          e.isDir
              ? '「${e.name}」及其内部所有内容会从服务器上删除，无法恢复。'
              : '「${e.name}」会从服务器上删除，无法恢复。',
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
    setState(() => _loading = true);
    try {
      if (e.isDir) {
        // 递归列出并删（WebDAV 服务端通常不会替客户端级联删）
        await _deleteRecursive(client, e.path);
      } else {
        await client.delete(e.path);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已删：${e.name}')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$err')));
    } finally {
      await _load();
    }
  }

  Future<void> _deleteRecursive(WebDavClient client, String path) async {
    final entries = await client.list(path, depth: 1);
    for (final e in entries) {
      if (e.isDir) {
        await _deleteRecursive(client, e.path);
      } else {
        await client.delete(e.path);
      }
    }
    await client.delete(path);
  }

  /// 复用：让用户输入一个名字（用于新建/重命名）
  Future<String?> _askName({required BuildContext ctx, required String title, required String hint, String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogCtx, ctrl.text), child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _downloadOne(DavEntry e, {bool share = false}) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    final f = await Downloader.withUi(
      context,
      client.urlFor(e.path),
      baseName(e.path),
      headers: client.headers,
      title: e.name,
    );
    if (f == null) return;
    if (!mounted) return;
    setState(() => _downloaded.add(e.path));
    if (share) {
      if (!mounted) return;
      try {
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享失败：$e')));
        }
      }
    }
  }

  Future<void> _downloadAll(List<DavEntry> files) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('下载这个目录里的 ${files.length} 个文件？'),
        content: Text('总大小约 ${formatBytes(files.fold<int>(0, (a, b) => a + b.size))}，'
            '会依次下载到手机的下载目录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;
    final client = ref.read(davClientProvider);
    if (client == null) return;

    var done = 0;
    for (final e in files) {
      if (!mounted) return;
      try {
        final dir = await downloadTargetDir();
        if (dir == null) break;
        final target = File(p.join(dir.path, Downloader.safeName(baseName(e.path))));
        await client.download(e.path, target.path);
        done++;
        if (mounted) setState(() => _downloaded.add(e.path));
      } catch (_) {
        // 单个失败就跳过，继续下一个
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('下载完成：$done / ${files.length} 个文件')));
  }
}

/// v1.9.0：简易文本编辑器（仅用于「服务器下载站」里直接改 .md / .txt / .json 等）。
/// 不替换项目里别的编辑器。
class _TextEditorPage extends StatefulWidget {
  final String title;
  final String initial;
  const _TextEditorPage({required this.title, required this.initial});
  @override
  State<_TextEditorPage> createState() => _TextEditorPageState();
}

class _TextEditorPageState extends State<_TextEditorPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed = _ctrl.text != widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: changed ? () => Navigator.of(context).pop(_ctrl.text) : null,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _ctrl,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '（空文件）',
          ),
          onChanged: (_) => setState(() {}), // 让保存按钮 enable/disable
        ),
      ),
    );
  }
}
