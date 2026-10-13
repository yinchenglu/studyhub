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
/// 应用私有目录 `文档/recordings/`。故意**不**直接写系统「下载」目录：
///   * 前台服务运行在 App 进程里，写公共目录要「所有文件访问权限」，
///     而那个权限在录音这个场景里要额外弹窗、用户很容易懵；
///   * 私有目录一定能写，服务启动时不用先申请权限，
///     少一步就少一处「点开始没反应」的可能。
/// 需要拿出来的话，页面上有「导出到下载目录」和「分享」两条路。
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
  /// v1.6.0：可以在设置里指定一个自定义目录（见「设置 → 录音录像保存位置」）。
  /// 自定目录建不出来（路径没权限、外置卡拔了）就**静默退回**应用私有目录 ——
  /// 录音这种「点一下就该开始」的东西，不能因为目录问题直接失败。
  static Future<Directory> outputDir() async {
    final custom = await SettingsStore.instance.recorderDirPath();
    if (custom != null && custom.isNotEmpty) {
      try {
        final dir = Directory(custom);
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      } catch (_) {
        // 落回默认目录
      }
    }
    return defaultDir();
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
  static Future<List<File>> listAll() async {
    try {
      final dir = await outputDir();
      final out = <File>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.startsWith('录音_') && !name.startsWith('录像_')) continue;
        out.add(e);
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
    } catch (_) {
      return const <File>[];
    }
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
