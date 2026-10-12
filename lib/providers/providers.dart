import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dav/webdav_client.dart';
import '../data/local/db.dart';
import '../data/local/settings_store.dart';
import '../data/models/models.dart';
import '../data/repositories/media_repo.dart';
import '../data/repositories/note_repo.dart';
import '../data/repositories/quiz_repo.dart';

/// 本地设置
final settingsProvider = Provider<SettingsStore>((ref) => SettingsStore.instance);

// ------------------------------------------------------------- 账号与连接

class AccountState {
  final DavAccount? account;
  final WebDavClient? client;
  final ConnectionCheck? check;
  final bool loading;
  final String? error;

  /// 本地保存过的全部账号（首页 / 设置页的切换列表）
  final List<DavAccount> saved;

  const AccountState({
    this.account,
    this.client,
    this.check,
    this.loading = false,
    this.error,
    this.saved = const [],
  });

  bool get isLoggedIn => account != null && client != null;

  /// 除当前账号外还有别的可切 —— 用来决定要不要显示「切换」入口
  bool get hasOtherAccounts =>
      saved.where((e) => e.baseUrl != account?.baseUrl || e.username != account?.username).isNotEmpty;

  AccountState copyWith({
    DavAccount? account,
    WebDavClient? client,
    ConnectionCheck? check,
    bool? loading,
    String? error,
    List<DavAccount>? saved,
    bool clearError = false,
    bool clearAccount = false,
  }) =>
      AccountState(
        account: clearAccount ? null : (account ?? this.account),
        client: clearAccount ? null : (client ?? this.client),
        check: check ?? this.check,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        saved: saved ?? this.saved,
      );
}

class AccountNotifier extends StateNotifier<AccountState> {
  AccountNotifier() : super(const AccountState());

  /// App 启动时恢复上次的登录
  Future<void> restore() async {
    await refreshSaved();
    final acc = await SettingsStore.instance.loadAccount();
    if (acc == null) return;
    state = state.copyWith(account: acc, client: WebDavClient(acc), clearAccount: false);
    // 后台悄悄探测一次，不阻塞界面
    checkInBackground();
  }

  /// 重新读一遍本地保存的账号列表
  Future<void> refreshSaved() async {
    final list = await SettingsStore.instance.savedAccounts();
    state = state.copyWith(saved: list);
  }

  /// 登录：保存账号 + 做一次完整检测
  Future<ConnectionCheck> login(DavAccount acc) async {
    state = state.copyWith(loading: true, clearError: true);
    final client = WebDavClient(acc);
    try {
      final check = await client.check();
      if (!check.ok) {
        state = state.copyWith(loading: false, error: check.message);
        return check;
      }
      await SettingsStore.instance.saveAccount(acc);
      await SettingsStore.instance.setLastServerCheck(DateTime.now().toIso8601String());
      final saved = await SettingsStore.instance.savedAccounts();
      state = AccountState(account: acc, client: client, check: check, saved: saved);
      return check;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return ConnectionCheck(ok: false, message: e.toString());
    }
  }

  /// 切到另一个已保存的账号。
  ///
  /// 切换不动服务器上的任何东西，只是把「当前用哪个账号」换掉，
  /// 然后重建 client、清掉上一账号留下的连接检测结果。
  /// 各页面的数据靠 ref.listen(accountProvider) 自己重新拉。
  Future<void> switchAccount(DavAccount acc) async {
    state = state.copyWith(loading: true, clearError: true);
    await SettingsStore.instance.switchTo(acc);
    await refreshSaved();
    state = AccountState(
      account: acc,
      client: WebDavClient(acc),
      saved: state.saved,
    );
    checkInBackground();
  }

  /// 从列表里删掉一个账号（连密码一起）
  Future<void> removeAccount(DavAccount acc) async {
    await SettingsStore.instance.removeAccount(acc);
    final cur = state.account;
    final same = cur != null && cur.baseUrl == acc.baseUrl && cur.username == acc.username;
    await refreshSaved();
    if (same) {
      state = state.copyWith(clearAccount: true);
    }
  }

