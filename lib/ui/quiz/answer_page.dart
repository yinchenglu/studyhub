import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

enum QuizMode { practice, exam }

/// 答题页。
///
/// v1.3.0 起的变化：
///   * 左右滑动切上一题 / 下一题
///   * 顶栏有「显示答案」开关，做题过程中随时能切，不用回设置页
///   * 显示答案模式下：可选 3/5/8/10/15 秒自动跳下一题，并带暂停/继续
///   * 不带答案模式下：答对立刻自动跳，答错停留可配置的秒数
///   * 修掉两个老问题：
///       1. 多选题永远不自动跳（提交走的是另一条分支，漏了调度）
///       2. 往回翻已经做过的题不显示答案（用的是一次性的 _submitted 标记，
///          翻页时被清掉了。现在改成按题号记录「这题已经揭示过答案」）
///   * 新增填空题 / 问答题
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

  /// 题号 → 已选选项下标
  final Map<int, List<int>> _choices = {};

  /// 题号 → 手打答案（填空 / 问答）
  final Map<int, String> _texts = {};

  /// 已经揭示过答案的题号。
  /// 之所以要按题号记下来（而不是用一个全局 bool），是因为翻页时不能把
  /// 「这题已经答过、答案已经显示」这件事忘掉 —— 那正是「回看不到答案」的根因。
  final Set<int> _revealed = {};

  /// 问答题的自评结果（题号 → 我答对了吗）。问答题没法自动判分，只能自评。
  final Map<int, bool> _essayVerdict = {};

  int _i = 0;
  bool _finished = false;

  /// 显示答案（true = 一答就出答案；false = 要按「确认答案」才判定）
  bool _showAnswerNow = true;

  /// 考试模式倒计时
  Timer? _examTimer;
  int _remainSec = 0;

  /// 自动跳下一题的倒计时
  Timer? _autoTimer;
  int _autoRemainMs = 0;
  bool _autoPaused = false;
  int _autoFor = -1; // 倒计时是为哪一题排的，切题后就作废

  final TextEditingController _input = TextEditingController();

  Question get _q => _list[_i];
  List<int> get _myChoice => _choices[_i] ?? const [];
  String get _myText => _texts[_i] ?? '';
  bool get _revealedHere => _revealed.contains(_i);
  bool get _isExam => widget.mode == QuizMode.exam;

  @override
  void initState() {
    super.initState();
    _list = List<Question>.from(widget.questions);
    if (widget.randomize) _list.shuffle(Random(DateTime.now().millisecondsSinceEpoch));
    _load();
    if (_isExam) _startExamClock();
  }

  void _startExamClock() {
    _remainSec = (widget.examMinutes ?? 40) * 60;
    _examTimer?.cancel();
    _examTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remainSec--);
      if (_remainSec <= 0) {
        _examTimer?.cancel();
        _submitExam();
      }
    });
  }

  Future<void> _load() async {
    // 注意两点：
    //   1. 从 provider 本身读值，不要走 `.notifier.state` —— 那个 state 是
    //      @protected 的，在外部读会被 lint 判为 invalid_use_of_protected_member。
    //   2. 读值是同步的，别加 await（analyzer 会报 await_only_futures）。
    final v = ref.read(quizPrefsProvider).showAnswerNow;
    if (!mounted) return;
    setState(() => _showAnswerNow = v);
  }

  @override
  void dispose() {
    _examTimer?.cancel();
    _autoTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 自动跳题

  /// 排一次「N 秒后自动跳下一题」。
  ///
  /// 两种模式取的时间完全不同：
  ///   * 显示答案模式 → 用设置里选的固定秒数（3/5/8…），0 表示不自动跳
  ///   * 不带答案模式 → 答对几乎立刻跳；答错停留用户设置的秒数，好让人看完解析
  void _scheduleAutoNext(int idx, bool correct) {
    _cancelAuto();
    if (_isExam || _finished) return;
    final prefs = ref.read(quizPrefsProvider);

    int ms;
    if (_showAnswerNow) {
      if (prefs.autoNextSec <= 0) return;
      ms = prefs.autoNextSec * 1000;
    } else {
      if (!prefs.autoNext) return;
      ms = correct ? 600 : prefs.wrongStaySec * 1000;
    }

    _autoFor = idx;
    _autoRemainMs = ms;
    // 注意：不重置 _autoPaused —— 用户按了「暂停」就该一直暂停，
    // 否则每答一题就又自动跑起来，暂停按钮等于没用。
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_autoPaused) return;
      setState(() => _autoRemainMs -= 100);
      if (_autoRemainMs <= 0) {
        t.cancel();
        final target = _autoFor;
        _autoRemainMs = 0;
        _autoFor = -1;
        if (mounted && target == _i && !_finished) _next();
      }
    });
  }

  void _cancelAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
    _autoRemainMs = 0;
    _autoFor = -1;
  }

  void _togglePause() {
    setState(() => _autoPaused = !_autoPaused);
  }

  // ------------------------------------------------------------ 判定

  bool _choiceCorrect(Question q, List<int> mine) {
    if (mine.length != q.answer.length) return false;
    final a = [...mine]..sort();
    final b = [...q.answer]..sort();
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 归一化：去掉所有空白和常见标点，再比大小写。
  /// 不这么做的话「答案写对了但多了个句号」也会被判错，很打击人。
  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\u3000]'), '')
      .replaceAll(RegExp(r'''[，。；：、！？,.;:!?"'“”‘’（）()【】\[\]《》<>·—\-_]'''), '');

  bool _fillCorrect(Question q, String input) {
    final mine = _norm(input);
    if (mine.isEmpty) return false;
    for (final a in q.textAccept) {
      // 一个答案项里可以用 | / ； 分隔多个等价写法
      for (final part in a.split(RegExp(r'[|/；;]'))) {
        final exp = _norm(part);
        if (exp.isNotEmpty && exp == mine) return true;
      }
    }
    return false;
  }

  /// 某道题算不算答对
  bool _correctAt(int k) {
    final q = _list[k];
    if (q.isEssay) return _essayVerdict[k] ?? false;
    if (q.isFill) return _fillCorrect(q, _texts[k] ?? '');
    return _choiceCorrect(q, _choices[k] ?? const []);
  }

  int get _answeredCount {
    var n = 0;
    for (var k = 0; k < _list.length; k++) {
      if (_choices.containsKey(k)) {
        n++;
      } else {
        final t = _texts[k];
        if (t != null && t.trim().isNotEmpty) n++;
      }
    }
    return n;
  }

  /// 记录对错：错 → 进错题本；对 → 错题本里标记为已掌握。
  /// 同时对错都会写入「已刷题」记录，刷题列表的进度条就是靠它统计的。
  Future<void> _record(Question q, List<int> mine, bool correct, {String myText = ''}) async {
    try {
      if (q.bankDir.isNotEmpty && q.id.isNotEmpty) {
        await AppDb.instance.markDone(q.bankDir, q.id);
      }
      if (correct) {
        if (q.bankDir.isNotEmpty && q.id.isNotEmpty) {
          await AppDb.instance.markMastered(q.bankDir, q.id, true);
        }
      } else {
        await AppDb.instance.upsertWrong(q, mine, myText: myText);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ 作答

  void _choose(int idx) {
    if (_revealedHere && !_isExam) return;
    final q = _q;
    // 「显示答案」开着时，单选/判断点一下就直接判定，不用再按确认。
    // 多选不行 —— 用户还得把剩下的选项也点完。
    final autoSubmit = !_isExam && _showAnswerNow && !q.isMulti;
    setState(() {
      if (q.isMulti) {
        final cur = [...(_choices[_i] ?? const <int>[])];
        cur.contains(idx) ? cur.remove(idx) : cur.add(idx);
        _choices[_i] = cur;
      } else {
        _choices[_i] = [idx];
      }
    });
    // 提交放在 setState 外面：_commit 自己也会 setState，
    // 套在一起是没意义的嵌套 setState。
    if (autoSubmit) _commit();
  }

  /// 提交当前题：揭示答案 → 记录 → 排自动跳题
  void _commit() {
    final idx = _i;
    final q = _list[idx];
    final mine = _choices[idx] ?? const <int>[];
    if (!q.isTextInput && mine.isEmpty) return;
    if (q.isTextInput && _myText.trim().isEmpty) return;

    final correct = _correctAt(idx);
    setState(() => _revealed.add(idx));
    _record(q, mine, correct, myText: _texts[idx] ?? '');
    _scheduleAutoNext(idx, correct);
  }

  /// 问答题自评（唯一可行的判分方式 —— 程序没法读懂人话）
  void _judgeEssay(bool ok) {
    final idx = _i;
    final q = _list[idx];
    setState(() {
      _essayVerdict[idx] = ok;
      _revealed.add(idx);
    });
    _record(q, const [], ok, myText: _texts[idx] ?? '');
    _scheduleAutoNext(idx, ok);
  }

  // ------------------------------------------------------------ 翻页

  void _goTo(int idx) {
    if (idx < 0 || idx >= _list.length) return;
    _cancelAuto();
    setState(() => _i = idx);
    _syncInput();
  }

  void _next() {
    if (_i < _list.length - 1) {
      _goTo(_i + 1);
    } else {
      if (_isExam) {
        _submitExam();
      } else {
        _cancelAuto();
        setState(() => _finished = true);
      }
    }
  }

  void _prev() => _goTo(_i - 1);

  /// 把输入框内容同步成当前题的草稿。
  /// 只在切题时调用，绝不能放在 build 里 —— 那会把用户正在打的字冲掉。
  void _syncInput() {
    final t = _texts[_i] ?? '';
    if (_input.text != t) {
      _input.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: t.length),
      );
    }
  }

  void _onInputChanged(String v) {
    _texts[_i] = v;
    setState(() {});
  }

  /// 练习模式提前结束：直接看小结
  void _finishPractice() {
    _cancelAuto();
    setState(() => _finished = true);
    ref.invalidate(wrongProvider);
    ref.invalidate(statsProvider);
  }

  Future<void> _submitExam() async {
    _examTimer?.cancel();
    _cancelAuto();
    // 统一记录对错（没作答的题不计入错题本，也不计入「已刷」）
    for (var k = 0; k < _list.length; k++) {
      final q = _list[k];
      final mine = _choices[k] ?? const <int>[];
      final text = _texts[k] ?? '';
      if (mine.isEmpty && text.trim().isEmpty) continue;
      _revealed.add(k);
      await _record(q, mine, _correctAt(k), myText: text);
    }
    ref.invalidate(wrongProvider);
    ref.invalidate(statsProvider);
    if (mounted) setState(() => _finished = true);
  }

  void _restart({bool wrongOnly = false}) {
    final wrong = <Question>[];
    for (var k = 0; k < _list.length; k++) {
      if (!_correctAt(k)) wrong.add(_list[k]);
    }
    _cancelAuto();
    _examTimer?.cancel();
    setState(() {
      _list = wrongOnly ? (wrong.isEmpty ? _list : wrong) : List<Question>.from(widget.questions);
      if (widget.randomize && !wrongOnly) _list.shuffle();
      _choices.clear();
      _texts.clear();
      _revealed.clear();
      _essayVerdict.clear();
      _i = 0;
      _finished = false;
    });
    _syncInput();
    if (_isExam) _startExamClock();
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
      appBar: _appBar(),
      body: _finished ? _resultView() : _questionView(),
    );
  }

  PreferredSizeWidget _appBar() {
    final scheme = Theme.of(context).colorScheme;
    final countdown = _autoRemainMs > 0;
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: 16), overflow: TextOverflow.ellipsis),
          Text(
            _isExam ? '模拟考试' : '第 ${_i + 1} / ${_list.length} 题',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        if (_isExam)
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _remainSec < 300 ? scheme.errorContainer : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined, size: 14),
                  const SizedBox(width: 4),
                  Text(formatDuration(_remainSec * 1000),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        if (!_isExam) ...[
          if (countdown)
            Center(
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: _autoPaused ? scheme.surfaceContainerHighest : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _autoPaused ? '已暂停' : '${(_autoRemainMs / 1000).ceil()} 秒后下一题',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ),
          IconButton(
            tooltip: _autoPaused ? '继续自动跳题' : '暂停自动跳题（多看一会）',
            onPressed: _togglePause,
            icon: Icon(_autoPaused ? Icons.play_circle_outline : Icons.pause_circle_outline),
          ),
          IconButton(
            tooltip: _showAnswerNow ? '当前：直接显示答案（点一下改成不显示）' : '当前：不直接显示答案',
            onPressed: () async {
              final v = !_showAnswerNow;
              setState(() => _showAnswerNow = v);
              await ref.read(quizPrefsProvider.notifier).setShowAnswerNow(v);
            },
            icon: Icon(_showAnswerNow ? Icons.visibility : Icons.visibility_off_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              final n = ref.read(quizPrefsProvider.notifier);
              if (v == 'end') {
                _finishPractice();
              } else if (v.startsWith('autoNext:')) {
                n.setAutoNextSec(int.parse(v.split(':')[1]));
              } else if (v.startsWith('autoOn:')) {
                n.setAutoNext(v.split(':')[1] == '1');
              } else if (v.startsWith('stay:')) {
                n.setWrongStaySec(int.parse(v.split(':')[1]));
              }
            },
            itemBuilder: (_) {
              final p = ref.read(quizPrefsProvider);
              return <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                    enabled: false,
                    height: 32,
                    child: Text('自动跳题秒数（显示答案时）', style: TextStyle(fontSize: 11.5))),
                for (final s in Defaults.autoNextSecOptions)
                  CheckedPopupMenuItem<String>(
                    value: 'autoNext:$s',
                    checked: p.autoNextSec == s,
                    child: Text(s == 0 ? '不自动跳' : '$s 秒'),
                  ),
                const PopupMenuDivider(),
                CheckedPopupMenuItem<String>(
                  value: 'autoOn:${p.autoNext ? 0 : 1}',
                  checked: p.autoNext,
                  child: const Text('不显示答案时也自动跳题'),
                ),
                const PopupMenuItem<String>(
                    enabled: false,
                    height: 32,
                    child: Text('答错后停留', style: TextStyle(fontSize: 11.5))),
                for (final s in Defaults.wrongStaySecOptions)
                  CheckedPopupMenuItem<String>(
                    value: 'stay:$s',
                    checked: p.wrongStaySec == s,
                    child: Text('$s 秒'),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                    value: 'end',
                    child: ListTile(leading: Icon(Icons.done_all), title: Text('结束本轮'), dense: true)),
              ];
            },
          ),
        ],
      ],
    );
  }

  Widget _questionView() {
    final scheme = Theme.of(context).colorScheme;
    final q = _q;

    return Column(
      children: [
        LinearProgressIndicator(value: (_i + 1) / _list.length, minHeight: 3),
        Expanded(
          // 左右滑动切题。阈值给 300 px/s：低于这个速度的横向划动多半
          // 只是手指抖动或想横向看长文本，不该翻页。
          child: GestureDetector(
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 300) {
                _prev();
              } else if (v < -300) {
                _next();
              }
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
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
                if (q.isTextInput) ..._textAnswerArea(q) else ..._optionsArea(q),
                const SizedBox(height: 16),
                if (_revealedHere) _analysisCard(q),
              ],
            ),
          ),
        ),
        _bottomBar(q),
      ],
    );
  }

  List<Widget> _optionsArea(Question q) {
    final mine = _myChoice;
    return [
      for (var j = 0; j < q.options.length; j++) _optionTile(j, q, mine),
      if (!_revealedHere && q.isMulti)
        FilledButton.icon(
          onPressed: mine.isEmpty ? null : _commit,
          icon: const Icon(Icons.check),
          label: const Text('确认答案'),
        ),
    ];
  }

  List<Widget> _textAnswerArea(Question q) {
    final scheme = Theme.of(context).colorScheme;
    final locked = _revealedHere && !_isExam;
    return [
      TextField(
        controller: _input,
        enabled: !locked,
        maxLines: q.isEssay ? 8 : 2,
        minLines: q.isEssay ? 4 : 1,
        textInputAction: q.isEssay ? TextInputAction.newline : TextInputAction.done,
        onChanged: _onInputChanged,
        decoration: InputDecoration(
          hintText: q.isFill ? '在下面写出你的答案' : '写下你的作答要点，再对照参考答案自评',
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 10),
      if (!_revealedHere)
        FilledButton.icon(
          onPressed: _myText.trim().isEmpty ? null : _commit,
          icon: Icon(q.isEssay ? Icons.menu_book_outlined : Icons.check),
          label: Text(q.isEssay ? '对照参考答案' : '确认答案'),
        ),
      if (q.isEssay && _revealedHere && !_isExam) ...[
        const SizedBox(height: 4),
        Text(
          '问答题没法自动判分，请你自己对照参考答案判断：',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _judgeEssay(true),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('我答对了'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _judgeEssay(false),
                icon: const Icon(Icons.highlight_off),
                label: const Text('我答错了'),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  Widget _optionTile(int j, Question q, List<int> mine) {
    final scheme = Theme.of(context).colorScheme;
    final picked = mine.contains(j);
    final isRight = q.answer.contains(j);

    Color bg = scheme.surfaceContainerHighest.withValues(alpha: 0.35);
    Color border = Colors.transparent;
    Color fg = scheme.onSurface;
    IconData? icon;

    if (_revealedHere) {
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
            border: Border.all(
                color: border == Colors.transparent ? scheme.outlineVariant.withValues(alpha: 0.5) : border,
                width: 1),
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
                  color: picked || (_revealedHere && isRight) ? scheme.primary.withValues(alpha: 0.15) : scheme.surface,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(String.fromCharCode(65 + j),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
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

  Widget _analysisCard(Question q) {
    final scheme = Theme.of(context).colorScheme;
    if (_isExam) return const SizedBox.shrink();
    final isEssay = q.isEssay;
    final judged = _essayVerdict.containsKey(_i);
    final correct = _correctAt(_i);
    final tone = judged ? (correct ? const Color(0xFF1D9E75) : scheme.error) : scheme.primary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                !judged
                    ? Icons.menu_book_outlined
                    : (correct ? Icons.check_circle_outline : Icons.highlight_off),
                size: 18,
                color: tone,
              ),
              const SizedBox(width: 6),
              Text(
                !judged
                    ? '参考答案'
                    : (correct ? '答对了' : '答错了，已自动记入错题本'),
                style: TextStyle(fontWeight: FontWeight.w600, color: tone),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (q.isTextInput)
            Text(
              '${isEssay ? '参考答案' : '正确答案'}：${q.textAccept.isEmpty ? '（题库里没写答案）' : q.textAccept.join(' / ')}',
              style: const TextStyle(fontSize: 13.5, height: 1.6),
            )
          else
            Text(
              '正确答案：${q.answer.map((e) => String.fromCharCode(65 + e)).join(' ')}',
              style: const TextStyle(fontSize: 13.5),
            ),
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
        border: Border(
            top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.6)),
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
            if (_isExam)
              OutlinedButton.icon(
                onPressed: _showCard,
                icon: const Icon(Icons.grid_view_outlined, size: 18),
                label: Text('答题卡 $_answeredCount/${_list.length}'),
              )
            else
              Text('已答 $_answeredCount/${_list.length}', style: const TextStyle(fontSize: 12.5)),
            const Spacer(),
            FilledButton.icon(
              onPressed: _next,
              icon: const Icon(Icons.chevron_right, size: 18),
              label: Text(_i == _list.length - 1 ? (_isExam ? '交卷' : '看小结') : '下一题'),
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
                        _goTo(k);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: (_choices.containsKey(k) || (_texts[k] ?? '').trim().isNotEmpty)
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                          border: k == _i
                              ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5)
                              : null,
                        ),
                        child: Text('${k + 1}', style: const TextStyle(fontSize: 12.5)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _submitExam();
                  },
                  child: const Text('交卷')),
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
    var scorable = 0;
    final wrongIdx = <int>[];
    for (var k = 0; k < _list.length; k++) {
      // 问答题没法自动判分，考试模式下不计入得分（练习模式是用户自评过的）
      if (_list[k].isEssay && (_isExam || !_essayVerdict.containsKey(k))) {
        continue;
      }
      scorable++;
      if (_correctAt(k)) {
        right++;
      } else {
        wrongIdx.add(k);
      }
    }
    final answered = _answeredCount;
    final score = scorable == 0 ? 0 : (right * 100 / scorable).round();

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
                    Text('$score',
                        style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            color: score >= 60 ? const Color(0xFF0F6E56) : scheme.error)),
                    Text('分', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text('答对 $right / $scorable 题', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '答错 ${wrongIdx.length} 题'
                '${_list.length - answered > 0 ? ' · 未作答 ${_list.length - answered} 题' : ''}'
                '${_list.length - scorable > 0 ? ' · 问答题不计分' : ''}',
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
          Text('错题回顾',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (var n = 0; n < wrongIdx.length; n++) ...[
                  if (n > 0) const Divider(height: 1),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.close, size: 18, color: Colors.red),
                    title: Text(_list[wrongIdx[n]].stem.replaceAll('\n', ' '),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_answerLine(_list[wrongIdx[n]]), style: const TextStyle(fontSize: 12)),
                    onTap: () {
                      _cancelAuto();
                      setState(() {
                        _revealed.add(wrongIdx[n]);
                        _finished = false;
                        _i = wrongIdx[n];
                      });
                      _syncInput();
                    },
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

  String _answerLine(Question q) {
    if (q.isTextInput) {
      return '${q.isEssay ? '参考答案' : '正确答案'}：'
          '${q.textAccept.isEmpty ? '（题库里没写答案）' : q.textAccept.join(' / ')}';
    }
    return '正确答案：${q.answer.map((e) => String.fromCharCode(65 + e)).join(' ')}';
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      );
}

extension on Question {
  /// 保留这个 extension 是为了 `q.typeLabel` 这种写法读起来顺；
  /// 真正的映射表已经收敛到 `Question.typeLabelOf`，别在这里再抄一份。
  String get typeLabel => Question.typeLabelOf(type);
}
