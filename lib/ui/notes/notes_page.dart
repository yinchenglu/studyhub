import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants.dart';
import '../../core/sort_utils.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/html_view_page.dart';
import '../common/pdf_view_page.dart';
import '../common/sort_menu.dart';
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
///
/// v1.3.0 起：
///   * .html / .htm 也能在 App 内直接预览（WebView）
///   * 去掉「全部笔记（平铺）」—— 平铺列表把目录层级拍平了，找东西反而更乱，
///     换成右上角的排序按钮（名称 / 修改时间 / 大小，可切升降序）
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => NotesPageState();
}

class NotesPageState extends ConsumerState<NotesPage> {
  /// 每一行的固定高度。
  /// 写死是有意的：靠它才能直接算出「上次看的那篇」该滚到哪儿。
  /// 用 ListView.builder 时屏幕外的行还没挂载，GlobalKey + ensureVisible
  /// 那套是拿不到的，只能自己算偏移。
  static const double _kRowHeight = 72;

  /// 当前所在子目录（相对 notes），空串表示根
  String _sub = '';
  bool _loading = false;
  String? _error;
  List<DavEntry> _entries = const [];

  /// 排序方式（降序/升序、按什么排）
  SortPref _sort = const SortPref();

  /// 多选模式
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// 列表滚动控制器 —— 进目录时要自动滚到「上次看的那篇」
  final ScrollController _scroll = ScrollController();

  /// 当前目录里上次打开过的那篇笔记（高亮用）
  String? _lastPath;

  /// 当前目录下、装着「上次看到的那篇」的子目录（v1.5.0）。
  /// 有它才能在**目录**上也打「上次看到这儿」，不用一层层点进去找。
  String? _lastDirPath;

  /// 已经为哪个目录做过自动定位。
  /// 每次 _load 都滚一遍会把用户手动滚到的位置冲掉，
  /// 只有「刚进这个目录」那一次才该定位。
  String? _scrolledFor;

