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

  /// 上传中（显示进度用）
  bool _uploading = false;
  double? _uploadProgress;

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

  /// 手机返回键：优先返回上级目录；已在本页根目录时返回 false
  bool handleBack() {
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
    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
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

  List<DavEntry> get _shown => sortEntries(_dirEntries, _sort);

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功后自动拉一次内容
    ref.listen(accountProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (next && prev != next) _load();
    });

    return Scaffold(
      appBar: AppBar(
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
        bottom: _uploading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _uploadProgress, minHeight: 3),
              )
            : null,
      ),
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
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: shown.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) {
        final e = shown[i];
        if (e.isDir) {
          return ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: const Color(0xFF7F77DD).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.folder_rounded, color: Color(0xFF7F77DD)),
            ),
            title: Text(e.name),
            subtitle: e.modified == null
                ? null
                : Text(formatTime(e.modified), style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              setState(() => _sub = e.path.substring(AppDirs.media.length + 1));
              await _load();
            },
            onLongPress: () => _showDirActions(e),
          );
        }
        final isVideo = FileTypes.isPlayable(e.name);
        return ListTile(
          leading: _thumbFromPath(e.path, isVideo),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${formatBytes(e.size)}${e.modified == null ? '' : ' · ${formatTime(e.modified)}'}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Icon(
            isVideo ? Icons.play_circle_outline : Icons.photo_outlined,
            color: scheme.primary,
          ),
          onTap: () => _open(MediaItem(path: e.path, isVideo: isVideo, size: e.size, modified: e.modified)),
          onLongPress: () => _showActions(e),
        );
      },
    );
  }

  // ------------------------------------------------------------ 菜单

  /// 目录长按菜单
  void _showDirActions(DavEntry e) {
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
                setState(() => _sub = e.path.substring(AppDirs.media.length + 1));
                _load();
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
          ],
        ),
      ),
    );
  }

  /// 文件长按菜单：可以不用打开就直接下载 / 改名
  void _showActions(DavEntry e) {
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
          ],
        ),
      ),
    );
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
      if (mounted) ref.invalidate(recentProvider);
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
