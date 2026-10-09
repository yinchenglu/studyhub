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

/// 刷题：按目录浏览服务器 quiz 目录，每个含 .json 的目录 = 一套题库
class QuizPage extends ConsumerStatefulWidget {
  const QuizPage({super.key});

  @override
  ConsumerState<QuizPage> createState() => QuizPageState();
}

class QuizPageState extends ConsumerState<QuizPage> {
  /// 当前所在子目录（相对 quiz），空串表示根
  String _sub = '';
  /// 当前目录下的子目录（每项带题目数量）
  List<_BankNode> _nodes = const [];
  /// 当前目录本身如果放了 json，就是一套「本目录题库」
  QuestionBank? _hereBank;
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

  Future<void> _load() async {
    final repo = ref.read(quizRepoProvider);
    final wrongMap = await AppDb.instance.wrongCountByBank();
    if (repo == null) {
      setState(() {
        _nodes = const [];
        _hereBank = null;
        _wrongByBank = wrongMap;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await repo.listChildren(_sub);
      final dirs = entries.where((e) => e.isDir).toList();
      final loose = entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).toList();

      final nodes = <_BankNode>[];
      for (final d in dirs) {
        QuestionBank? bank;
        try {
          bank = await repo.loadBank(d.path);
        } catch (_) {}
        final b = bank;
        nodes.add(_BankNode(
          entry: d,
          name: (b != null && b.name.isNotEmpty) ? b.name : d.name,
          count: b?.count ?? 0,
          isWordBank: b?.isWordBank ?? false,
        ));
      }

      // 当前目录直接放了 json 就是一套题库
      QuestionBank? here;
      if (loose.isNotEmpty) {
        try {
          final b = await repo.loadBank(joinPath(AppDirs.quiz, _sub));
          if (b.count > 0) here = b;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _hereBank = here;
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
    // 登录成功后自动拉一次
    ref.listen(accountProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (next && prev != next) _load();
    });

    return Scaffold(
      automaticallyImplyLeading: false,
      appBar: AppBar(
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
    if (_loading && _nodes.isEmpty && _hereBank == null) {
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

    final empty = _nodes.isEmpty && _hereBank == null;

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
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            _sub.isEmpty ? '题库目录' : '目录：$_sub',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary),
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
                  '在服务器 ${AppDirs.quiz}/ 下建目录，把题库 .json 放进去；'
                  '也可以放进多级子目录，App 支持一层层点进去。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

        // 当前目录自身的题库
        if (_hereBank != null) _bankCard(_hereBank!, title: '本目录题库'),

        // 子目录
        for (final n in _nodes) _dirCard(n),
      ],
    );
  }

  Widget _bankCard(QuestionBank b, {String? title}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
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
                      Text(title ?? b.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
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
    );
  }

  /// 子目录：含 json 就是一个题库（点击选练法），否则点进去看下一层
  Widget _dirCard(_BankNode n) {
    final scheme = Theme.of(context).colorScheme;
    final hasBank = n.count > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            if (hasBank) {
              await _openBankOf(n);
            } else {
              setState(() => _sub = _relOf(n.entry.path));
              await _load();
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (hasBank ? const Color(0xFFEF9F27) : const Color(0xFF7F77DD)).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    hasBank ? (n.isWordBank ? Icons.abc : Icons.quiz_outlined) : Icons.folder_rounded,
                    color: hasBank ? const Color(0xFFEF9F27) : const Color(0xFF7F77DD),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        '${hasBank ? '${n.count} 题' : '目录，点进去看下一层'}'
                        '${hasBank && (_wrongByBank[n.entry.path] ?? 0) > 0 ? ' · 错题 ${_wrongByBank[n.entry.path]}' : ''}'
                        '${hasBank && n.isWordBank ? ' · 单词库' : ''}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (hasBank)
                  IconButton(
                    tooltip: '进入目录',
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () async {
                      setState(() => _sub = _relOf(n.entry.path));
                      await _load();
                    },
                  ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBankOf(_BankNode n) async {
    final repo = ref.read(quizRepoProvider);
    if (repo == null) return;
    try {
      final bank = await repo.loadBank(n.entry.path);
      if (bank.count == 0) {
        _toast('这个目录里没有题目');
        return;
      }
      if (!mounted) return;
      _showModes(bank);
    } catch (e) {
      _toast('读取题库失败：$e');
    }
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
            _mode(Icons.folder_open_outlined, '进入该目录', '看看里面还有哪些子目录/题库', () {
              setState(() => _sub = _relOf(bank.dir));
              _load();
            }),
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

/// 刷题页目录树上的一项
class _BankNode {
  final DavEntry entry;
  final String name;
  final int count;
  final bool isWordBank;

  const _BankNode({
    required this.entry,
    required this.name,
    required this.count,
    required this.isWordBank,
  });
}
