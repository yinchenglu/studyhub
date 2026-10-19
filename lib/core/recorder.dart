import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/local/settings_store.dart';

/// 录音服务的当前状态。对应 `MainActivity.kt` 里 `status` 方法返回的那个 map。
class RecorderStatus {
  /// 服务是不是在录。
  final bool running;

  /// 已经录了多久（毫秒）。没在录时是 0。
  ///
  /// 这个数由**原生侧**算（`System.currentTimeMillis() - startedAt`），
  /// 不是 Dart 侧自己数秒。原因：录音过程中 App 可能被系统冻结、
  /// Flutter 引擎可能暂停，Dart 的 `Timer` 会停；而原生服务在跑前台通知，
  /// 时间一直在走。两边对不上时，用户看到的是 UI 数字比实际短。
  final int elapsedMs;

  /// 上一次启动失败的原始错误（原生 `MediaRecorder` 抛出来的 message）。
  ///
  /// 为什么要传这个而不是让原生直接抛给 Dart：
  ///   录音是「点一下就开始跑」的东西，失败发生在**服务线程**里，
  ///   而 `start()` 那次 MethodChannel 调用早就返回 true 了。
  ///   只能靠轮询 status 时把这个字段带回来，界面上再提示用户。
  final String? error;

  const RecorderStatus({this.running = false, this.elapsedMs = 0, this.error});

  bool get hasError => error != null && error!.isNotEmpty;
}

/// 后台录音的 Dart 侧封装。
///
/// 通道名与 `MainActivity.kt` 的 `RECORDER_CHANNEL` 必须一致：`studyhub/recorder`。
///
/// ── 为什么录音要跑到原生服务里 ──────────────────────────
/// Flutter 侧没有「后台服务」这个概念。`record` 之类的包都是在前台跑：
/// 一旦 App 切到后台或息屏，Android 会冻结 Dart isolate，录音就断了。
/// 真正能「息屏继续录」的只有一条路 —— 原生 `Service` +
/// `startForeground()` + `foregroundServiceType="microphone"`。
/// 服务详情见 `MainActivity.kt` 里的 `RecorderService`。
///
/// ── 文件落在哪儿 ────────────────────────────────────────
/// v2.2.0 起默认改成手机「下载」目录的 `Download/StudyHub/录音录像/`：
/// 用户点名要直接在文件管理器里看到录音录像，不想再走「导出」一步。
/// 写公共目录需要「所有文件访问」权限 —— 没给权限时**静默退回**
/// 应用私有目录 `文档/recordings/`，保证「点开始就录上」永远成立。
/// v1.6.0 起也可以在页面上改成别的文件夹（自定义目录优先级最高）。
/// 列表会把私有目录里的历史文件一起列出来，旧录音不会「消失」。
///
/// 本类**不抛异常**给调用方（除了明确要感知失败的 [start]）：
/// 录音这件事失败的原因往往是环境（麦克风被别的应用占着），
/// 让工具页照常显示并给出提示，比整页崩掉有用。
class AudioRecorder {
  AudioRecorder._();

  /// 与 `MainActivity.kt` 的 `RECORDER_CHANNEL` 必须逐字一致。
  static const MethodChannel _ch = MethodChannel('studyhub/recorder');

  /// 录音文件所在的子目录名（相对应用文档目录）。
  static const String folderName = 'recordings';

  /// 录音 / 录像输出目录，不存在就建。
  ///
  /// v2.2.2：**跟「设置 → 下载目录」保持一致**。用户在设置里把下载目录
  /// 改到哪，录音录像就跟着存到哪；没设置过就是默认的 `Download/StudyHub`。
  /// 写不进去（没有「所有文件访问」权限）再静默退回应用私有目录 ——
  /// 录音这种「点一下就该开始」的东西，不能因为目录问题直接失败。
  static Future<Directory> outputDir() async {
    final pub = await publicDir();
    if (pub != null) return pub;
    return defaultDir();
  }

  /// 公共目录：**设置里的「下载目录」**（没设置过就是 `Download/StudyHub`）。
  ///
  /// 写得了就返回目录，写不了返回 null。判定方式是真的试写一个小探针
  /// 文件再删掉 —— 权限状态光问 permission_handler 在一些 ROM 上不准，
  /// 写一次最踏实。结果缓存在本会话内（[_publicCache]），
  /// 设置改了 / 权限中途变了用 [recheck] 强制重验。
  static Directory? _publicCache;

