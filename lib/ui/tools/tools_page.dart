import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import 'download_site_page.dart';
import 'server_html_tools.dart';
import 'tool_pages.dart';
import 'tool_pages_ext.dart';

/// 工具页
///
/// 布局约定：
///   * 最上面单独一行是「服务器下载站」—— 直接进，不折叠、不藏在菜单里
///   * 下面按用途分成 6 类，一共 20 个离线小工具
///   * 最后再挂一个「服务器小工具」，识别服务器 tools 目录里的 html 小工具
///
/// v1.3.0 按用户要求重排了分类归属与顺序：
///   测量与感官 ← 挂画助手（要对着实物比水平线，本质是测量）
///   时间与效率 ← LED 屏幕（滚动字幕就是打鸡血/报时用的）
///   生活与娱乐 提到第 3 位，SOS 手电筒放它第一个
///   颜色与设计 ← 简易画板（画画就是配色调色的事）
class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});

  /// 全部离线小工具，按用途分类
  static const categories = <_Category>[
    _Category('测量与感官', Icons.straighten, [
      _ToolDef('直尺', Icons.straighten, Color(0xFF185FA5)),
      _ToolDef('量角器', Icons.architecture, Color(0xFF7F77DD)),
      _ToolDef('噪声测量', Icons.graphic_eq, Color(0xFF1D9E75)),
      _ToolDef('屏幕坏点检测', Icons.grid_on, Color(0xFFD4537E)),
      _ToolDef('挂画助手', Icons.straighten_outlined, Color(0xFF72243E)),
    ]),
    _Category('时间与效率', Icons.schedule, [
      _ToolDef('番茄时钟', Icons.timer_outlined, Color(0xFFD85A30)),
      _ToolDef('日期计算', Icons.calendar_month_outlined, Color(0xFFEF9F27)),
      _ToolDef('时间戳转换', Icons.access_time, Color(0xFF534AB7)),
      _ToolDef('提词器', Icons.vertical_align_bottom, Color(0xFF27500A)),
      _ToolDef('LED 屏幕', Icons.brightness_high, Color(0xFFEF9F27)),
    ]),
    // 用户要求：生活与娱乐排第 3。它原来在最后一位。
    _Category('生活与娱乐', Icons.sports_esports_outlined, [
      _ToolDef('SOS 手电筒', Icons.flashlight_on, Color(0xFFB8860B)),
      _ToolDef('抛硬币', Icons.casino_outlined, Color(0xFFE0A020)),
      _ToolDef('快递查询', Icons.local_shipping_outlined, Color(0xFF185FA5)),
    ]),
    _Category('颜色与设计', Icons.palette_outlined, [
      _ToolDef('配色助手', Icons.auto_awesome, Color(0xFFD4537E)),
      _ToolDef('颜色码转换', Icons.colorize_outlined, Color(0xFF0C447C)),
      _ToolDef('简易画板', Icons.brush_outlined, Color(0xFF7F77DD)),
    ]),
    _Category('文字与编码', Icons.text_fields, [
      _ToolDef('摩斯电码', Icons.wifi_tethering, Color(0xFF0F6E56)),
      _ToolDef('加密编码', Icons.lock_outline, Color(0xFF993C1D)),
      _ToolDef('二维码生成', Icons.qr_code_2, Color(0xFF1D9E75)),
    ]),
    _Category('设备与应用', Icons.phone_android, [
      _ToolDef('应用管理', Icons.apps_outlined, Color(0xFF34C759)),
    ]),
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
          // ---------- 置顶：服务器下载站（单独一行）----------
          _DownloadStationRow(logged: logged),
          const SizedBox(height: 10),

          // ---------- 服务器 html 小工具 ----------
          _ServerToolsRow(logged: logged),

          // ---------- 离线小工具 ----------
          for (final c in categories) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
              child: Row(
                children: [
                  Icon(c.icon, size: 16, color: scheme.primary),
                  const SizedBox(width: 7),
                  Text(c.name,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
                  const SizedBox(width: 7),
                  Text('${c.tools.length} 个',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 11,
              crossAxisSpacing: 11,
              childAspectRatio: 0.98,
              children: [
                for (final t in c.tools) _toolCard(context, t),
              ],
            ),
          ],

          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.offline_bolt_outlined, size: 17, color: scheme.onSurfaceVariant),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '这些小工具都做在 App 里，没网也能用。\n'
                    '上面两个按钮需要连上你的 WebDAV 服务器：'
                    '「下载站」读 /${AppDirs.download}，「小工具」读 /${AppDirs.tools}。',
                    style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolCard(BuildContext context, _ToolDef t) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => toolPageOf(t.name)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(t.icon, color: t.color, size: 22),
              ),
              const SizedBox(height: 9),
              Text(
                t.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具名 → 页面。放在一处，加新工具只要改这里。
Widget toolPageOf(String name) {
  switch (name) {
    case '直尺':
      return const RulerPage();
    case '量角器':
      return const ProtractorPage();
    case '噪声测量':
      return const NoiseMeterPage();
    case '屏幕坏点检测':
      return const DeadPixelPage();
    case '番茄时钟':
      return const PomodoroPage();
    case '日期计算':
      return const DateCalcPage();
    case '时间戳转换':
      return const TimestampPage();
    case '提词器':
      return const TeleprompterPage();
    case '配色助手':
      return const ColorSchemeHelperPage();
    case '颜色码转换':
      return const ColorConvertPage();
    case '挂画助手':
      return const LevelHelperPage();
    case '摩斯电码':
      return const MorsePage();
    case '加密编码':
      return const CipherPage();
    case '二维码生成':
      return const QrToolPage();
    case '应用管理':
      return const AppManagerPage();
    case 'LED 屏幕':
      return const LedMarqueePage();
    case 'SOS 手电筒':
      return const SosTorchPage();
    case '抛硬币':
      return const CoinFlipPage();
    case '简易画板':
      return const SketchPadPage();
    case '快递查询':
      return const ExpressQueryPage();
    default:
      return const Scaffold(body: Center(child: Text('这个工具还没做好')));
  }
}

/// 置顶的服务器下载站按钮（独占一行）
class _DownloadStationRow extends StatelessWidget {
  final bool logged;
  const _DownloadStationRow({required this.logged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: const Color(0xFF0F6E56),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (!logged) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('需要先连接你的 WebDAV 服务器')),
            );
            return;
          }
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadSitePage()));
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 17, 18, 17),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.cloud_download_outlined, color: Colors.white, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('服务器下载站',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                    const SizedBox(height: 3),
                    Text(
                      '浏览 /${AppDirs.download} 里的文件，一键下载到手机',
                      style: TextStyle(
                          fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 服务器 html 小工具入口
class _ServerToolsRow extends StatelessWidget {
  final bool logged;
  const _ServerToolsRow({required this.logged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (!logged) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('需要先连接你的 WebDAV 服务器')),
            );
            return;
          }
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ServerHtmlToolsPage()));
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF72243E).withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.web_asset, color: Color(0xFF72243E), size: 22),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('服务器小工具',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '在 App 里运行 /${AppDirs.tools} 里的 html 小工具',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Category {
  final String name;
  final IconData icon;
  final List<_ToolDef> tools;
  const _Category(this.name, this.icon, this.tools);
}

class _ToolDef {
  final String name;
  final IconData icon;
  final Color color;
  const _ToolDef(this.name, this.icon, this.color);
}

/// 供别处复用的工具函数
Future<List<DavEntry>> listToolFiles(WebDavClient client) async {
  final entries = await client.list(AppDirs.tools, depth: 1);
  return entries.where((e) => !e.isDir).toList();
}

String humanSize(int bytes) => formatBytes(bytes);
