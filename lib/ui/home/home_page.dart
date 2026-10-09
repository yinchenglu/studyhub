import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../providers/providers.dart';
import '../quiz/wrong_book_page.dart';
import 'login_page.dart';
import 'server_guide_page.dart';
import 'settings_page.dart';

/// 首页：未登录时给目录结构引导，登录后给账户信息 + 各类数量 + 错题本
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('学聚'),
        actions: [
          IconButton(
            tooltip: '刷新统计',
            onPressed: () {
              ref.invalidate(statsProvider);
              ref.invalidate(recentProvider);
              ref.read(accountProvider.notifier).recheck();
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(statsProvider);
          ref.invalidate(recentProvider);
          await ref.read(accountProvider.notifier).recheck();
          await ref.read(statsProvider.future);
        },
        child: account.isLoggedIn ? const _LoggedInView() : const _NotLoggedInView(),
      ),
    );
  }
}

/// ---------------------------------------------------------------- 未登录
class _NotLoggedInView extends ConsumerWidget {
  const _NotLoggedInView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        Icon(Icons.cloud_sync_outlined, size: 56, color: scheme.primary.withValues(alpha: 0.8)),
        const SizedBox(height: 12),
        Text('先把你的 WebDAV 服务器连上', textAlign: TextAlign.center, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          '所有笔记、视频、题库都存在你自己的服务器上，App 只负责读取和播放。',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage())),
          icon: const Icon(Icons.login),
          label: const Text('连接我的 WebDAV 服务器'),
        ),
        const SizedBox(height: 24),
        // ---- 未登录时也把服务器目录结构讲清楚 ----
        Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.account_tree_outlined, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('服务器端目录结构（照着建就行）',
                            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const SelectableText(
                      '/StudyHub/\n'
                      '  ├─ notes/     笔记（.md + 配图）\n'
                      '  ├─ media/     视频与图片\n'
                      '  ├─ quiz/      题库（.json）\n'
                      '  ├─ tools/     词库、速查表\n'
                      '  └─ backup/    错题本、备份',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.6),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('点这里看每个目录放什么、怎么建', style: TextStyle(fontSize: 12, color: scheme.primary)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '资料全部存在你自己的服务器上，App 不会上传任何内容到第三方。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 错题本是纯本地的，没登录也能看
        Card(
          child: ListTile(
            leading: const Icon(Icons.rule_folder_outlined),
            title: const Text('错题本'),
            subtitle: const Text('本地保存，不需要联网'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrongBookPage())),
          ),
        ),
      ],
    );
  }
}

