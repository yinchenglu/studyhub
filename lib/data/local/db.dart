import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/constants.dart';
import '../models/models.dart';
import 'settings_store.dart';

/// 本地 SQLite：错题本、播放进度、收藏、媒体索引缓存
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<void> init() async {
    await db;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'studyhub.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE wrong (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bank_dir TEXT NOT NULL,
            bank_name TEXT NOT NULL,
            question_id TEXT NOT NULL,
            stem TEXT NOT NULL,
            options TEXT NOT NULL,
            answer TEXT NOT NULL,
            analysis TEXT,
            tags TEXT,
            last_choice TEXT,
            wrong_count INTEGER DEFAULT 1,
            mastered INTEGER DEFAULT 0,
            last_wrong_at INTEGER NOT NULL,
            my_note TEXT,
            qtype TEXT,
            text_accept TEXT,
            last_text TEXT,
            UNIQUE(bank_dir, question_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE progress (
            path TEXT PRIMARY KEY,
            position_ms INTEGER,
            duration_ms INTEGER,
            updated_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE media_index (
            path TEXT PRIMARY KEY,
            is_dir INTEGER,
            is_video INTEGER,
            size INTEGER,
            modified INTEGER,
            scanned_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE favorite (
            path TEXT PRIMARY KEY,
            kind TEXT,
            title TEXT,
            added_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE quiz_done (
            bank_dir TEXT NOT NULL,
            question_id TEXT NOT NULL,
            done_at INTEGER NOT NULL,
            PRIMARY KEY (bank_dir, question_id)
          )
        ''');
        await db.execute('CREATE INDEX idx_wrong_bank ON wrong(bank_dir)');
        await db.execute('CREATE INDEX idx_wrong_mastered ON wrong(mastered)');
        await db.execute('CREATE INDEX idx_quiz_done_bank ON quiz_done(bank_dir)');
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          // v1.2.0 新增：记录每套题库刷过哪些题，用来显示进度条
          await db.execute('''
            CREATE TABLE IF NOT EXISTS quiz_done (
              bank_dir TEXT NOT NULL,
              question_id TEXT NOT NULL,
              done_at INTEGER NOT NULL,
              PRIMARY KEY (bank_dir, question_id)
            )
          ''');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_quiz_done_bank ON quiz_done(bank_dir)');
        }
        if (from < 3) {
          // v1.3.0 新增：错题本要能记住原题题型和文本答案。
          // 不加这三列的话，填空题从错题本里还原出来会变成单选题
          // （旧代码靠 answer 的长度猜题型），而且手打的答案也丢了。
          for (final col in const [
            'qtype TEXT',
            'text_accept TEXT',
            'last_text TEXT',
          ]) {
            try {
              await db.execute('ALTER TABLE wrong ADD COLUMN $col');
            } catch (_) {
              // 列已经存在（重复升级 / 新装库已带这些列）时忽略
            }
          }
        }
      },
    );
  }

  // ------------------------------------------------------------ 刷题进度

  /// 标记某套题库里的某道题「刷过了」（对错都算刷过）
  Future<void> markDone(String bankDir, String questionId) async {
    if (bankDir.isEmpty || questionId.isEmpty) return;
    final d = await db;
    await d.insert(
      'quiz_done',
      {
        'bank_dir': bankDir,
        'question_id': questionId,
        'done_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markDoneBatch(Iterable<(String, String)> items) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = d.batch();
    for (final it in items) {
      if (it.$1.isEmpty || it.$2.isEmpty) continue;
      batch.insert(
        'quiz_done',
        {'bank_dir': it.$1, 'question_id': it.$2, 'done_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 单套题库已刷题数
  Future<int> doneCount(String bankDir) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS c FROM quiz_done WHERE bank_dir = ?', [bankDir]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 所有题库的已刷题数：bank_dir → 已刷数量
  Future<Map<String, int>> doneCountByBank() async {
    final d = await db;
    final rows = await d.rawQuery('SELECT bank_dir, COUNT(*) AS c FROM quiz_done GROUP BY bank_dir');
    return {for (final r in rows) r['bank_dir'].toString(): (r['c'] as int?) ?? 0};
  }

  /// 某套题库刷过的题目 id 集合（做「只练没刷过的」时用）
  Future<Set<String>> doneIds(String bankDir) async {
    final d = await db;
    final rows = await d.query('quiz_done', columns: ['question_id'], where: 'bank_dir = ?', whereArgs: [bankDir]);
    return rows.map((r) => r['question_id'].toString()).toSet();
  }

  Future<void> clearDone({String? bankDir}) async {
    final d = await db;
    if (bankDir == null) {
      await d.delete('quiz_done');
    } else {
      await d.delete('quiz_done', where: 'bank_dir = ?', whereArgs: [bankDir]);
    }
  }

  // ------------------------------------------------------------ 错题本

  /// 答错时写入：已存在就累加错误次数并刷新快照。
  ///
  /// [myText] 是填空题 / 问答题手打的答案；选择题传空串即可。
  /// [qtype] 存原题题型，否则从错题本还原时题型会丢（填空变单选）。
  Future<void> upsertWrong(Question q, List<int> myChoice, {String myText = ''}) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await d.query('wrong',
        where: 'bank_dir = ? AND question_id = ?', whereArgs: [q.bankDir, q.id], limit: 1);
    if (rows.isEmpty) {
      await d.insert('wrong', {
        'bank_dir': q.bankDir,
        'bank_name': q.bankName,
        'question_id': q.id,
        'stem': q.stem,
        'options': '${_json(q.options)}',
        'answer': '${_json(q.answer)}',
        'analysis': q.analysis,
        'tags': '${_json(q.tags)}',
        'last_choice': '${_json(myChoice)}',
        'wrong_count': 1,
        'mastered': 0,
        'last_wrong_at': now,
        'my_note': '',
        'qtype': q.type,
        'text_accept': '${_json(q.textAccept)}',
        'last_text': myText,
      });
    } else {
      final old = WrongRecord.fromMap(rows.first);
      await d.update(
        'wrong',
        {
          'wrong_count': old.wrongCount + 1,
          'mastered': 0,
          'last_choice': '${_json(myChoice)}',
          'last_wrong_at': now,
          'stem': q.stem,
          'options': '${_json(q.options)}',
          'answer': '${_json(q.answer)}',
          'analysis': q.analysis,
          'qtype': q.type,
          'text_accept': '${_json(q.textAccept)}',
          'last_text': myText,
        },
        where: 'id = ?',
        whereArgs: [old.id],
      );
    }
  }

  /// 答对时把错题标记为已掌握（从错题本视图里淡出，但仍保留记录）
  Future<void> markMastered(String bankDir, String questionId, bool mastered) async {
    final d = await db;
    await d.update('wrong', {'mastered': mastered ? 1 : 0},
        where: 'bank_dir = ? AND question_id = ?', whereArgs: [bankDir, questionId]);
  }

  Future<List<WrongRecord>> listWrong({String? bankDir, bool? mastered, List<String>? tags}) async {
    final d = await db;
    final where = <String>[];
    final args = <dynamic>[];
    if (bankDir != null) {
      where.add('bank_dir = ?');
      args.add(bankDir);
    }
    if (mastered != null) {
      where.add('mastered = ?');
      args.add(mastered ? 1 : 0);
    }
    final rows = await d.query('wrong',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'last_wrong_at DESC');
    var list = rows.map(WrongRecord.fromMap).toList();
    if (tags != null && tags.isNotEmpty) {
      list = list.where((r) => r.tags.any(tags.contains)).toList();
    }
    return list;
  }

  Future<int> wrongCount({bool? mastered}) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS c FROM wrong ${mastered == null ? '' : 'WHERE mastered = ${mastered ? 1 : 0}'}');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 按题库统计错题数量
  Future<Map<String, int>> wrongCountByBank() async {
    final d = await db;
    final rows = await d.rawQuery('SELECT bank_dir, COUNT(*) AS c FROM wrong GROUP BY bank_dir');
    return {for (final r in rows) r['bank_dir'].toString(): (r['c'] as int?) ?? 0};
  }

  /// 所有错题的标签（用于错题本按知识点分组）
  Future<List<String>> wrongTags() async {
    final list = await listWrong();
    final set = <String>{};
    for (final r in list) {
      set.addAll(r.tags);
    }
    final out = set.toList()..sort();
    return out;
  }

  Future<void> updateWrongNote(int id, String note) async {
    final d = await db;
    await d.update('wrong', {'my_note': note}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteWrong(int id) async {
    final d = await db;
    await d.delete('wrong', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearWrong() async {
    final d = await db;
    await d.delete('wrong');
  }

  // ------------------------------------------------------------ 播放进度

  Future<void> saveProgress(String path, int positionMs, int durationMs) async {
    final d = await db;
    await d.insert(
      'progress',
      {
        'path': path,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PlayProgress?> getProgress(String path) async {
    final d = await db;
    final rows = await d.query('progress', where: 'path = ?', whereArgs: [path], limit: 1);
    if (rows.isEmpty) return null;
    final m = rows.first;
    return PlayProgress(
      path: path,
      positionMs: (m['position_ms'] as int?) ?? 0,
      durationMs: (m['duration_ms'] as int?) ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch((m['updated_at'] as int?) ?? 0),
    );
  }

  /// 最近看过的视频（首页「最近浏览」用）
  Future<List<MapEntry<String, PlayProgress>>> recentPlayed({int limit = 10}) async {
    final d = await db;
    final rows = await d.query('progress', orderBy: 'updated_at DESC', limit: limit);
    return rows
        .map((m) => MapEntry(
              m['path'].toString(),
              PlayProgress(
                path: m['path'].toString(),
                positionMs: (m['position_ms'] as int?) ?? 0,
                durationMs: (m['duration_ms'] as int?) ?? 0,
                updatedAt: DateTime.fromMillisecondsSinceEpoch((m['updated_at'] as int?) ?? 0),
              ),
            ))
        .toList();
  }

  Future<void> clearProgress() async {
    final d = await db;
    await d.delete('progress');
  }

  // ------------------------------------------------------------ 媒体索引

  Future<void> replaceMediaIndex(List<Map<String, Object?>> rows) async {
    final d = await db;
    final batch = d.batch();
    batch.delete('media_index');
    for (final r in rows) {
      batch.insert('media_index', r, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<int> mediaIndexCount({bool? isVideo}) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS c FROM media_index WHERE is_dir = 0 ${isVideo == null ? '' : 'AND is_video = ${isVideo ? 1 : 0}'}');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  String _json(Object o) {
    // 轻量 JSON 编码，避免额外 import 到 dart:convert 之外的歧义
    if (o is List) {
      return '[${o.map((e) => e is num ? '$e' : '"${e.toString().replaceAll('"', '\\"')}"').join(',')}]';
    }
    return '"${o.toString()}"';
  }
}

/// 缓存管理：下载目录、占用统计、一键清理、LRU 淘汰
class CacheManager {
  CacheManager._();
  static final CacheManager instance = CacheManager._();

  Directory? _cacheDir;
  Directory? _downloadDir;

  Future<Directory> get cacheDir async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationCacheDirectory();
    _cacheDir = Directory(p.join(base.path, 'dav'));
    if (!await _cacheDir!.exists()) await _cacheDir!.create(recursive: true);
    return _cacheDir!;
  }

  /// 默认下载目录：Android 放系统「下载 / StudyHub」，其他平台放应用文档目录
  static Future<String> defaultDownloadPath() async {
    if (Platform.isAndroid) {
      try {
        final base = await getExternalStorageDirectory();
        if (base != null) {
          const mark = '/Android/';
          final i = base.path.indexOf(mark);
          final root = i > 0 ? base.path.substring(0, i) : base.path;
          return p.join(root, 'Download', Defaults.androidDownloadFolder);
        }
      } catch (_) {}
      return '/storage/emulated/0/Download/${Defaults.androidDownloadFolder}';
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, Defaults.androidDownloadFolder);
  }

  /// 应用专属目录：不需要任何权限，一定能写；缺点是文件管理器里不太好找
  static Future<String> appPrivateDownloadPath() async {
    try {
      final base = await getExternalStorageDirectory();
      if (base != null) return p.join(base.path, Defaults.androidDownloadFolder);
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, Defaults.androidDownloadFolder);
  }

  /// 用户主动下载的离线文件（和临时缓存分开，清理缓存不会删掉它）
  /// 目录可以在「设置 → 下载目录」里改
  Future<Directory> get downloadDir async {
    if (_downloadDir != null) return _downloadDir!;
    var target = (await SettingsStore.instance.downloadDirPath())?.trim() ?? '';
    if (target.isEmpty) target = await defaultDownloadPath();
    final d = Directory(target);
    if (!await d.exists()) await d.create(recursive: true);
    _downloadDir = d;
    return d;
  }

  /// 设置里改过下载目录后调用，下次重新解析
  void resetDownloadDirCache() => _downloadDir = null;

  /// 当前下载目录的路径字符串（设置页展示用，解析失败时给个兜底值）
  Future<String> downloadDirPath() async {
    try {
      return (await downloadDir).path;
    } catch (_) {
      return await defaultDownloadPath();
    }
  }

  /// 缓存文件命名：路径 hash + 原文件名，避免中文与重名
  String cacheFileName(String remotePath) {
    final h = remotePath.hashCode.abs().toRadixString(16);
    return '$h-${p.basename(remotePath)}';
  }

  Future<File> cachedFile(String remotePath) async => File(p.join((await cacheDir).path, cacheFileName(remotePath)));

  Future<File> downloadedFile(String remotePath) async {
    final safe = remotePath.replaceAll('/', '_');
    return File(p.join((await downloadDir).path, safe));
  }

  Future<bool> isDownloaded(String remotePath) async => (await downloadedFile(remotePath)).exists();

  /// 目录占用
  Future<int> sizeOf(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<int> cacheSize() async => sizeOf(await cacheDir);
  Future<int> downloadSize() async => sizeOf(await downloadDir);

  /// 清理临时缓存（离线下载的文件保留）
  Future<void> clearCache() async {
    final d = await cacheDir;
    if (await d.exists()) {
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 删除某个已下载文件
  Future<void> deleteDownload(String remotePath) async {
    final f = await downloadedFile(remotePath);
    if (await f.exists()) await f.delete();
  }

  Future<void> clearDownloads() async {
    final d = await downloadDir;
    if (await d.exists()) {
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 缓存超过上限时按最久未访问淘汰
  Future<int> trimCache(int limitBytes) async {
    final d = await cacheDir;
    if (!await d.exists()) return 0;
    final files = <FileSystemEntity>[];
    await for (final e in d.list(recursive: true)) {
      if (e is File) files.add(e);
    }
    var total = 0;
    final stats = <MapEntry<File, FileStat>>[];
    for (final f in files) {
      try {
        final st = await f.stat();
        total += st.size;
        stats.add(MapEntry(f as File, st));
      } catch (_) {}
    }
    if (total <= limitBytes) return 0;
    stats.sort((a, b) => a.value.accessed.compareTo(b.value.accessed));
    var freed = 0;
    for (final e in stats) {
      if (total - freed <= limitBytes) break;
      try {
        freed += e.value.size;
        await e.key.delete();
      } catch (_) {}
    }
    return freed;
  }
}

/// 软件统计计数用的小工具
class Counters {
  Counters._();
  static Future<int> fileCountInDir(Directory d) async {
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final e in d.list()) {
      if (e is File) n++;
    }
    return n;
  }

  static Future<SharedPreferences> prefs() => SharedPreferences.getInstance();
}
