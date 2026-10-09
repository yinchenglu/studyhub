import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    return Scaffold(
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
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载到手机'),
              subtitle: Text('${formatBytes(e.size)} · 存到下载目录'),
              onTap: () {
                Navigator.pop(context);
                _downloadOne(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('先下载再分享'),
              onTap: () {
                Navigator.pop(context);
                _downloadOne(e, share: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制文件的直链'),
              subtitle: const Text('可以在浏览器里打开（需要能连通你的服务器）'),
              onTap: () {
                Navigator.pop(context);
                final client = ref.read(davClientProvider);
                if (client == null) return;
                Clipboard.setData(ClipboardData(text: client.urlFor(e.path)));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('链接已复制')));
              },
            ),
          ],
        ),
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
