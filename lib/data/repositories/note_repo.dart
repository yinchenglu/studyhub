import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../dav/webdav_client.dart';
import '../models/models.dart';

/// 笔记仓库：全部读写都发生在 WebDAV 的 notes 目录
class NoteRepo {
  final WebDavClient dav;
  NoteRepo(this.dav);

  String get _root => AppDirs.notes;

  /// 列出某个相对目录（相对 notes）下的条目
  Future<List<DavEntry>> listDir(String sub) => dav.list(joinPath(_root, sub), depth: 1);

  /// 列出某个目录下的 .md 笔记
  Future<List<NoteMeta>> listNotes(String sub, {bool recursive = false}) async {
    final entries = await dav.list(joinPath(_root, sub), depth: recursive ? -1 : 1);
    return entries
        .where((e) => !e.isDir && FileTypes.isMarkdown(e.name))
        .map((e) => NoteMeta(path: e.path, title: titleFromFileName(e.name), modified: e.modified, size: e.size))
        .toList();
  }

  /// 递归扫描整个 notes 目录，用于首页统计与搜索
  Future<List<NoteMeta>> allNotes({int maxDepth = Defaults.scanMaxDepth}) async {
    final out = <NoteMeta>[];
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
          if (cur.value + 1 <= maxDepth) queue.add(MapEntry(e.path.substring(AppDirs.notes.length + 1), cur.value + 1));
        } else if (FileTypes.isMarkdown(e.name)) {
          out.add(NoteMeta(path: e.path, title: titleFromFileName(e.name), modified: e.modified, size: e.size));
        }
      }
    }
    return out;
  }

  Future<String> readNote(String path) => dav.readText(path);

  /// 保存笔记。做一份同名 .bak 放到 backup 目录，防止误覆盖
  Future<void> saveNote(String path, String content, {bool backup = true}) async {
    if (backup) {
      try {
        final old = await dav.readText(path);
        if (old.trim().isNotEmpty) {
          final name = baseName(path);
          await dav.writeText(joinPath(AppDirs.backup, 'note_bak/${name.replaceAll('.md', '')}_${DateTime.now().millisecondsSinceEpoch}.md.bak'), old);
        }
      } catch (_) {
        // 新文件没有旧内容，忽略
      }
    }
    await dav.writeText(path, content);
  }

  /// 新建笔记（相对 notes 目录的路径）
  Future<String> createNote(String dirSub, String title, {String content = ''}) async {
    final fileName = title.toLowerCase().endsWith('.md') ? title : '$title.md';
    final rel = joinPath(joinPath(_root, dirSub), fileName);
    final head = content.isEmpty ? '# $title\n\n' : content;
    await dav.writeText(rel, head);
    return rel;
  }

  Future<void> createDir(String dirSub, String name) async {
    await dav.ensureDir(joinPath(joinPath(_root, dirSub), name));
  }

  Future<void> deleteEntry(String path) => dav.delete(path);

  Future<void> renameEntry(String from, String to) => dav.move(from, to);

  /// 上传图片到笔记所在目录，返回可直接写进 markdown 的文件名
  Future<String> uploadImage(String dirSub, String localPath, String nameHint) async {
    final bytes = await File(localPath).readAsBytes();
    final ext = p.extension(localPath).replaceAll('.', '');
    var name = nameHint.trim();
    if (name.isEmpty) name = 'img_${DateTime.now().millisecondsSinceEpoch}';
    if (!name.contains('.')) name = '$name.$ext';
    final rel = joinPath(joinPath(_root, dirSub), name);
    await dav.writeBytes(rel, Uint8List.fromList(bytes), contentType: _mimeOf(ext));
    return name; // markdown 里用相对路径引用
  }

  /// 把 markdown 里的相对图片路径解析成 WebDAV 完整地址
  String resolveUrl(String notePath, String src) {
    if (src.startsWith('http://') || src.startsWith('https://')) return src;
    final dir = parentOf(notePath);
    final clean = src.replaceAll(RegExp(r'^\./'), '');
    return dav.urlFor(joinPath(dir, clean));
  }

  /// 笔记里用到的图片域名（给 cached_network_image 带鉴权头）
  Map<String, String> get authHeaders => dav.headers;

  String _mimeOf(String ext) {
    switch (ext.toLowerCase()) {
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
      default:
        return 'image/jpeg';
    }
  }

  /// 把整份笔记导出成本地 markdown 文件（离线备份）
  Future<File> exportNote(String path, Directory target) async {
    final content = await readNote(path);
    final f = File(p.join(target.path, baseName(path)));
    await f.writeAsString(content);
    return f;
  }

  /// 读取笔记里引用的所有图片名（编辑器「图片」按钮列表用）
  List<String> imageRefsIn(String markdown) {
    final re = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
    return re.allMatches(markdown).map((m) => m.group(1)!).toList();
  }

  /// 简易校验：题库/笔记的 JSON 是否合法（工具页也用得上）
  bool isValidJson(String text) {
    try {
      jsonDecode(text);
      return true;
    } catch (_) {
      return false;
    }
  }
}
