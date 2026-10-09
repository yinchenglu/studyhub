import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../models/models.dart';

/// WebDAV 统一错误
class DavException implements Exception {
  final String message;
  final int? statusCode;
  DavException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// 手写的 WebDAV 客户端。
/// 为什么不用现成库：需要自己控制「中文路径编码」「chfs 的 Depth:1 兼容降级」
/// 「Range 分段检测」「流式播放地址拼接」这几件事。
class WebDavClient {
  final DavAccount account;
  late final Dio _dio;

  /// 服务器是否支持 Depth:1 深度列目录（chfs 等可能不支持，需要降级）
  bool deepListSupported = true;

  WebDavClient(this.account) {
    _dio = Dio(BaseOptions(
      baseUrl: _base,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 60),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (s) => s != null && s < 500, // 自己判断状态码，便于给出人话提示
      headers: {'Authorization': authHeader, 'User-Agent': 'StudyHub/1.0'},
    ));
  }

  // ---------------------------------------------------------------- 基础

  String get authHeader =>
      'Basic ${base64Encode(utf8.encode('${account.username}:${account.password}'))}';

  /// 播放器 / 图片组件用的请求头
  Map<String, String> get headers => {'Authorization': authHeader};

  String get _base {
    var b = account.baseUrl.trim();
    if (b.isEmpty) return '/';
    if (!b.endsWith('/')) b = '$b/';
    return b;
  }

  /// 入口地址里自带的路径前缀，例如 https://nas/dav/ → /dav/
  String get _basePath {
    final p = Uri.tryParse(_base)?.path ?? '/';
    return p.endsWith('/') ? p : '$p/';
  }

  List<String> get _rootSegments =>
      account.root.split('/').where((e) => e.trim().isNotEmpty).toList();

  /// 相对资料根的路径 → 服务器上的绝对路径（未编码）
  String _absolute(String rel) {
    final r = rel.replaceAll(RegExp(r'^/+|/+$'), '');
    final root = '/' + _rootSegments.join('/');
    if (_rootSegments.isEmpty) return r.isEmpty ? '/' : '/$r';
    return r.isEmpty ? root : '$root/$r';
  }

  /// 逐段做百分号编码，中文、空格、# 等都不会出错
  static String encodePath(String absolutePath) {
    final segs = absolutePath.split('/').where((e) => e.isNotEmpty).map(Uri.encodeComponent);
    final joined = segs.join('/');
    return absolutePath.endsWith('/') ? '/$joined/' : '/$joined';
  }

  /// 给播放器 / 图片用的完整可访问 URL（带文件名的绝对地址）
  String urlFor(String rel, {bool asDir = false}) {
    final abs = _absolute(rel);
    final p = encodePath(asDir ? (abs.endsWith('/') ? abs : '$abs/') : abs);
    // _base 一定以 / 结尾，p 一定以 / 开头，拼起来正好
    return '$_base${p.startsWith('/') ? p.substring(1) : p}';
  }

  // ---------------------------------------------------------------- 列目录

  /// 列出某个相对目录下的条目。depth=1 只列当前层，depth=infinity 递归
  Future<List<DavEntry>> list(String rel, {int depth = 1}) async {
    final entries = await _propfind(rel, depth: depth);
    if (depth == 1 && entries.length <= 1) {
      // 服务器可能不支持 Depth:1（chfs 常见）→ 尝试 infinity，再不行就标记降级
      try {
        final deep = await _propfind(rel, depth: -1);
        if (deep.length > 1) {
          deepListSupported = false;
          return _onlyDirectChildren(rel, deep);
        }
      } catch (_) {
        deepListSupported = false;
      }
    }
    return entries;
  }

  List<DavEntry> _onlyDirectChildren(String rel, List<DavEntry> all) {
    final base = rel.replaceAll(RegExp(r'^/+|/+$'), '');
    final prefix = base.isEmpty ? '' : '$base/';
    return all.where((e) {
      final p = e.path;
      if (!p.startsWith(prefix)) return false;
      final rest = p.substring(prefix.length);
      return rest.isNotEmpty && !rest.contains('/');
    }).toList();
  }

