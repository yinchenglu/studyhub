import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import '../media/image_viewer_page.dart';
import '../media/player_page.dart';
import '../notes/note_read_page.dart';
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

        // ---- 我的收藏（v1.7.0；按用户要求放在错题本上面）----
        const _FavoriteSection(),

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
        //
        // v1.5.0：清除按钮从 1 个拆成 2 个 —— 一个清笔记、一个清视频。
        // 原来那一个「清除」是把两边一起抹掉，可实际想清的时候往往是「视频那一堆
        // 看了一半的片子看烦了想清掉，笔记的记录还要留着」。而且这个动作不可撤销，
        // 一刀切太粗暴。
        // 另外：哪边没有记录就不显示对应的按钮，免得出现「点了没反应」。
        //
        // v1.7.0（用户第 6 条）：默认只露最近 5 条，剩下的点「更多」再展开。
        // 展开状态存在 recentExpandedProvider 里 —— 首页是 ConsumerWidget、
        // 自己不带 state，`setState` 用不了。
        recent.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (all) {
            final expanded = ref.watch(recentExpandedProvider);
            final shown = expanded ? all : all.take(5).toList();
            final hasNote = all.any((e) => e.key.startsWith('${AppDirs.notes}/'));
            final hasMedia = all.any((e) => !e.key.startsWith('${AppDirs.notes}/'));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('最近浏览', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    if (all.length > 5) ...[
                      const SizedBox(width: 6),
                      Text('共 ${all.length} 条',
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    ],
                    const Spacer(),
                    if (all.length > 5)
                      TextButton(
                        onPressed: () =>
                            ref.read(recentExpandedProvider.notifier).state = !expanded,
                        child: Text(expanded ? '收起' : '更多'),
                      ),
                  ],
                ),
                // 清记录的两个按钮单独一行 —— 和「更多」挤在同一行会溢出
                if (hasNote || hasMedia)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (hasNote)
                        TextButton(
                          onPressed: () => _clearRecent(context, ref, note: true),
                          child: const Text('清笔记记录'),
                        ),
                      if (hasMedia)
                        TextButton(
                          onPressed: () => _clearRecent(context, ref, note: false),
                          child: const Text('清视频记录'),
                        ),
                    ],
                  ),
                if (all.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: Text('还没有浏览记录，去「视频」或「笔记」里打开一个试试',
                            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      ),
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _recentTile(context, ref, shown[i]),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
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

  /// 清空「最近浏览」。
  ///
  /// [note] 为 true 只清笔记的记录，false 只清视频（含音频）的记录 ——
  /// 对应右边那两个按钮。进度和记录在同一张表里（progress），
  /// 所以清记录的同时也就把「看到哪了」一起归零了，这是符合预期的：
  /// 记录都没了还留着进度，下次点进去接着播反而莫名其妙。
  Future<void> _clearRecent(BuildContext context, WidgetRef ref, {required bool note}) async {
    final what = note ? '笔记' : '视频';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('清除$what浏览记录？'),
        content: Text(note
            ? '会清空「最近浏览」里的笔记记录，这些笔记的「上次看到这」提示也会一起消失。\n视频记录不受影响。'
            : '会清空「最近浏览」里的视频记录，这些视频的播放进度也会一起归零。\n笔记记录不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    if (note) {
      await AppDb.instance.clearNoteProgress();
    } else {
      await AppDb.instance.clearMediaProgress();
    }
    ref.invalidate(recentProvider);
  }
}

/// 切到底部菜单的某个模块。做成顶层函数是因为首页里几个子组件都要用，
/// 各自再写一遍容易改漏。
void _switchTab(WidgetRef ref, int i) => ref.read(tabIndexProvider.notifier).state = i;

