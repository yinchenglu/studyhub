import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../home/login_page.dart';
import 'image_viewer_page.dart';
import 'player_page.dart';

/// 媒体库：自动扫描服务器 media 目录，按目录浏览视频与图片
class MediaPage extends ConsumerStatefulWidget {
  const MediaPage({super.key});

  @override
  ConsumerState<MediaPage> createState() => MediaPageState();
}

class MediaPageState extends ConsumerState<MediaPage> {
  String _sub = '';
  bool _flat = false;
  bool _loading = false;
  bool _scanning = false;
  String? _error;
  List<DavEntry> _dirEntries = const [];
  List<MediaItem> _flatItems = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 从别的菜单切进来 / 再次点「视频」时调用：回到根目录并刷新
  Future<void> reload() async {
    if (_sub.isNotEmpty || _flat) {
      setState(() {
        _sub = '';
        _flat = false;
      });
    }
    await _load();
  }

  /// 手机返回键：优先返回上级目录；已在本页根目录时返回 false
  bool handleBack() {
    if (_flat) {
      setState(() => _flat = false);
      _load();
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
    final repo = ref.read(mediaRepoProvider);
    if (repo == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_flat) {
        setState(() => _scanning = true);
        final items = await repo.scanAll();
        setState(() {
          _flatItems = items;
          _loading = false;
          _scanning = false;
        });
      } else {
        final entries = await repo.listDir(_sub);
        setState(() {
          _dirEntries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
        _scanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功后自动拉一次内容
    ref.listen(accountProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (next && prev != next) _load();
    });

    return Scaffold(
      automaticallyImplyLeading: false,
      appBar: AppBar(
        leading: (_sub.isNotEmpty || _flat)
            ? IconButton(
                tooltip: '返回上级目录',
                onPressed: () {
                  if (_flat) {
                    setState(() => _flat = false);
                    _load();
                  } else {
                    _goUp();
                  }
                },
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('视频'),
            if (logged)
              Text(
                _flat ? '全部文件（已扫描 ${_flatItems.length}）' : '/${AppDirs.media}${_sub.isEmpty ? '' : '/$_sub'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _flat ? '按目录浏览' : '扫描全部',
            onPressed: () {
              setState(() => _flat = !_flat);
              _load();
            },
            icon: Icon(_flat ? Icons.folder_outlined : Icons.grid_view_outlined),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
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
    if (_scanning) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 16),
          Center(child: Text('正在扫描服务器目录…', style: TextStyle(fontSize: 13))),
        ],
      );
    }
    if (_loading && _dirEntries.isEmpty && _flatItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
          const SizedBox(height: 12),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 32), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.6))),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    return _flat ? _flatList() : _dirList();
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
          Center(child: Text('把视频丢进服务器的 media 目录再下拉刷新', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _dirEntries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) {
        final e = _dirEntries[i];
        if (e.isDir) {
          return ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: const Color(0xFF7F77DD).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.folder_rounded, color: Color(0xFF7F77DD)),
            ),
            title: Text(e.name),
            subtitle: e.modified == null ? null : Text(formatTime(e.modified), style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              setState(() => _sub = e.path.substring(AppDirs.media.length + 1));
              await _load();
            },
          );
        }
        final isVideo = FileTypes.isPlayable(e.name);
        return ListTile(
          leading: _thumb(e, isVideo),
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

  /// 平铺全部
  Widget _flatList() {
    final scheme = Theme.of(context).colorScheme;
    if (_flatItems.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 90),
          Icon(Icons.video_library_outlined, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Center(child: Text('没有扫描到文件')),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _flatItems.length,
      itemBuilder: (context, i) {
        final m = _flatItems[i];
        return ListTile(
          leading: _thumbFromPath(m.path, m.isVideo),
          title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${parentOf(m.path).replaceFirst('${AppDirs.media}/', '')} · ${formatBytes(m.size)}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Icon(m.isVideo ? Icons.play_circle_outline : Icons.photo_outlined, color: scheme.primary),
          onTap: () => _open(m),
          onLongPress: () => _showActions(
            DavEntry(path: m.path, isDir: false, size: m.size, modified: m.modified),
          ),
        );
      },
    );
  }

  /// 长按菜单：可以不用打开就直接下载
  void _showActions(DavEntry e) {
    final isVideo = FileTypes.isPlayable(e.name);
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
                  Expanded(child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(isVideo ? Icons.play_circle_outline : Icons.image_outlined),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(context);
                _open(MediaItem(path: e.path, isVideo: isVideo, size: e.size, modified: e.modified));
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载到本地'),
              subtitle: Text('保存到下载目录（${formatBytes(e.size)}）', style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _downloadEntry(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadEntry(DavEntry e) async {
    final client = ref.read(davClientProvider);
    if (client == null) return;
    await Downloader.withUi(context, client.urlFor(e.path), e.name, headers: client.headers);
  }

  Widget _thumb(DavEntry e, bool isVideo) => _thumbFromPath(e.path, isVideo);

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
