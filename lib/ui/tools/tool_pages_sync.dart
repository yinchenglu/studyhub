import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/sync_service.dart';
import '../../providers/providers.dart';
import 'tool_pages.dart';

/// 文件夹同步（v1.5.0 用户第 1 条第 ⑷ 项）。
///
/// 打开开关之后，只要 App 还活着，就每隔几分钟对一次：
/// 本地目录 ↔ 服务器目录，直到两边一致。
///
/// 具体策略和边界都写在 lib/core/sync_service.dart 的注释里，这里只做界面：
///   * 比对依据是「文件大小 + 修改时间」，时间给 3 秒容差（HTTP 日期没有毫秒）
///   * 双向模式下冲突以「修改时间新的赢」，覆盖动作会写进日志
///   * 「删掉对端多出来的文件」默认关，且只在单向模式下允许开
class FolderSyncPage extends ConsumerStatefulWidget {
  const FolderSyncPage({super.key});

  @override
  ConsumerState<FolderSyncPage> createState() => _FolderSyncPageState();
}

class _FolderSyncPageState extends ConsumerState<FolderSyncPage> {
  late final _local = TextEditingController(text: SyncService.instance.config.localDir);
  late final _remote = TextEditingController(text: SyncService.instance.config.remoteDir);
  bool _dirty = false;

