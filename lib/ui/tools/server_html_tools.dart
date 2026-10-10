import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/html_view_page.dart';

/// 服务器上的一个 html 小工具
class ServerToolEntry {
  final String path;
  final String name;
  final String category;

  const ServerToolEntry({required this.path, required this.name, required this.category});
}

/// 服务器小工具：识别服务器 tools 目录里的 html 小工具。
///
/// 目录约定：
///   * tools/单位换算/index.html  →  分类「单位换算」
///   * tools/公式表.html          →  归到「独立小工具」这个分类
///
/// 一个子文件夹就是一个分类；根目录下散放的 html 单独归一类。
class ServerHtmlToolsPage extends ConsumerStatefulWidget {
  const ServerHtmlToolsPage({super.key});

  @override
  ConsumerState<ServerHtmlToolsPage> createState() => _ServerHtmlToolsPageState();
}

class _ServerHtmlToolsPageState extends ConsumerState<ServerHtmlToolsPage> {
  /// 分类名 → 小工具列表
  Map<String, List<ServerToolEntry>> _groups = const {};
  bool _loading = true;
  String? _error;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

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
      final entries = await client.list(AppDirs.tools, depth: 1);
      final groups = <String, List<ServerToolEntry>>{};

      // 1) 根目录下散放的 html → 独立分类
      final rootHtml = entries
          .where((e) => !e.isDir && FileTypes.isHtml(e.name))
          .map((e) => ServerToolEntry(
                path: e.path,
                name: _prettyName(e.name, '独立小工具'),
                category: '独立小工具',
              ))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (rootHtml.isNotEmpty) groups['独立小工具'] = rootHtml;

      // 2) 每个子目录一个分类
      final dirs = entries.where((e) => e.isDir).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final d in dirs) {
        List<DavEntry> sub;
        try {
          sub = await client.list(d.path, depth: 1);
        } catch (_) {
          continue;
        }
        final html = sub
            .where((e) => !e.isDir && FileTypes.isHtml(e.name))
            .map((e) => ServerToolEntry(
                  path: e.path,
                  name: _prettyName(e.name, d.name),
                  category: d.name,
                ))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        if (html.isEmpty) continue;
        groups[d.name] = html;
      }

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _total = groups.values.fold<int>(0, (a, b) => a + b.length);
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

  /// index.html 这种入口文件直接用分类名，免得列表里一堆「index」
  String _prettyName(String fileName, String category) {
    final n = baseName(fileName);
    if (AppDirs.htmlEntryNames.contains(n.toLowerCase())) return category;
    final i = n.lastIndexOf('.');
    return i > 0 ? n.substring(0, i) : n;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logged = ref.watch(accountProvider).isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务器小工具'),
            Text(
              _total > 0 ? '/${AppDirs.tools} · $_total 个' : '/${AppDirs.tools}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: !logged
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '服务器小工具在 WebDAV 的 /${AppDirs.tools} 目录里，\n需要先连接服务器。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.7, color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(_error!,
                            textAlign: TextAlign.center, style: const TextStyle(height: 1.6)),
                      ),
                    )
                  : _groups.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 60),
                            Icon(Icons.widgets_outlined,
                                size: 46, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            const Center(child: Text('还没发现 html 小工具')),
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                '把你的 html 小工具放进服务器的 ${AppDirs.tools} 目录：\n\n'
                                '· 一个子文件夹 = 一个分类，比如 ${AppDirs.tools}/单位换算/index.html\n'
                                '· 直接放在 ${AppDirs.tools} 根目录下的 .html 会归到「独立小工具」\n\n'
                                '放进去以后，这里点一下就能在 App 里运行。',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12.5, height: 1.8, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        )
                      : RefreshIndicator(onRefresh: _load, child: _list(scheme)),
    );
  }

  Widget _list(ColorScheme scheme) {
    final keys = _groups.keys.toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '这些是你放在服务器上的网页小工具，点开直接在 App 里运行，不用装浏览器。',
                  style: const TextStyle(fontSize: 12.5, height: 1.55),
                ),
              ),
            ],
          ),
        ),
        for (final k in keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(k,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
                const SizedBox(width: 6),
                Text('${_groups[k]!.length} 个',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          for (final t in _groups[k]!) _tile(t, scheme),
        ],
      ],
    );
  }

  Widget _tile(ServerToolEntry t, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Card(
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: t.category == '独立小工具'
                    ? const Color(0xFFEF9F27).withValues(alpha: 0.15)
                    : const Color(0xFF7F77DD).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                t.category == '独立小工具' ? Icons.html : Icons.web_asset,
                size: 21,
                color: t.category == '独立小工具'
                    ? const Color(0xFFEF9F27)
                    : const Color(0xFF7F77DD),
              ),
            ),
            title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(baseName(t.path),
                style: const TextStyle(fontSize: 11.5), maxLines: 1),
            trailing: const Icon(Icons.play_circle_outline),
            onTap: () async {
              final client = ref.read(davClientProvider);
              if (client == null) return;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HtmlViewPage(
                  title: t.name,
                  url: client.urlFor(t.path),
                  headers: client.headers,
                  errorHint: '如果是 http 明文站点，确认清单里已允许明文流量',
                ),
              ));
            },
          ),
        ),
      );
}