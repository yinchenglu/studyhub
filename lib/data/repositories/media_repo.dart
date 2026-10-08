import '../dav/webdav_client.dart';
import '../local/db.dart';
import '../models/models.dart';
import '../../core/constants.dart';
import '../../core/utils.dart';

/// 媒体库仓库：扫描 WebDAV 上的视频与图片
class MediaRepo {
  final WebDavClient dav;
  MediaRepo(this.dav);

  String get _root => AppDirs.media;

  /// 浏览某一层目录（面包屑导航用）
  Future<List<DavEntry>> listDir(String sub) async {
    final entries = await dav.list(joinPath(_root, sub), depth: 1);
    return entries.where((e) {
      if (e.isDir) return true;
      return FileTypes.isVideo(e.name) || FileTypes.isImage(e.name) || FileTypes.isAudio(e.name);
    }).toList();
  }

  /// 全库扫描（「全部文件」平铺视图用），结果写入本地索引，避免每次重新扫
  Future<List<MediaItem>> scanAll({int maxDepth = Defaults.scanMaxDepth, void Function(int found)? onProgress}) async {
    final out = <MediaItem>[];
    final queue = <MapEntry<String, int>>[MapEntry('', 0)];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      List<DavEntry> entries;
      try {
        entries = await dav.list(joinPath(_root, cur.key), depth: 1);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e.isDir) {
          if (cur.value + 1 <= maxDepth) {
            final rel = e.path.substring(AppDirs.media.length + 1);
            queue.add(MapEntry(rel, cur.value + 1));
          }
        } else if (FileTypes.isPlayable(e.name) || FileTypes.isImage(e.name)) {
          out.add(MediaItem(path: e.path, isVideo: FileTypes.isPlayable(e.name), size: e.size, modified: e.modified));
        }
      }
      onProgress?.call(out.length);
    }
    // 写入本地索引
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await AppDb.instance.replaceMediaIndex(out
          .map((m) => <String, Object?>{
                'path': m.path,
                'is_dir': 0,
                'is_video': m.isVideo ? 1 : 0,
                'size': m.size,
                'modified': m.modified?.millisecondsSinceEpoch ?? 0,
                'scanned_at': now,
              })
          .toList());
    } catch (_) {}
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return out;
  }

  /// 统计视频与图片数量（首页四宫格用）
  Future<Map<String, int>> counts({int maxDepth = 3}) async {
    var video = 0, image = 0;
    final queue = <MapEntry<String, int>>[MapEntry('', 0)];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      List<DavEntry> entries;
      try {
        entries = await dav.list(joinPath(_root, cur.key), depth: 1);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e.isDir) {
          if (cur.value + 1 <= maxDepth) queue.add(MapEntry(e.path.substring(AppDirs.media.length + 1), cur.value + 1));
        } else if (FileTypes.isVideo(e.name)) {
          video++;
        } else if (FileTypes.isImage(e.name)) {
          image++;
        }
      }
    }
    return {'video': video, 'image': image};
  }

  /// 同一目录下的兄弟文件，用于播放页「下一集 / 上一集」
  Future<List<MediaItem>> siblingsOf(String path) async {
    final dir = parentOf(path);
    final entries = await dav.list(dir, depth: 1);
    return entries
        .where((e) => !e.isDir && (FileTypes.isPlayable(e.name) || FileTypes.isImage(e.name)))
        .map((e) => MediaItem(path: e.path, isVideo: FileTypes.isPlayable(e.name), size: e.size, modified: e.modified))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 图片浏览：只取同目录图片
  Future<List<MediaItem>> imagesInDir(String dir) async {
    final entries = await dav.list(dir, depth: 1);
    return entries
        .where((e) => !e.isDir && FileTypes.isImage(e.name))
        .map((e) => MediaItem(path: e.path, isVideo: false, size: e.size, modified: e.modified))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }
}