  @override
  void dispose() {
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  SyncConfig _cfgFromFields(SyncConfig base) => base.copy(
        localDir: _local.text.trim(),
        remoteDir: _remote.text.trim(),
      );

  Future<void> _saveAndRun() async {
    final dir = Directory(_local.text.trim());
    if (_local.text.trim().isEmpty || !await dir.exists()) {
      if (mounted) toast(context, '本地目录不存在，先改一下路径');
      return;
    }
    await SyncService.instance.saveConfig(_cfgFromFields(SyncService.instance.config));
    setState(() => _dirty = false);
    await SyncService.instance.runOnce();
  }

  @override
  Widget build(BuildContext context) {
    final svc = SyncService.instance;
    final logged = ref.watch(accountProvider).isLoggedIn;
    return ToolScaffold(
      title: '文件夹同步',
      subtitle: '本地文件夹 ↔ 服务器文件夹，后台每隔几分钟对一次',
      actions: [
        IconButton(
          tooltip: '说明',
          icon: const Icon(Icons.help_outline),
          onPressed: _showHelp,
        ),
      ],
      child: AnimatedBuilder(
        animation: svc,
        builder: (context, _) {
          final cfg = svc.config;
          final st = svc.state;
          final scheme = Theme.of(context).colorScheme;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              // ---------- 总开关 ----------
              Card(
                elevation: 0,
                color: cfg.enabled
                    ? scheme.primaryContainer.withValues(alpha: 0.45)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                child: SwitchListTile(
                  value: cfg.enabled,
                  onChanged: !logged
                      ? null
                      : (v) async {
                          if (v) {
                            final c = _cfgFromFields(cfg);
                            if (!c.usable) {
                              toast(context, '先把本地目录和服务器目录都填上');
                              return;
                            }
                            await svc.saveConfig(c.copy(enabled: true));
                            setState(() => _dirty = false);
                          } else {
                            await svc.setEnabled(false);
                          }
                        },
                  title: const Text('自动同步', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    cfg.enabled
                        ? '正在后台跑：每 ${cfg.intervalMin} 分钟对一次'
                        : '打开后每 ${cfg.intervalMin} 分钟对比一次，直到两边一致',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  secondary: Icon(
                    cfg.enabled ? Icons.sync : Icons.sync_disabled,
                    color: cfg.enabled ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!logged)
                const Padding(
                  padding: EdgeInsets.only(top: 8, left: 4),
                  child: Text('还没登录服务器，同步需要先登录（首页 → 登录）',
                      style: TextStyle(fontSize: 12.5, color: Colors.orange)),
                ),

              const ToolSection('要同步的两个目录'),

              TextField(
                controller: _local,
                decoration: InputDecoration(
                  labelText: '本地文件夹（手机上的绝对路径）',
                  hintText: '/storage/emulated/0/Download/StudyHub',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '用默认下载目录',
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () async {
                      final d = await downloadTargetDir();
                      if (!mounted || d == null) return;
                      _local.text = d.path;
                      setState(() => _dirty = true);
                      toast(context, '已填：${d.path}');
                    },
                  ),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _remote,
                decoration: const InputDecoration(
                  labelText: '服务器文件夹（资料库里的路径）',
                  hintText: 'notes/我的资料',
                  helperText: '相对资料根目录，不用写开头的 /StudyHub',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: st.busy ? null : _saveAndRun,
                      icon: Icon(_dirty ? Icons.save : Icons.play_arrow, size: 18),
                      label: Text(st.busy
                          ? '正在同步…'
                          : (_dirty ? '保存并立即对一次' : '立即对一次')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '清空日志',
                    onPressed: () {
                      svc.clearLog();
                      toast(context, '日志已清空');
                    },
                    icon: const Icon(Icons.cleaning_services_outlined),
                  ),
                ],
              ),

              const ToolSection('同步方向'),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in SyncDirection.values)
                    ChoiceChip(
                      label: Text(syncDirectionName(d).split('（').first,
                          style: const TextStyle(fontSize: 12.5)),
                      selected: cfg.direction == d,
                      onSelected: (_) async {
                        await svc.saveConfig(_cfgFromFields(cfg).copy(direction: d));
                        setState(() => _dirty = false);
                      },
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(syncDirectionName(cfg.direction),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),

              const ToolSection('每隔多久对一次'),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in Defaults.syncIntervalOptions)
                    ChoiceChip(
                      label: Text(m >= 60 ? '${m ~/ 60} 小时' : '$m 分钟',
                          style: const TextStyle(fontSize: 12.5)),
                      selected: cfg.intervalMin == m,
                      onSelected: (_) async {
                        await svc.saveConfig(_cfgFromFields(cfg).copy(intervalMin: m));
                        setState(() => _dirty = false);
                      },
                    ),
                ],
              ),

              // ---------- 删除选项 ----------
              if (cfg.direction != SyncDirection.both)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: cfg.deleteExtra,
                  onChanged: (v) async {
                    await svc.saveConfig(_cfgFromFields(cfg).copy(deleteExtra: v));
                    setState(() => _dirty = false);
                  },
                  title: const Text('删掉对端多出来的文件', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    cfg.direction == SyncDirection.up
                        ? '服务器上有、本地没有的文件会被删掉'
                        : '本地有、服务器没有的文件会被删掉',
                    style: const TextStyle(fontSize: 12),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('双向模式下不提供删除（谁该删谁说不清），需要严格镜像请选单向',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),

              const ToolSection('这一轮的情况'),

              Card(
                elevation: 0,
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (st.busy)
                            const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              st.error != null
                                  ? Icons.error_outline
                                  : (st.uploaded + st.downloaded + st.deleted > 0
                                      ? Icons.sync
                                      : Icons.cloud_done_outlined),
                              size: 18,
                              color: st.error != null ? scheme.error : scheme.primary,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(st.phase,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _line('本地文件', '${st.localCount} 个'),
                      _line('服务器文件', '${st.remoteCount} 个'),
                      _line('本轮上传 / 下载 / 删除',
                          '${st.uploaded} / ${st.downloaded} / ${st.deleted}'),
                      if (st.failed > 0) _line('失败', '${st.failed} 个（看下面的日志）'),
                      _line('上次对比', _timeText(st.lastRun)),
                      if (st.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(st.error!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
                        ),
                    ],
                  ),
                ),
              ),

              const ToolSection('日志'),

              if (st.log.isEmpty)
                Text('还没有记录', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))
              else
                for (final l in st.log)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(l,
                        style: TextStyle(
                            fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant)),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _line(String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            child: Text(k, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _timeText(DateTime? t) {
    if (t == null) return '还没跑过';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return '今天 $hm';
    return '${t.month}-${t.day} $hm';
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('同步说明'),
        content: SingleChildScrollView(
          child: Text(
            '怎么判断该传哪个\n'
            '· 先比文件大小，再比修改时间（给 3 秒容差 —— HTTP 的日期没有毫秒，'
            '有些服务器还会抹秒，容差太小会每轮都白传一遍）。\n'
            '· 双向模式下两边都改了同一个文件时，修改时间新的那份赢，'
            '旧的会被覆盖，动作都写在日志里。\n\n'
            '什么时候会停\n'
            '· 不会停。开着就每个周期对一次，两边一致时就是「零动作」，很轻。\n'
            '· App 被系统彻底关掉后不会自己醒过来（那要写常驻前台服务，'
            'Android 对这类应用限制很严）。重新打开 App 会自动接着跑，配置都在。\n\n'
            '几个提醒\n'
            '· 服务器目录要写资料库里的相对路径，比如 notes/我的资料。\n'
            '· 本地目录一般是 /storage/emulated/0/Download/... ；'
            'Android 11 起只能访问「下载」这类公共目录和 App 自己的目录。\n'
            '· 目录里名字以点开头的文件和临时文件会被跳过。\n'
            '· 删除是不可恢复的：手动删掉的本地文件，下一轮会被当成「本地没有」再下回来，'
            '除非你打开了「删掉对端多出来的文件」。',
            style: const TextStyle(height: 1.7, fontSize: 13.5),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了')),
        ],
      ),
    );
  }
}

/// 给外部（设置页 / 首页）用的一行状态文案
String syncStatusText() {
  final svc = SyncService.instance;
  final cfg = svc.config;
  if (!cfg.enabled) return '未开启';
  final st = svc.state;
  if (st.busy) return st.phase;
  if (st.error != null) return '出错：${st.error}';
  return st.phase;
}