  Future<void> checkInBackground() async {
    final client = state.client;
    if (client == null) return;
    try {
      final check = await client.check();
      state = state.copyWith(check: check);
    } catch (_) {}
  }

  /// 手动重新检测（设置页 / 首页刷新按钮）
  Future<ConnectionCheck?> recheck() async {
    final client = state.client;
    if (client == null) return null;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final check = await client.check();
      await SettingsStore.instance.setLastServerCheck(DateTime.now().toIso8601String());
      state = state.copyWith(check: check, loading: false);
      return check;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return ConnectionCheck(ok: false, message: e.toString());
    }
  }

  Future<void> logout() async {
    await SettingsStore.instance.logout();
    state = state.copyWith(clearAccount: true);
  }
}

final accountProvider = StateNotifierProvider<AccountNotifier, AccountState>((ref) => AccountNotifier());

/// 当前账号的标识串（地址 + 用户名），未登录为空串。
///
/// 各页面用它做 `ref.listen` 的 key 来决定要不要重新拉数据。
/// **不能只监听 isLoggedIn** —— 从「家里的群晖」切到「公司的 NAS」时
/// isLoggedIn 一直是 true，前后相等，页面就不会重载，看到的还是上一台服务器的内容。
String accountKeyOf(AccountState s) =>
    s.account == null ? '' : '${s.account!.baseUrl}|${s.account!.username}';

/// 当前登录用的 WebDAV 客户端（未登录为 null）
final davClientProvider = Provider<WebDavClient?>((ref) => ref.watch(accountProvider).client);

/// 底部导航当前选中的下标。
/// 首页的四宫格点了以后直接切到对应模块，这样返回键的行为和点底部菜单完全一致。
final tabIndexProvider = StateProvider<int>((ref) => 0);

// ------------------------------------------------------------- 各模块仓库

final noteRepoProvider = Provider<NoteRepo?>((ref) {
  final c = ref.watch(davClientProvider);
  return c == null ? null : NoteRepo(c);
});

final mediaRepoProvider = Provider<MediaRepo?>((ref) {
  final c = ref.watch(davClientProvider);
  return c == null ? null : MediaRepo(c);
});

final quizRepoProvider = Provider<QuizRepo?>((ref) {
  final c = ref.watch(davClientProvider);
  return c == null ? null : QuizRepo(c);
});

// ------------------------------------------------------------- 首页统计

/// 首页剩下的唯一一个统计：错题本数字。
///
/// v1.4.0 把「笔记多少篇 / 视频多少个 / 题库多少套」那组四宫格去掉了：
///   * 用户明确要求删掉；
///   * 那几个数字每次下拉都要把 notes / media / quiz / tools 四个目录
///     各扫一遍（media 还要递归），服务器一慢，下拉刷新就卡在那儿。
/// 现在只查本地 SQLite，秒回。
final statsProvider = FutureProvider<StatsSummary>((ref) async {
  final db = AppDb.instance;
  final wrongCount = await db.wrongCount();
  final unmastered = await db.wrongCount(mastered: false);
  return StatsSummary(wrongCount: wrongCount, todayReviewCount: unmastered);
});

/// 最近浏览（本地播放 / 打开记录，视频和笔记都在里面）
final recentProvider = FutureProvider<List<MapEntry<String, PlayProgress>>>((ref) async {
  return AppDb.instance.recentPlayed(limit: 12);
});

// ------------------------------------------------------------- 主题

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    state = await SettingsStore.instance.themeMode();
  }

  Future<void> set(ThemeMode m) async {
    state = m;
    await SettingsStore.instance.setThemeMode(m);
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) => ThemeModeNotifier());

// ------------------------------------------------------------- 刷题设置

class QuizPrefs {
  final int perRound;
  final int examCount;
  final int examMinutes;
  final bool autoNext;
  final bool showAnswerNow;

  /// 「显示答案」模式下答完停留几秒自动跳下一题（0 = 不自动跳）
  final int autoNextSec;

