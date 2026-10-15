import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/html_view_page.dart';
import 'tools_page.dart';

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
///
/// v1.7.0（用户第 5 条）：
///   * 分类和工具都**按名字开头的序号排**（`01_` < `2.` < `10 `），
///     没编号的垫底 —— 见 `core/utils.dart` 的 `compareByLeadingNumber`
///   * 显示时把序号前缀和它后面的空格剥掉（`03 单位换算` → `单位换算`）
///   * 卡片改成和内置工具箱一模一样：一行 3 个、图标与文字同排、行高钉死
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
      //
      // v1.7.0：排序改成**先按原始文件名里的序号**排（`01_` < `2.` < `10 `），
      // 再 map 成显示名。顺序不能反过来：显示名已经把序号剥掉了，
      // 拿它排序等于按字面排，序号就白编了。
      final rootRaw = entries.where((e) => !e.isDir && FileTypes.isHtml(e.name)).toList()
        ..sort((a, b) => compareByLeadingNumber(a.name, b.name));
      final rootHtml = rootRaw
          .map((e) => ServerToolEntry(
                path: e.path,
                name: _prettyName(e.name, '独立小工具'),
                category: '独立小工具',
              ))
          .toList();
      if (rootHtml.isNotEmpty) groups['独立小工具'] = rootHtml;

      // 2) 每个子目录一个分类。目录本身也按名称里的序号排（v1.7.0）
      final dirs = entries.where((e) => e.isDir).toList()
        ..sort((a, b) => compareByLeadingNumber(a.name, b.name));
      for (final d in dirs) {
        List<DavEntry> sub;
        try {
          sub = await client.list(d.path, depth: 1);
        } catch (_) {
          continue;
        }
        // 显示用的分类名：剥掉 `01_` `2.` 这类前缀（用户要求「不显示前面的数字和空格」）
        final label = stripLeadingNumber(d.name);
        final htmlRaw = sub.where((e) => !e.isDir && FileTypes.isHtml(e.name)).toList()
          ..sort((a, b) => compareByLeadingNumber(a.name, b.name));
        final html = htmlRaw
            .map((e) => ServerToolEntry(
                  path: e.path,
                  name: _prettyName(e.name, label),
                  category: label,
                ))
            .toList();
        if (html.isEmpty) continue;
        // 极端情况下两个目录剥完前缀会同名（`01_计算` 和 `1.计算`），
        // 后者会覆盖前者。真出现这种目录，说明该整理服务器了。
        groups[label] = html;
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

  /// index.html 这种入口文件直接用分类名，免得列表里一堆「index」。
  /// v1.7.0：显示名统一剥掉开头序号（`03 单位换算.html` → `单位换算`）。
  String _prettyName(String fileName, String category) {
    final n = baseName(fileName);
    if (AppDirs.htmlEntryNames.contains(n.toLowerCase())) return stripLeadingNumber(category);
    final i = n.lastIndexOf('.');
    return stripLeadingNumber(i > 0 ? n.substring(0, i) : n);
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
            // v1.8.0 按用户要求「各个类别之间的间隔太远，缩小一些」：
            // 上下留白 12/6 → 5/3（合计砍掉 10px）。
            // 这个间距之所以显眼，是因为它 = 上内边距 + 标题整行高 + 下内边距
            // ≈ 5 + 18 + 3 = 26px，而一张卡片本身才 34px 高 ——
            // 近乎一整个卡片的高度都用来当分类之间的空白了。
            padding: const EdgeInsets.fromLTRB(16, 5, 16, 3),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 15, color: scheme.primary),
                const SizedBox(width: 5),
                Text(k,
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.primary)),
                const SizedBox(width: 6),
                Text('${_groups[k]!.length} 个',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          // v1.7.0：卡片布局跟内置工具箱**完全对齐** ——
          // 一行 3 个、图标与文字同一排、格子高度用 mainAxisExtent 钉死 34。
          // 之前用的是 childAspectRatio，高度会随屏幕宽度变，「压缩行距」看运气。
          // v1.8.0：行间距 6 → 5，配合上面的留白一起收紧。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _groups[k]!.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: 34,
                mainAxisSpacing: 5,
                crossAxisSpacing: 6,
              ),
              itemBuilder: (_, i) => _tile(_groups[k]![i], scheme),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(ServerToolEntry t, ColorScheme scheme) {
    final loose = t.category == '独立小工具';
    // v1.8.0 按用户要求：图标换成**和内置小工具一样的那一套**。
    // 名字能对上内置工具（`日期计算` / `二维码生成` / `LED屏幕`…）就直接借它的
    // 图标和配色；对不上才用兜底的 web_asset —— 见 ToolsPage.iconForName 的注释。
    final builtinIcon = ToolsPage.iconForName(t.name);
    final builtinColor = ToolsPage.colorForName(t.name);
    final icon = builtinIcon ?? (loose ? Icons.html : Icons.web_asset);
    final accent = builtinColor ?? (loose ? const Color(0xFFEF9F27) : const Color(0xFF7F77DD));
    return Tooltip(
      // 卡片太小放不下完整路径，用 tooltip 补上（想知道服务器上的原文件名时能看到）
      message: baseName(t.path),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            // 图标和文字放同一排（与内置工具箱一致）；文字放不下就整体缩小
            child: Row(
              children: [
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: 4),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      t.name,
                      maxLines: 1,
                      softWrap: false,
                      // v1.8.0 需求13：和内置工具页保持一致 —— 基准字号
                      // 12.5 → 24（FittedBox 是 scaleDown，永远不会放大，
                      // 所以基准字号就是字号上限），短名字顶满 34 高的格子，
                      // 长名字照样按宽度自动缩。见 tools_page.dart 里的长注释。
                      style: TextStyle(fontSize: 24, height: 1.05, color: scheme.onSurface),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}