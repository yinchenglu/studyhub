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
import '../widgets/folder_picker.dart';
import 'login_page.dart';

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
  // v1.9.0：笔记目录要隐藏的文件夹名（逗号分隔字符串）
  String _noteHiddenDirs = 'image';

  /// 播放时自动隐藏控制栏（v1.8.0）。默认 false —— 菜单一直显示。
  bool _autoHideUi = false;

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
    final autoHide = await SettingsStore.instance.autoHidePlayerUi();
    // v1.9.0：笔记隐藏目录（显示成 csv）—— 必须在 setState 外面 await，
    // 否则 setState 回调不是 async，编译报 await only in async。
    final hiddenCsv = await SettingsStore.instance.noteHiddenDirsCsv();
    if (!mounted) return;
    setState(() {
      _cacheBytes = cache;
      _downloadBytes = dl;
      _speed = sp;
      _cacheLimit = limit;
      _saveHistory = saveHist;
      _downloadDir = dlDir;
      _autoHideUi = autoHide;
      _noteHiddenDirs = hiddenCsv;
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

          // v1.9.0：笔记 section（隐藏目录名配置）
          _section('笔记'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: const Text('笔记里要隐藏的文件夹'),
                  subtitle: Text(
                    _noteHiddenDirs.isEmpty ? '（读取中…）' : _noteHiddenDirs,
                    style: const TextStyle(fontSize: 12),
                  ),
                  isThreeLine: false,
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: _editHiddenDirs,
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '「image」始终在隐藏列表里。多个文件夹名用英文逗号分隔（如 image, assets, pic, img, photos）。重启 App 后生效。',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
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
            child: Column(
              children: [
                ListTile(
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
                const Divider(height: 1),
                // v1.8.0：用户要求「播放时菜单默认一直显示」，只有点全屏、
                // 或点菜单外的画面区域才收起。想恢复成「几秒后自动淡出」
                // 就打开这个开关（默认关）。
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: const Text('自动隐藏菜单'),
                  subtitle: Text(_autoHideUi
                      ? '播放中控制栏会在 3.5 秒后自动隐藏，点屏幕再呼出'
                      : '控制栏一直显示；点全屏或点画面空白处才会收起'),
                  value: _autoHideUi,
                  onChanged: (v) async {
                    await SettingsStore.instance.setAutoHidePlayerUi(v);
                    if (mounted) setState(() => _autoHideUi = v);
                  },
                ),
                const Divider(height: 1),
                // v1.5.0 起，播放器底栏那行小字（手势说明）挪到了这里。
                // 底栏本来就挤，那行字长期占着一行、又小又看不清，
                // 放在设置里想看的时候再点开，内容还能写得更全。
                ListTile(
                  leading: const Icon(Icons.touch_app_outlined),
                  title: const Text('播放器手势说明'),
                  subtitle: const Text('双击快进快退、左右滑拖进度、长按锁定方向……'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showGestureHelp,
                ),
              ],
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
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  secondary: const Icon(Icons.visibility_outlined),
                  title: const Text('选择后立即显示答案'),
                  subtitle: const Text('关掉就是「先自己想，按确认才判定」。'
                      '答题页顶栏的眼睛按钮随时能把当前这道题的答案调出来'),
                  value: prefs.showAnswerNow,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setShowAnswerNow(v),
                ),
                const Divider(height: 1),
                // v1.7.0：这里原来还有个「答完自动下一题」总开关（连带答题页菜单里的
                // 「不显示答案时也自动跳题」），用户要求撤掉 —— 只留三个时间设置，
                // 秒数选「不自动跳」就等于关。整段的行高也压了一档。
                //
                // ★ v1.8.0 用户又反馈「那 3 个自动跳题秒数的选项行距还是太宽」。
                //   上一版只是把 ListTile 设成 dense + visualDensity(-2)，
                //   但 ListTile 有 title **和** subtitle 时最少也要两行 + 上下内边距，
                //   压到 ~56px 就到头了。
                //   现在改成自己拼的**一行**：图标 + 标题 + 灰色说明 + 右侧下拉，
                //   整行高度降到 ~30px（说明文字跟标题同一行、字号小一档），
                //   在同一个屏幕里一眼能看全这三项，不用来回扫。
                _secRow(
                  icon: Icons.timelapse,
                  title: '自动跳题秒数',
                  hint: prefs.autoNextSec == 0
                      ? '普通模式：不自动跳'
                      : '普通模式：答完 ${prefs.autoNextSec} 秒跳下一题',
                  value: prefs.autoNextSec,
                  options: Defaults.autoNextSecOptions,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setAutoNextSec(v),
                ),
                const Divider(height: 1),
                _secRow(
                  icon: Icons.timer_off_outlined,
                  title: '答错和显示答案跳题秒数',
                  hint: prefs.wrongStaySec == 0
                      ? '答错、或点了「显示答案」之后：不自动跳'
                      : '答错、或点了「显示答案」之后：停留 ${prefs.wrongStaySec} 秒再跳',
                  value: prefs.wrongStaySec,
                  options: Defaults.wrongStaySecOptions,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setWrongStaySec(v),
                ),
                const Divider(height: 1),
                // 第三个时间 —— 「带答案刷题（只看不做）」自己的翻页间隔。
                // 答题页顶栏那个切换按钮切过去之后，就按这个秒数自动翻。
                _secRow(
                  icon: Icons.menu_book_outlined,
                  title: '只看不做跳题秒数',
                  hint: prefs.browseNextSec == 0
                      ? '带答案刷题（只看不做）：不自动跳'
                      : '带答案刷题（只看不做）：每 ${prefs.browseNextSec} 秒翻一页',
                  value: prefs.browseNextSec,
                  options: Defaults.browseNextSecOptions,
                  onChanged: (v) => ref.read(quizPrefsProvider.notifier).setBrowseNextSec(v),
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
                  title: const Text('清空视频播放进度'),
                  subtitle: const Text('所有视频的观看进度归零，「最近浏览」里的视频记录一并清掉'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final ok = await _confirm('清空视频播放进度？', '所有视频的观看进度会归零，笔记的浏览记录不受影响。');
                    if (!ok) return;
                    await AppDb.instance.clearMediaProgress();
                    ref.invalidate(recentProvider);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空视频进度')));
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('清空笔记浏览进度'),
                  subtitle: const Text('忘掉「每个目录上次看到哪篇」，下次进去重新定位'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final ok = await _confirm('清空笔记浏览进度？', '笔记内容不会被删，只是忘掉阅读位置记录。');
                    if (!ok) return;
                    await AppDb.instance.clearNoteProgress();
                    ref.invalidate(recentProvider);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空笔记进度')));
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('清空刷题进度'),
                  subtitle: const Text('每套题库的「已刷 N 题」归零，错题本不受影响'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final ok = await _confirm('清空刷题进度？', '所有题库的刷题记录都会清零（错题本保留）。');
                    if (!ok) return;
                    await AppDb.instance.clearDone();
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空刷题进度')));
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
                // v1.9.0：版本号不一致时给红字强提示
                if (kAppVersion != kPubspecVersion.split('+').first)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: Colors.red.withValues(alpha: 0.12),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '版本号不一致！\nkAppVersion=$kAppVersion  pubspec=$kPubspecVersion\n跑 python tools/bump_version.py 同步。',
                            style: const TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('学聚 · StudyHub'),
                  subtitle: Text('版本 $kAppVersion　自用版\n资料全部存放在你自己的 WebDAV 服务器'),
                  isThreeLine: true,
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

  /// v1.8.0：刷题那三个「跳题秒数」的紧凑行。
  ///
  /// 为什么不用 `ListTile(title:, subtitle:, trailing: DropdownButton)` ——
  /// 上一版就是这么写的（dense + visualDensity(-2)），用户连续两版都在说
  /// 「行距太宽」。两个原因：
  ///   1. ListTile 只要有 subtitle，最少也是两行文字 + 上下内边距，压到 ~56px 到头；
  ///   2. `DropdownButton.itemHeight` 有硬断言
  ///      `assert(itemHeight == null || itemHeight >= kMinInteractiveDimension)`，
  ///      48 是允许的最小值 —— 只要用它，整行就别想低于 48。
  ///
  /// 所以这里两件事一起改：
  ///   * 说明文字跟标题放**同一行**（字号小一档、灰色、放不下省略），省掉一整行；
  ///   * 下拉换成 `PopupMenuButton` + 自绘小胶囊（`PopupMenuItem.height` 可自由设，
  ///     v1.7.0 答题页那三个菜单已经用 height: 34 跑在真机上了，是验证过的写法）。
  ///
  /// 结果：一行从 ~56px 降到 ~32px，三项在一屏里能同时看全。
  Widget _secRow({
    required IconData icon,
    required String title,
    required String hint,
    required int value,
    required List<int> options,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 8, 3),
      child: Row(
        children: [
          Icon(icon, size: 17, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<int>(
            tooltip: '选择秒数',
            padding: EdgeInsets.zero,
            onSelected: onChanged,
            itemBuilder: (_) => [
              for (final s in options)
                PopupMenuItem<int>(
                  value: s,
                  height: 34,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(s == 0 ? '不自动跳' : '$s 秒',
                            style: const TextStyle(fontSize: 13)),
                      ),
                      if (s == value) const Icon(Icons.check, size: 16),
                    ],
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.fromLTRB(9, 3, 5, 3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(value == 0 ? '不自动跳' : '$value 秒',
                      style: const TextStyle(fontSize: 12.5)),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

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
                  // v1.6.0：用户要求「下载目录要能自定义文件夹」——
                  // 光能手填路径太费劲，给一个能一层层点进去的文件夹选择器
                  ActionChip(
                    avatar: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('浏览文件夹…'),
                    onPressed: () async {
                      final picked = await showDialog<String>(
                        context: ctx,
                        builder: (_) => FolderPicker(
                          initial: ctrl.text.trim().isEmpty ? sysPath : ctrl.text.trim(),
                        ),
                      );
                      if (picked != null && picked.isNotEmpty) ctrl.text = picked;
                    },
                  ),
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

  /// v1.9.0：编辑笔记隐藏目录（多个用英文逗号分隔）
  Future<void> _editHiddenDirs() async {
    final ctrl = TextEditingController(text: _noteHiddenDirs);
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('笔记里要隐藏的文件夹'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '多个文件夹名用英文逗号分隔。重启 App 后生效。\n「image」永远在列表里，不用写。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '隐藏的文件夹名',
                  hintText: 'image, assets, pic, img, photos',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await SettingsStore.instance.setNoteHiddenDirs(result);
    if (!mounted) return;
    final fresh = await SettingsStore.instance.noteHiddenDirsCsv();
    if (mounted) setState(() => _noteHiddenDirs = fresh);
  }

  /// 播放器手势说明。
  ///
  /// 这段文字原来是直接印在播放器底栏上的（一行 10.5 号小字），
  /// v1.5.0 按用户要求从底栏撤掉、内容搬到这里 —— 底栏留给按钮，
  /// 说明放在设置里反而能写得更细，也不占播放画面。
  void _showGestureHelp() {
    // 故意**不写 const**：这是一张 record 列表，写成 const 就是把
    // 「const 集合里放东西」的几类坑（F/G/H 三道网管的那些）主动往身上引，
    // 而这个对话框一辈子也开不了几次，那点分配开销不值一提。
    // 图标也都挑的是 Flutter 里最老最稳的那几个，不拿构建轮次去赌新图标。
    final rows = <(IconData, String, String)>[
      (Icons.touch_app, '双击屏幕左半边', '快退 10 秒'),
      (Icons.touch_app, '双击屏幕右半边', '快进 10 秒'),
      (Icons.touch_app, '双击屏幕中间', '播放 / 暂停'),
      (Icons.swap_horiz, '左右滑动', '拖动进度（松手才真正跳转，拖动时中间有预览时间）'),
      (Icons.volume_up, '右半屏上下滑', '调音量，上滑变大声'),
      (Icons.brightness_6, '左半屏上下滑', '调画面亮度，上滑变亮'),
      (Icons.touch_app, '点一下屏幕', '呼出或收起控制栏'),
      (Icons.lock_outline, '长按屏幕', '锁定 / 解锁屏幕方向；锁定后点屏幕不再呼出控制栏'),
      (Icons.volume_off, '底栏最右的喇叭', '点一下静音，再点一下恢复音量'),
      (Icons.speed, '底栏最左的倍速', '选 0.5× ~ 3.0×'),
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放器手势说明'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(r.$1, size: 17),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            Text(r.$3, style: TextStyle(fontSize: 12, height: 1.4, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                '横竖屏是跟着手机自动转的，不用点开关。想固定住长按屏幕锁定即可。',
                style: TextStyle(fontSize: 12, height: 1.5, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
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

/// v1.9.0 新增：设置页「关于」里点 README 进入的全文页面。
/// 内容默认从 assets/README.md 读；如果资产里没有就 fallback 到内置的简版。
class ReadmePage extends StatelessWidget {
  const ReadmePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('README · 项目自述')),
      body: const _ReadmeBody(),
    );
  }
}

class _ReadmeBody extends StatelessWidget {
  const _ReadmeBody();

  @override
  Widget build(BuildContext context) {
    // v1.9.0：先读 assets/README.md，没有就用内置 fallback（避免初次安装空页面）
    return FutureBuilder<String>(
      future: _loadReadme(),
      builder: (context, snap) {
        final text = snap.data ?? _fallback;
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 14, height: 1.6, fontFamily: 'monospace'),
          ),
        );
      },
    );
  }

  Future<String> _loadReadme() async {
    try {
      final file = File('assets/README.md');
      if (await file.exists()) return await file.readAsString();
    } catch (_) {}
    return _fallback;
  }

  static const _fallback = '''
# 学聚 StudyHub v1.9.0 · 项目自述

## 是什么
学聚是一款**自用版**学习/资料管理 App。
所有笔记、视频、题库都放在**你自己的 WebDAV 服务器**上，
App 只是个壳子 + 离线缓存 + 阅读/做题/播放体验。

## 文件框架
```
studyhub_app/
├── lib/
│   ├── main.dart             入口，初始化媒体/数据库/拼音
│   ├── app.dart              路由表
│   ├── core/                 工具（自然排序、屏幕、设置）
│   ├── data/
│   │   ├── dav/              WebDAV 客户端（增删查、上传）
│   │   ├── local/            本地数据库 + 设置存储
│   │   ├── models/           题目、笔记、收藏等数据模型
│   │   └── repositories/     笔记/题库/视频仓库
│   └── ui/                   页面（home/notes/quiz/tools/videos/common）
├── assets/                   静态资源（区划码 json / 字体 / 未来加 README.md）
├── tools/
│   ├── bump_version.py       改版本号脚本（v1.9.0 新增）
│   └── build_id_region.py    构建区划码数据
├── pubspec.yaml              依赖 + 版本号（version: 1.9.0+16）
└── android/                  Android 构建配置
```

## 数据来源
| 数据 | 来源 | License |
|---|---|---|
| 区划码 id_region.json | github.com/yescallop/areacodes | CC0 |
| 拼音表 | github.com/mozillazg/python-pinyin | MIT |
| 字体（翻页时钟） | 思源宋体/方正免费字体 | OFL |

## 怎么改版本号
跑 `python tools/bump_version.py 1.10.0`，自动同步两处。

## 怎么改笔记根目录的图片隐藏规则
设置页 → 笔记 → 「图片文件夹名」（v1.9.0 改）—— 输入多个文件夹名用逗号分隔。

## 服务器目录规范
见 StudyHub/README.md（v1.9.0 创建）。

## 维护日志
- v1.8.0：knots3d 图片兜底 / PDF 翻页 / 收藏空态 / 填空问答 / 身份证历史码 3002
- v1.9.0：笔记/视频/工具/数独大改 / 服务器上传 / README / 路路词典
''';
}
