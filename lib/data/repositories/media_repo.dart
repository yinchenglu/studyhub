import 'dart:io';

// 上传要原样转发 CancelToken（让用户能在上传中途取消），
// 而 CancelToken 是 dio 的类型 —— Dart 的 import 不传递，
// 哪怕 webdav_client 已经引过，这里也得自己引一份。
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

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

  // ------------------------------------------------------------ 写操作

  /// 在某个相对目录下新建目录
  Future<void> createDir(String sub, String name) async {
    await dav.ensureDir(joinPath(joinPath(_root, sub), name));
  }

  /// 重命名（目录和文件都走这一条，WebDAV 的 MOVE 是同一个语义）
  Future<void> renameEntry(String from, String to) async {
    await dav.move(from, to);
    // 本地扫描索引里存的是旧路径，留着就是脏数据。
    // replaceMediaIndex 会先清空整张表，传空列表正好等于「清空」。
    try {
      await AppDb.instance.replaceMediaIndex(const []);
    } catch (_) {}
  }

  /// 上传本地文件到某个相对目录，返回新建的相对路径。
  /// 视频走流式上传，不会把整个文件读进内存。
  Future<String> uploadFile(
    String sub,
    String localPath, {
    String? nameHint,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final f = File(localPath);
    final ext = p.extension(localPath).replaceFirst('.', '');
    var name = (nameHint ?? '').trim();
    if (name.isEmpty) name = baseName(localPath);
    if (!name.contains('.') && ext.isNotEmpty) name = '$name.$ext';
    final rel = joinPath(joinPath(_root, sub), name);
    await dav.writeFileStream(
      rel,
      f,
      contentType: mimeOf(ext),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return rel;
  }

  /// 扩展名 → Content-Type。视频的 MIME 影响服务器能不能正确识别，
  /// 认不出就交给服务器自己嗅探（返回 null）。
  static String? mimeOf(String ext) {
    switch (ext.toLowerCase()) {
      case 'mp4':
        return 'video/mp4';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'flv':
        return 'video/x-flv';
      case 'ts':
        return 'video/mp2t';
      case 'rmvb':
      case 'rm':
        return 'application/vnd.rn-realmedia';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'heic':
        return 'image/heic';
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      default:
        return null;
    }
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
