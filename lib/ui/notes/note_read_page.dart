import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../data/repositories/note_repo.dart';
import '../../providers/providers.dart';
import '../common/pdf_view_page.dart';
import '../media/image_viewer_page.dart';
import '../media/player_page.dart';
import 'note_edit_page.dart';
import 'note_export.dart';
import 'reading_page.dart';

/// 笔记阅读页：Markdown 渲染 + 纯文本查看
///
/// v1.7.0：**去掉了 `imageOnly`**。它原来负责「在笔记里点开一张图片」，
/// 但只是一个 AppBar + InteractiveViewer 的简易页：不能左右滑、不能横竖屏切换、
/// 不能下载 —— 而「视频」模块里点图片用的 `ImageViewerPage` 三样都有。
/// 现在图片统一走 `ImageViewerPage`（入口在 `notes_page._openImage`），
/// 这个参数就没人用了，留着只会让人以为还有第二条图片预览的路。
class NoteReadPage extends ConsumerStatefulWidget {
  final String path;

  /// 纯文本查看（.txt / .csv / .json 之类）
  final bool plain;

  /// 同目录里所有能读的笔记路径（**按列表页当前的排序**）。
  ///
  /// v1.7.0 新增，用来支撑三件事：
  ///   1. 工具栏的「列表」按钮 —— 一眼看到本目录还有哪些笔记，点一下直接切过去
  ///   2. 左划 / 右划切上一篇、下一篇
  ///   3. 传给「阅读模式」，让它底栏的上一篇 / 下一篇也能真正跨文件
  /// 为空时这些入口整体隐藏（比如从别处单独打开一篇）。
  final List<String> siblings;

  const NoteReadPage({
    super.key,
    required this.path,
    this.plain = false,
    this.siblings = const [],
  });

  @override
  ConsumerState<NoteReadPage> createState() => _NoteReadPageState();
}

class _NoteReadPageState extends ConsumerState<NoteReadPage> {
  /// 当前正在读哪一篇。
  /// 之所以不直接用 widget.path —— 要在同一个页面里原地切换上一篇 / 下一篇，
  /// 换成 pushReplacement 会连着整页（含渲染）重建，滑动切换会闪。
  late String _path = widget.path;

  String? _content;
  bool _loading = true;
  String? _error;

