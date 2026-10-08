import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import 'server_files_page.dart';
import 'tool_pages.dart';

/// 工具页：全部离线可用，只有「服务器速查表」需要联网读 /tools
class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});

  static const _tools = <_ToolItem>[
    _ToolItem('单位换算', Icons.straighten, Color(0xFF185FA5), ToolKind.unit),
    _ToolItem('二维码', Icons.qr_code_2, Color(0xFF1D9E75), ToolKind.qr),
    _ToolItem('时间戳', Icons.schedule, Color(0xFF7F77DD), ToolKind.timestamp),
    _ToolItem('取色器', Icons.palette_outlined, Color(0xFFD4537E), ToolKind.color),
    _ToolItem('随机抽签', Icons.casino_outlined, Color(0xFFEF9F27), ToolKind.lottery),
    _ToolItem('番茄钟', Icons.timer_outlined, Color(0xFFD85A30), ToolKind.pomodoro),
    _ToolItem('秒表', Icons.timer, Color(0xFF534AB7), ToolKind.stopwatch),
    _ToolItem('摩斯电码', Icons.graphic_eq, Color(0xFF0F6E56), ToolKind.morse),
    _ToolItem('加密编码', Icons.lock_outline, Color(0xFF993C1D), ToolKind.cipher),
    _ToolItem('字数统计', Icons.text_fields, Color(0xFF27500A), ToolKind.wordCount),
    _ToolItem('计算器', Icons.calculate_outlined, Color(0xFF0C447C), ToolKind.calc),
    _ToolItem('服务器速查表', Icons.folder_shared_outlined, Color(0xFF72243E), ToolKind.server),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final logged = ref.watch(accountProvider).isLoggedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('工具')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.primaryContainer.withOpacity(0.35), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Icon(Icons.offline_bolt_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '这些小工具都做在 App 里，没网也能用。只有「服务器速查表」会去读你服务器 ${AppDirs.tools} 目录里的文件。',
                    style: const TextStyle(fontSize: 12.5, height: 1.55),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
            children: [
              for (final t in _tools)
                Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      if (t.kind == ToolKind.server && !logged) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('需要先连接 WebDAV 服务器')));
                        return;
                      }
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _pageFor(t.kind)));
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: t.color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                          child: Icon(t.icon, color: t.color, size: 22),
                        ),
                        const SizedBox(height: 10),
                        Text(t.name, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pageFor(ToolKind kind) {
    switch (kind) {
      case ToolKind.unit:
        return const UnitConverterPage();
      case ToolKind.qr:
        return const QrToolPage();
      case ToolKind.timestamp:
        return const TimestampPage();
      case ToolKind.color:
        return const ColorPickerToolPage();
      case ToolKind.lottery:
        return const LotteryPage();
      case ToolKind.pomodoro:
        return const PomodoroPage();
      case ToolKind.stopwatch:
        return const StopwatchPage();
      case ToolKind.morse:
        return const MorsePage();
      case ToolKind.cipher:
        return const CipherPage();
      case ToolKind.wordCount:
        return const WordCountPage();
      case ToolKind.calc:
        return const CalculatorPage();
      case ToolKind.server:
        return const ServerFilesPage();
    }
  }
}

enum ToolKind { unit, qr, timestamp, color, lottery, pomodoro, stopwatch, morse, cipher, wordCount, calc, server }

class _ToolItem {
  final String name;
  final IconData icon;
  final Color color;
  final ToolKind kind;
  const _ToolItem(this.name, this.icon, this.color, this.kind);
}

/// 供服务器速查表复用的工具函数
Future<List<DavEntry>> listToolFiles(WebDavClient client) async {
  final entries = await client.list(AppDirs.tools, depth: 1);
  return entries.where((e) => !e.isDir).toList();
}

String humanSize(int bytes) => formatBytes(bytes);