  Future<List<DavEntry>> _propfind(String rel, {int depth = 1}) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/>'
        '</d:prop></d:propfind>';
    final uri = urlFor(rel, asDir: true);
    try {
      final resp = await _dio.request<String>(
        uri,
        data: body,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': depth < 0 ? 'infinity' : '$depth', 'Content-Type': 'application/xml; charset=utf-8'},
          responseType: ResponseType.plain,
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code == 207 || code == 200) {
        return _parsePropfind(resp.data ?? '', rel);
      }
      if (code == 401) throw DavException('账号或密码不对（HTTP 401），请检查用户名与应用密码');
      if (code == 403) throw DavException('没有访问权限（HTTP 403），检查该账号是否被允许访问此目录');
      if (code == 404) throw DavException('路径不存在（HTTP 404）：${account.root}${rel.isEmpty ? '' : '/$rel'}');
      if (code == 405) throw DavException('服务器未开启 WebDAV 或不允许 PROPFIND（HTTP 405）');
      throw DavException('列目录失败：HTTP $code', statusCode: code);
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  List<DavEntry> _parsePropfind(String xmlText, String requestRel) {
    final out = <DavEntry>[];
    if (xmlText.trim().isEmpty) return out;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (_) {
      throw DavException('服务器返回的不是标准 WebDAV 数据，可能没开启 WebDAV 服务');
    }
    final selfRel = requestRel.replaceAll(RegExp(r'^/+|/+$'), '');

    for (final resp in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'response')) {
      String? href;
      for (final h in resp.descendants.whereType<XmlElement>().where((e) => e.name.local == 'href')) {
        href = h.innerText.trim();
        break;
      }
      if (href == null || href.isEmpty) continue;

      final rel = _hrefToRel(href);
      if (rel == null) continue;
      if (rel == selfRel) continue; // 跳过目录自身
      final name = rel.contains('/') ? rel.substring(rel.lastIndexOf('/') + 1) : rel;
      if (name.isEmpty || name.startsWith('.')) continue; // 跳过临时文件

      final isDir = resp.descendants.any((n) => n is XmlElement && n.name.local == 'collection');
      final sizeTxt = _inner(resp, 'getcontentlength');
      final modTxt = _inner(resp, 'getlastmodified');
      out.add(DavEntry(
        path: rel,
        isDir: isDir,
        size: int.tryParse(sizeTxt ?? '') ?? 0,
        modified: _parseDate(modTxt),
        contentType: _inner(resp, 'getcontenttype'),
      ));
    }

    // 目录在前，然后按名字排序（中文按拼音近似：直接字符序，够用）
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  String? _inner(XmlElement resp, String localName) {
    for (final e in resp.descendants.whereType<XmlElement>()) {
      // 只认 200 的 propstat
      if (e.name.local == localName) return e.innerText;
    }
    return null;
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return HttpDate.parse(s).toLocal();
    } catch (_) {
      return DateTime.tryParse(s);
    }
  }

  /// 把 href 转成「相对资料根目录」的路径；不属于本根目录的返回 null
  String? _hrefToRel(String href) {
    String path;
    if (href.startsWith('http://') || href.startsWith('https://')) {
      path = Uri.parse(href).path;
    } else {
      path = href;
    }
    var decoded = path;
    try {
      decoded = Uri.decodeComponent(path);
    } catch (_) {}

    // 去掉入口地址自带的路径前缀
    final bp = _basePath.replaceAll(RegExp(r'/+$'), '');
    if (bp.isNotEmpty && bp != '/' && decoded.startsWith(bp)) {
      decoded = decoded.substring(bp.length);
    }

    final segs = decoded.split('/').where((e) => e.isNotEmpty).toList();
    final root = _rootSegments;
    if (root.isNotEmpty) {
      if (segs.length < root.length) return null;
      for (var i = 0; i < root.length; i++) {
        if (segs[i] != root[i]) return null; // 不在资料根目录内，忽略
      }
      segs.removeRange(0, root.length);
    }
    return segs.join('/');
  }

