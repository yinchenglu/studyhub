import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';
import '../../data/local/settings_store.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import 'login_page.dart';
import 'server_guide_page.dart';

/// 设置页：账号、缓存、播放、刷题、外观、关于
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  int _cacheBytes = 0;
  int _downloadBytes = 0;
  double _speed = 1.0;
  int _cacheLimit = 2048;
  bool _busy = false;
  bool _saveHistory = true;
  String _downloadDir = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = await CacheManager.instance.cacheSize();
    final dl = await CacheManager.instance.downloadSize();
    final sp = await SettingsStore.instance.playbackSpeed();
    final limit = await SettingsStore.instance.cacheLimitMb();
    final saveHist = await SettingsStore.instance.saveViewHistory();
    final dlDir = await CacheManager.instance.downloadDirPath();
    if (!mounted) return;
    setState(() {
      _cacheBytes = cache;
      _downloadBytes = dl;
      _speed = sp;
      _cacheLimit = limit;
      _saveHistory = saveHist;
      _downloadDir = dlDir;
    });
  }

  Future<void> _clearCache() async {
    final ok = await _confirm('清理临时缓存？', '清掉后本地不占空间，已下载的离线文件会保留。下次看视频会重新在线缓冲。');
    if (!ok) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await CacheManager.instance.clearCache();
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clearDownloads() async {
    final ok = await _confirm('删除所有已下载文件？', '删除后需要重新下载才能离线观看。');
    if (!ok) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await CacheManager.instance.clearDownloads();
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _confirm(String title, String content) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final prefs = ref.watch(quizPrefsProvider);
    final themeMode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _section('WebDAV 账号'),
          if (account.isLoggedIn)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.storage_rounded),
                    title: Text(account.account?.alias ?? ''),
                    subtitle: Text('${account.account?.baseUrl}\n账号：${account.account?.username} · 根目录：${account.account?.root}'),
                    isThreeLine: true,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.sync),
                    title: const Text('重新检测服务器能力'),
                    subtitle: Text(
                      account.check == null
                          ? '未检测'
                          : (account.check!.canWrite ? '可读写' : '只读') +
                              ' · ' +
                              (account.check!.supportsRange ? '支持拖进度' : '不支持拖进度'),
                    ),
                    trailing: account.loading
                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chevron_right),
                    onTap: () async {
                      await ref.read(accountProvider.notifier).recheck();
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text('切换 / 新增账号'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage())),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.logout, color: scheme.error),
                    title: Text('退出登录', style: TextStyle(color: scheme.error)),
                    onTap: () async {
                      final ok = await _confirm('退出登录？', '会清除本机保存的账号信息（服务器上的资料不受影响）。');
                      if (!ok) return;
                      await ref.read(accountProvider.notifier).logout();
                      ref.invalidate(statsProvider);
                      if (mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            )
          else
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: ListTile(
                leading: const Icon(Icons.login),
                title: const Text('还没有登录'),
                subtitle: const Text('点这里连接你的 WebDAV 服务器'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginPage())),
              ),
            ),

          _section('存储与缓存'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_alt_outlined),
                  title: const Text('下载目录'),
                  subtitle: Text(
                    _downloadDir.isEmpty ? '（读取中…）' : _downloadDir,
                    style: const TextStyle(fontSize: 12),
                  ),
                  isThreeLine: false,
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: _editDownloadDir,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('临时缓存'),
                  subtitle: Text('当前 ${formatBytes(_cacheBytes)} · 上限 ${_cacheLimit} MB'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text('上限', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      Expanded(
                        child: Slider(
                          value: _cacheLimit.toDouble().clamp(256, 8192),
                          min: 256,
                          max: 8192,
                          divisions: 31,
                          label: '${_cacheLimit}MB',
                          onChanged: (v) => setState(() => _cacheLimit = v.round()),
                          onChangeEnd: (v) async {
                            await SettingsStore.instance.setCacheLimitMb(v.round());
                            final freed = await CacheManager.instance.trimCache(v.round() * 1024 * 1024);
                            await _load();
                            if (mounted && freed > 0) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已按上限清理 ${formatBytes(freed)}')));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('离线下载文件'),
                  subtitle: Text('当前 ${formatBytes(_downloadBytes)}'),
                  trailing: TextButton(onPressed: _downloadBytes > 0 ? _clearDownloads : null, child: const Text('全部删除')),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('一键清理缓存'),
                  subtitle: const Text('清理后本地不占空间，离线下载保留'),
                  enabled: !_busy,
                  trailing: _busy
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  onTap: _clearCache,
                ),
              ],
            ),
          ),

          _section('播放'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('默认播放倍速'),
              subtitle: Text('${_speed.toStringAsFixed(1)}×'),
              trailing: SizedBox(
                width: 120,
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  onChanged: (v) => setState(() => _speed = v),
                  onChangeEnd: (v) async {
                    final fixed = (v * 10).round() / 10;
                    await SettingsStore.instance.setPlaybackSpeed(fixed);
                    if (mounted) setState(() => _speed = fixed);
                  },
                ),
              ),
            ),
          ),

          _section('刷题'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.format_list_numbered),
                  title: const Text('每轮题数'),
                  subtitle: Text('${prefs.perRound} 题'),
                  trailing: _stepper(
                    onMinus: prefs.perRound > 5 ? () => ref.read(quizPrefsProvider.notifier).setPerRound(prefs.perRound - 5) : null,
                    onPlus: prefs.perRound < 100 ? () => ref.read(quizPrefsProvider.notifier).setPerRound(prefs.perRound + 5) : null,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('模拟考试题量'),
                  subtitle: Text('${prefs.examCount} 题 / ${prefs.examMinutes} 分钟'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: prefs.examCount > 10
                            ? () => ref.read(quizPrefsProvider.notifier).setExamCount(prefs.examCount - 10)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      IconButton(
                        onPressed: prefs.examCount < 200
                            ? () => ref.read(quizPrefsProvider.notifier).setExamCount(prefs.examCount + 10)
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text('考试时长', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      Expanded(
                        child: Slider(
                          value: prefs.examMinutes.toDouble().clamp(5, 180),
                          min: 5,
                          max: 180,
                          divisions: 35,
                          label: '${prefs.examMinutes}分',
                          onChanged: (v) => ref.read(quizPrefsProvider.notifier).setExamMinutes(v.round()),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.flash_on_outlined),
                  title: const Text('答完自动下一题'),
                  subtitle: const Text('不开「显示答案」时生效：答对立刻跳，答错停留一会儿'),
                  value: prefs.autoNext,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setAutoNext(v),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_outlined),
                  title: const Text('选择后立即显示答案'),
                  subtitle: const Text('关掉就是「先自己想，按确认才判定」'),
                  value: prefs.showAnswerNow,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setShowAnswerNow(v),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timelapse),
                  title: const Text('自动跳题秒数'),
                  subtitle: Text(prefs.autoNextSec == 0
                      ? '不自动跳（只对「显示答案」模式生效）'
                      : '显示答案后 ${prefs.autoNextSec} 秒自动跳下一题'),
                  trailing: DropdownButton<int>(
                    value: prefs.autoNextSec,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in Defaults.autoNextSecOptions)
                        DropdownMenuItem(value: s, child: Text(s == 0 ? '关闭' : '$s 秒')),
                    ],
                    onChanged: (v) {
                      if (v != null) ref.read(quizPrefsProvider.notifier).setAutoNextSec(v);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_off_outlined),
                  title: const Text('答错后停留'),
                  subtitle: Text('答错后 ${prefs.wrongStaySec} 秒再自动跳到下一题，方便看解析'),
                  trailing: DropdownButton<int>(
                    value: prefs.wrongStaySec,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in Defaults.wrongStaySecOptions)
                        DropdownMenuItem(value: s, child: Text('$s 秒')),
                    ],
                    onChanged: (v) {
                      if (v != null) ref.read(quizPrefsProvider.notifier).setWrongStaySec(v);
                    },
                  ),
                ),
              ],
            ),
          ),

          _section('外观'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  groupValue: themeMode,
                  title: const Text('跟随系统'),
                  onChanged: (v) => ref.read(themeModeProvider.notifier).set(v!),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  groupValue: themeMode,
                  title: const Text('浅色'),
                  onChanged: (v) => ref.read(themeModeProvider.notifier).set(v!),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  groupValue: themeMode,
                  title: const Text('深色'),
                  onChanged: (v) => ref.read(themeModeProvider.notifier).set(v!),
                ),
              ],
            ),
          ),

          _section('数据'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('导出错题本到服务器'),
                  subtitle: const Text('写成 markdown 放到 backup 目录，方便电脑上看'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportWrong(),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('清空错题本'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final ok = await _confirm('清空错题本？', '所有错题记录都会被删除，无法恢复。');
                    if (!ok) return;
                    await ref.read(wrongProvider.notifier).clearAll();
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空')));
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.history_outlined),
                  title: const Text('保存浏览记录'),
                  subtitle: const Text('关掉后不再记录观看进度，「最近浏览」也不再新增'),
                  value: _saveHistory,
                  onChanged: (v) async {
                    await SettingsStore.instance.setSaveViewHistory(v);
                    if (mounted) setState(() => _saveHistory = v);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.history_toggle_off),
                  title: const Text('清空播放进度'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final ok = await _confirm('清空播放进度？', '所有视频的观看进度会归零。');
                    if (!ok) return;
                    await AppDb.instance.clearProgress();
                    ref.invalidate(recentProvider);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空')));
                  },
                ),
              ],
            ),
          ),

          _section('关于'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('学聚 · StudyHub'),
                  subtitle: Text('版本 1.0.0　自用版\n资料全部存放在你自己的 WebDAV 服务器'),
                  isThreeLine: true,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('服务器目录规范'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('隐私'),
                  subtitle: const Text('账号密码加密保存在本机，App 只连你自己的服务器'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper({VoidCallback? onMinus, VoidCallback? onPlus}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(onPressed: onMinus, icon: const Icon(Icons.remove_circle_outline)),
          IconButton(onPressed: onPlus, icon: const Icon(Icons.add_circle_outline)),
        ],
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// 修改下载目录：可以手填，也可以一键选「系统下载目录 / 应用专属目录」
  Future<void> _editDownloadDir() async {
    final scheme = Theme.of(context).colorScheme;
    final sysPath = await CacheManager.defaultDownloadPath();
    final appPath = await CacheManager.appPrivateDownloadPath();
    if (!mounted) return;

    final ctrl = TextEditingController(text: _downloadDir.isEmpty ? sysPath : _downloadDir);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: '保存路径',
                  hintText: '/storage/emulated/0/Download/StudyHub',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('系统下载目录'),
                    onPressed: () => ctrl.text = sysPath,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.phone_android_outlined, size: 16),
                    label: const Text('应用专属目录'),
                    onPressed: () => ctrl.text = appPath,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '说明\n'
                '· 写「下载」这类公共目录需要「所有文件访问」权限，第一次下载时会弹窗申请\n'
                '· 应用专属目录不需要权限，但文件管理器里不太好找\n'
                '· 目录不存在会自动创建',
                style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, '__cancel__'), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (result == null || result == '__cancel__') return;

    // 试建目录并写一个探针文件，确认真的可写
    final target = result.isEmpty ? sysPath : result;
    try {
      final d = Directory(target);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File(p.join(d.path, '.studyhub_write_test'));
      await probe.writeAsString('ok');
      if (await probe.exists()) await probe.delete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('这个目录写不进去，换一个试试：$e')),
        );
      }
      return;
    }

    await SettingsStore.instance.setDownloadDirPath(result.isEmpty ? null : result);
    CacheManager.instance.resetDownloadDirCache();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载目录已改为 $target')));
    }
  }

  /// 把错题本导出成 markdown 写到服务器的 backup 目录
  Future<void> _exportWrong() async {
    final client = ref.read(davClientProvider);
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先登录 WebDAV 才能导出')));
      return;
    }
    final list = await AppDb.instance.listWrong();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('错题本是空的')));
      return;
    }
    final buf = StringBuffer('# 错题本导出 ${DateTime.now().toString().substring(0, 16)}\n\n');
    final byBank = <String, List<WrongRecord>>{};
    for (final r in list) {
      byBank.putIfAbsent(r.bankName.isEmpty ? r.bankDir : r.bankName, () => []).add(r);
    }
    for (final e in byBank.entries) {
      buf.writeln('## ${e.key}（${e.value.length} 题）\n');
      for (var i = 0; i < e.value.length; i++) {
        final r = e.value[i];
        buf.writeln('### ${i + 1}. ${r.stem.replaceAll('\n', ' ')}');
        for (var j = 0; j < r.options.length; j++) {
          final mark = r.answer.contains(j) ? '**✔**' : '';
          final mine = r.lastChoice.contains(j) ? '（我的选择）' : '';
          buf.writeln('- ${String.fromCharCode(65 + j)}. ${r.options[j]} $mark $mine');
        }
        if (r.analysis.isNotEmpty) buf.writeln('\n> 解析：${r.analysis}');
        if (r.myNote.isNotEmpty) buf.writeln('\n> 我的笔记：${r.myNote}');
        buf.writeln('\n');
      }
    }
    try {
      final path = 'backup/错题本_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}.md';
      await client.writeText(path, buf.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出到服务器 $path（${list.length} 题）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }
}
