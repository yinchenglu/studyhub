import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../data/repositories/quiz_repo.dart';
import '../../providers/providers.dart';
import 'answer_page.dart';

/// 错题本：本地保存，按题库 / 知识点分组，可重做、可标记掌握
///
/// v1.5.0 改版（按用户要求）：
///   * 改成**两级目录**：第一层列分组（题库 / 知识点），点进去才看题目列表。
///     原来是一屏把分组和题目全平铺出来，错题一多就滚不动、找不着。
///   * 详情页支持**左右滑动切上一题 / 下一题**（横向 PageView）。
///     配套改了「标记掌握」的行为：不再标一下就退出页面 ——
///     能滑着刷的时候，标完顺手滑到下一条才是正常用法。
class WrongBookPage extends ConsumerStatefulWidget {
  const WrongBookPage({super.key});

  @override
  ConsumerState<WrongBookPage> createState() => _WrongBookPageState();
}

class _WrongBookPageState extends ConsumerState<WrongBookPage> {
  int _filter = 0; // 0 全部 1 未掌握 2 已掌握
  int _group = 0; // 0 按题库 1 按知识点

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _refresh() {
    ref.read(wrongProvider.notifier).refresh(
          mastered: _filter == 0 ? null : _filter == 2,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wrongProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('错题本'),
        actions: [
          IconButton(
            tooltip: '全部重做',
            onPressed: () => _redo(state.valueOrNull ?? const []),
            icon: const Icon(Icons.replay_circle_filled_outlined),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('全部')),
                      ButtonSegment(value: 1, label: Text('未掌握')),
                      ButtonSegment(value: 2, label: Text('已掌握')),
                    ],
                    selected: {_filter},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      setState(() => _filter = s.first);
                      _refresh();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: _group == 0 ? '按题库分组' : '按知识点分组',
                  onPressed: () => setState(() => _group = _group == 0 ? 1 : 0),
                  icon: Icon(_group == 0 ? Icons.folder_outlined : Icons.label_outline),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: state.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('读取失败：$e')),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.emoji_events_outlined, size: 48, color: scheme.onSurfaceVariant),
                          const SizedBox(height: 12),
                          const Text('这里空空的，说明你还没做错过题'),
                          const SizedBox(height: 4),
                          Text('去刷题吧，做错的题会自动收进来', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  : _groupList(list),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组目录（v1.5.0 改版）。
  ///
  /// 原来是「分组标题 + 该组所有题平铺」——错题攒到几百条以后，
  /// 一屏能塞几十道题，想找某一道只能一路滚着看，滑都滑不动。
  /// 现在改成和刷题页一样的**两级目录**：
  /// 这一层只列分组（按题库 / 按知识点），点进去才看题目列表。
  Widget _groupList(List<WrongRecord> list) {
    final scheme = Theme.of(context).colorScheme;
    final groups = <String, List<WrongRecord>>{};
    for (final r in list) {
      if (_group == 0) {
        final k = r.bankName.isEmpty ? r.bankDir : r.bankName;
        groups.putIfAbsent(k, () => []).add(r);
      } else {
        if (r.tags.isEmpty) {
          groups.putIfAbsent('未分类', () => []).add(r);
        } else {
          for (final t in r.tags) {
            groups.putIfAbsent(t, () => []).add(r);
          }
        }
      }
    }
    final keys = groups.keys.toList()..sort();
    final byBank = _group == 0;

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: keys.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, gi) {
        final k = keys[gi];
        final items = groups[k]!;
        final unmastered = items.where((e) => !e.mastered).length;
        final tone = byBank ? const Color(0xFF185FA5) : const Color(0xFF7F77DD);
        return ListTile(
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(byBank ? Icons.folder_rounded : Icons.label_outline, color: tone),
          ),
          title: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '共 ${items.length} 题${unmastered > 0 ? ' · 未掌握 $unmastered' : ' · 全部已掌握'}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(
                builder: (_) => _WrongGroupPage(title: k, items: items, byBank: byBank),
              ))
              // 回来重拉一遍：里面可能标了「已掌握」或删了题，
              // 分组的计数、以及「未掌握」筛选的结果都得跟着变
              .then((_) => _refresh()),
        );
      },
    );
  }

  void _redo(List<WrongRecord> list) {
    if (list.isEmpty) return;
    final qs = list.map(questionFromWrong).toList();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnswerPage(questions: qs, title: '错题重做', randomize: true),
    )).then((_) => _refresh());
  }
}

/// 某一组错题的列表（一个题库 / 一个知识点）。
///
/// 单独一个页面，而不是展开在原页里 —— 见 `_groupList` 的说明。
class _WrongGroupPage extends ConsumerStatefulWidget {
  final String title;
  final List<WrongRecord> items;
  final bool byBank;

  const _WrongGroupPage({required this.title, required this.items, required this.byBank});

  @override
  ConsumerState<_WrongGroupPage> createState() => _WrongGroupPageState();
}

class _WrongGroupPageState extends ConsumerState<_WrongGroupPage> {
  late List<WrongRecord> _items;

