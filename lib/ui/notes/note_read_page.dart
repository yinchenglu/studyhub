import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../media/image_viewer_page.dart';
import 'note_edit_page.dart';
import 'note_export.dart';
import 'reading_page.dart';

/// 笔记阅读页：Markdown 渲染 + 图片 / 动图显示 + 纯文本查看
class NoteReadPage extends ConsumerStatefulWidget {
  final String path;
  final bool imageOnly;

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
    this.imageOnly = false,
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
    if (!widget.imageOnly) _load();
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

  // ------------------------------------------------------- 上一篇 / 下一篇

  bool get _hasSibs => widget.siblings.length > 1;

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

  /// dir = -1 上一篇，+1 下一篇
  void _siblingStep(int dir) {
    final i = _sibIndex;
    if (i < 0) return;
    final j = i + dir;
    if (j < 0) {
      toast(context, '已经是第一篇了');
      return;
    }
    if (j >= widget.siblings.length) {
      toast(context, '已经是最后一篇了');
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
      toast(context, '这篇还没有内容');
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
      toast(context, '第 ${n + 1} / $total 处');
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(noteRepoProvider);
    final title = titleFromFileName(_path);

    if (widget.imageOnly) {
      return Scaffold(
        appBar: AppBar(title: Text(baseName(_path))),
        body: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: CachedNetworkImage(
              imageUrl: repo?.resolveUrl(_path, baseName(_path)) ?? '',
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
          // v1.7.0 工具栏顺序（用户指定）：列表 → 查找 → 编辑 → 导出/分享+删除 → 阅读模式。
          // 「查找 / 编辑」紧挨在「导出 / 分享、删除笔记」之前 —— 这是用户明确要的
          // 「放到导出/分享、删除笔记那里并且排第一个、第二个」。
          if (_hasSibs)
            IconButton(
              tooltip: '本目录的笔记（第 ${_sibIndex + 1} / ${widget.siblings.length} 篇）',
              icon: const Icon(Icons.list_alt),
              onPressed: _showList,
            ),
          IconButton(
            tooltip: '在本文中查找',
            icon: const Icon(Icons.search),
            onPressed: _showFind,
          ),
          if (!widget.plain)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                await Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => NoteEditPage(path: _path)));
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
          IconButton(
            tooltip: '阅读模式',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReadingPage(path: _path, siblings: widget.siblings))),
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
