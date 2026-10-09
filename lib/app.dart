import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'providers/providers.dart';
import 'ui/home/home_page.dart';
import 'ui/media/media_page.dart';
import 'ui/notes/notes_page.dart';
import 'ui/quiz/quiz_page.dart';
import 'ui/tools/tools_page.dart';

class StudyHubApp extends ConsumerWidget {
  const StudyHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: '学聚',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: const RootShell(),
    );
  }
}

/// 底部五个菜单：首页 / 笔记 / 视频 / 刷题 / 工具
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  final _notesKey = GlobalKey<NotesPageState>();
  final _mediaKey = GlobalKey<MediaPageState>();
  final _quizKey = GlobalKey<QuizPageState>();

  DateTime? _lastBackAt;

  @override
  void initState() {
    super.initState();
    // 启动时恢复上次登录的 WebDAV 账号
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(accountProvider.notifier).restore();
    });
  }

  /// 点击底部菜单
  void _onTab(int i) {
    final cur = ref.read(tabIndexProvider);
    ref.read(tabIndexProvider.notifier).state = i;
    // 再点一次当前菜单 = 回到该模块根目录并刷新
    if (i == cur) _reloadTab(i);
  }

  void _reloadTab(int i) {
    switch (i) {
      case 1:
        _notesKey.currentState?.reload();
        break;
      case 2:
        _mediaKey.currentState?.reload();
        break;
      case 3:
        _quizKey.currentState?.reload();
        break;
    }
  }

  /// 返回键：① 当前模块先返回上级目录 → ② 不在首页先回首页 → ③ 连按两次才退出
  Future<bool> _handleBack() async {
    final index = ref.read(tabIndexProvider);
    final handled = switch (index) {
      1 => _notesKey.currentState?.handleBack() ?? false,
      2 => _mediaKey.currentState?.handleBack() ?? false,
      3 => _quizKey.currentState?.handleBack() ?? false,
      _ => false,
    };
    if (handled) return false;

    if (index != 0) {
      ref.read(tabIndexProvider.notifier).state = 0;
      return false;
    }

    final now = DateTime.now();
    if (_lastBackAt == null || now.difference(_lastBackAt!) > const Duration(seconds: 2)) {
      _lastBackAt = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('再按一次返回键退出'), duration: Duration(seconds: 2)),
      );
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(tabIndexProvider);
    // 菜单一变，就让它回到根目录并刷新一次（这样点菜单进去就有内容）
    ref.listen(tabIndexProvider, (prev, next) {
      if (prev != next) _reloadTab(next);
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: index,
          children: [
            const HomePage(),
            NotesPage(key: _notesKey),
            MediaPage(key: _mediaKey),
            QuizPage(key: _quizKey),
            const ToolsPage(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: _onTab,
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
            NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: '笔记'),
            NavigationDestination(icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: '视频'),
            NavigationDestination(icon: Icon(Icons.quiz_outlined), selectedIcon: Icon(Icons.quiz), label: '刷题'),
            NavigationDestination(icon: Icon(Icons.widgets_outlined), selectedIcon: Icon(Icons.widgets), label: '工具'),
          ],
        ),
      ),
    );
  }
}