  @override
  void initState() {
    super.initState();
    _items = List<WrongRecord>.from(widget.items);
  }

  /// 从详情页回来时重拉这一组。
  ///
  /// 按**自己这组的 id 集合**捞，而不是重新分组：详情页里可能标了「已掌握」
  /// 或删了题，id 集合能精确地把「改过的拿新值、删掉的不见了」处理掉，
  /// 又不会因为外面筛选条件变了就把这一组的题悄悄换掉。
  Future<void> _reload() async {
    final ids = _items.map((e) => e.id).whereType<int>().toSet();
    if (ids.isEmpty) return;
    try {
      final all = await AppDb.instance.listWrong();
      final mine = all.where((r) => r.id != null && ids.contains(r.id)).toList();
      if (!mounted) return;
      if (mine.isEmpty) {
        // 这组的题被删光了，留个空壳页面没意义
        Navigator.of(context).maybePop();
        return;
      }
      setState(() => _items = mine);
    } catch (_) {
      // 捞失败就沿用旧数据，总比把列表清空强
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${_items.length} 题', style: const TextStyle(fontSize: 11.5)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '练这一组',
            onPressed: () {
              final qs = _items.map(questionFromWrong).toList();
              Navigator.of(context)
                  .push(MaterialPageRoute(
                    builder: (_) => AnswerPage(questions: qs, title: '错题重做', randomize: true),
                  ))
                  .then((_) => _reload());
            },
            icon: const Icon(Icons.replay_circle_filled_outlined),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.only(bottom: 32),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 52),
        itemBuilder: (context, i) {
          final r = _items[i];
          return ListTile(
            dense: true,
            leading: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: r.mastered
                    ? const Color(0xFF1D9E75).withValues(alpha: 0.14)
                    : scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: r.mastered
                  ? const Icon(Icons.check, size: 16, color: Color(0xFF1D9E75))
                  : Text('${r.wrongCount}',
                      style: TextStyle(fontSize: 12.5, color: scheme.error, fontWeight: FontWeight.w600)),
            ),
            title: Text(r.stem.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              r.tags.isEmpty ? '错误 ${r.wrongCount} 次' : '${r.tags.take(3).join(' · ')} · 错 ${r.wrongCount} 次',
              style: const TextStyle(fontSize: 11.5),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            // 点某一道题进详情，并把**整组**一起带过去 ——
            // 详情页要靠它做左右滑动切上一题 / 下一题
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _WrongDetailPage(list: _items, initialIndex: i),
              ));
              await _reload();
            },
          );
        },
      ),
    );
  }
}

/// 单条错题详情。
///
/// v1.5.0 起支持**左右滑动切上一题 / 下一题**：整个页面是一个横向 PageView，
/// 每一页是一条错题的详情。所以构造时要拿到「这一组」的全部记录和当前下标，
/// 而不是单单一条。
class _WrongDetailPage extends ConsumerStatefulWidget {
  final List<WrongRecord> list;
  final int initialIndex;

  const _WrongDetailPage({required this.list, required this.initialIndex});

  @override
  ConsumerState<_WrongDetailPage> createState() => _WrongDetailPageState();
}

class _WrongDetailPageState extends ConsumerState<_WrongDetailPage> {
  late final PageController _pc;
  late List<WrongRecord> _list;
  late int _i;

  WrongRecord get _rec => _list[_i];

  @override
  void initState() {
    super.initState();
    _list = List<WrongRecord>.from(widget.list);
    _i = widget.initialIndex.clamp(0, _list.length - 1);
    _pc = PageController(initialPage: _i);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  /// 标记掌握 / 取消掌握。
  ///
  /// 这里**不再自动退出页面**：既然能左右滑着刷，标完一条顺手滑到下一条
  /// 才是正常的用法。原来标一下就 pop 回去，等于每次都把人踢出详情页。
  Future<void> _toggleMastered() async {
    final r = _rec;
    if (r.id == null) return;
    final next = !r.mastered;
    await ref.read(wrongProvider.notifier).setMastered(r.id!, r.bankDir, r.questionId, next);
    if (!mounted) return;
    setState(() => _list[_i] = r.copyWith(mastered: next));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(next ? '已标记为掌握' : '已改回未掌握'),
      duration: const Duration(seconds: 1),
    ));
  }

  Future<void> _delete() async {
    final r = _rec;
    if (r.id == null) return;
    await ref.read(wrongProvider.notifier).remove(r.id!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已从错题本删掉'),
      duration: Duration(seconds: 1),
    ));
    // 删完就直接退出：留在原地会显示一条已经被删掉的题，
    // 而「自动跳下一条」又要处理一大堆边界（删的是最后一条怎么办、
    // 列表空了怎么办），不如退回去让上层刷新，干净。
    Navigator.of(context).pop();
  }

  Future<void> _editNote() async {
    final r = _rec;
    final c = TextEditingController(text: r.myNote);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('我的笔记'),
        content: TextField(
          controller: c,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(hintText: '记点自己的理解、易错点…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('保存')),
        ],
      ),
    );
    if (result == null || r.id == null) return;
    await ref.read(wrongProvider.notifier).saveNote(r.id!, result);
    if (!mounted) return;
    setState(() => _list[_i] = r.copyWith(myNote: result));
  }

  @override
  Widget build(BuildContext context) {
    final n = _list.length;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('错题详情'),
            if (n > 1)
              Text('第 ${_i + 1} / $n 题 · 左右滑动切题',
                  style: const TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _rec.mastered ? '标记为未掌握' : '标记为已掌握',
            icon: Icon(_rec.mastered ? Icons.undo : Icons.check_circle_outline),
            onPressed: _toggleMastered,
          ),
          IconButton(
            tooltip: '删除这条错题',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pc,
        itemCount: n,
        onPageChanged: (k) => setState(() => _i = k),
        itemBuilder: (_, k) => _WrongDetailBody(
          record: _list[k],
          onEditNote: k == _i ? _editNote : null,
        ),
      ),
    );
  }
}

