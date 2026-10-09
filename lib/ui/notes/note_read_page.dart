import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../media/image_viewer_page.dart';
import 'note_edit_page.dart';
import 'note_export.dart';

/// 笔记阅读页：Markdown 渲染 + 图片 / 动图显示 + 纯文本查看
class NoteReadPage extends ConsumerStatefulWidget {
  final String path;
  final bool imageOnly;

  /// 纯文本查看（.txt / .csv / .json 之类）
  final bool plain;

  const NoteReadPage({super.key, required this.path, this.imageOnly = false, this.plain = false});

  @override
  ConsumerState<NoteReadPage> createState() => _NoteReadPageState();
}

class _NoteReadPageState extends ConsumerState<NoteReadPage> {
  String? _content;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.imageOnly) _load();
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await repo.readNote(widget.path);
      if (!mounted) return;
      setState(() {
        _content = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 把 markdown 里的相对图片地址换成 WebDAV 完整地址
  Uri _resolve(String src) {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return Uri.parse(src);
    return Uri.parse(repo.resolveUrl(widget.path, src));
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(noteRepoProvider);
    final title = titleFromFileName(widget.path);

    if (widget.imageOnly) {
      return Scaffold(
        appBar: AppBar(title: Text(baseName(widget.path))),
        body: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: CachedNetworkImage(
              imageUrl: repo?.resolveUrl(widget.path, baseName(widget.path)) ?? '',
              httpHeaders: repo?.authHeaders ?? const {},
              placeholder: (_, __) => const CircularProgressIndicator(),
              errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined, size: 48),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (!widget.plain)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                await Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => NoteEditPage(path: widget.path)));
                _load();
              },
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'export') await _export();
              if (v == 'delete') await _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                      leading: Icon(Icons.ios_share), title: Text('导出 / 分享'), dense: true)),
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline), title: Text('删除笔记'), dense: true)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_error!,
                        textAlign: TextAlign.center, style: const TextStyle(height: 1.6)),
                  ),
                )
              : widget.plain
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _content ?? '',
                        style: const TextStyle(fontSize: 14, height: 1.7, fontFamily: 'monospace'),
                      ),
                    )
                  : Markdown(
                      data: _content ?? '',
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                      selectable: true,
                      onTapLink: (text, href, title) {},
                      imageBuilder: (uri, title, alt) {
                        final resolved = uri.hasScheme ? uri : _resolve(uri.toString());
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => ImageViewerPage(
                                  images: [resolved.toString()],
                                  headers: repo?.authHeaders ?? const {},
                                  initialIndex: 0,
                                  titles: [baseName(resolved.path)],
                                ),
                              )),
                              child: CachedNetworkImage(
                                imageUrl: resolved.toString(),
                                httpHeaders: repo?.authHeaders ?? const {},
                                fit: BoxFit.contain,
                                placeholder: (_, __) => Container(
                                  height: 120,
                                  alignment: Alignment.center,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.4),
                                  child: const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2)),
                                ),
                                errorWidget: (_, url, err) => Container(
                                  height: 90,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .errorContainer
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text('图片加载失败：${baseName(url)}',
                                      style: const TextStyle(fontSize: 12)),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                        p: const TextStyle(fontSize: 15.5, height: 1.75),
                        h1: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.5),
                        h2: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, height: 1.5),
                        h3: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                        blockquoteDecoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(
                              left: BorderSide(
                                  color: Theme.of(context).colorScheme.primary, width: 3)),
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
    );
  }

  /// 导出 / 分享这一篇（PDF / HTML / Markdown 三选一）
  Future<void> _export() async {
    await showNoteExportSheet(context, [
      DavEntry(path: widget.path, isDir: false, size: 0),
    ]);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这篇笔记？'),
        content: const Text('服务器上的文件会被删除，无法恢复。'),
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
      await repo.deleteEntry(widget.path);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }
}