/// ---------------------------------------------------------------- 我的收藏
///
/// v1.7.0 用户第 6 条：笔记 / 视频里的文件和文件夹长按都能收藏，
/// 收藏的东西集中摆在这儿，按「笔记」「视频」两类分开。
///
/// 点一下的行为分两种：
///   * 文件 —— **直接打开**（笔记进阅读页、视频进播放器），这才是「快速打开」
///   * 文件夹 —— 切到对应模块。跨页把某个目录就地展开需要各模块配合，
///     这里用最稳的方式：导航过去 + 明确告诉用户该进哪个目录
/// 长按 = 取消收藏（会先问一次，免得手滑）。
class _FavoriteSection extends ConsumerWidget {
  const _FavoriteSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(favoriteProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return fav.maybeWhen(
      data: (list) {
        // v1.8.0：即使收藏为空也始终显示「我的收藏」区域（用户要求）
        final notes = list.where((e) => e.isNote).toList();
        final media = list.where((e) => !e.isNote).toList();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('我的收藏', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text('${list.length} 项 · 长按可取消',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 6),
              Card(
                child: Column(
                  children: [
                    if (notes.isNotEmpty) ...[
                      _groupHeader('笔记', notes.length, Icons.description_outlined, scheme),
                      for (var i = 0; i < notes.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        _tile(context, ref, notes[i]),
                      ],
                    ],
                    if (notes.isNotEmpty && media.isNotEmpty) const Divider(height: 8),
                    if (media.isNotEmpty) ...[
                      // 视频和图片都归在这一组：收藏里只存了路径，
                      // 分组靠 kind 的 media 前缀，细分没意义
                      _groupHeader('视频 / 图片', media.length, Icons.play_circle_outline, scheme),
                      for (var i = 0; i < media.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        _tile(context, ref, media[i]),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
      orElse: () => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('我的收藏', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text('0 项 · 长按可取消',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 6),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text('还没有收藏，在笔记或视频里长按文件/文件夹即可收藏',
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(String label, int n, IconData icon, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text('$label · $n 项',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _tile(BuildContext context, WidgetRef ref, FavoriteItem f) {
    final scheme = Theme.of(context).colorScheme;
    final name = f.title.isEmpty ? baseName(f.path) : f.title;
    final accent = f.isFolder
        ? const Color(0xFF185FA5)
        : (f.isNote ? const Color(0xFF7F77DD) : scheme.primary);
    // 收藏里只存了路径 —— 是视频还是图片，靠扩展名现判
    final isImg = !f.isNote && !f.isFolder && FileTypes.isImage(f.path);
    return ListTile(
      dense: true,
      leading: Icon(
        f.isFolder
            ? Icons.folder_rounded
            : (f.isNote
                ? Icons.article_outlined
                : (isImg ? Icons.image_outlined : Icons.play_circle_outline)),
        color: accent,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        f.isFolder ? '文件夹 · 点击切到${f.isNote ? '笔记' : '视频'}模块' : baseName(f.path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _open(context, ref, f),
      onLongPress: () => _unfavorite(context, ref, f),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, FavoriteItem f) async {
    if (f.isFolder) {
      _switchTab(ref, f.isNote ? 1 : 2);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已切到${f.isNote ? '笔记' : '视频'}模块，进入「${f.title}」就能看到'),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    if (f.isNote) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => NoteReadPage(path: f.path)));
      ref.invalidate(recentProvider);
      return;
    }
    // 视频 / 音频 / 图片：收藏里只有一个路径，类型靠扩展名现判 ——
    // 原来这里写死 isVideo: true，收藏一张图片点开就会拿播放器去解图片
    final client = ref.read(davClientProvider);
    if (client == null) return;
    if (FileTypes.isPlayable(f.path)) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerPage(
          playlist: [MediaItem(path: f.path, isVideo: FileTypes.isVideo(f.path))],
          initialIndex: 0,
        ),
      ));
    } else if (FileTypes.isImage(f.path)) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageViewerPage(
          images: [client.urlFor(f.path)],
          headers: client.headers,
          titles: [baseName(f.path)],
        ),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打不开这个文件：${baseName(f.path)}')));
      return;
    }
    ref.invalidate(recentProvider);
  }

  Future<void> _unfavorite(BuildContext context, WidgetRef ref, FavoriteItem f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('取消收藏？'),
        content: Text(f.title.isEmpty ? f.path : f.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('取消收藏')),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.removeFavorite(f.path);
    ref.invalidate(favoriteProvider);
    ref.invalidate(isFavoriteProvider(f.path));
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
