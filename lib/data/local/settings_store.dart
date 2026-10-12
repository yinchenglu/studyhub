import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../models/models.dart';

/// 本地设置 + 账号（密码单独用系统加密存储保存）
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();

  static const _kAccount = 'dav_account';
  static const _kTheme = 'theme_mode';
  static const _kSpeed = 'playback_speed';
  static const _kQuizCount = 'quiz_count';
  static const _kExamCount = 'exam_count';
  static const _kExamMinutes = 'exam_minutes';
  static const _kCacheLimit = 'cache_limit_mb';
  static const _kAutoNext = 'quiz_auto_next';
  static const _kShowAnswer = 'quiz_show_answer_now';
  // v1.3.0 新增：
  //   _kAutoNextSec —— 「显示答案」模式下，答完停留几秒自动跳下一题（0 = 不自动跳）
  //   _kWrongStaySec —— 「不带答案」模式下，答错后停留几秒再自动跳下一题
  static const _kAutoNextSec = 'quiz_auto_next_sec';
  static const _kWrongStaySec = 'quiz_wrong_stay_sec';
  static const _kLastServerCheck = 'last_server_check';
  static const _kSaveHistory = 'save_view_history';
  static const _kDownloadDir = 'download_dir';
  static const _kRecentServers = 'recent_servers';

  final _secure = const FlutterSecureStorage();
  SharedPreferences? _p;

  Future<void> init() async {
    _p ??= await SharedPreferences.getInstance();
  }

  Future<SharedPreferences> get _prefs async {
    _p ??= await SharedPreferences.getInstance();
    return _p!;
  }

  // ----------------------------------------------------------- 账号（支持多个）
  //
  // v1.4.0 起：可以同时保存好几个 WebDAV 服务器 / 账号，首页直接切换。
  //
  // 存储布局（密码和列表故意分两处）：
  //   dav_accounts    —— JSON 数组，每项 {alias, baseUrl, username, root}，**不含密码**
  //   dav_active_key  —— 当前用哪个，值形如 "http://192.168.1.10:5005/|admin"
  //   FlutterSecureStorage —— 每个账号一条密码，key 由 baseUrl|username 派生
  //
  // 密码不放进 JSON 是因为 SharedPreferences 是明文的；分开存还有个额外好处：
  // 同一台服务器换用户名时，两个人的密码天然不会串。
  //
  // 兼容：老版本只存了一个 dav_account，首次 loadAccount 时会自动搬进列表。

  static const _kAccounts = 'dav_accounts';
  static const _kActiveKey = 'dav_active_key';

  /// 账号的唯一标识。同一个地址下的不同用户算两个账号。
  static String keyOf(DavAccount a) => '${a.baseUrl}|${a.username}';

  DavAccount? _account;

  DavAccount? get account => _account;

  bool get isLoggedIn => _account != null && _account!.baseUrl.isNotEmpty;

  Future<SharedPreferences> get _prefs async {
    _p ??= await SharedPreferences.getInstance();
    return _p!;
  }

  /// 读账号列表（不含密码，内部用）
  Future<List<DavAccount>> _rawAccounts() async {
    final p = await _prefs;
    final s = p.getString(_kAccounts);
    if (s == null || s.isEmpty) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => DavAccount.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeAccounts(List<DavAccount> list) async {
    final p = await _prefs;
    await p.setString(_kAccounts, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// 全部保存过的账号，**含密码**（首页 / 设置页的切换列表用）
  Future<List<DavAccount>> savedAccounts() async {
    final out = <DavAccount>[];
    for (final a in await _rawAccounts()) {
      final pwd = await _secure.read(key: a.secretKey) ?? '';
      out.add(a.copyWith(password: pwd));
    }
    return out;
  }

  /// 从本地恢复上次用的账号。
  /// 顺便把老版本的单个账号搬进新的列表结构。
  Future<DavAccount?> loadAccount() async {
    final p = await _prefs;

    // ---- 一次性迁移：老结构 dav_account → dav_accounts ----
    final legacy = p.getString(_kAccount);
    if (legacy != null) {
      try {
        final acc = DavAccount.fromJson(jsonDecode(legacy) as Map<String, dynamic>);
        final pwd = await _secure.read(key: acc.secretKey) ?? '';
        await saveAccount(acc.copyWith(password: pwd));
      } catch (_) {
        // 迁不动就当没有，不能让老数据把启动流程卡死
      }
      await p.remove(_kAccount);
    }

    final list = await _rawAccounts();
    if (list.isEmpty) return null;

    final key = p.getString(_kActiveKey);
    DavAccount pick = list.first;
    if (key != null) {
      for (final e in list) {
        if (keyOf(e) == key) {
          pick = e;
          break;
        }
      }
    }
    final pwd = await _secure.read(key: pick.secretKey) ?? '';
    _account = pick.copyWith(password: pwd);
    return _account;
  }

  /// 保存一个账号并把它设为「当前」。
  /// 已存在（同名同地址同用户）就更新，否则插到列表最前面。
  Future<void> saveAccount(DavAccount acc) async {
    final p = await _prefs;
    await _secure.write(key: acc.secretKey, value: acc.password);
    final list = await _rawAccounts();
    list.removeWhere((e) => keyOf(e) == keyOf(acc));
    list.insert(
      0,
      DavAccount(
        alias: acc.alias,
        baseUrl: acc.baseUrl,
        username: acc.username,
        password: '',
        root: acc.root,
      ),
    );
    await _writeAccounts(list);
    await p.setString(_kActiveKey, keyOf(acc));
    _account = acc;
    await rememberServer(acc);
  }

  /// 切到另一个已经保存过的账号（首页 / 设置页点一下就走这里）
  Future<void> switchTo(DavAccount acc) async {
    final p = await _prefs;
    await p.setString(_kActiveKey, keyOf(acc));
    // 切过去的账号要排到最前，列表顺序就是「最近用过」
    final list = await _rawAccounts();
    list.removeWhere((e) => keyOf(e) == keyOf(acc));
    list.insert(
      0,
      DavAccount(alias: acc.alias, baseUrl: acc.baseUrl, username: acc.username, password: '', root: acc.root),
    );
    await _writeAccounts(list);
    _account = acc; // 外面传进来的已经带密码
  }

  /// 从列表里彻底删掉一个账号（连密码一起删）
  Future<void> removeAccount(DavAccount acc) async {
    final list = await _rawAccounts();
    list.removeWhere((e) => keyOf(e) == keyOf(acc));
    await _writeAccounts(list);
    try {
      await _secure.delete(key: acc.secretKey);
    } catch (_) {}
    final p = await _prefs;
    if (p.getString(_kActiveKey) == keyOf(acc)) {
      await p.remove(_kActiveKey);
      _account = null;
    }
  }

  /// 断开当前连接。
  /// **不删已保存的账号列表** —— 用户只是退出，不是把服务器忘了；
  /// 下次在首页点一下就能切回来。要彻底删得用 removeAccount。
  Future<void> logout() async {
    final p = await _prefs;
    await p.remove(_kActiveKey);
    _account = null;
  }

  // ----------------------------------------------------------- 历史服务器地址

  /// 记住一个用过的服务器地址（只存别名 / 地址 / 根目录，不存用户名密码），最多 8 条
  Future<void> rememberServer(DavAccount acc) async {
    if (acc.baseUrl.trim().isEmpty) return;
    final p = await _prefs;
    final list = await recentServers();
    list.removeWhere((e) => e.baseUrl == acc.baseUrl && e.root == acc.root);
    list.insert(
      0,
      DavAccount(alias: acc.alias, baseUrl: acc.baseUrl, username: '', password: '', root: acc.root),
    );
    await p.setString(_kRecentServers, jsonEncode(list.take(8).map((e) => e.toJson()).toList()));
  }

  Future<List<DavAccount>> recentServers() async {
    final p = await _prefs;
    final s = p.getString(_kRecentServers);
    if (s == null || s.isEmpty) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => DavAccount.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> forgetServer(String baseUrl) async {
    final p = await _prefs;
    final list = await recentServers();
    list.removeWhere((e) => e.baseUrl == baseUrl);
    await p.setString(_kRecentServers, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ----------------------------------------------------------- 外观与偏好

  Future<ThemeMode> themeMode() async {
    final p = await _prefs;
    switch (p.getString(_kTheme)) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode m) async {
    final p = await _prefs;
    await p.setString(_kTheme, m.name);
  }

  Future<double> playbackSpeed() async {
    final p = await _prefs;
    return p.getDouble(_kSpeed) ?? Defaults.playbackSpeed;
  }

  Future<void> setPlaybackSpeed(double v) async {
    final p = await _prefs;
    await p.setDouble(_kSpeed, v);
  }

  Future<int> quizCount() async {
    final p = await _prefs;
    return p.getInt(_kQuizCount) ?? Defaults.quizCountPerRound;
  }

  Future<void> setQuizCount(int v) async {
    final p = await _prefs;
    await p.setInt(_kQuizCount, v);
  }

  Future<int> examCount() async {
    final p = await _prefs;
    return p.getInt(_kExamCount) ?? Defaults.examCount;
  }

  Future<void> setExamCount(int v) async {
    final p = await _prefs;
    await p.setInt(_kExamCount, v);
  }

  Future<int> examMinutes() async {
    final p = await _prefs;
    return p.getInt(_kExamMinutes) ?? Defaults.examMinutes;
  }

  Future<void> setExamMinutes(int v) async {
    final p = await _prefs;
    await p.setInt(_kExamMinutes, v);
  }

  Future<int> cacheLimitMb() async {
    final p = await _prefs;
    return p.getInt(_kCacheLimit) ?? Defaults.cacheLimitMb;
  }

  Future<void> setCacheLimitMb(int v) async {
    final p = await _prefs;
    await p.setInt(_kCacheLimit, v);
  }

  Future<bool> autoNext() async {
    final p = await _prefs;
    return p.getBool(_kAutoNext) ?? false;
  }

  Future<void> setAutoNext(bool v) async {
    final p = await _prefs;
    await p.setBool(_kAutoNext, v);
  }

  Future<bool> showAnswerNow() async {
    final p = await _prefs;
    return p.getBool(_kShowAnswer) ?? true;
  }

  Future<void> setShowAnswerNow(bool v) async {
    final p = await _prefs;
    await p.setBool(_kShowAnswer, v);
  }

  /// 「显示答案」模式下自动跳下一题的秒数。0 表示不自动跳。
  Future<int> autoNextSec() async {
    final p = await _prefs;
    return p.getInt(_kAutoNextSec) ?? Defaults.autoNextSec;
  }

  Future<void> setAutoNextSec(int v) async {
    final p = await _prefs;
    await p.setInt(_kAutoNextSec, v);
  }

  /// 「不带答案」模式下答错后停留的秒数（答对是立刻跳）
  Future<int> wrongStaySec() async {
    final p = await _prefs;
    return p.getInt(_kWrongStaySec) ?? Defaults.wrongStaySec;
  }

  Future<void> setWrongStaySec(int v) async {
    final p = await _prefs;
    await p.setInt(_kWrongStaySec, v);
  }

  Future<void> setLastServerCheck(String text) async {
    final p = await _prefs;
    await p.setString(_kLastServerCheck, text);
  }

  Future<String?> lastServerCheck() async {
    final p = await _prefs;
    return p.getString(_kLastServerCheck);
  }

  // ----------------------------------------------------------- 浏览记录 / 下载目录

  /// 是否记录浏览（播放）记录。关掉后不再写入播放进度，首页「最近浏览」也不再新增
  Future<bool> saveViewHistory() async {
    final p = await _prefs;
    return p.getBool(_kSaveHistory) ?? true;
  }

  Future<void> setSaveViewHistory(bool v) async {
    final p = await _prefs;
    await p.setBool(_kSaveHistory, v);
  }

  /// 自定义下载目录。null / 空串表示用默认目录
  Future<String?> downloadDirPath() async {
    final p = await _prefs;
    final v = p.getString(_kDownloadDir);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> setDownloadDirPath(String? path) async {
    final p = await _prefs;
    if (path == null || path.trim().isEmpty) {
      await p.remove(_kDownloadDir);
    } else {
      await p.setString(_kDownloadDir, path.trim());
    }
  }
}
