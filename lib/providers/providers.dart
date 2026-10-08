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

  const AccountState({this.account, this.client, this.check, this.loading = false, this.error});

  bool get isLoggedIn => account != null && client != null;

  AccountState copyWith({
    DavAccount? account,
    WebDavClient? client,
    ConnectionCheck? check,
    bool? loading,
    String? error,
    bool clearError = false,
    bool clearAccount = false,
  }) =>
      AccountState(
        account: clearAccount ? null : (account ?? this.account),
        client: clearAccount ? null : (client ?? this.client),
        check: check ?? this.check,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

class AccountNotifier extends StateNotifier<AccountState> {
  AccountNotifier() : super(const AccountState());

  /// App 启动时恢复上次的登录
  Future<void> restore() async {
    final acc = await SettingsStore.instance.loadAccount();
    if (acc == null) return;
    state = AccountState(account: acc, client: WebDavClient(acc));
    // 后台悄悄探测一次，不阻塞界面
    checkInBackground();
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
      state = AccountState(account: acc, client: client, check: check);
      return check;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return ConnectionCheck(ok: false, message: e.toString());
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
    state = const AccountState();
  }
}

final accountProvider = StateNotifierProvider<AccountNotifier, AccountState>((ref) => AccountNotifier());

/// 当前登录用的 WebDAV 客户端（未登录为 null）
final davClientProvider = Provider<WebDavClient?>((ref) => ref.watch(accountProvider).client);

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

/// 首页四宫格 + 错题本数字。下拉刷新时 ref.invalidate 重算
final statsProvider = FutureProvider<StatsSummary>((ref) async {
  final account = ref.watch(accountProvider);
  final db = AppDb.instance;

  final wrongCount = await db.wrongCount();
  final todayReview = await db.wrongCount(mastered: false);

  if (!account.isLoggedIn) {
    return StatsSummary(wrongCount: wrongCount, todayReviewCount: todayReview);
  }

  final notes = NoteRepo(account.client!);
  final media = MediaRepo(account.client!);
  final quiz = QuizRepo(account.client!);

  var noteCount = 0, videoCount = 0, imageCount = 0, bankCount = 0, toolCount = 0;

  await Future.wait([
    notes.allNotes(maxDepth: 3).then((v) => noteCount = v.length).catchError((_) => noteCount = 0),
    media.counts(maxDepth: 3).then((v) {
      videoCount = v['video'] ?? 0;
      imageCount = v['image'] ?? 0;
    }).catchError((_) => 0),
    quiz.bankCount().then((v) => bankCount = v).catchError((_) => bankCount = 0),
    _countTools(account.client!).then((v) => toolCount = v).catchError((_) => toolCount = 0),
  ]);

  return StatsSummary(
    noteCount: noteCount,
    videoCount: videoCount,
    imageCount: imageCount,
    bankCount: bankCount,
    toolCount: toolCount,
    wrongCount: wrongCount,
    todayReviewCount: todayReview,
  );
});

Future<int> _countTools(WebDavClient client) async {
  try {
    final entries = await client.list('tools', depth: 1);
    return entries.where((e) => !e.isDir).length + entries.where((e) => e.isDir).length;
  } catch (_) {
    return 0;
  }
}

/// 最近浏览（本地播放进度记录）
final recentProvider = FutureProvider<List<MapEntry<String, PlayProgress>>>((ref) async {
  return AppDb.instance.recentPlayed(limit: 8);
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
  const QuizPrefs({
    this.perRound = 20,
    this.examCount = 30,
    this.examMinutes = 40,
    this.autoNext = false,
    this.showAnswerNow = true,
  });
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
    );
  }

  Future<void> setPerRound(int v) async {
    await SettingsStore.instance.setQuizCount(v);
    state = QuizPrefs(perRound: v, examCount: state.examCount, examMinutes: state.examMinutes, autoNext: state.autoNext, showAnswerNow: state.showAnswerNow);
  }

  Future<void> setExamCount(int v) async {
    await SettingsStore.instance.setExamCount(v);
    state = QuizPrefs(perRound: state.perRound, examCount: v, examMinutes: state.examMinutes, autoNext: state.autoNext, showAnswerNow: state.showAnswerNow);
  }

  Future<void> setExamMinutes(int v) async {
    await SettingsStore.instance.setExamMinutes(v);
    state = QuizPrefs(perRound: state.perRound, examCount: state.examCount, examMinutes: v, autoNext: state.autoNext, showAnswerNow: state.showAnswerNow);
  }

  Future<void> setAutoNext(bool v) async {
    await SettingsStore.instance.setAutoNext(v);
    state = QuizPrefs(perRound: state.perRound, examCount: state.examCount, examMinutes: state.examMinutes, autoNext: v, showAnswerNow: state.showAnswerNow);
  }

  Future<void> setShowAnswerNow(bool v) async {
    await SettingsStore.instance.setShowAnswerNow(v);
    state = QuizPrefs(perRound: state.perRound, examCount: state.examCount, examMinutes: state.examMinutes, autoNext: state.autoNext, showAnswerNow: v);
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
