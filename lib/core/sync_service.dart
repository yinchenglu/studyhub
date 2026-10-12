import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/dav/webdav_client.dart';
import '../data/models/models.dart';
import '../data/local/settings_store.dart';
import 'constants.dart';

/// 文件夹同步（v1.5.0 用户第 1 条第 ⑷ 项）。
///
/// 用户的原话是「把本地某个文件夹与服务器文件夹内容同步，只要学聚 App 后台一直运行，
/// 开关打开后就每几分钟识别一次，直至同步完成」。所以这里做的是：
///   * 一个常驻的 Timer（挂在单例上，跟页面没关系，切页/退到后台都继续跑）
///   * 每轮：列本地 → 列服务器 → 按「大小 + 修改时间」比对 → 传需要传的
///   * 一轮里只要有动静就记日志；两边一致时标「已同步」，下个周期接着看
///
/// 三个必须说清的边界（UI 里也写了）：
///   1. App 被系统彻底杀掉后 Timer 不会自己醒 —— 真要常驻得写前台服务。
///      回到 App 会自动接着跑，配置也还在。
///   2. 双向模式下冲突以「修改时间新的赢」。两边同时改同一个文件时，
///      旧的那份会被覆盖（会被写进日志，不会闷声干掉）。
///   3. 「删掉对端多出来的文件」默认关闭，而且只在单向模式下生效 ——
///      双向模式下谁该删谁本来就说不清，宁可留着让用户自己看。
enum SyncDirection { both, up, down }

String syncDirectionName(SyncDirection d) {
  switch (d) {
    case SyncDirection.both:
      return '双向（两边互补）';
    case SyncDirection.up:
      return '只上传（本地 → 服务器）';
    case SyncDirection.down:
      return '只下载（服务器 → 本地）';
  }
}

SyncDirection syncDirectionOf(int v) {
  switch (v) {
    case 1:
      return SyncDirection.up;
    case 2:
      return SyncDirection.down;
    default:
      return SyncDirection.both;
  }
}

class SyncConfig {
  final bool enabled;
  final String localDir;
  final String remoteDir;
  final SyncDirection direction;
  final int intervalMin;
  final bool deleteExtra;

  const SyncConfig({
    this.enabled = false,
    this.localDir = '',
    this.remoteDir = '',
    this.direction = SyncDirection.both,
    this.intervalMin = Defaults.syncIntervalMin,
    this.deleteExtra = false,
  });

  bool get usable => localDir.trim().isNotEmpty && remoteDir.trim().isNotEmpty;

  SyncConfig copy({
    bool? enabled,
    String? localDir,
    String? remoteDir,
    SyncDirection? direction,
    int? intervalMin,
    bool? deleteExtra,
  }) =>
      SyncConfig(
        enabled: enabled ?? this.enabled,
        localDir: localDir ?? this.localDir,
        remoteDir: remoteDir ?? this.remoteDir,
        direction: direction ?? this.direction,
        intervalMin: intervalMin ?? this.intervalMin,
        deleteExtra: deleteExtra ?? this.deleteExtra,
      );
}

class SyncState {
  final bool busy;
  final String phase;
  final int localCount;
  final int remoteCount;
  final int uploaded;
  final int downloaded;
  final int deleted;
  final int failed;
  final DateTime? lastRun;
  final String? error;
  final List<String> log;

  const SyncState({
    this.busy = false,
    this.phase = '还没跑过',
    this.localCount = 0,
    this.remoteCount = 0,
    this.uploaded = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.failed = 0,
    this.lastRun,
    this.error,
    this.log = const [],
  });

  bool get changedThisRun => uploaded + downloaded + deleted > 0;

  SyncState copy({
    bool? busy,
    String? phase,
    int? localCount,
    int? remoteCount,
    int? uploaded,
    int? downloaded,
    int? deleted,
    int? failed,
    DateTime? lastRun,
    String? error,
    bool clearError = false,
    List<String>? log,
  }) =>
      SyncState(
        busy: busy ?? this.busy,
        phase: phase ?? this.phase,
        localCount: localCount ?? this.localCount,
        remoteCount: remoteCount ?? this.remoteCount,
        uploaded: uploaded ?? this.uploaded,
        downloaded: downloaded ?? this.downloaded,
        deleted: deleted ?? this.deleted,
        failed: failed ?? this.failed,
        lastRun: lastRun ?? this.lastRun,
        error: clearError ? null : (error ?? this.error),
        log: log ?? this.log,
      );
}