  /// 当前目录的完整路径（相对资料根目录）
  String get _dirPath => _sub.isEmpty ? AppDirs.notes : '${AppDirs.notes}/$_sub';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 从别的菜单切进来 / 再次点「笔记」时调用：回到根目录并刷新
  Future<void> reload() async {
    if (_sub.isNotEmpty || _selecting) {
      setState(() {
        _sub = '';
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
      final list = await repo.listDir(_sub);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
        // 选中的条目可能已经被删了，顺手清掉
        final alive = list.map((e) => e.path).toSet();
        _selected.removeWhere((p) => !alive.contains(p));
        if (_selected.isEmpty && _selecting) _selecting = false;
      });
      // 列表就位之后再找「上次看的那篇」并滚过去
      await _locateLast();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------- 上次看到哪儿

  /// 找出当前目录里上次打开过的笔记，高亮它，并滚到屏幕中间。
  ///
  /// 为什么要在本地记这个：用户是从「学某一块内容」的角度用这个 App 的，
  /// 每次进来都要在同一个目录里重新翻找上次看到第几篇，很烦。
  ///
  /// v1.5.0 补上「目录也要提示」：
  ///   原来只认**直接躺在当前目录里**的那篇笔记（`parentOf(p) == dir`），
  ///   一旦那篇藏在子目录里，退到上一层就什么提示都没有了 ——
  ///   用户得挨个文件夹点进去找。现在会多记一层 `_lastDirPath`：
  ///   「当前目录下的哪个子目录里装着上次看到的那篇」，在目录上同样打标。
  Future<void> _locateLast() async {
    final dir = _dirPath;
    String? found;      // 直接躺在当前目录里的那篇
    String? viaDir;     // 当前目录下、包着那篇的子目录
    try {
      final notes = await AppDb.instance.recentNotes();
      for (final p in notes) {
        // recentNotes 是跨目录的，只认自己这棵子树
        if (parentOf(p) == dir) {
          found = p;
          break;
        }
        final deeper = _childDirOf(dir, p);
        if (deeper != null) {
          viaDir = deeper;
          break;
        }
      }
    } catch (_) {
      // 本地库读不出来不影响浏览，最多不高亮
    }
    if (!mounted) return;

    final target = found ?? viaDir;
    final changed = _lastPath != found || _lastDirPath != viaDir;
    if (changed) {
      setState(() {
        _lastPath = found;
        _lastDirPath = viaDir;
      });
    }
    if (target == null) return;

    // 已经给这个目录定位过、而且目标没变 → 不打扰用户当前的位置
    if (_scrolledFor == dir && !changed) return;
    _scrolledFor = dir;

    // 等这一帧把列表布局出来，否则拿不到 viewport / maxScrollExtent
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOn(target!));
  }

  /// [path] 位于 [dir] 的**某个子目录**里时，返回「dir 下面那一层目录」的完整路径。
  ///
  ///   dir = notes/中医, path = notes/中医/经络/任脉.md  →  notes/中医/经络
  ///   dir = notes/中医, path = notes/中医/任脉.md      →  null（就在本层，不算子目录）
  ///   dir = notes/中医, path = notes/西医/xxx.md       →  null（不在 dir 底下）
  ///
  /// 只在 dir 后面**紧跟**一段且后面还有斜杠时才算 —— 也就是只认「下一层」，
  /// 再深的地方由用户自己点进去再定位。
  String? _childDirOf(String dir, String path) {
    final prefix = '$dir/';
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    final i = rest.indexOf('/');
    if (i <= 0) return null;
    return '$prefix${rest.substring(0, i)}';
  }

  /// 把某一项滚到视口中间
  void _centerOn(String path) {
    if (!mounted || !_scroll.hasClients) return;
    final idx = _shown.indexWhere((e) => e.path == path);
    if (idx < 0) return;

    const step = _kRowHeight + 1; // +1 是分隔线
    final viewport = _scroll.position.viewportDimension;
    var target = idx * step - (viewport - _kRowHeight) / 2;
    final max = _scroll.position.maxScrollExtent;
    if (target < 0) target = 0;
    if (target > max) target = max;
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
  }

  /// 屏幕上真正展示的顺序（排过序的）
  List<DavEntry> get _shown => sortEntries(_entries, _sort);

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
      _shown.where((e) => _selected.contains(e.path)).toList();

  /// 选中的可导出笔记数（目录算 1 项，导出时递归展开）
  int get _pickedExportable =>
      _pickedEntries.where((e) => e.isDir || FileTypes.isReadableText(e.name)).length;

  // ------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功或切换账号后自动拉一次内容（App 启动时往往还没登录，那时列表是空的）
    ref.listen(accountProvider.select(accountKeyOf), (prev, next) {
      if (next.isNotEmpty && prev != next) _load();
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
                '/${AppDirs.notes}${_sub.isEmpty ? '' : '/$_sub'}'
                '${_entries.isEmpty ? '' : ' · ${_entries.length} 项'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          if (logged && _entries.length > 1)
            SortButton(
              value: _sort,
              onChanged: (v) => setState(() => _sort = v),
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
              '这个目录是空的',
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

    final shown = _shown;
    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.only(bottom: _selecting ? 16 : 24),
      itemCount: shown.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, i) {
        final e = shown[i];
        final isMd = FileTypes.isMarkdown(e.name);
        final isPdf = FileTypes.isPdf(e.name);
        final isImg = FileTypes.isImage(e.name);
        final isHtml = FileTypes.isHtml(e.name);
        final isTxt = !e.isDir && !isHtml && FileTypes.isReadableText(e.name);
        final checked = _selected.contains(e.path);
        // 上次看过的那篇。多选时不显示，免得跟勾选态打架。
        // v1.5.0：如果上次看的那篇在某个子目录里，那个**子目录**也高亮 ——
        // 不然退到上一层就完全没有线索了。
        final isLast = !_selecting && (e.path == _lastPath || (e.isDir && e.path == _lastDirPath));

        final iconColor = e.isDir
            ? const Color(0xFF185FA5)
            : isImg
                ? const Color(0xFF1D9E75)
                : isPdf
                    ? const Color(0xFFD4537E)
                    : isHtml
                        ? const Color(0xFFD85A30)
                        : const Color(0xFF7F77DD);

        // 先建 ListTile 再套一层 SizedBox：
        // 行高固定住，「上次看的那篇」才能靠 index 直接算出滚动位置。
        final tile = ListTile(
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
                                  : isHtml
                                      ? Icons.language_outlined
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
              if (isPdf || isHtml) '可预览',
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
            // 必须限一行 —— 行高是写死的 _kRowHeight，换行会被裁掉
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLast)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('上次看到这儿',
                            style: TextStyle(fontSize: 10.5, color: scheme.primary)),
                      ),
                    if (isTxt || isPdf || isImg || isHtml || e.isDir)
                      const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
          onTap: () async {
            if (_selecting) {
              _toggle(e);
              return;
            }
            if (e.isDir) {
              setState(() {
                _sub = e.path.substring(AppDirs.notes.length + 1);
              });
              await _load();
            } else if (isMd) {
              // 记一笔「这篇我看过」—— 下次进这个目录要定位到它
              await AppDb.instance.touchNote(e.path);
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteReadPage(path: e.path)));
              await _load();
            } else if (isPdf) {
              await _openPdf(e);
            } else if (isHtml) {
              await _openHtml(e);
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

        return SizedBox(
          height: _kRowHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isLast ? scheme.primaryContainer.withValues(alpha: 0.32) : null,
              // 左边一条竖线：比整行变底色更容易一眼扫到
              border: Border(
                left: BorderSide(
                  color: isLast ? scheme.primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: tile,
          ),
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

  /// 预览目录里的 HTML
  ///
  /// v1.4.0 改成「先把文件内容读下来，再交给 WebView 渲染」。
  /// 之前是把服务器地址丢给 WebView 让它自己去下载，只要服务器要鉴权
  /// （或者那次请求慢了、被拦了），主文档就加载失败，用户看到
  /// 「页面加载失败」—— 而他明明能从别的地方打开这个文件。
  /// 内容由我们自己取，主文档就一定能显示出来。
  ///
  /// baseUrl 给的是「该文件所在目录」的服务器地址（以 / 结尾），
  /// 这样 html 里写死的相对路径（`<img src="a.png">`）仍然指向服务器。
  /// 子资源是 WebView 自己去拿的，带不上我们的 Authorization 头，
  /// 所以服务器允许免鉴权访问才能显示图片 —— 不允许也只是图裂，正文照看。
  Future<void> _openHtml(DavEntry e) async {
    final repo = ref.read(noteRepoProvider);
    final client = ref.read(davClientProvider);
    if (repo == null || client == null) return;

    setState(() => _loading = true);
    String content;
    try {
      content = await repo.readNote(e.path);
    } catch (err) {
      if (mounted) setState(() => _loading = false);
      _toast('打不开这个文件：$err');
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HtmlViewPage(
        title: e.name,
        html: content,
        baseUrl: client.urlFor(parentOf(e.path), asDir: true),
        headers: repo.authHeaders,
        errorHint: '页面里的图片 / 样式需要服务器允许免鉴权访问才能显示，'
            '正文不受影响。',
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
    // 用户在相册里挑图可能花很久，回来时这个页面可能已经被销毁了
    if (!mounted) return;
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
