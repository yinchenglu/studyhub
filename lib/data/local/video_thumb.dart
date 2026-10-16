import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 视频缩略图缓存（v1.9.0+30 新增）
///
/// 需求：视频列表 / 平铺里每个视频都要有自己的封面画面，而不是清一色的
/// 「▶ 占位图标」。
///
/// 三层设计，缺一层都不行：
///
///   1. **原生抽帧** —— 走 `studyhub/thumb` 通道，Kotlin 侧用 Android 自带的
///      `MediaMetadataRetriever`。它能**直接吃 http(s) 地址 + 请求头**，
///      正好带上 WebDAV 的 Basic Auth，不用先把整个视频下到本地再抽。
///      （Dart 侧没有纯 Dart 的 mp4 解码器；引第三方插件又要赌它跟
///       Flutter 3.47.6 / compileSdk 35 的兼容性 —— 这个项目历次翻车
///       全在依赖上，能不加就不加。）
///
///   2. **磁盘缓存** —— 本类。抽一帧要发一次网络请求 + 解码，很贵；
///      抽完落成 `<应用支持目录>/vidthumb/<md5>.jpg`，第二次进同一个
///      目录直接读文件，一行网络请求都不发。
///
///   3. **内存去重**（`_inflight` / `_done` / `_failed`）—— 列表滚动时
///      `itemBuilder` 会对同一个格子反复构造，没有去重就会对同一个视频
///      发起 N 次抽帧请求。这是整个设计里最容易被忽略、但最影响性能的一层。
///
/// **失败一律静默降级**成「没有封面」：抽帧失败的原因太多了（老容器
/// mkv / rmvb、服务器不支持 Range 请求、网络抖动、编码不支持……），
/// 任何一个都不该让视频列表变慢或报错。
class VideoThumbCache {
  VideoThumbCache._();

  /// 全局单例。缩略图是「按服务器路径」唯一确定的，没有多账号隔离的必要
  /// （路径里已经带了账号的根目录前缀）。
  static final VideoThumbCache instance = VideoThumbCache._();

  static const MethodChannel _channel = MethodChannel('studyhub/thumb');

  /// 同时最多抽几个。
  ///
  /// 视频列表一屏可能十几个视频，不限并发会把「网络 + 解码」同时拉满，
  /// 结果列表本身滚动也跟着卡。2 是个体感上「几乎立刻有封面」又不会
  /// 抢资源的档位。
  static const int _maxConcurrent = 2;

  /// 封面宽度（像素）。列表里最大也就 200 逻辑像素（双指放到最大），
  /// 320 已经够清晰，再大只是白占磁盘。
  static const int thumbWidth = 320;

  Directory? _dir;
  bool _dirFailed = false;

  /// 正在抽的（去重用）。完成后会被移到 `_done` 或 `_failed`。
  final Map<String, Future<File?>> _inflight = <String, Future<File?>>{};

  /// 已经抽好、能直接用的（服务器路径 → 本地文件）。
  final Map<String, File> _done = <String, File>{};

  /// 确认抽不出来的（去重用）。
  ///
  /// **必须记下来**：不然每次 rebuild（滚动一下就是几十次）都会对同一个
  /// 「抽不出来」的视频再发一次请求 —— 白费流量、白卡顿，而且因为
  /// MediaMetadataRetriever 失败往往要等超时，拖慢的是整个列表。
  final Set<String> _failed = <String>{};

  /// 当前并发数
  int _running = 0;

  /// 同步拿已经缓存好的缩略图，拿不到返回 null。
  ///
  /// 专门给 `build()` 用 —— build 里不能 await。
  File? peek(String videoPath) => _done[videoPath];

  /// 这个视频是不是已经确定抽不出来了（UI 可以据此不再显示 loading）。
  bool isFailed(String videoPath) => _failed.contains(videoPath);

