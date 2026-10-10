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

  // ----------------------------------------------------------- 账号

  DavAccount? _account;

  DavAccount? get account => _account;

  bool get isLoggedIn => _account != null && _account!.baseUrl.isNotEmpty;

  /// 从本地恢复上次登录的账号
  Future<DavAccount?> loadAccount() async {
    final p = await _prefs;
    final s = p.getString(_kAccount);
    if (s == null) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final acc = DavAccount.fromJson(j);
      final pwd = await _secure.read(key: acc.secretKey) ?? '';
      _account = acc.copyWith(password: pwd);
      return _account;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAccount(DavAccount acc) async {
    final p = await _prefs;
    await _secure.write(key: acc.secretKey, value: acc.password);
    await p.setString(_kAccount, jsonEncode(acc.toJson()));
    _account = acc;
    await rememberServer(acc);
  }

  /// 退出登录：只清账号本体。
  /// 已登录过的「服务器地址」保留下来，下次打开登录页可以直接选，用户名密码留空。
  Future<void> logout() async {
    final p = await _prefs;
    await p.remove(_kAccount);
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
