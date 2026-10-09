import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../data/repositories/quiz_repo.dart';
import '../../providers/providers.dart';
import '../home/login_page.dart';
import 'answer_page.dart';
import 'wrong_book_page.dart';

/// 刷题：按目录浏览服务器 quiz 目录。
///
/// v1.2.0 起：**一个 .json = 一套题库**。
/// 进到一个目录里能看到该目录下所有题库（章节/单元）的列表，
/// 每套题库都有进度条；点某套题库会弹出菜单，既可以只刷这一套，
/// 也可以把这个目录下所有题库合并起来刷。
class QuizPage extends ConsumerStatefulWidget {
  const QuizPage({super.key});

  @override
  ConsumerState<QuizPage> createState() => QuizPageState();
}

class QuizPageState extends ConsumerState<QuizPage> {
  /// 当前所在子目录（相对 quiz），空串表示根
  String _sub = '';
  /// 当前目录下的子目录
  List<_DirNode> _dirs = const [];
  /// 当前目录下的题库文件（每个 .json 一套）
  List<QuizBankRef> _banks = const [];
  /// 题库路径 → 已刷题数
  Map<String, int> _doneByBank = const {};
  /// 题库路径 → 错题数
  Map<String, int> _wrongByBank = const {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 从别的菜单切进来 / 再次点「刷题」时调用：回到根目录并刷新
  Future<void> reload() async {
    if (_sub.isNotEmpty) setState(() => _sub = '');
    await _load();
  }

  /// 手机返回键：优先返回上级目录；已在本页根目录时返回 false
  bool handleBack() {
    if (_sub.isNotEmpty) {
      _goUp();
      return true;
    }
    return false;
  }

  void _goUp() {
    setState(() => _sub = parentOf(_sub));
    _load();
  }

  /// 服务器路径 → 相对 quiz 的路径
  String _relOf(String path) =>
      path.startsWith('${AppDirs.quiz}/') ? path.substring(AppDirs.quiz.length + 1) : '';

  String get _curDirPath => joinPath(AppDirs.quiz, _sub);

  Future<void> _load() async {
    final repo = ref.read(quizRepoProvider);
    final done = await AppDb.instance.doneCountByBank();
    final wrong = await AppDb.instance.wrongCountByBank();
    // 这两个 await 之后页面可能已经被销毁（切走 / 退出登录触发了重建），
    // 不挡一下的话下面的 setState 会直接抛 "setState() called after dispose()"
    if (!mounted) return;
    if (repo == null) {
      setState(() {
        _dirs = const [];
        _banks = const [];
        _doneByBank = done;
        _wrongByBank = wrong;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = _curDirPath;
      final entries = await repo.listChildren(_sub);
      final subDirs = entries.where((e) => e.isDir).toList();

      final banks = await repo.banksInDir(dir);
      final dirs = await Future.wait(subDirs.map((d) async {
        final n = await repo.jsonCountInDir(d.path);
        return _DirNode(entry: d, count: n);
      }));

      if (!mounted) return;
      setState(() {
        _banks = banks;
        _dirs = dirs;
        _doneByBank = done;
        _wrongByBank = wrong;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;
    // 登录成功后自动拉一次
    ref.listen(accountProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (next && prev != next) _load();
    });

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _sub.isNotEmpty
            ? IconButton(
                tooltip: '返回上级目录',
                onPressed: _goUp,
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('刷题'),
            if (logged)
              Text(
                '/${AppDirs.quiz}${_sub.isEmpty ? '' : '/$_sub'}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '题库体检：检查 quiz 目录里的 json 有没有写错',
            onPressed: _validateBanks,
            icon: const Icon(Icons.fact_check_outlined),
          ),
          IconButton(tooltip: '刷新题库', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: !logged
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined, size: 48, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('题库存在你的服务器上'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const LoginPage()))
                        .then((_) => _load()),
                    child: const Text('去连接'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading && _banks.isEmpty && _dirs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 44, color: scheme.error),
          const SizedBox(height: 12),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 32), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.6))),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }

    final empty = _banks.isEmpty && _dirs.isEmpty;
    final totalQ = _banks.fold<int>(0, (a, b) => a + b.count);
    final totalDone = _banks.fold<int>(0, (a, b) => a + (_doneByBank[b.path] ?? 0).clamp(0, b.count));

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        // 错题本入口
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card(
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: scheme.errorContainer.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.rule_folder_outlined, color: scheme.error, size: 20),
              ),
              title: const Text('错题本'),
              subtitle: const Text('本地保存 · 按题库和知识点分组'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrongBookPage())).then((_) => _load()),
            ),
          ),
        ),

        if (empty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.quiz_outlined, size: 44, color: scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text(_sub.isEmpty ? '没读到题库' : '这个目录里没有题库'),
                const SizedBox(height: 8),
                Text(
                  '在服务器 ${AppDirs.quiz}/ 下建目录，把题库 .json 放进去。\n'
                  '一个 .json 就是一套题库（比如「第一章.json」「第二章.json」），'
                  '放同一个目录里，进这个目录就能看到每套题库的进度。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

        // 本目录题库总览 + 合并刷
        if (_banks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.layers_outlined, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('本目录 ${_banks.length} 套题库 · 共 $totalQ 题',
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: totalQ == 0 ? 0 : totalDone / totalQ,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 6),
                    Text('已刷 $totalDone / $totalQ 题',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _openDirMenu(),
                            icon: const Icon(Icons.merge_type, size: 18),
                            label: const Text('合并整个目录一起刷'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (_dirs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text(_sub.isEmpty ? '题库目录' : '子目录',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
          ),
        for (final d in _dirs) _dirCard(d),

        if (_banks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text('题库（${_banks.length} 套）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
          ),
        for (final b in _banks) _bankCard(b),
      ],
    );
  }

  /// 子目录：点进去看里面的题库列表
  Widget _dirCard(_DirNode n) {
    final scheme = Theme.of(context).colorScheme;
    final rel = _relOf(n.entry.path);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            setState(() => _sub = rel);
            await _load();
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: const Color(0xFF7F77DD).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
                  child: const Icon(Icons.folder_rounded, color: Color(0xFF7F77DD)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.entry.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        n.count > 0 ? '${n.count} 套题库' : '子目录',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一套题库：进度条 + 菜单
  Widget _bankCard(QuizBankRef b) {
    final scheme = Theme.of(context).colorScheme;
    final done = (_doneByBank[b.path] ?? 0).clamp(0, b.count);
    final wrong = _wrongByBank[b.path] ?? 0;
    final ratio = b.count == 0 ? 0.0 : done / b.count;
    final finished = b.count > 0 && done >= b.count;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openBankMenu(b),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (finished ? const Color(0xFF1D9E75) : const Color(0xFFEF9F27)).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        finished ? Icons.check_circle_outline : (b.isWordBank ? Icons.abc : Icons.quiz_outlined),
                        color: finished ? const Color(0xFF1D9E75) : const Color(0xFFEF9F27),
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            '共 ${b.count} 题 · 已刷 $done'
                            '${wrong > 0 ? ' · 错题 $wrong' : ''}'
                            '${b.isWordBank ? ' · 单词库' : ''}',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Text('${(ratio * 100).round()}%',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: finished ? const Color(0xFF1D9E75) : scheme.primary)),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: ratio,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(3),
                  color: finished ? const Color(0xFF1D9E75) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 菜单

  /// 单套题库的菜单：既能只刷这一套，也能把整个目录合并起来刷
  void _openBankMenu(QuizBankRef ref0) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Row(
                  children: [
                    Expanded(child: Text(ref0.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                    Text('${ref0.count} 题', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: LinearProgressIndicator(
                  value: ref0.count == 0 ? 0 : (_doneByBank[ref0.path] ?? 0).clamp(0, ref0.count) / ref0.count,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const _SheetLabel('刷这一套'),
              _mode(Icons.list_alt, '顺序练', '按题库原顺序，每次 ${ref.read(quizPrefsProvider).perRound} 题', () => _startSingle(ref0, _Mode.order)),
              _mode(Icons.shuffle, '随机练', '打乱顺序，每次 ${ref.read(quizPrefsProvider).perRound} 题', () => _startSingle(ref0, _Mode.random)),
              _mode(Icons.auto_awesome, '智能复习', '错题优先 + 没做过的题优先', () => _startSingle(ref0, _Mode.smart)),
              _mode(Icons.fiber_new_outlined, '只刷没刷过的', '跳过已经刷过的题目', () => _startSingle(ref0, _Mode.fresh)),
              _mode(Icons.replay, '只练错题', '把这一套的错题重做一遍', () => _startSingle(ref0, _Mode.wrongOnly)),
              _mode(Icons.timer_outlined, '模拟考试', '${ref.read(quizPrefsProvider).examCount} 题 / ${ref.read(quizPrefsProvider).examMinutes} 分钟', () => _setupExam(ref0)),
              if (_banks.length > 1) ...[
                const Divider(height: 18),
                const _SheetLabel('跨题库'),
                _mode(Icons.merge_type, '合并整个目录一起刷', '把这 ${_banks.length} 套题库（共 ${_banks.fold<int>(0, (a, b) => a + b.count)} 题）混在一起练', _openDirMenu),
              ],
              const Divider(height: 18),
              _mode(Icons.restart_alt, '重置这一套的进度', '把「已刷」清零，错题本不受影响', () => _resetProgress([ref0.path]), danger: true),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 整个目录合并刷的菜单
  Future<void> _openDirMenu() async {
    final paths = _banks.map((e) => e.path).toList();
    final total = _banks.fold<int>(0, (a, b) => a + b.count);
    final done = _banks.fold<int>(0, (a, b) => a + (_doneByBank[b.path] ?? 0).clamp(0, b.count));
    final dirName = _sub.isEmpty ? '根目录' : _sub;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(
                children: [
                  Expanded(child: Text('合并刷：$dirName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  Text('$total 题', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('已刷 $done / $total · 来自 ${_banks.length} 套题库',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            const Divider(height: 8),
            _mode(Icons.list_alt, '顺序合并刷', '按题库顺序一套套来，每次 ${ref.read(quizPrefsProvider).perRound} 题', () => _startDir(_Mode.order)),
            _mode(Icons.shuffle, '随机合并刷', '所有题目打乱后抽 ${ref.read(quizPrefsProvider).perRound} 题', () => _startDir(_Mode.random)),
            _mode(Icons.auto_awesome, '智能复习', '错题优先 + 没做过的题优先', () => _startDir(_Mode.smart)),
            _mode(Icons.fiber_new_outlined, '只刷没刷过的', '跳过已经刷过的题目', () => _startDir(_Mode.fresh)),
            _mode(Icons.replay, '只练错题', '该目录下所有题库的错题', () => _startDir(_Mode.wrongOnly)),
            _mode(Icons.timer_outlined, '模拟考试', '${ref.read(quizPrefsProvider).examCount} 题 / ${ref.read(quizPrefsProvider).examMinutes} 分钟', () => _setupExamDir()),
            const Divider(height: 18),
            _mode(Icons.restart_alt, '重置整个目录的进度', '把这 ${_banks.length} 套题库的「已刷」清零', () => _resetProgress(paths), danger: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _mode(IconData icon, String title, String sub, VoidCallback onTap, {bool danger = false}) => ListTile(
        leading: Icon(icon, color: danger ? Theme.of(context).colorScheme.error : null),
        title: Text(title, style: danger ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        onTap: () {
          Navigator.pop(context);
          onTap();
        },
      );

  // ---------------------------------------------------------------- 开始刷题

  List<Question> _pick(List<Question> all, List<Question> wrongs, Set<String> doneIds, _Mode mode, int perRound) {
    switch (mode) {
      case _Mode.order:
        return all.take(perRound).toList();
      case _Mode.random:
        final l = List<Question>.from(all)..shuffle(Random());
        return l.take(perRound).toList();
      case _Mode.wrongOnly:
        return wrongs;
      case _Mode.fresh:
        final l = all.where((q) => !doneIds.contains(q.id)).toList()..shuffle(Random());
        return l.take(perRound).toList();
      case _Mode.smart:
        final wrongIds = wrongs.map((e) => e.id).toSet();
        final wrongQs = all.where((q) => wrongIds.contains(q.id)).toList()..shuffle();
        final freshQs = all.where((q) => !wrongIds.contains(q.id) && !doneIds.contains(q.id)).toList()..shuffle();
        final rest = all.where((q) => !wrongIds.contains(q.id) && doneIds.contains(q.id)).toList()..shuffle();
        return [...wrongQs, ...freshQs, ...rest].take(perRound).toList();
    }
  }

  Future<void> _startSingle(QuizBankRef ref0, _Mode mode) async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) return;
    _busy(true);
    try {
      final bank = await repo.loadBankFile(ref0.path);
      if (bank.count == 0) {
        _toast('这套题库没有题目，或者文件格式不对');
        return;
      }
      final all = bank.allQuestions();
      final perRound = ref.read(quizPrefsProvider).perRound;
      final wrongs = (await AppDb.instance.listWrong(bankDir: ref0.path)).map(questionFromWrong).toList();
      if (mode == _Mode.wrongOnly && wrongs.isEmpty) {
        _toast('这套题库还没有错题');
        return;
      }
      final doneIds = await AppDb.instance.doneIds(ref0.path);
      final list = _pick(all, wrongs, doneIds, mode, perRound);
      if (list.isEmpty) {
        _toast(mode == _Mode.fresh ? '这套题库已经全部刷过了，真棒' : '没有可练的题目');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AnswerPage(questions: list, title: bank.name),
      ));
    } catch (e) {
      _toast('读取题库失败：$e');
    } finally {
      _busy(false);
      _load();
    }
  }

  Future<void> _startDir(_Mode mode) async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) return;
    _busy(true);
    try {
      final merged = await repo.mergeDir(_curDirPath);
      if (merged.count == 0) {
        _toast('这个目录里没有题目');
        return;
      }
      final all = merged.allQuestions();
      final perRound = ref.read(quizPrefsProvider).perRound;
      final pathSet = _banks.map((e) => e.path).toSet();
      final wrongs = (await AppDb.instance.listWrong())
          .where((w) => pathSet.contains(w.bankDir))
          .map(questionFromWrong)
          .toList();
      if (mode == _Mode.wrongOnly && wrongs.isEmpty) {
        _toast('这个目录下的题库还没有错题');
        return;
      }
      final doneIds = <String>{};
      for (final b in _banks) {
        doneIds.addAll(await AppDb.instance.doneIds(b.path));
      }
      final list = _pick(all, wrongs, doneIds, mode, perRound);
      if (list.isEmpty) {
        _toast(mode == _Mode.fresh ? '这个目录里的题都刷过了' : '没有可练的题目');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AnswerPage(questions: list, title: merged.name),
      ));
    } catch (e) {
      _toast('读取题库失败：$e');
    } finally {
      _busy(false);
      _load();
    }
  }

  Future<void> _setupExam(QuizBankRef ref0) async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) return;
    _busy(true);
    QuestionBank bank;
    try {
      bank = await repo.loadBankFile(ref0.path);
    } catch (e) {
      _toast('读取题库失败：$e');
      return;
    } finally {
      _busy(false);
    }
    final all = bank.allQuestions();
    if (all.isEmpty) {
      _toast('这套题库没有题目');
      return;
    }
    await _examSheet(title: bank.name, all: all);
  }

  Future<void> _setupExamDir() async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) return;
    _busy(true);
    QuestionBank bank;
    try {
      bank = await repo.mergeDir(_curDirPath);
    } catch (e) {
      _toast('读取题库失败：$e');
      return;
    } finally {
      _busy(false);
    }
    final all = bank.allQuestions();
    if (all.isEmpty) {
      _toast('这个目录里没有题目');
      return;
    }
    await _examSheet(title: bank.name, all: all);
  }

  Future<void> _examSheet({required String title, required List<Question> all}) async {
    final prefs = ref.read(quizPrefsProvider);
    var count = prefs.examCount;
    var minutes = prefs.examMinutes;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$title · 模拟考试', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('题库共 ${all.length} 题', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('题量'),
                    Expanded(
                      child: Slider(
                        value: count.toDouble().clamp(5, all.length < 5 ? 5 : all.length.toDouble()),
                        min: 5,
                        max: all.length < 5 ? 5 : all.length.toDouble(),
                        divisions: all.length > 5 ? (all.length - 5).clamp(1, 100) : 1,
                        label: '$count',
                        onChanged: (v) => setS(() => count = v.round()),
                      ),
                    ),
                    SizedBox(width: 34, child: Text('$count', textAlign: TextAlign.end)),
                  ],
                ),
                Row(
                  children: [
                    const Text('时长'),
                    Expanded(
                      child: Slider(
                        value: minutes.toDouble().clamp(5, 180),
                        min: 5,
                        max: 180,
                        divisions: 35,
                        label: '$minutes 分',
                        onChanged: (v) => setS(() => minutes = v.round()),
                      ),
                    ),
                    SizedBox(width: 46, child: Text('$minutes 分', textAlign: TextAlign.end)),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始考试'),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final shuffled = List<Question>.from(all)..shuffle();
                      await ref.read(quizPrefsProvider.notifier).setExamCount(count);
                      await ref.read(quizPrefsProvider.notifier).setExamMinutes(minutes);
                      if (!mounted) return;
                      await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => AnswerPage(
                          questions: shuffled.take(count).toList(),
                          title: title,
                          mode: QuizMode.exam,
                          examMinutes: minutes,
                        ),
                      ));
                      _load();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _resetProgress(List<String> paths) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重置刷题进度？'),
        content: Text('会把这 ${paths.length} 套题库的「已刷题数」清零（进度条回零）。错题本不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重置')),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in paths) {
      await AppDb.instance.clearDone(bankDir: p);
    }
    await _load();
  }

  void _busy(bool v) {
    if (mounted) setState(() => _loading = v);
  }

  /// 题库体检：把 quiz 目录里所有 json 都过一遍，指出字段写错的地方。
  /// （原来是工具页的独立工具，v1.2 工具页改版后挪到这里，跟题库放一起更顺手）
  Future<void> _validateBanks() async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) {
      _toast('需要先连接服务器');
      return;
    }
    _busy(true);
    final problems = <String>[];
    try {
      final visited = <String>{};
      Future<void> checkDir(String dir) async {
        if (!visited.add(dir)) return;
        problems.addAll((await repo.validate(dir)).map((e) => '$dir：$e'));
      }

      await checkDir(AppDirs.quiz);
      final rootDirs = await repo.listChildren('');
      for (final d in rootDirs.where((e) => e.isDir)) {
        await checkDir(d.path);
        try {
          final inner = await repo.listChildren(_relOf(d.path));
          for (final s in inner.where((e) => e.isDir)) {
            await checkDir(s.path);
          }
        } catch (_) {}
      }
    } catch (e) {
      problems.add('检查过程出错：$e');
    }
    _busy(false);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(problems.isEmpty ? '题库体检：全部正常' : '题库体检：发现 ${problems.length} 个问题'),
        content: SizedBox(
          width: double.maxFinite,
          child: problems.isEmpty
              ? const Text('所有题库文件的字段都是齐全的，放心刷。')
              : ListView(
                  shrinkWrap: true,
                  children: problems
                      .take(200)
                      .map((e) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text('· $e', style: const TextStyle(fontSize: 13, height: 1.5)),
                          ))
                      .toList(),
                ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
}

enum _Mode { order, random, wrongOnly, smart, fresh }

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              )),
        ),
      );
}

/// 目录树上的一个子目录
class _DirNode {
  final DavEntry entry;
  final int count;
  const _DirNode({required this.entry, required this.count});
}