/// 一条错题的正文（题干、选项、解析、笔记、重做按钮）。
///
/// 从原来那个「详情页」里剥出来：现在详情页是一个 PageView 的容器，
/// 每一页都渲染一份这个。剥出来之后这个组件是纯展示 + 回调，
/// 不碰状态，也不碰「左右滑」那些事。
class _WrongDetailBody extends StatelessWidget {
  final WrongRecord record;
  final Future<void> Function()? onEditNote;

  const _WrongDetailBody({required this.record, this.onEditNote});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Wrap(
          spacing: 6,
          children: [
            _chip(record.bankName.isEmpty ? record.bankDir : record.bankName, scheme.primary),
            _chip(Question.typeLabelOf(record.qtype), scheme.tertiary),
            _chip('错误 ${record.wrongCount} 次', scheme.error),
            for (final t in record.tags) _chip(t, scheme.onSurfaceVariant),
          ],
        ),
        const SizedBox(height: 14),
        SelectableText(record.stem, style: const TextStyle(fontSize: 16.5, height: 1.65, fontWeight: FontWeight.w500)),
        const SizedBox(height: 16),
        // 填空题 / 问答题没有选项，走「我的答案 ↔ 正确答案」对照块。
        // v1.3.0 加的：以前这类题进错题本后只剩题干 + 空白，看不出自己错在哪。
        // 选项为空时下面的 for 自然不执行，两者互斥，不会重复渲染。
        if (record.options.isEmpty) _textBlock(record, scheme),
        for (var j = 0; j < record.options.length; j++)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: record.answer.contains(j)
                  ? const Color(0xFF1D9E75).withValues(alpha: 0.12)
                  : record.lastChoice.contains(j)
                      ? scheme.errorContainer.withValues(alpha: 0.35)
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Text('${String.fromCharCode(65 + j)}. ', style: const TextStyle(fontWeight: FontWeight.w600)),
                Expanded(child: Text(record.options[j], style: const TextStyle(fontSize: 15, height: 1.5))),
                if (record.answer.contains(j)) const Icon(Icons.check, size: 17, color: Color(0xFF1D9E75)),
                if (!record.answer.contains(j) && record.lastChoice.contains(j))
                  Icon(Icons.close, size: 17, color: scheme.error),
              ],
            ),
          ),
        if (record.analysis.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('解析', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(height: 6),
                SelectableText(record.analysis, style: const TextStyle(fontSize: 14, height: 1.65)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (record.myNote.isNotEmpty) ...[
          Text('我的笔记', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(record.myNote, style: const TextStyle(fontSize: 14, height: 1.6)),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: onEditNote,
          icon: const Icon(Icons.edit_note, size: 18),
          label: Text(record.myNote.isEmpty ? '给这道题写点笔记' : '修改我的笔记'),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AnswerPage(questions: [questionFromWrong(record)], title: '重做'),
            ));
          },
          icon: const Icon(Icons.replay),
          label: const Text('现在重做一遍'),
        ),
        const SizedBox(height: 20),
        Text(
          '最近错误：${formatTime(record.lastWrongAt)}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      );

  /// 填空题 / 问答题的「我的答案 ↔ 正确答案」对照块。v1.3.0 新增。
  Widget _textBlock(WrongRecord r, ColorScheme scheme) {
    final mine = r.lastText.trim();
    // 优先用 textAccept（题库里写的可接受答案列表）；
    // 老数据没有这个字段，就退回 answer 里存的文本答案。
    final correct = r.textAccept.isNotEmpty
        ? r.textAccept
        : (r.answer.isNotEmpty ? <String>[r.answer.join(' ')] : const <String>[]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mine.isEmpty ? '我当时没有作答' : '我的答案',
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SelectableText(mine.isEmpty ? '（空）' : mine, style: const TextStyle(fontSize: 15, height: 1.6)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1D9E75).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('正确答案', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SelectableText(correct.isEmpty ? '（题库未提供答案）' : correct.join('   /   '),
                  style: const TextStyle(fontSize: 15, height: 1.6)),
            ],
          ),
        ),
      ],
    );
  }
}
