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
import 'tool_pages_calc.dart';
import 'tool_pages_compass.dart';
import 'tool_pages_ext.dart';
import 'tool_pages_id.dart';
import 'tool_pages_ph.dart';
import 'tool_pages_ph2.dart';
import 'tool_pages_ph3.dart';
import 'tool_pages_recorder.dart';
import 'tool_pages_sync.dart';
import 'tool_pages_translate.dart';
import 'tool_pages_v15.dart';
import 'tool_pages_v15b.dart';

/// 工具页
///
/// 布局约定：
///   * 最上面单独一行是「服务器下载站」—— 直接进，不折叠、不藏在菜单里
///   * 下面按用途分成 5 类，一共 41 个离线小工具
///   * 最后再挂一个「服务器小工具」，识别服务器 tools 目录里的 html 小工具
///
/// 分类的由来（每次加工具都要重申一遍，否则很容易按「技术实现」分类、
/// 而不是按「用户想干什么」分类）：
///   时间与效率 ← 用户点名放第一位；翻页时钟排这类第一个（v1.6.0）
///   测量与设计 ← 原「测量与感官」。用户要求排第二位，并把
///                地图坐标转换 / 指南针 / 配色助手 /
///                颜色码转换 / 简易画板 / 高级计算器 一并挪进来 ——
///                这些的共性都是「对着实物或屏幕比划、调参数」，算设计与测量
///   网络与编码 ← 原「文字与编码」。用户要求把 CIDR 子网计算并进来；
///                v1.7.0 又把身份证查户籍并进来
///   生活与娱乐 ← 用户点名放第四位，并把 文件夹同步 / 后台录音录像 /
///                应用管理 挪进来；v1.7.0 又把 SOS 手电筒挪进来
///   公卫小工具 ← 原「公卫数据」（v1.6.0 改名）。消杀计算器从这里起家，
///                扩成一组类 Epi Info StatCalc 的工具
///
/// v1.6.0 起分类由 11 类压到 6 类 —— 用户反馈「类似一个木函」，
/// 类别太多反而不好找，宁可每类工具多一点。
/// v1.7.0 再把「地理与定位」压掉（唯一成员身份证查户籍挪去网络与编码），
/// 剩 5 类。**分类只会越来越少，别再按细类拆回去。**
///
/// 卡片布局 v1.7.0 改版（用户要求）：
///   * 分类标题：去掉前面的小图标，字号 13 → 16
///   * 小工具格子：仍是一行 3 个；图标从「上方」挪到「文字左边」同一排；
///     字号 11.5 → 12.5；格子高度钉死 34（原来是靠 childAspectRatio 随宽度变）
///   * 名字长的格子用 FittedBox scaleDown 自动缩字，**不截断**（用户要求「显示全」）
class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});

  /// 全部离线小工具，按用途分类
  static const categories = <_Category>[
    // ① 时间与效率 —— 用户要求挪到第一位；翻页时钟排这类第一个
    _Category('时间与效率', [
      // v1.5.0 新增的横屏大字号翻页时钟（带农历/星期/节气）。v1.6.0 提到第一个
      _ToolDef('翻页时钟', Icons.watch_later_outlined, Color(0xFF0C447C)),
      _ToolDef('番茄时钟', Icons.timer_outlined, Color(0xFFD85A30)),
      _ToolDef('日期计算', Icons.calendar_month_outlined, Color(0xFFEF9F27)),
      _ToolDef('时间戳转换', Icons.access_time, Color(0xFF534AB7)),
      _ToolDef('提词器', Icons.vertical_align_bottom, Color(0xFF27500A)),
      _ToolDef('LED 屏幕', Icons.brightness_high, Color(0xFFEF9F27)),
      // v1.4.0 新增：多词典在线翻译（要联网）
      _ToolDef('翻译', Icons.translate, Color(0xFF185FA5), online: true),
    ]),

    // ② 测量与设计 —— 原「测量与感官」，v1.6.0 起并入 7 个工具（用户点名）
    _Category('测量与设计', [
      _ToolDef('直尺', Icons.straighten, Color(0xFF185FA5)),
      _ToolDef('量角器', Icons.architecture, Color(0xFF7F77DD)),
      _ToolDef('噪声测量', Icons.graphic_eq, Color(0xFF1D9E75)),
      _ToolDef('屏幕坏点检测', Icons.grid_on, Color(0xFFD4537E)),
      _ToolDef('挂画助手', Icons.straighten_outlined, Color(0xFF72243E)),
      // ↓ v1.6.0 从「生活与娱乐 / 地理与定位 / 颜色与设计 / 计算与网络」挪进来
      // v1.7.0：SOS 手电筒已按用户要求挪去「生活与娱乐」
      _ToolDef('地图坐标转换', Icons.swap_horiz, Color(0xFF1D9E75)),
      // 指南针：地磁方向 + 经纬度 + 海拔。
      // 方向靠磁力计（离线、不要权限），经纬度/海拔靠定位（要权限）。
      _ToolDef('指南针', Icons.explore, Color(0xFF0F7B6C)),
      _ToolDef('配色助手', Icons.auto_awesome, Color(0xFFD4537E)),
      _ToolDef('颜色码转换', Icons.colorize_outlined, Color(0xFF0C447C)),
      _ToolDef('简易画板', Icons.brush_outlined, Color(0xFF7F77DD)),
      _ToolDef('高级计算器', Icons.functions, Color(0xFF534AB7)),
    ]),

    // ③ 网络与编码 —— 原「文字与编码」，v1.6.0 起并入 CIDR 子网计算
    _Category('网络与编码', [
      _ToolDef('摩斯电码', Icons.wifi_tethering, Color(0xFF0F6E56)),
      _ToolDef('加密编码', Icons.lock_outline, Color(0xFF993C1D)),
      _ToolDef('二维码生成', Icons.qr_code_2, Color(0xFF1D9E75)),
      // v1.5.0 新增：一维条码（Code128 / Code39 / EAN-13 / EAN-8 / UPC-A）
      _ToolDef('条码生成器', Icons.view_week, Color(0xFF72243E)),
      // v1.6.0 从「计算与网络」挪进来
      _ToolDef('CIDR 子网计算', Icons.hub_outlined, Color(0xFF0C447C)),
      // v1.7.0 从「地理与定位」挪进来（该分类因此清空、取消）
      // 身份证前 6 位查户籍地（自带 2978 个区划码，不用联网）
      _ToolDef('身份证查户籍', Icons.badge_outlined, Color(0xFFB8860B)),
    ]),

    // ④ 生活与娱乐 —— 用户要求排第四，并并入 3 个工具
    _Category('生活与娱乐', [
      _ToolDef('抛硬币', Icons.casino_outlined, Color(0xFFE0A020)),
      // 快递查询要访问快递 100 的接口，是联网工具
      _ToolDef('快递查询', Icons.local_shipping_outlined, Color(0xFF185FA5), online: true),
      // ↓ v1.6.0 从「同步与备份 / 音频与录制 / 设备与应用」挪进来
      // 文件夹同步：本地文件夹 ↔ 服务器文件夹，后台每隔几分钟对一次
      _ToolDef('文件夹同步', Icons.sync_alt, Color(0xFF0F7B6C)),
      // 后台录音录像：类似 Alibi
      _ToolDef('后台录音录像', Icons.fiber_manual_record, Color(0xFFD4537E)),
      _ToolDef('应用管理', Icons.apps_outlined, Color(0xFF34C759)),
      // v1.7.0 从「测量与设计」挪进来（用户点名）
      _ToolDef('SOS 手电筒', Icons.flashlight_on, Color(0xFFB8860B)),
    ]),

    // ⑤ 公卫小工具 —— 原「公卫数据」，v1.6.0 改名并扩容
    _Category('公卫小工具', [
      _ToolDef('消杀计算器', Icons.science_outlined, Color(0xFF0F7B6C)),
      // v1.6.0 新增：现场配药时设备该开多大流量
      _ToolDef('杀虫剂流量计算', Icons.opacity_outlined, Color(0xFF1D9E75)),
      _ToolDef('公共卫生统计', Icons.pie_chart_outline, Color(0xFF185FA5)),
      _ToolDef('病例对照研究', Icons.compare_arrows, Color(0xFF993C1D)),
      _ToolDef('队列研究', Icons.timeline, Color(0xFF534AB7)),
      // v1.6.0 新增的两个高级统计分析
      _ToolDef('分层分析', Icons.layers_outlined, Color(0xFF0C447C)),
      _ToolDef('交互作用', Icons.hub_outlined, Color(0xFF72243E)),
      _ToolDef('食物中毒分析', Icons.restaurant_menu, Color(0xFFD4537E)),
      _ToolDef('Logistic 回归', Icons.insights, Color(0xFF0C447C)),
      _ToolDef('营养配餐', Icons.local_dining, Color(0xFF1D9E75)),
      // v1.6.0 新增：逐日估计传染速度
      _ToolDef('实时再生指数 Rt', Icons.ssid_chart, Color(0xFFD93025)),
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
              // v1.7.0：标题行不再放图标，上下留白压缩一点
              padding: const EdgeInsets.fromLTRB(2, 14, 2, 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(c.name,
                      style: TextStyle(
                          // 用户要求「字体要更大一些」
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary)),
                  const SizedBox(width: 7),
                  Text('${c.tools.length} 个',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: c.tools.length,
              // v1.7.0：用 mainAxisExtent 把格子高度**钉死**成 34，不再用
              // childAspectRatio —— 后者算出来的高度会随屏幕宽度变，
              // 「进一步压缩行距」就变成看运气了。间距 8 → 6。
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: 34,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemBuilder: (_, i) => _toolCard(context, c.tools[i]),
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
                    '卡片右上角带蓝色小点的，是需要联网的工具；'
                    '没有小点的都能离线用。\n'
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
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => toolPageOf(t.name)),
        ),
        child: Stack(
          children: [
            Padding(
              // 联网工具右上角有小点，右边多让一点位，免得点压到字上
              padding: EdgeInsets.only(
                  left: 6, right: t.online ? 11 : 6, top: 3, bottom: 3),
              child: Row(
                children: [
                  // v1.7.0：图标和文字放进**同一排**（原来是图标在上、文字在下）。
                  // 图标保留，尺寸 17 → 14，把省下的宽度让给文字。
                  Icon(t.icon, color: t.color, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FittedBox(
                      // 「文字要显示全」——所以是 scaleDown（放不下就整体缩小），
                      // 不是 ellipsis。最长的几个名字（7 个字或带字母的）会被
                      // 缩到 11px 上下，这是「一行 3 个 + 名字不截断」的必然代价。
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        t.name,
                        maxLines: 1,
                        style: TextStyle(
                          // 字号 11.5 → 12.5（用户要求「字体加大」）
                          fontSize: 12.5,
                          height: 1.0,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 联网工具：卡片右上角一个小圆点（用户要求「加一个网络的小点」）
            if (t.online)
              Positioned(
                right: 5,
                top: 5,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF185FA5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
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
    case '消杀计算器':
      return const DisinfectCalcPage();
    case '翻译':
      return const TranslatePage();
    // ---- v1.5.0 ----
    case '高级计算器':
      return const AdvCalcPage();
    case 'CIDR 子网计算':
      return const CidrCalcPage();
    case '地图坐标转换':
      return const CoordinateConvertPage();
    case '公共卫生统计':
      return const EpiStatsPage();
    case '病例对照研究':
      return const CaseControlPage();
    case '队列研究':
      return const CohortPage();
    case '食物中毒分析':
      return const FoodPoisoningPage();
    case 'Logistic 回归':
      return const LogisticPage();
    case '营养配餐':
      return const NutritionPage();
    // ---- v1.6.0 新增的四个公卫工具 ----
    case '杀虫剂流量计算':
      return const SprayFlowPage();
    case '实时再生指数 Rt':
      return const RtPage();
    case '分层分析':
      return const StratifiedPage();
    case '交互作用':
      return const InteractionPage();
    case '条码生成器':
      return const BarcodePage();
    case '身份证查户籍':
      return const IdCardPage();
    case '文件夹同步':
      return const FolderSyncPage();
    case '翻页时钟':
      return const FlipClockPage();
    case '指南针':
      return const CompassPage();
    case '后台录音录像':
      return const AudioRecorderPage();
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
    // 这一行的配色是写死的（深绿底 + 白字），跟亮/暗主题无关，
    // 所以不需要 scheme —— 之前留了个没用上的局部变量。
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
  final List<_ToolDef> tools;

  /// v1.7.0：用户要求「主目录不需要图标」—— 分类标题前那个小图标删掉了
  /// （下面的小工具格子里仍然保留图标，那条要求是「图标和文字放在一排」）。
  /// 所以这里不再有 icon 字段，别再加回来。
  const _Category(this.name, this.tools);
}

class _ToolDef {
  final String name;
  final IconData icon;
  final Color color;

  /// 要不要联网。
  ///
  /// 用户要求「内置小工具哪些需要联网，要做区分标记」——
  /// 因为很多人是在没网的地方用这些工具（野外调查、下乡、飞机上），
  /// 点进去才发现要联网会很恼火。**默认 false（离线）**，
  /// 只有确实要访问网络的工具才显式标 true。
  /// 判据：要么请求远程接口（翻译 / 快递查询），要么依赖 WebDAV 服务器。
  final bool online;

  const _ToolDef(this.name, this.icon, this.color, {this.online = false});
}

/// 供别处复用的工具函数
Future<List<DavEntry>> listToolFiles(WebDavClient client) async {
  final entries = await client.list(AppDirs.tools, depth: 1);
  return entries.where((e) => !e.isDir).toList();
}

String humanSize(int bytes) => formatBytes(bytes);