  // ---------------------------------------------------------------- 读

  Future<String> readText(String rel) async {
    final bytes = await readBytes(rel);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List> readBytes(String rel) async {
    try {
      final resp = await _dio.get<List<int>>(
        urlFor(rel),
        options: Options(responseType: ResponseType.bytes, validateStatus: (s) => s != null && s < 500),
      );
      final code = resp.statusCode ?? 0;
      if (code == 200 || code == 206) {
        return Uint8List.fromList(resp.data ?? const []);
      }
      throw DavException('下载失败：HTTP $code', statusCode: code);
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  /// 文件是否存在
  Future<bool> exists(String rel) async {
    try {
      final resp = await _dio.head(urlFor(rel), options: Options(validateStatus: (s) => s != null && s < 500));
      return (resp.statusCode ?? 0) < 400;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 写

  Future<void> writeText(String rel, String content) =>
      writeBytes(rel, Uint8List.fromList(utf8.encode(content)), contentType: 'text/markdown; charset=utf-8');

  Future<void> writeBytes(String rel, Uint8List bytes, {String? contentType}) async {
    try {
      final abs = _absolute(rel);
      // 目标目录不存在时先建（chfs / 部分服务器 PUT 不会自动建目录）
      final parent = abs.substring(0, abs.lastIndexOf('/'));
      await ensureDirAbsolute(parent);
      final resp = await _dio.put<void>(
        urlFor(rel),
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: {
            Headers.contentLengthHeader: bytes.length,
            if (contentType != null) Headers.contentTypeHeader: contentType,
            'Overwrite': 'T',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code != 200 && code != 201 && code != 204) {
        if (code == 403) throw DavException('服务器不允许写入（HTTP 403）：该账号是只读的，笔记只能看不能改');
        throw DavException('保存失败：HTTP $code', statusCode: code);
      }
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  /// 逐级建目录，已存在会静默跳过
  Future<void> ensureDir(String rel) => ensureDirAbsolute(_absolute(rel));

  Future<void> ensureDirAbsolute(String absPath) async {
    final segs = absPath.split('/').where((e) => e.isNotEmpty).toList();
    var cur = '';
    for (final s in segs) {
      cur = '$cur/$s';
      try {
        final resp = await _dio.request<void>(
          '$_base${encodePath(cur)}',
          options: Options(method: 'MKCOL', validateStatus: (s) => s != null && s < 500),
        );
        final code = resp.statusCode ?? 0;
        // 201 新建成功；405/301 表示已存在；409 表示父目录还没建好（不会发生，因为我们逐级）
        if (code == 403) {
          throw DavException('无法创建目录（HTTP 403）：服务器不允许写入');
        }
      } on DioException catch (e) {
        // 网络异常直接抛出，让用户看到
        if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.connectionError) {
          throw _friendly(e);
        }
      }
    }
  }

  Future<void> delete(String rel) async {
    try {
      final resp = await _dio.delete<void>(urlFor(rel), options: Options(validateStatus: (s) => s != null && s < 500));
      final code = resp.statusCode ?? 0;
      if (code != 200 && code != 204 && code != 404) {
        throw DavException('删除失败：HTTP $code', statusCode: code);
      }
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  /// 重命名 / 移动
  Future<void> move(String fromRel, String toRel) async {
    try {
      final dest = urlFor(toRel);
      final resp = await _dio.request<void>(
        urlFor(fromRel),
        options: Options(
          method: 'MOVE',
          headers: {'Destination': dest, 'Overwrite': 'F'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code != 201 && code != 204) {
        throw DavException('移动/重命名失败：HTTP $code', statusCode: code);
      }
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  // ---------------------------------------------------------------- 检测

  /// 连上之后做三件事：能不能读、能不能写、能不能拖进度条
  Future<ConnectionCheck> check() async {
    final missing = <String>[];
    int total = 0;
    // 1. 读根目录
    List<DavEntry> rootEntries;
    try {
      rootEntries = await list('', depth: 1);
    } catch (e) {
      return ConnectionCheck(ok: false, message: e.toString());
    }
    total = rootEntries.length;

    // 2. 缺哪些标准目录
    final names = rootEntries.where((e) => e.isDir).map((e) => e.name).toSet();
    for (final d in AppDirsConst.fixedDirs) {
      if (!names.contains(d)) missing.add(d);
    }

    // 3. 写入测试
    var canWrite = false;
    const probe = '.studyhub_write_test';
    try {
      await writeText(probe, 'studyhub');
      canWrite = true;
      await delete(probe);
    } catch (_) {
      canWrite = false;
    }

    // 4. Range 分段测试（影响在线拖进度）
    var supportsRange = false;
    DavEntry? probeFile;
    for (final e in rootEntries) {
      if (!e.isDir && e.size > 1024) {
        probeFile = e;
        break;
      }
    }
    if (probeFile == null) {
      // 根目录没有大文件就往下找一层
      for (final d in rootEntries.where((e) => e.isDir)) {
        try {
          final sub = await list(d.path, depth: 1);
          final f = sub.where((e) => !e.isDir && e.size > 1024).toList();
          if (f.isNotEmpty) {
            probeFile = f.first;
            break;
          }
        } catch (_) {}
      }
    }
    if (probeFile != null) supportsRange = await testRange(probeFile.path);

    final buf = StringBuffer();
    if (canWrite) {
      buf.write('连接正常，可读取也可写入（笔记能改能传图）');
    } else {
      buf.write('连接正常，但服务器不允许写入，笔记只能查看、不能修改');
    }
    buf.write(supportsRange ? '；支持断点/进度拖动。' : '；服务器不支持 Range，在线播放时不能拖进度条，建议先下载。');
    if (missing.isNotEmpty) buf.write(' 缺少目录：${missing.join('、')}');

    return ConnectionCheck(
      ok: true,
      canWrite: canWrite,
      supportsRange: supportsRange,
      fileCount: total,
      message: buf.toString(),
      missingDirs: missing,
    );
  }

  /// 用 Range 请求 2 个字节，返回 206 说明服务器支持分段
  Future<bool> testRange(String rel) async {
    try {
      final resp = await _dio.get<List<int>>(
        urlFor(rel),
        options: Options(
          headers: {'Range': 'bytes=0-1'},
          responseType: ResponseType.bytes,
          validateStatus: (s) => true,
        ),
      );
      return resp.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// 断点下载：已下载部分会继续，支持取消
  Future<void> download(String rel, String savePath, {CancelToken? cancelToken, void Function(int, int)? onProgress}) async {
    try {
      final dir = Directory(savePath.substring(0, savePath.lastIndexOf(Platform.pathSeparator)));
      if (!await dir.exists()) await dir.create(recursive: true);
      await _dio.download(
        urlFor(rel),
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        deleteOnError: true,
      );
    } on DioException catch (e) {
      throw _friendly(e);
    }
  }

  // ---------------------------------------------------------------- 错误人话化

  DavException _friendly(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return DavException('连接超时：服务器没响应，检查地址和端口是否正确、手机和服务器是否在同一网络');
      case DioExceptionType.connectionError:
        return DavException('连不上服务器：${e.message ?? ''}\n（检查地址、端口、是否开了 https）');
      case DioExceptionType.badCertificate:
        return DavException('HTTPS 证书不被信任：自建服务器的证书问题，可改用 http 或导入证书');
      default:
        return DavException('网络错误：${e.message ?? e.type.toString()}');
    }
  }
}

/// 标准目录常量（避免循环依赖，单独放一份）
class AppDirsConst {
  static const List<String> fixedDirs = ['notes', 'media', 'quiz', 'tools', 'download', 'backup'];
}
