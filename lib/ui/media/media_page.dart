import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/sort_utils.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../common/sort_menu.dart';
import '../home/login_page.dart';
import 'image_viewer_page.dart';
import 'player_page.dart';

/// 媒体库：按目录浏览服务器 media 目录里的视频与图片
///
/// v1.3.0 起：
///   * 去掉「全部文件（已扫描）」—— 全库扫描很慢，而且几百个文件平铺一屏，
///     不如按目录一层层找。换成右上角排序按钮。
///   * 新增：新建目录 / 上传视频 / 上传图片
///   * 长按菜单新增「重命名」，目录和文件都能改名
///
/// v1.4.0 起：
///   * 新增**多选**模式（右上角 ☑ 进入），批量删除；
///     目录和文件的右键（长按）菜单里也都加了「删除」。
class MediaPage extends ConsumerStatefulWidget {
  const MediaPage({super.key});

  @override
  ConsumerState<MediaPage> createState() => MediaPageState();
}

class MediaPageState extends ConsumerState<MediaPage> {
  String _sub = '';
  bool _loading = false;
  String? _error;
  List<DavEntry> _dirEntries = const [];

  /// 排序方式
  SortPref _sort = const SortPref();

  /// 本机记下的**播放进度**（完整服务器路径 → 进度）。
  ///
  /// v1.5.0 新增：用户要求「视频也和笔记一样，目录和文件都要标出看到哪了」。
  /// 一次把媒体类的进度全取出来，文件行和目录行都靠它渲染，
  /// 不在 itemBuilder 里查数据库（那样列表一滚就是一串异步查询）。
  Map<String, PlayProgress> _progress = const {};

  /// 上传中（显示进度用）
  bool _uploading = false;
  double? _uploadProgress;

  /// 删除中（显示进度用）
  bool _deleting = false;

  /// 多选模式。`null` = 不在多选；否则装的是已选中的**完整服务器路径**。
  ///
  /// 用「可空集合」而不是「bool + 集合」是因为这两者必须同时成立 ——
  /// 拆成两个字段迟早会出现 `_selecting == true` 但 `_selected` 为 null
  /// 的中间态，然后在某处空指针。
  Set<String>? _selected;

  bool get _selecting => _selected != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 从别的菜单切进来 / 再次点「视频」时调用：回到根目录并刷新
  Future<void> reload() async {
    if (_sub.isNotEmpty) {
      setState(() => _sub = '');
    }
    await _load();
  }

  /// 手机返回键：多选中就先退出多选 → 再逐级返回上级目录 → 本页根目录返回 false
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