  /// 「不带答案」模式下答错后停留几秒再跳下一题（答对立刻跳）
  final int wrongStaySec;

  const QuizPrefs({
    this.perRound = 20,
    this.examCount = 30,
    this.examMinutes = 40,
    this.autoNext = false,
    this.showAnswerNow = true,
    this.autoNextSec = 3,
    this.wrongStaySec = 6,
  });

  QuizPrefs copy({
    int? perRound,
    int? examCount,
    int? examMinutes,
    bool? autoNext,
    bool? showAnswerNow,
    int? autoNextSec,
    int? wrongStaySec,
  }) =>
      QuizPrefs(
        perRound: perRound ?? this.perRound,
        examCount: examCount ?? this.examCount,
        examMinutes: examMinutes ?? this.examMinutes,
        autoNext: autoNext ?? this.autoNext,
        showAnswerNow: showAnswerNow ?? this.showAnswerNow,
        autoNextSec: autoNextSec ?? this.autoNextSec,
        wrongStaySec: wrongStaySec ?? this.wrongStaySec,
      );
}

class QuizPrefsNotifier extends StateNotifier<QuizPrefs> {
  QuizPrefsNotifier() : super(const QuizPrefs()) {
    _load();
  }

  Future<void> _load() async {
    final s = SettingsStore.instance;
    state = QuizPrefs(
      perRound: await s.quizCount(),
      examCount: await s.examCount(),
      examMinutes: await s.examMinutes(),
      autoNext: await s.autoNext(),
      showAnswerNow: await s.showAnswerNow(),
      autoNextSec: await s.autoNextSec(),
      wrongStaySec: await s.wrongStaySec(),
    );
  }

  Future<void> setPerRound(int v) async {
    await SettingsStore.instance.setQuizCount(v);
    state = state.copy(perRound: v);
  }

  Future<void> setExamCount(int v) async {
    await SettingsStore.instance.setExamCount(v);
    state = state.copy(examCount: v);
  }

  Future<void> setExamMinutes(int v) async {
    await SettingsStore.instance.setExamMinutes(v);
    state = state.copy(examMinutes: v);
  }

  Future<void> setAutoNext(bool v) async {
    await SettingsStore.instance.setAutoNext(v);
    state = state.copy(autoNext: v);
  }

  Future<void> setShowAnswerNow(bool v) async {
    await SettingsStore.instance.setShowAnswerNow(v);
    state = state.copy(showAnswerNow: v);
  }

  Future<void> setAutoNextSec(int v) async {
    await SettingsStore.instance.setAutoNextSec(v);
    state = state.copy(autoNextSec: v);
  }

  Future<void> setWrongStaySec(int v) async {
    await SettingsStore.instance.setWrongStaySec(v);
    state = state.copy(wrongStaySec: v);
  }
}

final quizPrefsProvider = StateNotifierProvider<QuizPrefsNotifier, QuizPrefs>((ref) => QuizPrefsNotifier());

// ------------------------------------------------------------- 错题本

class WrongNotifier extends StateNotifier<AsyncValue<List<WrongRecord>>> {
  WrongNotifier() : super(const AsyncValue.loading()) {
    refresh();
  }

  Future<void> refresh({String? bankDir, bool? mastered}) async {
    state = const AsyncValue.loading();
    try {
      final list = await AppDb.instance.listWrong(bankDir: bankDir, mastered: mastered);
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> remove(int id) async {
    await AppDb.instance.deleteWrong(id);
    await refresh();
  }

  Future<void> setMastered(int id, String bankDir, String qid, bool v) async {
    await AppDb.instance.markMastered(bankDir, qid, v);
    await refresh();
  }

  Future<void> saveNote(int id, String note) async {
    await AppDb.instance.updateWrongNote(id, note);
    await refresh();
  }

  Future<void> clearAll() async {
    await AppDb.instance.clearWrong();
    await refresh();
  }
}

final wrongProvider = StateNotifierProvider<WrongNotifier, AsyncValue<List<WrongRecord>>>((ref) => WrongNotifier());