  Future<Directory?> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    if (_dirFailed) return null;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}vidthumb');
      if (!await d.exists()) await d.create(recursive: true);
      return _dir = d;
    } catch (_) {
      // 拿不到目录就彻底放弃缩略图 —— 总比每次进来都试一遍再抛异常强
      _dirFailed = true;
      return null;
    }
  }

  /// 服务器路径 → 文件名。
  ///
  /// 直接用路径当文件名不行：里面有 `/`、有中文、可能还有 `%` 转义，
  /// 在 Android 上会直接创建失败。md5 一下就都是安全字符了，
  /// 而且天然定长、不会撞「文件名过长」。
  String _fileName(String videoPath) =>
      '${md5.convert(utf8.encode(videoPath)).toString()}.jpg';

  /// 取某个视频的封面。
  ///
  /// **幂等**：同一个 [videoPath] 重复调用只会真正抽一次帧，其余的都拿到
  /// 同一个 Future。所以可以在 `itemBuilder` 里放心地每帧调用。
  ///
  /// [url] 是带鉴权的完整地址（`WebDavClient.urlFor` 的结果），
  /// [headers] 是 WebDAV 的 Basic Auth 头。
  Future<File?> get(
    String videoPath,
    String url,
    Map<String, String> headers,
  ) {
    final done = _done[videoPath];
    if (done != null) return Future<File?>.value(done);
    if (_failed.contains(videoPath)) return Future<File?>.value();
    final running = _inflight[videoPath];
    if (running != null) return running;

    final task = _run(videoPath, url, headers);
    _inflight[videoPath] = task;
    return task;
  }

  Future<File?> _run(
    String videoPath,
    String url,
    Map<String, String> headers,
  ) async {
    try {
      final dir = await _ensureDir();
      if (dir == null) {
        _failed.add(videoPath);
        return null;
      }

      // 先看磁盘 —— 装 App 之后第一次进这个目录，或者上次抽过但被
      // 内存清掉了（切后台回来），都能直接命中。
      final f = File('${dir.path}${Platform.pathSeparator}${_fileName(videoPath)}');
      try {
        if (await f.exists() && await f.length() > 0) {
          _done[videoPath] = f;
          return f;
        }
      } catch (_) {
        // 文件系统抽风就往下走，重新抽一次
      }

      await _acquire();
      Uint8List? bytes;
      try {
        bytes = await _channel.invokeMethod<Uint8List>('videoThumb', <String, Object>{
          'url': url,
          'headers': headers,
          'timeMs': 0, // 0 = 让原生侧自己取「时长的 10%」，避开片头黑场
          'maxWidth': thumbWidth,
        });
      } on MissingPluginException {
        // 理论上不会发生（原生就在同一个 App 里），但真撞上说明这台机器
        // 上原生通道没注册，直接把整个功能关掉，别每次重试
        _dirFailed = true;
        _failed.add(videoPath);
        return null;
      } finally {
        _release();
      }

      if (bytes == null || bytes.isEmpty) {
        _failed.add(videoPath);
        return null;
      }

      // 先写临时文件再 rename —— 直接写目标文件的话，写到一半被打断
      // （用户退出页面 / 进程被杀）会留下一个 0 字节的坏文件，
      // 下次进来 `length() > 0` 判定不通过还得重抽，白白多一次网络请求。
      final tmp = File('${f.path}.tmp');
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        if (await f.exists()) await f.delete();
        await tmp.rename(f.path);
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        _failed.add(videoPath);
        return null;
      }

      _done[videoPath] = f;
      return f;
    } catch (_) {
      // 抽不出来就当没有封面，绝不打扰用户
      _failed.add(videoPath);
      return null;
    } finally {
      _inflight.remove(videoPath);
    }
  }

  Future<void> _acquire() async {
    while (_running >= _maxConcurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _running++;
  }

  void _release() {
    if (_running > 0) _running--;
  }

  /// 允许重新尝试之前失败的视频。
  ///
  /// 为什么要这个：一次网络抖动就会把某个视频永久标记成「抽不出来」，
  /// 之后不管网络好了多少次都不再试。挂在「下拉刷新 / 点刷新」上，
  /// 用户主动刷新时才给它一次机会 —— 既不会自己反复重试烧流量，
  /// 又不至于让人只能靠重启 App 恢复。
  void allowRetry() {
    _failed.clear();
  }

  /// 清空全部封面（内存 + 磁盘）。
  ///
  /// 给设置页的「一键清理缓存」用 —— 封面是纯缓存，删了下次进目录会
  /// 重新抽，不影响任何数据。
  Future<void> clear() async {
    _inflight.clear();
    _done.clear();
    _failed.clear();
    final dir = _dir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _dir = null;
    _dirFailed = false;
  }

  /// 只清内存（不删磁盘）。切账号 / 注销时用得到。
  void clearMemory() {
    _inflight.clear();
    _done.clear();
    _failed.clear();
  }
}
