import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../data/repositories/quiz_repo.dart';
import '../../providers/providers.dart';
import '../home/login_page.dart';
import 'answer_page.dart';
import 'wrong_book_page.dart';

/// 刷题：自动识别服务器 quiz 目录下的每套题库
class QuizPage extends ConsumerStatefulWidget {
  const QuizPage({super.key});

  @override
  ConsumerState<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends ConsumerState<QuizPage> {
  List<QuestionBank> _banks = const [];
  Map<String, int> _wrongByBank = const {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final repo = ref.read(quizRepoProvider);
    final wrongMap = await AppDb.instance.wrongCountByBank();
    if (repo == null) {
      setState(() {
        _banks = const [];
        _wrongByBank = wrongMap;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final banks = await repo.listBanks();
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _wrongByBank = wrongMap;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(accountProvider).isLoggedIn;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('刷题'),
        actions: [
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
    if (_loading && _banks.isEmpty) return const Center(child: CircularProgressIndicator());
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
              subtitle: Text('本地保存 · 按题库和知识点分组'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrongBookPage())).then((_) => _load()),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text('题库（共 ${_banks.length} 套）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
        ),
        if (_banks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.quiz_outlined, size: 44, color: scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                const Text('没读到题库'),
                const SizedBox(height: 8),
                Text(
                  '在服务器 ${AppDirsQuizHint.path} 下建一个子目录，'
                  '把题库 .json 放进去，App 每次进来都会重新读。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        for (final b in _banks)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showModes(b),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: const Color(0xFFEF9F27).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
                        child: Icon(b.isWordBank ? Icons.abc : Icons.quiz_outlined, color: const Color(0xFFEF9F27)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(
                              '${b.count} 题'
                              '${(_wrongByBank[b.dir] ?? 0) > 0 ? ' · 错题 ${_wrongByBank[b.dir]}' : ''}'
                              '${b.isWordBank ? ' · 单词库' : ''}',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 五种练法
  void _showModes(QuestionBank bank) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  Expanded(child: Text(bank.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  Text('${bank.count} 题', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            _mode(Icons.list_alt, '顺序练', '按题库原顺序，每次 ${ref.read(quizPrefsProvider).perRound} 题', () => _start(bank, _Mode.order)),
            _mode(Icons.shuffle, '随机练', '打乱顺序，每次 ${ref.read(quizPrefsProvider).perRound} 题', () => _start(bank, _Mode.random)),
            _mode(Icons.replay, '只练错题', '把该题库的错题全部重做一遍', () => _start(bank, _Mode.wrongOnly)),
            _mode(Icons.auto_awesome, '智能复习', '错题优先 + 没做过的题优先', () => _start(bank, _Mode.smart)),
            _mode(Icons.timer_outlined, '模拟考试', '${ref.read(quizPrefsProvider).examCount} 题 / ${ref.read(quizPrefsProvider).examMinutes} 分钟', () => _setupExam(bank)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _mode(IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        onTap: () {
          Navigator.pop(context);
          onTap();
        },
      );

  Future<void> _start(QuestionBank bank, _Mode mode) async {
    final all = bank.allQuestions();
    if (all.isEmpty) {
      _toast('这套题库没有题目');
      return;
    }
    final perRound = ref.read(quizPrefsProvider).perRound;
    List<Question> list;
    var randomize = false;

    switch (mode) {
      case _Mode.order:
        list = all.take(perRound).toList();
        break;
      case _Mode.random:
        list = List<Question>.from(all)..shuffle(Random());
        list = list.take(perRound).toList();
        randomize = false;
        break;
      case _Mode.wrongOnly:
        final wrongs = await AppDb.instance.listWrong(bankDir: bank.dir);
        if (wrongs.isEmpty) {
          _toast('这套题库还没有错题');
          return;
        }
        list = wrongs.map(questionFromWrong).toList();
        break;
      case _Mode.smart:
        final wrongs = await AppDb.instance.listWrong(bankDir: bank.dir, mastered: false);
        final wrongIds = wrongs.map((e) => e.questionId).toSet();
        final wrongQs = all.where((q) => wrongIds.contains(q.id)).toList()..shuffle();
        final freshQs = all.where((q) => !wrongIds.contains(q.id)).toList()..shuffle();
        list = [...wrongQs, ...freshQs].take(perRound).toList();
        break;
    }

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnswerPage(
        questions: list,
        title: bank.name,
        randomize: randomize,
      ),
    ));
    _load();
  }

  Future<void> _setupExam(QuestionBank bank) async {
    final prefs = ref.read(quizPrefsProvider);
    var count = prefs.examCount;
    var minutes = prefs.examMinutes;
    final all = bank.allQuestions();
    if (all.isEmpty) return;

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
                Text('${bank.name} · 模拟考试', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('题库共 ${all.length} 题', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('题量'),
                    Expanded(
                      child: Slider(
                        value: count.toDouble().clamp(5, all.length.toDouble()),
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
                          title: bank.name,
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

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
}

enum _Mode { order, random, wrongOnly, smart }

class AppDirsQuizHint {
  static const path = '/StudyHub/quiz/';
}