/// 一个文件的同步元信息
class _Meta {
  final int size;
  final DateTime? mtime;

  const _Meta(this.size, this.mtime);
}

/// 修改时间最多差这么多秒就算「同一份」（HTTP 日期没有毫秒，
/// 有些服务器还会把秒抹掉，容差给太小会每轮都重传一遍）。
const int _mtimeSlackSec = 3;

const int _maxLog = 60;

class SyncService extends ChangeNotifier {
  SyncService._();

  static final SyncService instance = SyncService._();

  WebDavClient? _client;
  SyncConfig _cfg = const SyncConfig();
  SyncState _state = const SyncState();
  Timer? _timer;
  bool _busy = false;
  bool _booted = false;

  SyncConfig get config => _cfg;
  SyncState get state => _state;
  bool get busy => _busy;

  /// 启动时读一次配置；上次是开着的话直接把 Timer 接上
  Future<void> boot() async {
    if (_booted) return;
    _booted = true;
    final s = SettingsStore.instance;
    _cfg = SyncConfig(
      enabled: await s.syncOn(),
      localDir: await s.syncLocalDir(),
      remoteDir: await s.syncRemoteDir(),
      direction: syncDirectionOf(await s.syncDirection()),
      intervalMin: await s.syncIntervalMin(),
      deleteExtra: await s.syncDeleteExtra(),
    );
    notifyListeners();
    if (_cfg.enabled && _cfg.usable) _arm();
  }

  /// 账号变化时调用（登录 / 切换服务器）
  void attach(WebDavClient? client) {
    if (identical(_client, client)) return;
    _client = client;
  }

  void _emit(SyncState st) {
    _state = st;
    notifyListeners();
  }

  void clearLog() {
    _emit(_state.copy(log: const []));
  }

  void _log(String line) {
    final t = DateTime.now();
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    final next = <String>['$stamp  $line', ..._state.log];
    _state = _state.copy(log: next.length > _maxLog ? next.sublist(0, _maxLog) : next);
  }

  // ---------------------------------------------------------------- 配置

  Future<void> saveConfig(SyncConfig c) async {
    final s = SettingsStore.instance;
    await s.setSyncOn(c.enabled);
    await s.setSyncLocalDir(c.localDir);
    await s.setSyncRemoteDir(c.remoteDir);
    await s.setSyncDirection(c.direction.index);
    await s.setSyncIntervalMin(c.intervalMin);
    await s.setSyncDeleteExtra(c.deleteExtra);
    final old = _cfg;
    _cfg = c;
    notifyListeners();
    if (!c.enabled) {
      _disarm();
    } else if (!old.usable || old.intervalMin != c.intervalMin) {
      _arm();
    } else if (_timer == null) {
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    final min = _cfg.intervalMin <= 0 ? 5 : _cfg.intervalMin;
    _timer = Timer.periodic(Duration(minutes: min), (_) => runOnce());
    _log('已开启：每 $min 分钟对比一次（${syncDirectionName(_cfg.direction)}）');
    notifyListeners();
    // 开开关后立刻先跑一轮，不然要干等一个周期
    Timer(const Duration(milliseconds: 400), () => runOnce());
  }

  void _disarm() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _log('已关闭自动同步');
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    await saveConfig(_cfg.copy(enabled: on));
    if (on) {
      _log('开关已打开');
      _emit(_state.copy(phase: '等下一轮…', clearError: true));
    } else {
      _emit(_state.copy(phase: '已停止'));
    }
  }

  // ---------------------------------------------------------------- 主流程