  /// 进入某个子目录
  void _enterDir(DavEntry e) {
    setState(() => _sub = e.path.substring(AppDirs.media.length + 1));
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // 进度是纯本地读取，和「拉目录列表」互不依赖 —— 一起发出去，别串行等
    unawaited(_loadProgress());
    try {
      final entries = await repo.listDir(_sub);
      if (!mounted) return;
      setState(() {
        _dirEntries = entries;
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

  /// 重新读一遍本地播放进度（进目录、看完视频回来时都要刷）
  Future<void> _loadProgress() async {
    try {
      final m = await AppDb.instance.videoProgress();
      if (mounted) setState(() => _progress = m);
    } catch (_) {
      // 本地库读不出来只影响「看到哪了」标记，不该让整个媒体页报错
    }
  }

  /// 当前所在目录的完整服务器路径（media 或其子目录）
  String get _dirPath => _sub.isEmpty ? AppDirs.media : '${AppDirs.media}/$_sub';

  /// 「看到 12:34 / 45:00 · 27%」这样的标记；没看过返回 null。
  ///
  /// 分档是为了别让列表里全是数字：
  ///   * 刚点开还没看（<10 秒）→ 「刚开始看」，说百分比没意义
  ///   * 看了 98% 以上 → 「已看完」，比「看到 44:30 / 45:00 · 99%」好读
  ///   * duration 为 0（老记录 / 直播流）→ 只说「看过」
  String? _watchHint(String path) {
    final p = _progress[path];
    if (p == null) return null;
    if (p.durationMs <= 0) return '看过';
    final pct = (p.positionMs / p.durationMs * 100).clamp(0, 100).round();
    if (pct >= 98) return '已看完';
    if (p.positionMs < 10000) return '刚开始看';
    return '看到 ${formatDuration(p.positionMs)} / ${formatDuration(p.durationMs)} · $pct%';
  }

  /// 这个目录（含子目录）里有没有看过的东西 → 返回「看过的有几个」。
  ///
  /// 0 表示这个目录还没碰过。路径前缀匹配是安全的：服务器路径里不会出现
  /// 别的分隔符，`dir/` 不会误伤同前缀的兄弟目录（`中医` 不会匹配到 `中医基础`，
  /// 因为比的是 `中医/` 带斜杠）。
  int _watchedUnder(String dirPath) {
    final prefix = '$dirPath/';
    var n = 0;
    for (final k in _progress.keys) {
      if (k.startsWith(prefix)) n++;
    }
    return n;
  }

  /// 最近看过的那个文件落在**当前目录的哪个子目录**里（对不上就返回 null）。
  ///
  /// 和笔记页的「上次看到这儿」一个思路：光是子目录里有东西还不够，
  /// 得把**最近**看的那条对应的目录高亮出来，用户才知道该点哪个进去。
  String? get _lastDirPath {
    final dir = _dirPath;
    final prefix = '$dir/';
    // 找出最近更新的那条记录
    MapEntry<String, PlayProgress>? best;
    for (final e in _progress.entries) {
      if (!e.key.startsWith(prefix)) continue;
      if (best == null || e.value.updatedAt.isAfter(best.value.updatedAt)) best = e;
    }
    if (best == null) return null;
    final rest = best.key.substring(prefix.length);
    final i = rest.indexOf('/');
    if (i <= 0) return null; // 就在当前目录里，不涉及子目录
    return '$prefix${rest.substring(0, i)}';
  }

  /// 当前目录里**最近看过的那一个文件**（不含子目录里的）。
  ///
  /// v1.6.0 用户要求「视频的浏览记录要跟笔记一样，文件夹、单个视频都改变底色」——
  /// 原来只在 trailing 上挂个小标签「看到这儿了」，太不显眼。
  /// 取法跟 `_lastDirPath` 同源：都是「最近更新时间最大的那条」。
  String? get _lastFilePath {
    final dir = _dirPath;
    final prefix = '$dir/';
    MapEntry<String, PlayProgress>? best;
    for (final e in _progress.entries) {
      if (!e.key.startsWith(prefix)) continue;
      if (e.key.substring(prefix.length).contains('/')) continue; // 在子目录里，不算
      if (best == null || e.value.updatedAt.isAfter(best.value.updatedAt)) best = e;
    }
    return best?.key;
  }

  /// 给「最近看过的那一行」加整行底色 + 左侧竖线。
  ///
  /// 抄的是笔记页 `notes_page.dart` 的写法（用户要求两边一致）：
  /// 整行变色比一个小标签容易一眼扫到，左侧竖线在浅色底上也能看见。
  Widget _watchTint(bool on, Widget child, ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          color: on ? scheme.primaryContainer.withValues(alpha: 0.32) : null,
          border: Border(
            left: BorderSide(color: on ? scheme.primary : Colors.transparent, width: 3),
          ),
        ),
        child: child,
      );

  List<DavEntry> get _shown => sortEntries(_dirEntries, _sort);

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功或切换账号后自动拉一次内容
    ref.listen(accountProvider.select(accountKeyOf), (prev, next) {
      if (next.isNotEmpty && prev != next) _load();
    });

    return Scaffold(
      appBar: _selecting ? _selectAppBar(scheme) : _browseAppBar(scheme, logged),
      body: !logged
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined, size: 48, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('还没有连接服务器'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const LoginPage()))
                        .then((_) => _load()),
                    child: const Text('去连接'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  /// 平时（浏览模式）的顶栏
  PreferredSizeWidget _browseAppBar(ColorScheme scheme, bool logged) => AppBar(
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
            const Text('视频'),
            if (logged)
              Text(
                '/${AppDirs.media}${_sub.isEmpty ? '' : '/$_sub'}'
                '${_dirEntries.isEmpty ? '' : ' · ${_dirEntries.length} 项'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          if (logged && _dirEntries.length > 1)
            SortButton(
              value: _sort,
              onChanged: (v) => setState(() => _sort = v),
            ),
          // 多选入口。目录为空时不显示 —— 没东西可勾。
          if (logged && _dirEntries.isNotEmpty)
            IconButton(
              tooltip: '多选',
              icon: const Icon(Icons.checklist),
              onPressed: () => _startSelect(),
            ),
          if (logged)
            PopupMenuButton<String>(
              icon: const Icon(Icons.add),
              onSelected: (v) async {
                if (v == 'dir') await _createDir();
                if (v == 'video') await _upload(isVideo: true);
                if (v == 'image') await _upload(isVideo: false);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'dir',
                    child: ListTile(
                        leading: Icon(Icons.create_new_folder_outlined),
                        title: Text('新建目录'),
                        dense: true)),
                PopupMenuItem(
                    value: 'video',
                    child: ListTile(
                        leading: Icon(Icons.video_library_outlined),
                        title: Text('上传视频'),
                        dense: true)),
                PopupMenuItem(
                    value: 'image',
                    child: ListTile(
                        leading: Icon(Icons.image_outlined),
                        title: Text('上传图片'),
                        dense: true)),
              ],
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
        bottom: _busyBar,
      );

  /// 多选模式下的顶栏：左边退出，标题显示选中数量，右边全选 + 删除
  PreferredSizeWidget _selectAppBar(ColorScheme scheme) {
    final sel = _selected ?? const <String>{};
    final all = _shown;
    final allSelected = all.isNotEmpty && sel.length >= all.length;
    return AppBar(
      automaticallyImplyLeading: false,
      leading: IconButton(
        tooltip: '退出多选',
        onPressed: _exitSelect,
        icon: const Icon(Icons.close),
      ),
      title: Text('已选 ${sel.length} 项'),
      actions: [
        TextButton(
          onPressed: allSelected ? _clearSelection : _selectAll,
          child: Text(allSelected ? '取消全选' : '全选'),
        ),
        IconButton(
          tooltip: '删除选中',
          onPressed: sel.isEmpty || _deleting
              ? null
              : () => _confirmDelete(_entriesFor(sel)),
          icon: Icon(Icons.delete_outline, color: sel.isEmpty ? null : scheme.error),
        ),
      ],
      bottom: _busyBar,
    );
  }

  /// 顶栏底下那条细进度条：上传 / 删除时显示
  PreferredSizeWidget? get _busyBar {
    if (_uploading) {
      return PreferredSize(
        preferredSize: const Size.fromHeight(3),
        child: LinearProgressIndicator(value: _uploadProgress, minHeight: 3),
      );
    }
    if (_deleting) {
      return const PreferredSize(
        preferredSize: Size.fromHeight(3),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    return null;
  }

  /// 把一组路径还原成 DavEntry。
  ///
  /// 兜底那个分支理论上走不到（选中的路径一定来自当前列表），
  /// 但列表刷新和删除之间有个时间窗，真撞上了也不该崩 —— 删除只用到 path。
  List<DavEntry> _entriesFor(Set<String> paths) => paths
      .map((p) => _dirEntries.firstWhere(
            (e) => e.path == p,
            orElse: () => DavEntry(path: p, isDir: false),
          ))
      .toList();

  // ------------------------------------------------------------ 多选

  /// 进入多选。[first] 非空时顺便把它勾上（长按直接进多选用）。
  void _startSelect([String? first]) {
    setState(() => _selected = <String>{if (first != null) first});
  }

  void _exitSelect() {
    setState(() => _selected = null);
  }

  void _toggleSelect(String path) {
    final s = _selected;
    if (s == null) return;
    setState(() {
      // Set.remove 返回「有没有真删掉」，正好当开关用
      if (!s.remove(path)) s.add(path);
    });
  }

  void _selectAll() {
    setState(() => _selected = _shown.map((e) => e.path).toSet());
  }

  void _clearSelection() {
    setState(() => _selected = <String>{});
  }

  Widget _body() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading && _dirEntries.isEmpty) {
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
              child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.6))),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    return _dirList();
  }

  /// 目录浏览
  Widget _dirList() {
    final scheme = Theme.of(context).colorScheme;
    if (_dirEntries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 90),
          Icon(Icons.video_library_outlined, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Center(child: Text('这个目录里没有视频或图片')),
          const SizedBox(height: 8),
          Center(
              child: Text('点右上角 + 上传视频 / 图片，或下拉刷新',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
        ],
      );
    }
    final shown = _shown;
    final sel = _selected;
    // 「最近看的那条在哪个子目录」整个列表只算一次 —— 它是全表扫的 getter，
    // 放在 itemBuilder 里就是「每个目录行都把所有记录扫一遍」，列表长了白费劲。
    final lastDir = _lastDirPath;
    // 同理，只算一次：本目录里最近看过的那个文件（整行变色用）
    final lastFile = _lastFilePath;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: shown.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) {
        final e = shown[i];
        final checked = sel != null && sel.contains(e.path);

        // 多选模式下：勾选框占据原本 chevron / 类型图标的位置，
        // 点整行就是勾选，长按菜单也停掉（避免和「选择」这个动作打架）。
        // 勾选框放右边而不是左边，是为了让左侧的图标 / 缩略图留在原位 ——
        // 选东西的时候眼睛是靠左边那列认人的。
        if (e.isDir) {
          // 这个目录里看过几个
          final watched = _watchedUnder(e.path);
          final tile = ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: const Color(0xFF7F77DD).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.folder_rounded, color: Color(0xFF7F77DD)),
            ),
            title: Text(e.name),
            subtitle: Text(
              <String>[
                if (e.modified != null) formatTime(e.modified),
                if (watched > 0) '里面有 $watched 个看过',
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: sel != null
                ? Checkbox(value: checked, onChanged: (_) => _toggleSelect(e.path))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // v1.5.0：和笔记页一样，把「最近看的那条在哪个目录里」标出来，
                      // 免得每次都要一层层点进去找
                      if (e.path == lastDir)
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('看到这儿了',
                              style: TextStyle(fontSize: 10.5, color: scheme.primary)),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
            onTap: () {
              if (sel != null) {
                _toggleSelect(e.path);
              } else {
                _enterDir(e);
              }
            },
            onLongPress: sel != null ? null : () => _showDirActions(e),
          );
          // v1.6.0：目录也整行变色（原来只有 trailing 上那个小标签）
          return _watchTint(e.path == lastDir, tile, scheme);
        }
        final isVideo = FileTypes.isPlayable(e.name);
        final hint = _watchHint(e.path);
        final tile = ListTile(
          leading: _thumbFromPath(e.path, isVideo),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            <String>[
              formatBytes(e.size),
              if (e.modified != null) formatTime(e.modified),
              // 看过的才加这一截；没看过就跟原来一样，不给列表添噪音
              if (hint != null) hint,
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: sel != null
              ? Checkbox(value: checked, onChanged: (_) => _toggleSelect(e.path))
              : Icon(
                  isVideo ? Icons.play_circle_outline : Icons.photo_outlined,
                  color: scheme.primary,
                ),
          onTap: () {
            if (sel != null) {
              _toggleSelect(e.path);
              return;
            }
            _open(MediaItem(path: e.path, isVideo: isVideo, size: e.size, modified: e.modified));
          },
          onLongPress: sel != null ? null : () => _showActions(e),
        );
        // v1.6.0：单个视频也整行变色
        return _watchTint(e.path == lastFile, tile, scheme);
      },
    );
  }

  // ------------------------------------------------------------ 菜单

  /// 目录长按菜单
  void _showDirActions(DavEntry e) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                      child: Text(e.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(ctx);
                _enterDir(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(e);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              subtitle: const Text('整个目录连同里面的东西一起删掉', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete([e]);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 文件长按菜单：可以不用打开就直接下载 / 改名 / 删除
  void _showActions(DavEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final isVideo = FileTypes.isPlayable(e.name);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                      child: Text(e.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(isVideo ? Icons.play_circle_outline : Icons.image_outlined),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(ctx);
                _open(MediaItem(path: e.path, isVideo: isVideo, size: e.size, modified: e.modified));
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载到本地'),
              subtitle: Text('保存到下载目录（${formatBytes(e.size)}）',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _downloadEntry(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(e);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete([e]);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 删除

  /// 删除确认 + 执行。
  ///
  /// 会先弹一个确认框 —— 这些是服务器上的文件，删掉本地没有任何回收站，
  /// 而且目录是递归删的，一次能带走几百个文件。误触的代价太大，
  /// 所以哪怕只删一个也要问一次，并且在框里写清楚到底会删掉什么。
  Future<void> _confirmDelete(List<DavEntry> targets) async {
    if (targets.isEmpty) return;
    final dirs = targets.where((e) => e.isDir).length;
    final files = targets.length - dirs;
    var bytes = 0;
    for (final t in targets) {
      if (!t.isDir) bytes += t.size;
    }

    final detail = <String>[
      if (dirs > 0) '$dirs 个目录（连同里面的全部内容）',
      if (files > 0) '$files 个文件${bytes > 0 ? '，共 ${formatBytes(bytes)}' : ''}',
    ].join('、');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final s = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(
            targets.length == 1 ? '删除「${targets.first.name}」？' : '删除这 ${targets.length} 项？',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail),
              const SizedBox(height: 10),
              Text(
                '文件会直接从服务器上抹掉，没有回收站，删了找不回来。',
                style: TextStyle(fontSize: 12.5, color: s.error),
              ),
              if (targets.length > 1) ...[
                const SizedBox(height: 10),
                Text(
                  targets.map((e) => e.name).take(6).join('、') +
                      (targets.length > 6 ? ' 等' : ''),
                  style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: s.error, foregroundColor: s.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;

    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    final paths = targets.map((e) => e.path).toList();
    setState(() => _deleting = true);
    try {
      final failed = await repo.deleteMany(paths);
      if (!mounted) return;
      setState(() => _selected = null); // 删完退出多选
      await _load();
      if (!mounted) return;
      final done = paths.length - failed.length;
      if (failed.isEmpty) {
        _toast('已删除 $done 项');
      } else {
        // 把第一条真实错误也带上 —— 只说「有 3 项没删掉」等于什么都没说
        _toast('已删除 $done 项，${failed.length} 项失败：${failed.first.value}');
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // ------------------------------------------------------------ 写操作

  Future<void> _rename(DavEntry e) async {
    final name = await _askText('重命名', '新名称', initial: e.name);
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    if (name.trim() == e.name) return;
    try {
      await repo.renameEntry(e.path, joinPath(parentOf(e.path), name.trim()));
      await _load();
      _toast('已改名为 ${name.trim()}');
    } catch (err) {
      _toast('重命名失败：$err');
    }
  }

  Future<void> _createDir() async {
    final name = await _askText('新建目录', '目录名（会建在当前目录下）');
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    try {
      await repo.createDir(_sub, name.trim());
      await _load();
      _toast('已创建目录 ${name.trim()}');
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  /// 从相册挑一个视频 / 图片传上去
  Future<void> _upload({required bool isVideo}) async {
    final picker = ImagePicker();
    XFile? x;
    try {
      x = isVideo
          ? await picker.pickVideo(source: ImageSource.gallery)
          : await picker.pickImage(source: ImageSource.gallery, imageQuality: 95);
    } catch (e) {
      _toast('选择文件失败：$e');
      return;
    }
    if (x == null) return;
    // 用户在相册里挑文件可能花很久，回来时这个页面可能已经不在了
    if (!mounted) return;

    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    setState(() {
      _uploading = true;
      _uploadProgress = null;
    });
    try {
      final rel = await repo.uploadFile(
        _sub,
        x.path,
        nameHint: baseName(x.path),
        onProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          setState(() => _uploadProgress = sent / total);
        },
      );
      if (!mounted) return;
      await _load();
      _toast('已上传到 $rel');
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = null;
        });
      }
    }
  }

  Future<String?> _askText(String title, String hint, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    // 让输入框默认全选，改名时直接打字就能覆盖旧名字
    c.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    final r = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('确定')),
        ],
      ),
    );
    c.dispose();
    return r;
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // ------------------------------------------------------------ 打开 / 下载

  Future<void> _downloadEntry(DavEntry e) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    await Downloader.withUi(context, client.urlFor(e.path), e.name, headers: client.headers);
  }

  /// 视频缩略图用占位图标（避免额外解码开销），图片直接显示
  Widget _thumbFromPath(String path, bool isVideo) {
    final repo = ref.read(mediaRepoProvider);
    if (!isVideo && repo != null) {
      final client = ref.read(davClientProvider);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 44,
          child: Image.network(
            client?.urlFor(path) ?? '',
            headers: client?.headers ?? const {},
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _iconBox(Icons.broken_image_outlined),
          ),
        ),
      );
    }
    return _iconBox(isVideo ? Icons.movie_outlined : Icons.image_outlined);
  }

  Widget _iconBox(IconData icon) => Container(
        width: 56,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF7F77DD).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: const Color(0xFF7F77DD), size: 20),
      );

  /// 打开视频或图片
  Future<void> _open(MediaItem item) async {
    final repo = ref.read(mediaRepoProvider);
    final client = ref.read(davClientProvider);
    if (repo == null || client == null) return;
    if (item.isVideo) {
      // 取出同目录兄弟文件当作播放列表
      List<MediaItem> list;
      try {
        list = await repo.siblingsOf(item.path);
      } catch (_) {
        list = [item];
      }
      var index = list.indexWhere((e) => e.path == item.path);
      if (index < 0) {
        list = [item];
        index = 0;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerPage(playlist: list, initialIndex: index),
      ));
      if (mounted) {
        ref.invalidate(recentProvider);
        // 刚从播放器回来 → 进度肯定变了，把列表上的「看到 12:34」刷新一下
        await _loadProgress();
      }
    } else {
      List<MediaItem> imgs;
      try {
        imgs = await repo.imagesInDir(parentOf(item.path));
      } catch (_) {
        imgs = [item];
      }
      var idx = imgs.indexWhere((e) => e.path == item.path);
      if (idx < 0) idx = 0;
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageViewerPage(
          images: imgs.map((e) => client.urlFor(e.path)).toList(),
          headers: client.headers,
          initialIndex: idx,
          titles: imgs.map((e) => e.name).toList(),
        ),
      ));
    }
  }
}

/// 供播放页复用：把 WebDAV 地址转成带鉴权的完整地址
String davUrl(WebDavClient client, String rel) => client.urlFor(rel);

/// 记录一次播放（首页最近浏览用）
Future<void> touchProgress(String path) async {
  final old = await AppDb.instance.getProgress(path);
  if (old == null) {
    await AppDb.instance.saveProgress(path, 0, 0);
  }
}
