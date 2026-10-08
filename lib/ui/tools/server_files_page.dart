import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

/// 服务器速查表：浏览 WebDAV /tools 目录里的词库、速查表、模板
/// 顺便提供「题库体检」——检查 quiz 目录下的 JSON 有没有写错
class ServerFilesPage extends ConsumerStatefulWidget {
  const ServerFilesPage({super.key});

  @override
  ConsumerState<ServerFilesPage> createState() => _ServerFilesPageState();
}

class _ServerFilesPageState extends ConsumerState<ServerFilesPage> {
  String _sub = '';
  bool _loading = true;
  String? _error;
  List<DavEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await client.list(joinPath(AppDirs.tools, _sub), depth: 1);
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务器速查表'),
            Text('/${AppDirs.tools}${_sub.isEmpty ? '' : '/$_sub'}', style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '给题库做个体检',
            onPressed: _validateBanks,
            icon: const Icon(Icons.fact_check_outlined),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.6)),
                  ),
                )
              : _entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder_off_outlined, size: 44, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text('这个目录是空的', style: TextStyle(color: scheme.onSurfaceVariant)),
                            const SizedBox(height: 8),
                            Text(
                              '把你的词库、速查表、模板（.md / .txt / .csv / .json）放到服务器的 ${AppDirs.tools} 目录里，这里就能直接翻。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return ListTile(
                            leading: Icon(
                              e.isDir ? Icons.folder_outlined : _iconForExt(FileTypes.ext(e.name)),
                              color: e.isDir ? const Color(0xFF72243E) : scheme.primary,
                            ),
                            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              e.isDir ? '文件夹' : '${formatBytes(e.size)}${e.modified == null ? '' : ' · ${formatTime(e.modified)}'}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () async {
                              if (e.isDir) {
                                setState(() => _sub = e.path.substring(AppDirs.tools.length + 1));
                                await _load();
                              } else {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TextFilePage(path: e.path)));
                              }
                            },
                          );
                        },
                      ),
                    ),
    );
  }

  IconData _iconForExt(String ext) {
    switch (ext) {
      case 'md':
        return Icons.article_outlined;
      case 'json':
        return Icons.data_object;
      case 'csv':
        return Icons.table_chart_outlined;
      case 'txt':
        return Icons.description_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Future<void> _validateBanks() async {
    final repo = ref.read(quizRepoProvider);
    final client = ref.read(davClientProvider);
    if (repo == null || client == null) return;
    setState(() => _loading = true);
    final all = <String>[];
    try {
      final dirs = await client.list(AppDirs.quiz, depth: 1);
      for (final d in dirs.where((e) => e.isDir)) {
        final errs = await repo.validate(d.path);
        all.addAll(errs.map((e) => '${d.name}：$e'));
      }
      // quiz 根目录下的散装 json 也检查
      final loose = dirs.where((e) => !e.isDir && FileTypes.isJson(e.name));
      for (final f in loose) {
        final errs = await repo.validate(parentOf(f.path));
        all.addAll(errs);
      }
    } catch (e) {
      all.add('检查过程出错：$e');
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(all.isEmpty ? '题库体检：全部正常' : '题库体检：发现 ${all.length} 个问题'),
        content: SizedBox(
          width: double.maxFinite,
          child: all.isEmpty
              ? const Text('所有题库文件的字段都是齐全的，放心刷。')
              : ListView(
                  shrinkWrap: true,
                  children: all.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('· $e', style: const TextStyle(fontSize: 13, height: 1.5)))).toList(),
                ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
      ),
    );
  }
}

/// 纯文本文件查看（md / txt / csv / json）
class TextFilePage extends ConsumerStatefulWidget {
  final String path;
  const TextFilePage({super.key, required this.path});

  @override
  ConsumerState<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends ConsumerState<TextFilePage> {
  String? _text;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    try {
      final t = await client.readText(widget.path);
      setState(() {
        _text = t;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(baseName(widget.path), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: _text == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _text!));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '下载到本地',
            onPressed: _download,
            icon: const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    _text ?? '',
                    style: const TextStyle(fontSize: 14, height: 1.7, fontFamily: 'monospace'),
                  ),
                ),
    );
  }

  Future<void> _download() async {
    final client = ref.read(davClientProvider);
    if (client == null || _text == null) return;
    try {
      final f = await CacheManager.instance.downloadedFile(widget.path);
      await f.writeAsString(_text!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存到 ${f.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }
}