/// ---------------------------------------------------------------- 已登录
class _LoggedInView extends ConsumerWidget {
  const _LoggedInView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final stats = ref.watch(statsProvider);
    final recent = ref.watch(recentProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final check = account.check;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ---- 账户卡片 ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.storage_rounded, color: scheme.onPrimaryContainer, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(account.account?.alias ?? '我的服务器',
                              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('${account.account?.username} · ${account.account?.root}',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (account.loading)
                      const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      IconButton(
                        tooltip: '重新检测',
                        onPressed: () => ref.read(accountProvider.notifier).recheck(),
                        icon: const Icon(Icons.sync, size: 20),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (check != null)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Chip(
                        icon: Icons.cloud_done_outlined,
                        label: check.canWrite ? '可读写' : '只读',
                        color: check.canWrite ? scheme.primary : scheme.tertiary,
                      ),
                      _Chip(
                        icon: Icons.fast_forward_outlined,
                        label: check.supportsRange ? '支持拖进度' : '不支持拖进度',
                        color: check.supportsRange ? scheme.primary : scheme.tertiary,
                      ),
                      if (check.missingDirs.isNotEmpty)
                        _Chip(
                          icon: Icons.warning_amber_outlined,
                          label: '缺目录 ${check.missingDirs.length} 个',
                          color: scheme.error,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
                        ),
                    ],
                  ),
                if (check != null && check.missingDirs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('缺少：${check.missingDirs.join('、')}，可点上面的标签查看怎么建',
                      style: TextStyle(fontSize: 12, color: scheme.error)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ---- 四宫格统计 ----
        stats.when(
          loading: () => const _StatsSkeleton(),
          error: (e, _) => _ErrorTile(text: '$e', onRetry: () => ref.invalidate(statsProvider)),
          data: (s) => Column(
            children: [
              Row(
                children: [
                  _StatTile(
                    label: '笔记',
                    value: s.noteCount,
                    unit: '篇',
                    icon: Icons.description_outlined,
                    color: ModuleColors.notes,
                    onTap: () => _goTab(ref, 1),
                  ),
                  const SizedBox(width: 12),
                  _StatTile(
                    label: '视频',
                    value: s.videoCount,
                    unit: '个',
                    icon: Icons.movie_outlined,
                    color: ModuleColors.media,
                    onTap: () => _goTab(ref, 2),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _StatTile(
                    label: '题库',
                    value: s.bankCount,
                    unit: '套',
                    icon: Icons.quiz_outlined,
                    color: ModuleColors.quiz,
                    onTap: () => _goTab(ref, 3),
                  ),
                  const SizedBox(width: 12),
                  _StatTile(
                    label: '工具',
                    value: 12,
                    unit: '个',
                    icon: Icons.widgets_outlined,
                    color: ModuleColors.tools,
                    onTap: () => _goTab(ref, 4),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ---- 错题本 ----
        Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrongBookPage())),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.error_outline, color: scheme.error, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('错题本', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        stats.maybeWhen(
                          data: (s) => Text('共 ${s.wrongCount} 题 · 未掌握 ${s.todayReviewCount} 题',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          orElse: () => Text('查看与复习做错的题目', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
        const SizedBox(height: 16),

        // ---- 服务器目录规范 ----
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('服务器目录规范'),
            subtitle: const Text('每个目录放什么、怎么建'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
          ),
        ),
        const SizedBox(height: 16),

        // ---- 最近浏览 ----
        Row(
          children: [
            Text('最近浏览', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            recent.maybeWhen(
              data: (list) => list.isEmpty
                  ? const SizedBox.shrink()
                  : TextButton.icon(
                      onPressed: () => _clearRecent(context, ref),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('清除'),
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
            TextButton(
              onPressed: () => _goTab(ref, 2),
              child: const Text('去媒体库'),
            ),
          ],
        ),
        recent.maybeWhen(
          data: (list) => list.isEmpty
              ? Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text('还没有播放记录，去「视频」里挑一个看看吧',
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                  ),
                )
              : Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.play_circle_outline, color: scheme.primary),
                          title: Text(baseName(list[i].key), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '看到 ${formatDuration(list[i].value.positionMs)} / ${formatDuration(list[i].value.durationMs)} · ${formatTime(list[i].value.updatedAt)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => _goTab(ref, 2),
                        ),
                      ],
                    ],
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// 切到底部菜单的某个模块（返回键行为因此和点底部菜单完全一致）
  void _goTab(WidgetRef ref, int i) => ref.read(tabIndexProvider.notifier).state = i;

  /// 清空「最近浏览」和所有播放进度
  Future<void> _clearRecent(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清除浏览记录？'),
        content: const Text('会清空「最近浏览」，同时把每个视频的观看进度归零。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.clearProgress();
    ref.invalidate(recentProvider);
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _Chip({required this.icon, required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final int value;
  final String unit;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _StatTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 6),
                    Text(label, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$value', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 3),
                    Text(unit, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(children: [
          Expanded(child: _box(context)),
          const SizedBox(width: 12),
          Expanded(child: _box(context)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _box(context)),
          const SizedBox(width: 12),
          Expanded(child: _box(context)),
        ]),
      ],
    );
  }

  Widget _box(BuildContext context) => Container(
        height: 84,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
        ),
      );
}

class _ErrorTile extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const _ErrorTile({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('统计失败：$text', style: const TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