  Future<void> runOnce() async {
    if (_busy) return;
    final c = _client;
    if (c == null) {
      _emit(_state.copy(error: '还没连上服务器，同步需要先登录', phase: '跳过'));
      return;
    }
    if (!_cfg.usable) {
      _emit(_state.copy(error: '本地目录或服务器目录还没填', phase: '跳过'));
      return;
    }

    final localRoot = Directory(_cfg.localDir);
    if (!await localRoot.exists()) {
      _emit(_state.copy(error: '本地目录不存在：${_cfg.localDir}', phase: '跳过'));
      return;
    }

    _busy = true;
    _emit(_state.copy(
      busy: true,
      phase: '正在列本地文件…',
      uploaded: 0,
      downloaded: 0,
      deleted: 0,
      failed: 0,
      clearError: true,
    ));

    try {
      final local = await _scanLocal(localRoot);
      _emit(_state.copy(localCount: local.length, phase: '正在列服务器文件…'));

      final remote = await _listRemoteAll(c, _cfg.remoteDir);
      _emit(_state.copy(remoteCount: remote.length, phase: '正在比对…'));

      final d = _cfg.direction;
      final mayUp = d == SyncDirection.both || d == SyncDirection.up;
      final mayDown = d == SyncDirection.both || d == SyncDirection.down;

      final keys = <String>{...local.keys, ...remote.keys};
      final sorted = keys.toList()..sort();

      var done = 0;
      for (final rel in sorted) {
        final l = local[rel];
        final r = remote[rel];
        final remoteRel = _joinRemote(_cfg.remoteDir, rel);

        if (l == null && r != null) {
          // 服务器上有、本地没有
          if (mayDown) {
            if (await _download(c, remoteRel, _localTarget(localRoot, rel), r)) {
              _emit(_state.copy(downloaded: _state.downloaded + 1));
              _log('↓ $rel');
            } else {
              _emit(_state.copy(failed: _state.failed + 1));
            }
          } else if (_cfg.deleteExtra && d == SyncDirection.up) {
            if (await _deleteRemote(c, remoteRel)) {
              _emit(_state.copy(deleted: _state.deleted + 1));
              _log('服务器删除（本地没有）$rel');
            } else {
              _emit(_state.copy(failed: _state.failed + 1));
            }
          }
        } else if (l != null && r == null) {
          // 本地有、服务器没有
          if (mayUp) {
            if (await _upload(c, remoteRel, _localTarget(localRoot, rel), l)) {
              _emit(_state.copy(uploaded: _state.uploaded + 1));
              _log('↑ $rel');
            } else {
              _emit(_state.copy(failed: _state.failed + 1));
            }
          } else if (_cfg.deleteExtra && d == SyncDirection.down) {
            final f = _localTarget(localRoot, rel);
            try {
              if (await f.exists()) await f.delete();
              _emit(_state.copy(deleted: _state.deleted + 1));
              _log('本地删除（服务器没有）$rel');
            } catch (e) {
              _emit(_state.copy(failed: _state.failed + 1));
              _log('删不掉 $rel：$e');
            }
          }
        } else if (l != null && r != null) {
          // 两边都有：先看大小，再看修改时间
          if (l.size == r.size && _sameTime(l.mtime, r.mtime)) continue;
          final lNewer = _isNewer(l.mtime, r.mtime);
          if (lNewer && mayUp) {
            if (await _upload(c, remoteRel, _localTarget(localRoot, rel), l)) {
              _emit(_state.copy(uploaded: _state.uploaded + 1));
              _log('↑ $rel（本地较新）');
            } else {
              _emit(_state.copy(failed: _state.failed + 1));
            }
          } else if (!lNewer && mayDown) {
            if (await _download(c, remoteRel, _localTarget(localRoot, rel), r)) {
              _emit(_state.copy(downloaded: _state.downloaded + 1));
              _log('↓ $rel（服务器较新）');
            } else {
              _emit(_state.copy(failed: _state.failed + 1));
            }
          }
        }
        done++;
        if (done % 20 == 0) {
          _emit(_state.copy(phase: '处理中 $done/${sorted.length}…'));
        }
      }

      final st = _state;
      final n = st.uploaded + st.downloaded + st.deleted;
      final tail = st.failed > 0 ? '，失败 ${st.failed} 个' : '';
      _emit(_state.copy(
        busy: false,
        lastRun: DateTime.now(),
        phase: n == 0 ? '已同步 · 两边一致$tail' : '本轮动了 $n 个文件$tail',
      ));
      _log(n == 0 ? '本轮无变化（本地 ${local.length} / 服务器 ${remote.length}）' : '本轮结束：↑${st.uploaded} ↓${st.downloaded} 删${st.deleted}$tail');
    } catch (e) {
      _emit(_state.copy(busy: false, phase: '出错停了', error: _msg(e), lastRun: DateTime.now()));
      _log('出错：${_msg(e)}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  String _msg(Object e) {
    var s = e.toString();
    if (s.startsWith('Exception: ')) s = s.substring(11);
    if (s.startsWith('Bad state: ')) s = s.substring(11);
    return s;
  }

  bool _sameTime(DateTime? a, DateTime? b) {
    if (a == null || b == null) return true;
    return a.difference(b).inSeconds.abs() <= _mtimeSlackSec;
  }

  bool _isNewer(DateTime? a, DateTime? b) {
    if (a == null) return false;
    if (b == null) return true;
    return a.isAfter(b.add(const Duration(seconds: _mtimeSlackSec)));
  }

  // ---------------------------------------------------------------- 本地

  Future<Map<String, _Meta>> _scanLocal(Directory root) async {
    final out = <String, _Meta>{};
    final rootPath = root.absolute.path;
    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.uri.pathSegments.isEmpty ? '' : ent.uri.pathSegments.last;
      if (name.startsWith('.')) continue; // 跳过隐藏文件 / 临时文件
      var rel = ent.path;
      if (rel.startsWith(rootPath)) {
        rel = rel.substring(rootPath.length);
      }
      rel = rel.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
      if (rel.isEmpty) continue;
      try {
        final st = await ent.stat();
        out[rel] = _Meta(st.size, st.modified);
      } catch (_) {
        // 读不到就跳过这一个，不打断整轮
      }
    }
    return out;
  }

  File _localTarget(Directory root, String rel) {
    var r = rel.replaceAll('\\', '/');
    final segs = r.split('/').where((e) => e.isNotEmpty && e != '.' && e != '..');
    return File('${root.absolute.path}${Platform.pathSeparator}${segs.join(Platform.pathSeparator)}');
  }

  // ---------------------------------------------------------------- 服务器

  /// 服务器端的完整相对路径（资料根目录之下）
  String _joinRemote(String dir, String rel) {
    var d = dir.trim();
    while (d.startsWith('/')) {
      d = d.substring(1);
    }
    while (d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    return d.isEmpty ? rel : '$d/$rel';
  }

  String _relOf(String path, String root) {
    var r = root.trim();
    while (r.startsWith('/')) {
      r = r.substring(1);
    }
    while (r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    var p = path;
    if (r.isNotEmpty) {
      if (!p.startsWith('$r/')) return '';
      p = p.substring(r.length + 1);
    }
    return p;
  }

  Future<Map<String, _Meta>> _listRemoteAll(WebDavClient c, String root) async {
    final out = <String, _Meta>{};
    List<DavEntry> first;
    try {
      first = await c.list(root, depth: -1);
    } catch (_) {
      first = const [];
    }
    // 服务器认 Depth: infinity 的话，一次就拿到全部（chfs / Nextcloud 都认）
    final recursive = first.any((e) => _relOf(e.path, root).contains('/'));
    if (recursive) {
      for (final e in first) {
        if (e.isDir) continue;
        final rel = _relOf(e.path, root);
        if (rel.isEmpty || rel.split('/').last.startsWith('.')) continue;
        out[rel] = _Meta(e.size, e.modified);
      }
      return out;
    }

    // 不认的话（有些服务器只给直接子项）自己一层层问
    final queue = <String>[root];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      if (!seen.add(dir)) continue;
      List<DavEntry> entries;
      try {
        entries = dir.isEmpty ? first : await c.list(dir, depth: 1);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        final rel = _relOf(e.path, root);
        if (rel.isEmpty) continue;
        if (e.isDir) {
          if (!seen.contains(e.path)) queue.add(e.path);
          continue;
        }
        if (rel.split('/').last.startsWith('.')) continue;
        out[rel] = _Meta(e.size, e.modified);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 传输

  Future<bool> _upload(WebDavClient c, String remoteRel, File local, _Meta l) async {
    try {
      if (!await local.exists()) return false;
      await c.writeFileStream(remoteRel, local);
      return true;
    } catch (e) {
      _log('上传失败 $remoteRel：${_msg(e)}');
      return false;
    }
  }

  Future<bool> _download(WebDavClient c, String remoteRel, File target, _Meta r) async {
    try {
      final parent = target.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await c.download(remoteRel, target.path);
      return true;
    } catch (e) {
      _log('下载失败 $remoteRel：${_msg(e)}');
      return false;
    }
  }

  Future<bool> _deleteRemote(WebDavClient c, String remoteRel) async {
    try {
      await c.delete(remoteRel);
      return true;
    } catch (e) {
      _log('删除失败 $remoteRel：${_msg(e)}');
      return false;
    }
  }
}
