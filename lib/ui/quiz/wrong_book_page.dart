import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils.dart';
import '../../data/models/models.dart';
import '../../data/repositories/quiz_repo.dart';
import '../../providers/providers.dart';
import 'answer_page.dart';

/// 错题本：本地保存，按题库 / 知识点分组，可重做、可标记掌握
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

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: keys.length,
      itemBuilder: (context, gi) {
        final k = keys[gi];
        final items = groups[k]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
              child: Row(
                children: [
                  Icon(_group == 0 ? Icons.folder_outlined : Icons.label_outline, size: 15, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text('$k（${items.length}）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _redo(items),
                    child: const Text('练这一组', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 52),
                    ListTile(
                      dense: true,
                      leading: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: items[i].mastered ? const Color(0xFF1D9E75).withValues(alpha: 0.14) : scheme.errorContainer.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: items[i].mastered
                            ? const Icon(Icons.check, size: 16, color: Color(0xFF1D9E75))
                            : Text('${items[i].wrongCount}', style: TextStyle(fontSize: 12.5, color: scheme.error, fontWeight: FontWeight.w600)),
                      ),
                      title: Text(items[i].stem.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        items[i].tags.isEmpty ? '错误 ${items[i].wrongCount} 次' : '${items[i].tags.take(3).join(' · ')} · 错 ${items[i].wrongCount} 次',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _WrongDetailPage(record: items[i]))),
                    ),
                  ],
                ],
              ),
            ),
          ],
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

/// 单条错题详情
class _WrongDetailPage extends ConsumerWidget {
  final WrongRecord record;
  const _WrongDetailPage({required this.record});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('错题详情'),
        actions: [
          IconButton(
            tooltip: record.mastered ? '标记为未掌握' : '标记为已掌握',
            icon: Icon(record.mastered ? Icons.undo : Icons.check_circle_outline),
            onPressed: () async {
              await ref.read(wrongProvider.notifier).setMastered(record.id!, record.bankDir, record.questionId, !record.mastered);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          IconButton(
            tooltip: '删除这条错题',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await ref.read(wrongProvider.notifier).remove(record.id!);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Wrap(
            spacing: 6,
            children: [
              _chip(record.bankName.isEmpty ? record.bankDir : record.bankName, scheme.primary),
              _chip('错误 ${record.wrongCount} 次', scheme.error),
              for (final t in record.tags) _chip(t, scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 14),
          SelectableText(record.stem, style: const TextStyle(fontSize: 16.5, height: 1.65, fontWeight: FontWeight.w500)),
          const SizedBox(height: 16),
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
                  if (!record.answer.contains(j) && record.lastChoice.contains(j)) Icon(Icons.close, size: 17, color: scheme.error),
                ],
              ),
            ),
          if (record.analysis.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(12)),
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
            onPressed: () => _editNote(context, ref),
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
      ),
    );
  }

  Future<void> _editNote(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController(text: record.myNote);
    final r = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('我的笔记'),
        content: TextField(controller: c, maxLines: 6, autofocus: true, decoration: const InputDecoration(hintText: '记点自己的理解、易错点…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('保存')),
        ],
      ),
    );
    if (r != null) {
      await ref.read(wrongProvider.notifier).saveNote(record.id!, r);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      );
}