  static Future<Directory?> publicDir({bool recheck = false}) async {
    if (!Platform.isAndroid) return null;
    if (!recheck && _publicCache != null) return _publicCache;
    Directory? out;
    try {
      // ① 设置里指定的下载目录
      var target = (await SettingsStore.instance.downloadDirPath())?.trim() ?? '';
      if (target.isEmpty) {
        // ② 没设置过：跟 CacheManager.defaultDownloadPath() 同一个位置
        var root = '';
        final base = await getExternalStorageDirectory();
        if (base != null) {
          // path_provider 给的是 …/Android/data/包名/files，截掉 /Android/
          const mark = '/Android/';
          final i = base.path.indexOf(mark);
          root = i > 0 ? base.path.substring(0, i) : base.path;
        }
        if (root.isEmpty) root = '/storage/emulated/0';
        target = p.join(root, 'Download', 'StudyHub');
      }
      final d = Directory(target);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File(p.join(d.path, '.studyhub_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      out = d;
    } catch (_) {
      out = null;
    }
    _publicCache = out;
    return out;
  }

  /// 设置里改了下载目录之后调用，下次重新解析（缓存里可能是旧路径）。
  static void resetDirCache() => _publicCache = null;

  /// v2.2.0/2.2.1 的旧位置（`Download/StudyHub/录音录像`）。
  ///
  /// 这两个版本装过的用户，录音留在这里；列表要一起扫，
  /// 不能让「升级一下录音都不见了」。
  static Future<Directory?> legacyDir() async {
    if (!Platform.isAndroid) return null;
    try {
      var root = '';
      final base = await getExternalStorageDirectory();
      if (base != null) {
        const mark = '/Android/';
        final i = base.path.indexOf(mark);
        root = i > 0 ? base.path.substring(0, i) : base.path;
      }
      if (root.isEmpty) root = '/storage/emulated/0';
      final d = Directory(p.join(root, 'Download', 'StudyHub', '录音录像'));
      return await d.exists() ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// 应用私有目录下的默认输出目录 `文档/recordings/`。
  ///
  /// 单独留一个公开方法，是为了让设置页 / 工具页能把这个路径显示给用户看
  /// （「当前保存到哪」这件事必须写清楚，否则用户根本不知道文件去哪了）。
  static Future<Directory> defaultDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, folderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 给一个还没被占用的文件名。
  ///
  /// 为什么要在**启动之前**就把路径定下来：`MediaRecorder` 需要一个
  /// 完整路径（它是原生直接在写文件），不能等录完再取名。
  /// 名字用「录音_年月日_时分秒」，同一秒内重复（连点两下）就加 `_2`、`_3`。
  ///
  /// [prefix] 用中文（录音 / 录像），[ext] 带点（`.m4a` / `.mp4`）。
  static Future<File> nextFile({
    String prefix = '录音',
    String ext = '.m4a',
    DateTime? at,
  }) async {
    final dir = await outputDir();
    final t = at ?? DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    final base = '${prefix}_${t.year}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var f = File(p.join(dir.path, '$base$ext'));
    var n = 1;
    while (await f.exists()) {
      n++;
      f = File(p.join(dir.path, '${base}_$n$ext'));
    }
    return f;
  }

  /// 开始后台录音。[file] 必须是 [nextFile] 给的那个（路径由原生写）。
  ///
  /// [maxDurationMs] 是「最长录多久」，0 = 不限。
  /// 计时和收尾都在**原生服务**里做（见 MainActivity.kt 的 scheduleAutoStop）——
  /// Dart 的 Timer 在 App 被冻结之后是停的，拿它来限时会直接失控。
  ///
  /// 这里会**真的**把异常抛出去（唯一一个这么做的接口）：
  /// 如果连服务都拉不起来（比如 manifest 里忘了声明、或系统拒绝了
  /// 前台服务），用户必须立刻知道，不能傻等一个永远不涨的计时器。
  static Future<void> start(File file, {int maxDurationMs = 0}) async {
    await _ch.invokeMethod<bool>('start', <String, Object?>{
      'path': file.path,
      'maxDurationMs': maxDurationMs,
    });
  }

  /// 停止录音并收尾（原生侧会 `stop()` + `release()` 并撤掉前台通知）。
  static Future<void> stop() async {
    await _ch.invokeMethod<bool>('stop');
  }

  /// 查一次状态。任何异常都吞掉并返回「没在录」——
  /// 这个方法每秒被调一次，出错刷屏没有意义。
  static Future<RecorderStatus> status() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('status');
      if (r == null) return const RecorderStatus();
      final ms = r['elapsedMs'];
      final err = r['error'];
      return RecorderStatus(
        running: r['running'] == true,
        elapsedMs: ms is num ? ms.toInt() : 0,
        error: err is String ? err : null,
      );
    } catch (_) {
      return const RecorderStatus();
    }
  }

  /// 目录里已有的录音 / 录像，按修改时间从新到旧。
  ///
  /// 只认 `录音_*` 和 `录像_*` 两个前缀，避免把用户手动丢进来的
  /// 其它音频也算成「我录的」。
  ///
  /// v2.2.0：默认目录从私有挪到了「下载」，但私有目录里的历史文件
  /// 不能就此看不见 —— 这里把当前目录和私有目录**都扫一遍**、按路径
  /// 去重后合并，旧录音照样能播、能删。v2.2.2 又把默认位置从
  /// `下载/StudyHub/录音录像` 改成跟「设置里的下载目录」一致，
  /// 所以旧子目录也要一起扫。
  static Future<List<File>> listAll() async {
    final dirs = <String>{};
    try {
      dirs.add((await outputDir()).path);
    } catch (_) {}
    try {
      dirs.add((await defaultDir()).path);
    } catch (_) {}
    try {
      final legacy = await legacyDir();
      if (legacy != null) dirs.add(legacy.path);
    } catch (_) {}

    final out = <File>[];
    final seen = <String>{};
    for (final dirPath in dirs) {
      try {
        await for (final e in Directory(dirPath).list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.startsWith('录音_') && !name.startsWith('录像_')) continue;
          if (seen.add(e.path)) out.add(e);
        }
      } catch (_) {
        // 单个目录扫不了（权限被收回之类）就跳过，别拖垮整个列表
      }
    }
    final withTime = <MapEntry<File, int>>[];
    for (final f in out) {
      try {
        withTime.add(MapEntry(f, (await f.stat()).modified.millisecondsSinceEpoch));
      } catch (_) {
        // 读不到时间就当作 0，排在最后
        withTime.add(MapEntry(f, 0));
      }
    }
    withTime.sort((a, b) => b.value.compareTo(a.value));
    return withTime.map((e) => e.key).toList();
  }

  /// 把毫秒数写成 `MM:SS` / `H:MM:SS`。
  ///
  /// 不引 `utils.dart` 的 `formatDuration`：那个是给「3 分 20 秒」这种
  /// 说明文字用的，录音计时器要的是等宽数字、到点不跳位。
  static String elapsedText(int ms) {
    final total = ms < 0 ? 0 : ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }
}
