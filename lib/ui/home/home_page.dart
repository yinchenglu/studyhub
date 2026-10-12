import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../quiz/wrong_book_page.dart';
import 'login_page.dart';
import 'server_guide_page.dart';
import 'settings_page.dart';

/// 首页：未登录时给目录结构引导，登录后给账号信息 + 错题本 + 最近浏览
///
/// v1.4.0 改动（按用户要求）：
///   * **删掉「笔记多少篇 / 视频多少个 / 题库多少套 / 工具几个」那组四宫格**。
///     那几个数字每次都要把服务器上的目录各扫一遍，服务器一慢下拉就卡住，
///     而且进 App 想看的是「接着上次继续」，不是看库存。
///   * **账号卡片加了「切换账号」** —— 可以同时保存好几个 WebDAV，
///     在首页点一下就能换，不用退回设置页再登录一遍。
///   * **「最近浏览」现在把笔记也纳进来了**（原来只有视频播放记录），
///     点笔记那条会切到笔记模块。
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
            tooltip: '刷新',
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
          // 统计只读本地 SQLite，正常不会挂；真挂了也别让下拉刷新崩掉
          try {
            await ref.read(statsProvider.future);
          } catch (_) {}
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
                const SizedBox(height: 12),
                // ---- 切换账号：可以同时存好几个 WebDAV，这里直接换 ----
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _switchAccount(context, ref),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: Text(account.saved.length > 1
                        ? '切换账号（已保存 ${account.saved.length} 个）'
                        : '切换 / 添加账号'),
                  ),
                ),
              ],
            ),
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

        // ---- 最近浏览（视频播放记录 + 笔记打开记录）----
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
          ],
        ),
        recent.maybeWhen(
          data: (list) => list.isEmpty
              ? Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text('还没有浏览记录，去「视频」或「笔记」里打开一个试试',
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                  ),
                )
              : Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _recentTile(context, ref, list[i]),
                      ],
                    ],
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// 一条最近浏览记录。笔记和视频的副标题不一样：
  /// 笔记没有「看到几分几秒」这回事，硬套格式会出现「看到 00:00 / 00:00」。
  Widget _recentTile(BuildContext context, WidgetRef ref, MapEntry<String, PlayProgress> e) {
    final scheme = Theme.of(context).colorScheme;
    final isNote = e.key.startsWith('${AppDirs.notes}/');
    return ListTile(
      dense: true,
      leading: Icon(
        isNote ? Icons.description_outlined : Icons.play_circle_outline,
        color: isNote ? scheme.tertiary : scheme.primary,
      ),
      title: Text(baseName(e.key), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        isNote
            ? '笔记 · 打开于 ${formatTime(e.value.updatedAt)}'
            : '看到 ${formatDuration(e.value.positionMs)} / ${formatDuration(e.value.durationMs)} · ${formatTime(e.value.updatedAt)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _goTab(ref, isNote ? 1 : 2),
    );
  }

  /// 切到底部菜单的某个模块（返回键行为因此和点底部菜单完全一致）
  void _goTab(WidgetRef ref, int i) => ref.read(tabIndexProvider.notifier).state = i;

  /// 切换 / 添加账号。
  /// 返回的可能是某条 DavAccount（切过去），也可能是添加新账号的指令。
  Future<void> _switchAccount(BuildContext context, WidgetRef ref) async {
    final st = ref.read(accountProvider);
    final cur = st.account;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('切换服务器账号', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (st.saved.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('还没有保存过别的账号', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  ),
                for (final a in st.saved)
                  Builder(builder: (_) {
                    final same = cur != null && cur.baseUrl == a.baseUrl && cur.username == a.username;
                    return ListTile(
                      leading: Icon(
                        same ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: same ? cs.primary : cs.onSurfaceVariant,
                      ),
                      title: Text(a.alias.isEmpty ? a.baseUrl : a.alias),
                      subtitle: Text('${a.username} · ${a.baseUrl}', style: const TextStyle(fontSize: 11.5)),
                      onTap: () => Navigator.pop(ctx, a),
                    );
                  }),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('添加新账号 / 登录'),
                  onTap: () => Navigator.pop(ctx, '__add__'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (!context.mounted || picked == null) return;

    if (picked == '__add__') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage()));
      if (context.mounted) {
        ref.invalidate(statsProvider);
        ref.invalidate(recentProvider);
      }
      return;
    }
    if (picked is! DavAccount) return;
    if (cur != null && cur.baseUrl == picked.baseUrl && cur.username == picked.username) return;

    await ref.read(accountProvider.notifier).switchAccount(picked);
    ref.invalidate(statsProvider);
    ref.invalidate(recentProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已切换到 ${picked.alias.isEmpty ? picked.baseUrl : picked.alias}')));
    }
  }

  /// 清空「最近浏览」和所有浏览 / 播放进度
  Future<void> _clearRecent(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清除浏览记录？'),
        content: const Text('会清空「最近浏览」，笔记和视频的进度也会一起归零。'),
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