  /// 正文滚动控制器（Markdown 与纯文本共用）——「查找」跳转要用它
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await repo.readNote(_path);
      if (!mounted) return;
      // 加载期间用户可能已经划到别的篇了，这时的结果必须丢掉
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
    return Uri.parse(repo.resolveUrl(_path, src));
  }

  /// v1.9.0：处理 md 里的链接点击（之前 onTapLink 是空的）。
  ///
  /// 支持的 href 形态：
  ///   * `http://` / `https://`              → 系统浏览器
  ///   * `/notes/<笔记>/<子>/xxx.md`         → 绝对路径跳转（去掉前导 `/`）
  ///   * `notes/<笔记>/<子>/xxx.md`          → 相对服务器根
  ///   * `02.卡里克垫结.md`                  → 相对当前 md 目录（推荐用法）
  ///   * `../index.md`                        → 相对当前 md 目录，跳上级
  ///
  /// 跳转时取该目录所有「可读」文件作为新笔记的兄弟列表，左右滑能继续切。
  Future<void> _onLinkTap(String href) async {
    if (href.isEmpty) return;
    // 1. 外链 → 系统浏览器
    if (href.startsWith('http://') || href.startsWith('https://')) {
      final uri = Uri.tryParse(href);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    // 2. 解码百分号编码（中文 / 空格）
    final decoded = Uri.decodeComponent(href);
    // 3. 拼成相对 notes 根的相对路径
    String rel;
    if (decoded.startsWith('/')) {
      rel = decoded.substring(1);
    } else if (decoded.startsWith('${AppDirs.notes}/')) {
      rel = decoded.substring(AppDirs.notes.length + 1);
    } else {
      // 相对当前 md 目录
      final dir = parentOf(_path);
      rel = joinPath(dir, decoded);
    }
    // 4. 跳过去：先看是不是文件
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return;
    // 5. 列同目录兄弟（保持左右滑切换）。失败时给空列表，不影响跳转。
    final dir = parentOf(rel);
    List<String> siblings = const [];
    try {
      final entries = await repo.listDir(dir);
      // 只算「能当笔记打开」的文件
      siblings = entries
          .where((e) => !e.isDir && (FileTypes.isMarkdown(e.name) || FileTypes.isReadableText(e.name)))
          .map((e) => e.path)
          .toList();
    } catch (_) {
      siblings = const [];
    }
    if (!mounted) return;
    // 6. 跳路由
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NoteReadPage(path: rel, siblings: siblings),
    ));
    if (mounted) _load();
  }

  /// 把 markdown 里的相对图片地址解析成多个候选 URL（多基准路径兜底）。
  ///
  /// 候选顺序：当前 md 目录 → 笔记根目录。
  /// 用于图片加载：第一个能加载成功的就用。
  List<String> _resolveCandidates(String src) {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) return [src];
    return repo.resolveUrlCandidates(_path, src);
  }

  // ------------------------------------------------------- 正文里的图片

  /// 这一篇正文里引用到的**所有**图片地址，按出现顺序、去重。
  ///
  /// 两种写法都认：
  ///   * Markdown 图片：`![说明](image/a.png)` / `![说明](image/a.png "标题")`
  ///   * 直接写 HTML：`<img src="image/a.png">`
  ///
  /// 为什么要凑齐一整份：点开一张图之后要能左右划着看本篇的其它图 ——
  /// 「视频」模块里点图片就是这个行为。原来只塞一张（`images: [resolved]`），
  /// 手势能划但没内容可划。
  List<String> _imageUrls() {
    final c = _content;
    if (c == null || c.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};

    void add(String raw) {
      // `![a](url "标题")` —— 取空格前那一段，别把标题当成路径的一部分
      var s = raw.trim();
      if (s.isEmpty) return;
      final sp = s.indexOf(' ');
      if (sp > 0 && !s.startsWith('<')) s = s.substring(0, sp);
      s = s.replaceAll(RegExp(r'''^<|>$'''), '');
      if (s.isEmpty || s.startsWith('data:')) return; // 内嵌 base64 不进画廊
      // 已经是完整地址就原样用；否则按「相对本篇的路径」解析
      final full = s.contains('://') ? s : _resolve(s).toString();
      if (seen.add(full)) out.add(full);
    }

    for (final m in RegExp(r'!\[[^\]]*\]\(([^)]*)\)').allMatches(c)) {
      add(m.group(1) ?? '');
    }
    for (final m in RegExp(r'''<img[^>]*?\bsrc\s*=\s*["']?([^"'>\s]+)''',
            caseSensitive: false)
        .allMatches(c)) {
      add(m.group(1) ?? '');
    }
    return out;
  }

  /// 在画廊里找 [url] 是第几张。
  ///
  /// 不能直接比字符串：Markdown 解析器吐出来的 uri 对中文 / 空格是**百分号编码**
  /// 过的，而我们从原文里抠出来的是原始字符，`==` 对不上（会退回到第一张，
  /// 表现成「点了第三张却从第一张开始看」）。所以退一步比**末段文件名**。
  int _galleryIndexOf(List<String> gallery, String url) {
    final t = _urlTail(url);
    for (var i = 0; i < gallery.length; i++) {
      if (gallery[i] == url || _urlTail(gallery[i]) == t) return i;
    }
    return -1;
  }

  /// 从 URL 里取文件名（解码过 —— 中文名要能看到中文）
  String _urlTail(String u) {
    try {
      final segs = Uri.parse(u).pathSegments;
      if (segs.isNotEmpty) return segs.last;
    } catch (_) {
      // 解析不了就当普通路径处理
    }
    return baseName(u);
  }

  // ------------------------------------------------------- 上一篇 / 下一篇

  /// v1.9.0：原本 `> 1`，导致"只有一个兄弟节点"的单页笔记（用户最常碰到的极短 md）
  /// 不能左右滑。改成 `> 0`：只要有兄弟就能滑。
  /// 视觉上"列表"按钮也用这个判断，所以两边一致。
  bool get _hasSibs => widget.siblings.isNotEmpty;

  int get _sibIndex => widget.siblings.indexOf(_path);

  Future<void> _jumpTo(String path) async {
    if (path == _path) return;
    setState(() {
      _path = path;
      _content = null;
      _loading = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _load();
    // 记一笔「这篇我看过」，下次进目录列表页会定位到它
    try {
      await AppDb.instance.touchNote(path);
    } catch (_) {}
  }

  /// 一条短提示。
  ///
  /// v1.7.0 修：这个文件里原来有 4 处写的是 `toast(context, '…')`，
  /// 而**顶层压根没有 toast 这个函数**（隔壁 reading_page.dart 里叫 `_snack`）——
  /// 本地几个自检脚本都没看出来，是云端 analyze 报了 4 条 undefined_method
  /// 才发现的。现在补成类内的一个私有方法。
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  /// dir = -1 上一篇，+1 下一篇
  void _siblingStep(int dir) {
    final i = _sibIndex;
    if (i < 0) return;
    final j = i + dir;
    if (j < 0) {
      _toast('已经是第一篇了');
      return;
    }
    if (j >= widget.siblings.length) {
      _toast('已经是最后一篇了');
      return;
    }
    _jumpTo(widget.siblings[j]);
  }

  /// 「列表」：本目录的笔记，点一条直接切过去
  Future<void> _showList() async {
    final cur = _path;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.66,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                '本目录的笔记 · 共 ${widget.siblings.length} 篇',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.siblings.length,
                itemBuilder: (_, i) {
                  final p = widget.siblings[i];
                  final on = p == cur;
                  return ListTile(
                    dense: true,
                    selected: on,
                    leading: SizedBox(
                      width: 26,
                      child: Text('${i + 1}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                    ),
                    title: Text(
                      titleFromFileName(p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    trailing: on ? const Icon(Icons.push_pin, size: 15) : null,
                    onTap: () => Navigator.pop(ctx, p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && picked != _path) await _jumpTo(picked);
  }

  // ------------------------------------------------------------- 本文查找

  Future<void> _showFind() async {
    final text = _content ?? '';
    if (text.trim().isEmpty) {
      _toast('这篇还没有内容');
      return;
    }
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) {
          final scheme = Theme.of(ctx2).colorScheme;
          final q = ctrl.text.trim();
          // 每次重建都重算一遍匹配位置。300 处封顶，够用且不会卡。
          final hits = <int>[];
          if (q.isNotEmpty) {
            final lq = q.toLowerCase();
            final lt = text.toLowerCase();
            var from = 0;
            while (hits.length < 300) {
              final i = lt.indexOf(lq, from);
              if (i < 0) break;
              hits.add(i);
              from = i + lq.length;
            }
          }
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx2).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx2).size.height * 0.6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                    child: TextField(
                      controller: ctrl,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: '在本文里找',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setSheet(() {}),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                    child: Text(
                      q.isEmpty
                          ? '输入关键字，只在**这一篇**里找'
                          : (hits.isEmpty
                              ? '本文里没有「$q」'
                              : '共 ${hits.length} 处${hits.length >= 300 ? '（只列出前 300）' : ''}，点一条跳过去'),
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: hits.isEmpty
                        ? Center(
                            child: Text(
                              q.isEmpty ? '支持中文、英文、标点' : '换个关键字试试',
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                            ),
                          )
                        : ListView.builder(
                            itemCount: hits.length,
                            itemBuilder: (_, i) {
                              final at = hits[i];
                              final s = (at - 18).clamp(0, text.length);
                              final e = (at + q.length + 18).clamp(0, text.length);
                              final snippet =
                                  text.substring(s, e).replaceAll('\n', ' ').trim();
                              return ListTile(
                                dense: true,
                                leading: SizedBox(
                                  width: 26,
                                  child: Text('${i + 1}',
                                      style: TextStyle(
                                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                                ),
                                title: Text(snippet,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13)),
                                onTap: () {
                                  Navigator.pop(ctx2);
                                  _scrollToChar(at, i, hits.length);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    ctrl.dispose();
  }

  /// 按「这一个匹配大约在全文的百分之几」估个位置滚过去。
  ///
  /// Markdown 渲染后的高度跟字符数**不成正比**（标题、图片、代码块的占比
  /// 各自不同），所以这里是近似定位，不是像素级精确。之所以还够用：
  /// 用户是从上面那份「带上下文的匹配列表」点进来的，已经知道要找什么，
  /// 落点附近扫一眼就能看到。真要精确得把 Markdown 拆成块再逐块量高，
  /// 代价大得多。
  void _scrollToChar(int idx, int n, int total) {
    final text = _content ?? '';
    if (text.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final ratio = (idx / text.length).clamp(0.0, 1.0);
      _scroll.animateTo((ratio * max).toDouble(),
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
      _toast('第 ${n + 1} / $total 处');
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(noteRepoProvider);
    final title = titleFromFileName(_path);

    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          // v1.9.0：用户要求「菜单顺序换一下，依次是列表、阅读模式、更多选项」——
          // 之前是 [列表, 更多, 阅读模式]，现在 [列表, 阅读模式, 更多]。
          // AppBar 上只留三个图标：
          //   [本目录的笔记] [阅读模式] [⋮ 查找/编辑/导出分享/删除]
          //   菜单内顺序：在本文中查找 → 编辑 → 导出 / 分享 → 删除笔记
          if (_hasSibs)
            IconButton(
              tooltip: '本目录的笔记（第 ${_sibIndex + 1} / ${widget.siblings.length} 篇）',
              icon: const Icon(Icons.list_alt),
              onPressed: _showList,
            ),
          IconButton(
            tooltip: '阅读模式',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReadingPage(path: _path, siblings: widget.siblings))),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              if (v == 'find') await _showFind();
              if (v == 'edit') {
                await Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => NoteEditPage(path: _path)));
                _load();
              }
              if (v == 'export') await _export();
              if (v == 'delete') await _delete();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'find',
                  child: ListTile(
                      leading: Icon(Icons.search), title: Text('在本文中查找'), dense: true)),
              // plain 模式（比如导出用的只读视图）不提供编辑
              if (!widget.plain)
                const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                        leading: Icon(Icons.edit_outlined), title: Text('编辑'), dense: true)),
              const PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                      leading: Icon(Icons.ios_share), title: Text('导出 / 分享'), dense: true)),
              const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline), title: Text('删除笔记'), dense: true)),
            ],
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // v1.7.0：左划 = 下一篇，右划 = 上一篇。
        //
        // 用 onHorizontalDragEnd 而不是 onHorizontalDragUpdate —— 只要一个
        // 「甩出去」的判定，中途不跟手：正文没有横滑动作，做成跟手的位移动画
        // 反而会跟「长按选字」的手感打架。
        // 判据用**速度**而不是位移：手指划完停在屏幕上再抬手，速度会掉到 0，
        // 那种「拖了一半又停住」不该被当成翻篇。
        onHorizontalDragEnd: _hasSibs
            ? (d) {
                final v = d.velocity.pixelsPerSecond.dx;
                if (v > 300) {
                  _siblingStep(-1);
                } else if (v < -300) {
                  _siblingStep(1);
                }
              }
            : null,
        child: _loading
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
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          _content ?? '',
                          style: const TextStyle(
                              fontSize: 14, height: 1.7, fontFamily: 'monospace'),
                        ),
                      )
                    : SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                        child: MarkdownBody(
                          data: _content ?? '',
                          selectable: true,
                          // v1.9.0：md 里的链接点击跳转。
                          // 之前 onTapLink 是空回调，所以 md 里点啥都没反应。
                          // 现在：
                          //   1. http(s):// → 用系统浏览器打开
                          //   2. 相对路径（如 02.卡里克垫结.md / image/xxx.png / ../index.md）→ 拼成 notes/<curDir>/<href> 走 WebDAV
                          //   3. 绝对路径以 notes/ 开头 → 直接当 WebDAV 路径
                          //   4. 找不到文件 → 提示一下（不直接报错）
                          onTapLink: (text, href, title) => _onLinkTap(href ?? ''),
                          imageBuilder: (uri, title, alt) {
                            final raw = uri.toString();
                            final candidates = uri.hasScheme ? [raw] : _resolveCandidates(raw);
                            // gallery 用第一个候选建索引（左右划切换靠文件名匹配）
                            final primaryUrl = candidates.first;
                            final gallery = _imageUrls();
                            final at = gallery.isEmpty ? 0 : _galleryIndexOf(gallery, primaryUrl);
                            final list = gallery.isEmpty ? <String>[primaryUrl] : gallery;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: GestureDetector(
                                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ImageViewerPage(
                                      images: list,
                                      headers: repo?.authHeaders ?? const {},
                                      initialIndex: at < 0 ? 0 : at,
                                      titles: list.map(_urlTail).toList(),
                                    ),
                                  )),
                                  child: _MultiCandidateImage(
                                    candidates: candidates,
                                    headers: repo?.authHeaders ?? const {},
                                    baseName: baseName(primaryUrl),
                                  ),
                                ),
                              ),
                            );
                          },
                          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                            p: const TextStyle(fontSize: 15.5, height: 1.75),
                            h1: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w700, height: 1.5),
                            h2: const TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w600, height: 1.5),
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
                      ),
      ),
    );
  }

  /// 导出 / 分享这一篇（PDF / HTML / Markdown 三选一）
  Future<void> _export() async {
    await showNoteExportSheet(context, [
      DavEntry(path: _path, isDir: false, size: 0),
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
      await repo.deleteEntry(_path);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }
}

/// 多候选 URL 图片组件：按顺序尝试每个候选地址，第一个加载成功就显示。
///
/// 用途：解决第三方笔记库（如 knots3d）的图片路径是相对笔记根目录写的，
/// 而 App 默认按「当前 md 所在目录」解析导致子目录里的 md 找不到根目录图片的问题。
class _MultiCandidateImage extends StatefulWidget {
  final List<String> candidates;
  final Map<String, String> headers;
  final String baseName;
  const _MultiCandidateImage({
    required this.candidates,
    required this.headers,
    required this.baseName,
  });

  @override
  State<_MultiCandidateImage> createState() => _MultiCandidateImageState();
}

class _MultiCandidateImageState extends State<_MultiCandidateImage> {
  int _idx = 0; // 当前正在试第几个候选
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // 只有一个候选时不需要特殊处理，直接用 CachedNetworkImage
    if (widget.candidates.length <= 1) {
      _loading = false;
    }
  }

  void _onError(Object err) {
    if (!mounted) return;
    if (_idx + 1 < widget.candidates.length) {
      // 还有下一个候选，切过去
      setState(() {
        _idx++;
        _loading = true;
        _failed = false;
      });
    } else {
      // 所有候选都失败了
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.candidates[_idx];
    final scheme = Theme.of(context).colorScheme;

    if (_failed) {
      return Container(
        height: 90,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('图片加载失败：${widget.baseName}',
            style: const TextStyle(fontSize: 12)),
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: widget.headers,
      fit: BoxFit.contain,
      placeholder: (_, __) => Container(
        height: 120,
        alignment: Alignment.center,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      errorWidget: (_, __, ___) {
        // 延迟一帧再切换候选，避免在 build 期间 setState
        WidgetsBinding.instance.addPostFrameCallback((_) => _onError(__));
        // 当前候选失败期间继续显示 placeholder
        return Container(
          height: 120,
          alignment: Alignment.center,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          child: const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }
}
