import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

enum QuizMode { practice, exam }

/// 答题页：练习模式（答完即出对错与解析）/ 考试模式（倒计时，交卷后统一评）
class AnswerPage extends ConsumerStatefulWidget {
  final List<Question> questions;
  final String title;
  final QuizMode mode;
  final bool randomize;
  final int? examMinutes;

  const AnswerPage({
    super.key,
    required this.questions,
    required this.title,
    this.mode = QuizMode.practice,
    this.randomize = false,
    this.examMinutes,
  });

  @override
  ConsumerState<AnswerPage> createState() => _AnswerPageState();
}

class _AnswerPageState extends ConsumerState<AnswerPage> {
  late List<Question> _list;
  final Map<int, List<int>> _choices = {}; // 题号 → 已选下标
  int _i = 0;
  bool _submitted = false; // 当前题是否已判定（练习模式）
  bool _finished = false;
  bool _showAnswerNow = true;

  Timer? _timer;
  int _remainSec = 0;

  Question get _q => _list[_i];
  List<int> get _myChoice => _choices[_i] ?? const [];

  @override
  void initState() {
    super.initState();
    _list = List<Question>.from(widget.questions);
    if (widget.randomize) _list.shuffle(Random(DateTime.now().millisecondsSinceEpoch));
    _load();
    if (widget.mode == QuizMode.exam) {
      _remainSec = (widget.examMinutes ?? 40) * 60;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _remainSec--);
        if (_remainSec <= 0) {
          _timer?.cancel();
          _submitExam();
        }
      });
    }
  }

  Future<void> _load() async {
    final v = await ref.read(quizPrefsProvider.notifier).state.showAnswerNow;
    if (mounted) setState(() => _showAnswerNow = v);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ 判定与记录

  bool _isCorrect(Question q, List<int> mine) {
    if (mine.length != q.answer.length) return false;
    final a = [...mine]..sort();
    final b = [...q.answer]..sort();
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 记录对错：错 → 进错题本；对 → 错题本里标记为已掌握
  Future<void> _record(Question q, List<int> mine, bool correct) async {
    try {
      if (correct) {
        if (q.bankDir.isNotEmpty && q.id.isNotEmpty) {
          await AppDb.instance.markMastered(q.bankDir, q.id, true);
        }
      } else {
        await AppDb.instance.upsertWrong(q, mine);
      }
    } catch (_) {}
  }

  void _choose(int idx) {
    if (_submitted && widget.mode == QuizMode.practice) return;
    final q = _q;
    setState(() {
      if (q.isMulti) {
        final cur = [...(_choices[_i] ?? const <int>[])];
        cur.contains(idx) ? cur.remove(idx) : cur.add(idx);
        _choices[_i] = cur;
      } else {
        _choices[_i] = [idx];
        if (widget.mode == QuizMode.practice && _showAnswerNow) _submitted = true;
      }
    });
    if (widget.mode == QuizMode.practice && _submitted) {
      _record(q, _myChoice, _isCorrect(q, _myChoice));
      if (ref.read(quizPrefsProvider).autoNext) {
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) _next();
        });
      }
    }
  }

  void _submitCurrent() {
    if (_myChoice.isEmpty) return;
    setState(() => _submitted = true);
    _record(_q, _myChoice, _isCorrect(_q, _myChoice));
  }

  void _next() {
    if (_i < _list.length - 1) {
      setState(() {
        _i++;
        _submitted = false;
      });
    } else {
      if (widget.mode == QuizMode.exam) {
        _submitExam();
      } else {
        setState(() => _finished = true);
      }
    }
  }

  void _prev() {
    if (_i > 0) {
      setState(() {
        _i--;
        _submitted = false;
      });
    }
  }

  /// 练习模式提前结束：把没答的跳过，直接看小结
  void _finishPractice() {
    // 尚未判定的题目按答错处理（用户可能直接退）
    setState(() => _finished = true);
    ref.invalidate(wrongProvider);
    ref.invalidate(statsProvider);
  }

  Future<void> _submitExam() async {
    _timer?.cancel();
    // 统一记录对错
    for (var k = 0; k < _list.length; k++) {
      final q = _list[k];
      final mine = _choices[k] ?? const <int>[];
      await _record(q, mine, _isCorrect(q, mine));
    }
    ref.invalidate(wrongProvider);
    ref.invalidate(statsProvider);
    if (mounted) setState(() => _finished = true);
  }

  void _restart({bool wrongOnly = false}) {
    final wrong = <Question>[];
    for (var k = 0; k < _list.length; k++) {
      final q = _list[k];
      if (!_isCorrect(q, _choices[k] ?? const [])) wrong.add(q);
    }
    setState(() {
      _list = wrongOnly ? (wrong.isEmpty ? _list : wrong) : List<Question>.from(widget.questions);
      if (widget.randomize && !wrongOnly) _list.shuffle();
      _choices.clear();
      _i = 0;
      _submitted = false;
      _finished = false;
    });
    if (widget.mode == QuizMode.exam) {
      _remainSec = (widget.examMinutes ?? 40) * 60;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _remainSec--);
        if (_remainSec <= 0) {
          _timer?.cancel();
          _submitExam();
        }
      });
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    if (_list.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: Text('这套题库里没有题目')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 16), overflow: TextOverflow.ellipsis),
            Text(
              widget.mode == QuizMode.exam ? '模拟考试' : '第 ${_i + 1} / ${_list.length} 题',
              style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (widget.mode == QuizMode.exam)
            Center(
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _remainSec < 300 ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer_outlined, size: 14),
                    const SizedBox(width: 4),
                    Text(formatDuration(_remainSec * 1000), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          if (widget.mode == QuizMode.practice)
            IconButton(
              tooltip: '结束本轮',
              icon: const Icon(Icons.done_all),
              onPressed: _finishPractice,
            ),
        ],
      ),
      body: _finished ? _resultView() : _questionView(),
    );
  }

  Widget _questionView() {
    final scheme = Theme.of(context).colorScheme;
    final q = _q;
    final mine = _myChoice;
    final correct = _submitted && _isCorrect(q, mine);

    return Column(
      children: [
        LinearProgressIndicator(value: (_i + 1) / _list.length, minHeight: 3),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              // 标签
              Wrap(
                spacing: 6,
                children: [
                  _tag(q.typeLabel, scheme.primary),
                  for (final t in q.tags.take(3)) _tag(t, scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                q.stem,
                style: const TextStyle(fontSize: 16.5, height: 1.65, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 18),
              for (var j = 0; j < q.options.length; j++) _optionTile(j, q, mine, correct),
              const SizedBox(height: 16),
              if (widget.mode == QuizMode.practice && !_submitted && q.isMulti)
                FilledButton.icon(
                  onPressed: mine.isEmpty ? null : _submitCurrent,
                  icon: const Icon(Icons.check),
                  label: const Text('确认答案'),
                ),
              if (_submitted || (widget.mode == QuizMode.exam && _finished)) _analysisCard(q, mine),
            ],
          ),
        ),
        _bottomBar(q),
      ],
    );
  }

  Widget _optionTile(int j, Question q, List<int> mine, bool correct) {
    final scheme = Theme.of(context).colorScheme;
    final picked = mine.contains(j);
    final isRight = q.answer.contains(j);

    Color bg = scheme.surfaceContainerHighest.withValues(alpha: 0.35);
    Color border = Colors.transparent;
    Color fg = scheme.onSurface;
    IconData? icon;

    if (_submitted) {
      if (isRight) {
        bg = const Color(0xFF1D9E75).withValues(alpha: 0.14);
        border = const Color(0xFF1D9E75);
        fg = const Color(0xFF0F6E56);
        icon = Icons.check_circle;
      } else if (picked) {
        bg = scheme.errorContainer.withValues(alpha: 0.5);
        border = scheme.error;
        fg = scheme.error;
        icon = Icons.cancel;
      }
    } else if (picked) {
      bg = scheme.primaryContainer.withValues(alpha: 0.55);
      border = scheme.primary;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _choose(j),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border == Colors.transparent ? scheme.outlineVariant.withValues(alpha: 0.5) : border, width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: picked || (_submitted && isRight) ? scheme.primary.withValues(alpha: 0.15) : scheme.surface,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(String.fromCharCode(65 + j), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(q.options[j], style: TextStyle(fontSize: 15, height: 1.5, color: fg))),
              if (icon != null) Icon(icon, size: 18, color: fg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analysisCard(Question q, List<int> mine) {
    final scheme = Theme.of(context).colorScheme;
    final correct = _isCorrect(q, mine);
    if (widget.mode == QuizMode.exam) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (correct ? const Color(0xFF1D9E75) : scheme.error).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(correct ? Icons.check_circle_outline : Icons.highlight_off, size: 18, color: correct ? const Color(0xFF1D9E75) : scheme.error),
              const SizedBox(width: 6),
              Text(
                correct ? '答对了' : '答错了，已自动记入错题本',
                style: TextStyle(fontWeight: FontWeight.w600, color: correct ? const Color(0xFF0F6E56) : scheme.error),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('正确答案：${q.answer.map((e) => String.fromCharCode(65 + e)).join(' ')}', style: const TextStyle(fontSize: 13.5)),
          if (q.analysis.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('解析：${q.analysis}', style: const TextStyle(fontSize: 13.5, height: 1.6)),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar(Question q) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: _i > 0 ? _prev : null,
              icon: const Icon(Icons.chevron_left, size: 18),
              label: const Text('上一题'),
            ),
            const Spacer(),
            if (widget.mode == QuizMode.exam)
              OutlinedButton.icon(
                onPressed: _showCard,
                icon: const Icon(Icons.grid_view_outlined, size: 18),
                label: Text('答题卡 ${_choices.length}/${_list.length}'),
              )
            else
              Text('已答 ${_choices.length}/${_list.length}', style: const TextStyle(fontSize: 12.5)),
            const Spacer(),
            FilledButton.icon(
              onPressed: _next,
              icon: const Icon(Icons.chevron_right, size: 18),
              label: Text(_i == _list.length - 1 ? (widget.mode == QuizMode.exam ? '交卷' : '看小结') : '下一题'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCard() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('答题卡', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var k = 0; k < _list.length; k++)
                    InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        setState(() {
                          _i = k;
                          _submitted = false;
                        });
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _choices.containsKey(k)
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                          border: k == _i ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
                        ),
                        child: Text('${k + 1}', style: const TextStyle(fontSize: 12.5)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: () { Navigator.pop(context); _submitExam(); }, child: const Text('交卷')),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 结果

  Widget _resultView() {
    final scheme = Theme.of(context).colorScheme;
    var right = 0;
    final wrongIdx = <int>[];
    for (var k = 0; k < _list.length; k++) {
      if (_isCorrect(_list[k], _choices[k] ?? const [])) {
        right++;
      } else {
        wrongIdx.add(k);
      }
    }
    final unanswered = _list.length - _choices.length;
    final score = _list.isEmpty ? 0 : (right * 100 / _list.length).round();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: 120,
                height: 120,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (score >= 60 ? const Color(0xFF1D9E75) : scheme.error).withValues(alpha: 0.12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$score', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: score >= 60 ? const Color(0xFF0F6E56) : scheme.error)),
                    Text('分', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text('答对 $right / ${_list.length} 题', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '答错 ${wrongIdx.length} 题${unanswered > 0 ? ' · 未作答 $unanswered 题' : ''}',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
              if (wrongIdx.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('做错的题已经进「错题本」了', style: TextStyle(fontSize: 12, color: scheme.error)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (wrongIdx.isNotEmpty) ...[
          Text('错题回顾', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (var n = 0; n < wrongIdx.length; n++) ...[
                  if (n > 0) const Divider(height: 1),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.close, size: 18, color: Colors.red),
                    title: Text(_list[wrongIdx[n]].stem.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '正确答案：${_list[wrongIdx[n]].answer.map((e) => String.fromCharCode(65 + e)).join(' ')}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => setState(() {
                      _i = wrongIdx[n];
                      _submitted = true;
                      _finished = false;
                    }),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('返回'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _restart(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('再来一轮'),
              ),
            ),
          ],
        ),
        if (wrongIdx.isNotEmpty) ...[
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: () => _restart(wrongOnly: true),
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('只重做错题'),
          ),
        ],
      ],
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      );
}

extension on Question {
  String get typeLabel {
    switch (type) {
      case 'multi':
        return '多选题';
      case 'judge':
        return '判断题';
      default:
        return '单选题';
    }
  }
}
