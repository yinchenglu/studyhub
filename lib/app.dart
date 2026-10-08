import 'package:flutter/material.dart';
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
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 启动时恢复上次登录的 WebDAV 账号
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(accountProvider.notifier).restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = const [HomePage(), NotesPage(), MediaPage(), QuizPage(), ToolsPage()];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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
    );
  }
}
