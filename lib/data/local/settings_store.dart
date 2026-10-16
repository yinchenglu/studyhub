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
  // v1.7.0 删掉了 _kAutoNext（'quiz_auto_next'）——「答完自动下一题」总开关撤了。
  static const _kShowAnswer = 'quiz_show_answer_now';
  // v1.3.0 新增：
  //   _kAutoNextSec —— 普通模式答完停留几秒自动跳下一题（0 = 不自动跳）
  //   _kWrongStaySec —— 答错 / 看过答案后停留几秒再自动跳下一题（0 = 不自动跳）
  static const _kAutoNextSec = 'quiz_auto_next_sec';
  static const _kWrongStaySec = 'quiz_wrong_stay_sec';
  static const _kBrowseNextSec = 'quiz_browse_next_sec';
  static const _kLastServerCheck = 'last_server_check';
  static const _kSaveHistory = 'save_view_history';
  static const _kDownloadDir = 'download_dir';
  static const _kRecentServers = 'recent_servers';
  // v1.8.0 新增：播放时自动隐藏控制栏。默认 **false** —— 见下面的注释。
  static const _kAutoHideUi = 'player_auto_hide_ui';
  // v1.9.0 新增：笔记目录里要隐藏的文件夹名（逗号分隔字符串）。默认 'image'。
  // 之前写死在 lib/core/constants.dart 的 AppDirs.hiddenDirNames = {imageDirName}，
  // 但用户下载的笔记里图片目录不一定叫 image（可能是 assets/pic/img/photos/...），
  // 所以做进设置里给用户自己加。
  static const _kNoteHiddenDirs = 'note_hidden_dirs';

  // 后台录音录像（v1.6.0）
  static const _kRecDir = 'recorder_dir';
  static const _kAudioMaxMin = 'recorder_audio_max_min';
  static const _kVideoMaxMin = 'recorder_video_max_min';
  static const _kRecLens = 'recorder_lens';
  static const _kVideoAudio = 'recorder_video_audio';
  static const _kVideoBg = 'recorder_video_background';

  // v1.5.0 新增：笔记「阅读模式」的外观与行为。
  // 全部走 SharedPreferences，不再单开表 —— 这几项都是「全局一套」的偏好，
  // 不是按文件区分的记录。
  static const _kReadFontSize = 'read_font_size';
  static const _kReadLineHeight = 'read_line_height';
  static const _kReadTheme = 'read_theme_index';
  static const _kReadFont = 'read_font_family';
  static const _kReadPaged = 'read_paged';
  static const _kReadAutoSec = 'read_auto_sec';

  /// 每本书读到哪了：key = read_pos:<笔记路径>，value = "章序号|页序号|滚动位置"
  static const _kReadPosPrefix = 'read_pos:';

  // v1.5.0 新增：文件夹同步（本地目录 ↔ 服务器目录）
  static const _kSyncOn = 'sync_on';
  static const _kSyncLocal = 'sync_local_dir';
  static const _kSyncRemote = 'sync_remote_dir';
  static const _kSyncDir = 'sync_direction';
  static const _kSyncMin = 'sync_interval_min';
  static const _kSyncDelete = 'sync_delete_extra';

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

  // 注意：_prefs 的 getter 只在文件开头（第 41 行）声明那一次。
  // 多账号功能合进来的时候曾经在这里又复制了一份，两个同名 getter
  // 直接 duplicate_definition 编译失败 —— 本地检查器当时没查这类错。

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

  // v1.7.0：`autoNext()` / `setAutoNext()` 连同 `_kAutoNext` 一起删掉了。
  // 用户要求设置里「只留 3 个时间设置」，「答完自动下一题」这个总开关
  // 和菜单里的「不显示答案时也自动跳题」都撤了 —— 秒数 0 就是「不跳」。
  // 磁盘上残留的旧键没人读，不影响。

  Future<bool> showAnswerNow() async {
    final p = await _prefs;
    return p.getBool(_kShowAnswer) ?? true;
  }

  Future<void> setShowAnswerNow(bool v) async {
    final p = await _prefs;
    await p.setBool(_kShowAnswer, v);
  }

  /// 普通模式答完自动跳下一题的秒数。0 表示不自动跳。
  ///
  /// v1.7.0：读回来必须**归一到当前选项**，否则升级前存着 8 秒的用户
  /// 会让设置页的 DropdownButton 直接断言崩（value 不在 items 里）。
  Future<int> autoNextSec() async {
    final p = await _prefs;
    final v = p.getInt(_kAutoNextSec) ?? Defaults.autoNextSec;
    return Defaults.normalizeSec(v, Defaults.autoNextSecOptions);
  }

  Future<void> setAutoNextSec(int v) async {
    final p = await _prefs;
    await p.setInt(_kAutoNextSec, v);
  }

  /// 答错 / 看过答案后停留的秒数（0 = 不自动跳）
  Future<int> wrongStaySec() async {
    final p = await _prefs;
    final v = p.getInt(_kWrongStaySec) ?? Defaults.wrongStaySec;
    return Defaults.normalizeSec(v, Defaults.wrongStaySecOptions);
  }

  Future<void> setWrongStaySec(int v) async {
    final p = await _prefs;
    await p.setInt(_kWrongStaySec, v);
  }

  /// 「带答案刷题（只看不做）」模式自动翻页的秒数。0 表示不自动跳。
  ///
  /// v1.6.0 新增：原来是跟 `autoNextSec` 共用同一个值的，
  /// 用户要求三种模式各自独立设置。
  Future<int> browseNextSec() async {
    final p = await _prefs;
    final v = p.getInt(_kBrowseNextSec) ?? Defaults.browseNextSec;
    return Defaults.normalizeSec(v, Defaults.browseNextSecOptions);
  }

  Future<void> setBrowseNextSec(int v) async {
    final p = await _prefs;
    await p.setInt(_kBrowseNextSec, v);
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

  /// 播放视频时控制栏要不要「几秒后自动隐藏」（v1.8.0）。
  ///
  /// 默认 **false**（用户明确要求「默认菜单一直显示不隐藏」）：
  /// 只有点全屏按钮、或点菜单外的画面区域才会收起控制栏。
  /// 打开这个开关后才恢复成「播放几秒后自动淡出」的老行为。
  Future<bool> autoHidePlayerUi() async {
    final p = await _prefs;
    return p.getBool(_kAutoHideUi) ?? false;
  }

  Future<void> setAutoHidePlayerUi(bool v) async {
    final p = await _prefs;
    await p.setBool(_kAutoHideUi, v);
  }

  /// 自定义下载目录。null / 空串表示用默认目录
  Future<String?> downloadDirPath() async {
    final p = await _prefs;
    final v = p.getString(_kDownloadDir);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  // ---------------------------------------------------------------- 笔记隐藏目录
  /// 笔记目录里要隐藏的文件夹名（去首尾空格、跳过空段、跳过 '.image' 这类隐藏文件夹）。
  /// 默认始终包含 'image'，用户可以加自己笔记里的资源目录（如 assets, pic, img, photos 等）。
  Future<Set<String>> noteHiddenDirs() async {
    final p = await _prefs;
    final raw = p.getString(_kNoteHiddenDirs) ?? 'image';
    final parts = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    parts.add('image'); // 'image' 永远在隐藏列表里
    return parts;
  }

  /// 取出原始 csv（去掉两端的逗号/空格），给设置页显示用 —— 不强加 'image'。
  Future<String> noteHiddenDirsCsv() async {
    final p = await _prefs;
    return p.getString(_kNoteHiddenDirs) ?? 'image';
  }

  Future<void> setNoteHiddenDirs(String csv) async {
    final p = await _prefs;
    // 去掉全角逗号 / 重复项 / 空白
    final cleaned = csv
        .replaceAll('，', ',')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .join(',');
    await p.setString(_kNoteHiddenDirs, cleaned.isEmpty ? 'image' : cleaned);
  }

  Future<void> setDownloadDirPath(String? path) async {
    final p = await _prefs;
    if (path == null || path.trim().isEmpty) {
      await p.remove(_kDownloadDir);
    } else {
      await p.setString(_kDownloadDir, path.trim());
    }
  }

  // ----------------------------------------------------------- 后台录音录像（v1.6.0）

  /// 录音 / 录像的保存目录。null / 空串 = 应用私有目录 `文档/recordings/`。
  ///
  /// 为什么不直接用系统的 SAF 目录选择器：原生前台服务是拿一个**绝对路径**
  /// 直接交给 MediaRecorder 去写的，而 SAF 给的是 `content://` URI，
  /// MediaRecorder 根本不认。所以这里只接受真实路径（页面上有文件夹浏览器）。
  Future<String?> recorderDirPath() async {
    final p = await _prefs;
    final v = p.getString(_kRecDir);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> setRecorderDirPath(String? path) async {
    final p = await _prefs;
    if (path == null || path.trim().isEmpty) {
      await p.remove(_kRecDir);
    } else {
      await p.setString(_kRecDir, path.trim());
    }
  }

  /// 录音最长录多少分钟。0 表示不限。
  Future<int> audioMaxMinutes() async {
    final p = await _prefs;
    return p.getInt(_kAudioMaxMin) ?? Defaults.audioMaxMinutes;
  }

  Future<void> setAudioMaxMinutes(int v) async {
    final p = await _prefs;
    await p.setInt(_kAudioMaxMin, v);
  }

  /// 录像最长录多少分钟。0 表示不限。
  Future<int> videoMaxMinutes() async {
    final p = await _prefs;
    return p.getInt(_kVideoMaxMin) ?? Defaults.videoMaxMinutes;
  }

  Future<void> setVideoMaxMinutes(int v) async {
    final p = await _prefs;
    await p.setInt(_kVideoMaxMin, v);
  }

  /// 录像用哪一侧摄像头：'back' / 'front'。
  ///
  /// v1.9.0：默认改成 'front'。这个工具最常见的场景是「录下自己的想法 / 一段口播」，
  /// 用前摄录比后摄自然得多。第一次进入录像页就是前摄，不需要手动再点「切换」。
  /// 用户随时可在页面上切回后摄，这个值会跟着存下来。
  Future<String> recorderLens() async {
    final p = await _prefs;
    final v = p.getString(_kRecLens);
    return (v == 'back') ? 'back' : 'front';
  }

  Future<void> setRecorderLens(String v) async {
    final p = await _prefs;
    await p.setString(_kRecLens, v == 'front' ? 'front' : 'back');
  }

  /// 录像要不要录音。
  Future<bool> videoWithAudio() async {
    final p = await _prefs;
    return p.getBool(_kVideoAudio) ?? true;
  }

  Future<void> setVideoWithAudio(bool v) async {
    final p = await _prefs;
    await p.setBool(_kVideoAudio, v);
  }

  /// 录像方式：true = 后台录像（相机交给前台服务，能息屏）；
  /// false = 前台录像（页面里有实时画面，退到后台就停）。
  Future<bool> videoBackground() async {
    final p = await _prefs;
    return p.getBool(_kVideoBg) ?? true;
  }

  Future<void> setVideoBackground(bool v) async {
    final p = await _prefs;
    await p.setBool(_kVideoBg, v);
  }

  // ------------------------------------------- 工具页自定义（v1.8.0）

  /// 用户自定义的工具顺序：`{"分类名": ["工具原名", …]}`。
  /// 没被自定义过的分类不在表里（那些分类照用代码里的内置顺序）。
  ///
  /// 为什么按分类存、而不是存一个全局大列表：工具页是**按分类分组**渲染的，
  /// 全局顺序一旦和分组叠在一起，「这个工具到底会落到哪个分类里」就说不清了。
  /// 按分类存，拖动只在分类内部生效，行为和看到的一模一样。
  static const _kToolOrder = 'tools_order';

  /// 工具**显示名**的自定义：`{"原名": "显示名"}`。
  /// 只改工具页列表里显示的那几个字；点进去之后的页面标题仍然用原名。
  static const _kToolAlias = 'tools_alias';

  Future<Map<String, List<String>>> toolOrder() async {
    final p = await _prefs;
    final raw = p.getString(_kToolOrder);
    if (raw == null || raw.isEmpty) return <String, List<String>>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        final out = <String, List<String>>{};
        d.forEach((k, v) {
          if (v is List) out['$k'] = v.map((e) => '$e').toList();
        });
        return out;
      }
    } catch (_) {
      // 存坏了就当没自定义过。**绝不能因为一份顺序让整个工具页打不开** ——
      // 这个页面是很多人的入口，宁可丢掉一点个性化。
    }
    return <String, List<String>>{};
  }

  Future<void> setToolOrder(Map<String, List<String>> v) async {
    final p = await _prefs;
    final clean = <String, List<String>>{};
    v.forEach((k, l) {
      if (l.isNotEmpty) clean[k] = l;
    });
    await p.setString(_kToolOrder, jsonEncode(clean));
  }

  Future<Map<String, String>> toolAliases() async {
    final p = await _prefs;
    final raw = p.getString(_kToolAlias);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        return d.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {
      // 同上：坏数据只当没设置
    }
    return <String, String>{};
  }

  Future<void> setToolAliases(Map<String, String> v) async {
    final p = await _prefs;
    // 空的、以及和原名一样的，都不必存 —— 存了反而让「恢复原名」找不到干净的默认态
    final clean = <String, String>{};
    v.forEach((k, val) {
      final t = val.trim();
      if (t.isNotEmpty && t != k) clean[k] = t;
    });
    await p.setString(_kToolAlias, jsonEncode(clean));
  }

  // ----------------------------------------------------------- 阅读模式（v1.5.0）

  Future<double> readFontSize() async {
    final p = await _prefs;
    return p.getDouble(_kReadFontSize) ?? Defaults.readFontSize;
  }

  Future<void> setReadFontSize(double v) async {
    final p = await _prefs;
    await p.setDouble(_kReadFontSize, v);
  }

  Future<double> readLineHeight() async {
    final p = await _prefs;
    return p.getDouble(_kReadLineHeight) ?? Defaults.readLineHeight;
  }

  Future<void> setReadLineHeight(double v) async {
    final p = await _prefs;
    await p.setDouble(_kReadLineHeight, v);
  }

  Future<int> readTheme() async {
    final p = await _prefs;
    return p.getInt(_kReadTheme) ?? 1;
  }

  Future<void> setReadTheme(int v) async {
    final p = await _prefs;
    await p.setInt(_kReadTheme, v);
  }

  Future<int> readFontFamily() async {
    final p = await _prefs;
    return p.getInt(_kReadFont) ?? 0;
  }

  Future<void> setReadFontFamily(int v) async {
    final p = await _prefs;
    await p.setInt(_kReadFont, v);
  }

  /// true = 左右翻页，false = 上下滚动
  Future<bool> readPaged() async {
    final p = await _prefs;
    return p.getBool(_kReadPaged) ?? true;
  }

  Future<void> setReadPaged(bool v) async {
    final p = await _prefs;
    await p.setBool(_kReadPaged, v);
  }

  /// 自动翻页间隔秒数，0 = 关闭
  Future<int> readAutoSec() async {
    final p = await _prefs;
    return p.getInt(_kReadAutoSec) ?? 0;
  }

  Future<void> setReadAutoSec(int v) async {
    final p = await _prefs;
    await p.setInt(_kReadAutoSec, v);
  }

  /// 某一篇读到哪了。返回的字符串由调用方自己解释（见阅读页 _savePos）
  Future<String?> readPos(String notePath) async {
    final p = await _prefs;
    return p.getString('$_kReadPosPrefix$notePath');
  }

  Future<void> setReadPos(String notePath, String value) async {
    final p = await _prefs;
    await p.setString('$_kReadPosPrefix$notePath', value);
  }

  Future<void> clearReadPos(String notePath) async {
    final p = await _prefs;
    await p.remove('$_kReadPosPrefix$notePath');
  }

  // ----------------------------------------------------------- 文件夹同步（v1.5.0）

  Future<bool> syncOn() async {
    final p = await _prefs;
    return p.getBool(_kSyncOn) ?? false;
  }

  Future<void> setSyncOn(bool v) async {
    final p = await _prefs;
    await p.setBool(_kSyncOn, v);
  }

  Future<String> syncLocalDir() async {
    final p = await _prefs;
    return p.getString(_kSyncLocal) ?? '';
  }

  Future<void> setSyncLocalDir(String v) async {
    final p = await _prefs;
    await p.setString(_kSyncLocal, v.trim());
  }

  Future<String> syncRemoteDir() async {
    final p = await _prefs;
    return p.getString(_kSyncRemote) ?? '';
  }

  Future<void> setSyncRemoteDir(String v) async {
    final p = await _prefs;
    await p.setString(_kSyncRemote, v.trim());
  }

  /// 0 = 双向，1 = 本地 → 服务器，2 = 服务器 → 本地
  Future<int> syncDirection() async {
    final p = await _prefs;
    return p.getInt(_kSyncDir) ?? 0;
  }

  Future<void> setSyncDirection(int v) async {
    final p = await _prefs;
    await p.setInt(_kSyncDir, v);
  }

  Future<int> syncIntervalMin() async {
    final p = await _prefs;
    return p.getInt(_kSyncMin) ?? Defaults.syncIntervalMin;
  }

  Future<void> setSyncIntervalMin(int v) async {
    final p = await _prefs;
    await p.setInt(_kSyncMin, v);
  }

  Future<bool> syncDeleteExtra() async {
    final p = await _prefs;
    return p.getBool(_kSyncDelete) ?? false;
  }

  Future<void> setSyncDeleteExtra(bool v) async {
    final p = await _prefs;
    await p.setBool(_kSyncDelete, v);
  }
}
