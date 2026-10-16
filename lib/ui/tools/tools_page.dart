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
import 'tool_pages_convert.dart';
import 'tool_pages_ext.dart';
import 'tool_pages_id.dart';
import 'tool_pages_ph.dart';
import 'tool_pages_ph2.dart';
import 'tool_pages_ph3.dart';
import 'tool_pages_dict.dart';
import 'tool_pages_recorder.dart';
import 'tool_pages_sudoku.dart';
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
/// v1.8.0 需求13：从 `ConsumerWidget` 改成 `ConsumerStatefulWidget`，
/// 因为「拖动换顺序 / 重命名」要有一份可变状态（用户自定义的顺序与显示名）。
///
/// 注意：`categories` / `iconForName` / `colorForName` 必须**留在 ToolsPage 上**
/// ——`server_html_tools.dart` 是按 `ToolsPage.iconForName(名字)` 调的，
/// 挪进 State 类就直接编译不过了。
class ToolsPage extends ConsumerStatefulWidget {
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
    // v1.9.0+22 按用户截图重排：
    //   * 「挂画助手」从最末位提前到第 3（视觉测量里最常用的放最前）
    //   * 「简易画板 / 高级计算器 / 单位换算」前移成第 2 行（这些都是写画、做题时常切换的工具）
    //   * 「地图坐标转换 / 指南针 / 配色助手 / 颜色码转换」挪到最后 4 个
    //     —— 这些属于「对着屏幕 / 取色卡才用」，用频次低
    _Category('测量与设计', [
      _ToolDef('直尺', Icons.straighten, Color(0xFF185FA5)),
      _ToolDef('量角器', Icons.architecture, Color(0xFF7F77DD)),
      // v1.7.0：SOS 手电筒已按用户要求挪去「生活与娱乐」；
      // v1.9.0+22 再把「挂画助手」前移到这一行的第三位（用户截图要求）
      _ToolDef('挂画助手', Icons.straighten_outlined, Color(0xFF72243E)),
      _ToolDef('噪声测量', Icons.graphic_eq, Color(0xFF1D9E75)),
      _ToolDef('屏幕坏点检测', Icons.grid_on, Color(0xFFD4537E)),
      _ToolDef('简易画板', Icons.brush_outlined, Color(0xFF7F77DD)),
      _ToolDef('高级计算器', Icons.functions, Color(0xFF534AB7)),
      // v1.8.0 新增：18 类单位换算 + 人民币大小写 + 亲戚称呼，
      // 全部集中在一个界面里用顶部分类切换（用户点名要「集中在一个界面」）
      _ToolDef('单位换算', Icons.transform, Color(0xFF0F6E56)),
      // ↓ v1.9.0+22 后挪到末尾 4 个（截图要求）：
      _ToolDef('地图坐标转换', Icons.swap_horiz, Color(0xFF1D9E75)),
      // 指南针：地磁方向 + 经纬度 + 海拔。
      // 方向靠磁力计（离线、不要权限），经纬度/海拔靠定位（要权限）。
      _ToolDef('指南针', Icons.explore, Color(0xFF0F7B6C)),
      _ToolDef('配色助手', Icons.auto_awesome, Color(0xFFD4537E)),
      _ToolDef('颜色码转换', Icons.colorize_outlined, Color(0xFF0C447C)),
    ]),

    // ③ 网络与编码 —— 原「文字与编码」，v1.6.0 起并入 CIDR 子网计算
    // v1.9.0+22 按用户截图重排：把 CIDR 子网计算从第 5 位提到第 3 位
    // （紧挨着加密编码），二维码 / 条码 / 身份证往后压。
    _Category('网络与编码', [
      _ToolDef('摩斯电码', Icons.wifi_tethering, Color(0xFF0F6E56)),
      _ToolDef('加密编码', Icons.lock_outline, Color(0xFF993C1D)),
      // v1.9.0+22：用户截图把 CIDR 子网计算从第 5 位提到第 3 位
      _ToolDef('CIDR 子网计算', Icons.hub_outlined, Color(0xFF0C447C)),
      _ToolDef('二维码生成', Icons.qr_code_2, Color(0xFF1D9E75)),
      // v1.5.0 新增：一维条码（Code128 / Code39 / EAN-13 / EAN-8 / UPC-A）
      _ToolDef('条码生成器', Icons.view_week, Color(0xFF72243E)),
      // v1.7.0 从「地理与定位」挪进来（该分类因此清空、取消）
      // 身份证前 6 位查户籍地（自带 2978 个区划码，不用联网）
      _ToolDef('身份证查户籍', Icons.badge_outlined, Color(0xFFB8860B)),
    ]),

    // ④ 生活与娱乐 —— 用户要求排第四，并并入 3 个工具
    // v1.9.0+22 按用户截图重排：把 SOS 手电筒提到第 1 位（户外场景最常点开的就是它），
    // 后台录像次之（按错就着它录），其它按原顺序接续。
    _Category('生活与娱乐', [
      // v1.7.0 从「测量与设计」挪进来（用户点名）；v1.9.0+22 提到本类第 1 位
      _ToolDef('SOS 手电筒', Icons.flashlight_on, Color(0xFFB8860B)),
      // 后台录音录像：类似 Alibi
      _ToolDef('后台录音录像', Icons.fiber_manual_record, Color(0xFFD4537E)),
      _ToolDef('抛硬币', Icons.casino_outlined, Color(0xFFE0A020)),
      // 文件夹同步：本地文件夹 ↔ 服务器文件夹，后台每隔几分钟对一次
      _ToolDef('文件夹同步', Icons.sync_alt, Color(0xFF0F7B6C)),
      _ToolDef('应用管理', Icons.apps_outlined, Color(0xFF34C759)),
      // 快递查询要访问快递 100 的接口，是联网工具
      _ToolDef('快递查询', Icons.local_shipping_outlined, Color(0xFF185FA5), online: true),
      // v1.9.0 大改：9 种主流异形 + 笔记模式 + 地狱难度 + 自动出题
      _ToolDef('数独', Icons.grid_3x3, Color(0xFF534AB7)),
      // v1.9.0 新增：对标欧路基础功能（多词库 / 查词 / 生词本 / 历史）
      _ToolDef('路路词典', Icons.menu_book_outlined, Color(0xFF185FA5)),
    ]),

    // ⑤ 公卫小工具 —— 原「公卫数据」，v1.6.0 改名并扩容。
    // v1.9.0+22 按用户截图重排：把「Logistic 回归」「实时再生指数 Rt」前移，
    // 「食物中毒分析」「营养配餐」挪到末尾 2 个。
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
      // ↓ v1.9.0+22：把「Logistic 回归」「实时再生指数 Rt」前移，
      // 「食物中毒分析」「营养配餐」挪到末尾 2 个（用户截图要求）
      _ToolDef('Logistic 回归', Icons.insights, Color(0xFF0C447C)),
      // v1.6.0 新增：逐日估计传染速度
      _ToolDef('实时再生指数 Rt', Icons.ssid_chart, Color(0xFFD93025)),
      _ToolDef('食物中毒分析', Icons.restaurant_menu, Color(0xFFD4537E)),
      _ToolDef('营养配餐', Icons.local_dining, Color(0xFF1D9E75)),
    ]),
  ];

  /// v1.8.0 按用户要求：**服务器小工具复用内置小工具那一套图标**。
  ///
  /// 背景：服务器上的 html 小工具是用户自己传上去的（多数就是内置工具导出的
  /// html 版），在「服务器小工具」页里原来所有格子共用一个 `Icons.web_asset`，
  /// 一眼看过去分不清谁是谁。既然名字能对上，就直接借内置的图标 + 配色。
  ///
  /// 名字要**归一后再比**，因为两边写法经常不一致：
  ///   * 服务器侧会带上 `01_` 前缀（已经在 `_prettyName` 里剥掉了）
  ///   * 空格写法不同：内置叫 `LED 屏幕`，文件名常写 `LED屏幕`
  ///   * 用户可能写成全角空格
  /// 所以统一去掉半角/全角空格再比。
  ///
  /// 对不上就返回 null，由调用方用自己的兜底图标 ——
  /// **不要硬凑一个近似图标**：随机配的图标比统一兜底更难认。
  static IconData? iconForName(String name) => _find(name)?.icon;

  static Color? colorForName(String name) => _find(name)?.color;

  /// 内部查表。`_ToolDef` 是私有类型，不能当公共方法的返回类型，
  /// 所以只在类内用，对外只露 iconForName / colorForName 两个。
  static _ToolDef? _find(String name) {
    final key = _normToolName(name);
    if (key.isEmpty) return null;
    for (final c in categories) {
      for (final t in c.tools) {
        if (_normToolName(t.name) == key) return t;
      }
    }
    return null;
  }

  static String _normToolName(String s) =>
      s.replaceAll(' ', '').replaceAll('\u3000', '').toLowerCase();

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  // ------------------------------------------------------------------
  // 用户自定义（v1.8.0 需求13）
  //
  //   _order : {分类名: [工具原名, …]} —— 只在这一类内部换顺序
  //   _alias : {工具原名: 显示名}     —— 只改列表里显示的字，
  //                                        `toolPageOf(原名)` 完全不受影响
  //   _editing : 是否处于「自定义」模式（这个模式下格子可以拖、点了是重命名）
  //
  // 两份表都从 SettingsStore 读，坏数据一律吞掉当没设置过 ——
  // 工具页是很多人的入口，绝不能因为一份存坏的自定义让整页打不开。
  // ------------------------------------------------------------------
  Map<String, List<String>> _order = <String, List<String>>{};
  Map<String, String> _alias = <String, String>{};
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(settingsProvider);
    final o = await s.toolOrder();
    final a = await s.toolAliases();
    if (!mounted) return;
    setState(() {
      _order = o;
      _alias = a;
    });
  }

  /// 某个分类**当前实际**要显示的工具顺序。
  ///
  /// 关键在最后那段「补齐」：用户自定义过顺序之后，如果 App 升级又加了新工具，
  /// 新工具不在存下来的名字表里，必须原样追加到末尾 ——
  /// 否则升级一次新工具就「消失」了，这种 bug 很难查。
  List<_ToolDef> _sortedTools(_Category c) {
    final saved = _order[c.name];
    if (saved == null || saved.isEmpty) return c.tools;
    final pending = <String, _ToolDef>{for (final t in c.tools) t.name: t};
    final out = <_ToolDef>[];
    for (final n in saved) {
      final t = pending.remove(n);
      if (t != null) out.add(t);
    }
    for (final t in c.tools) {
      if (pending.containsKey(t.name)) out.add(t);
    }
    return out;
  }

  Future<void> _drop(String cat, String from, String to) async {
    if (from == to) return;
    final c = ToolsPage.categories.firstWhere((x) => x.name == cat);
    final names = _sortedTools(c).map((t) => t.name).toList();
    final i = names.indexOf(from);
    if (i < 0) return;
    names.removeAt(i);
    // 注意两件事（自测 `.workbuddy/test_tool_order.py` 的分支 E/F 就是钉这两条）：
    //   1. 删掉 from 之后 to 的下标会往前挪一格，所以必须**重新取一次**
    //      下标，不能沿用拖动前的值；
    //   2. 往后拖要插到目标的**后面**，往前拖插到**前面**。
    //      统一插到前面的话，「把 A 拖到它右边紧邻的那一格」会插回原处、
    //      看起来就是「拖了没反应」—— 这是自测第一版抓出来的。
    //      判据必须是 `i <= j`（而不是 `i < j`）：删除之后目标的下标
    //      已经左移了一格，相邻后拖时会出现 i == j，用 `<` 又退回原处。
    final j = names.indexOf(to);
    if (j < 0) return;
    names.insert(i <= j ? j + 1 : j, from);
    setState(() => _order[cat] = names);
    await ref.read(settingsProvider).setToolOrder(_order);
  }

  Future<void> _rename(_ToolDef t) async {
    final v = await _askText(
      '重命名',
      '只改工具页里显示的名字，点进去之后的标题不变',
      initial: _alias[t.name] ?? t.name,
    );
    if (v == null || !mounted) return;
    final s = v.trim();
    setState(() {
      // 留空、或者改回原名 —— 都等于「没改」。删掉键而不是存一份
      // 和原名一样的值，这样「恢复默认」才有一个干净的默认态。
      if (s.isEmpty || s == t.name) {
        _alias.remove(t.name);
      } else {
        _alias[t.name] = s;
      }
    });
    await ref.read(settingsProvider).setToolAliases(_alias);
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('恢复默认'),
        content: const Text('把工具的顺序和显示名都恢复成默认？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    final s = ref.read(settingsProvider);
    await s.setToolOrder(<String, List<String>>{});
    await s.setToolAliases(<String, String>{});
    if (!mounted) return;
    setState(() {
      _order = <String, List<String>>{};
      _alias = <String, String>{};
    });
  }

  Future<String?> _askText(String title, String hint, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 12,
          // counterText 置空是为了不显示「0/12」那行，对话框会矮一大截
          decoration: InputDecoration(hintText: hint, counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text), child: const Text('确定')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logged = ref.watch(accountProvider).isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '改名字' : '工具'),
        actions: [
          if (_editing)
            TextButton(onPressed: _resetAll, child: const Text('恢复默认')),
          IconButton(
            icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
            tooltip: _editing ? '完成' : '给工具改显示名',
            onPressed: () => setState(() => _editing = !_editing),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ---------- 置顶：服务器下载站（单独一行）----------
          _DownloadStationRow(logged: logged),
          const SizedBox(height: 10),

          // ---------- 服务器 html 小工具 ----------
          _ServerToolsRow(logged: logged),

          // ---------- 自定义模式的操作提示 ----------
          if (_editing) _editHint(scheme),

          // ---------- 离线小工具 ----------
          for (final c in ToolsPage.categories) ...[
            Padding(
              // v1.7.0：标题行不再放图标，上下留白压缩一点
              // v1.8.0：按用户要求去掉类别后面的「N 个」个数统计。
              // 原来的写法是 name + SizedBox(7) + Text('${c.tools.length} 个')，
              // 三个都要删干净 —— 只删 Text 会留下那 7px 的悬空间距。
              padding: const EdgeInsets.fromLTRB(2, 14, 2, 7),
              child: Text(c.name,
                  style: TextStyle(
                      // 用户要求「字体要更大一些」
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary)),
            ),
            // 包一层 LayoutBuilder 只为拿到**格子的真实宽度**：
            // 拖动时那个跟着手指走的「影子卡片」要按同样的尺寸画，
            // 不然会在半空中变形。宽度 = (整行宽 - 两个 6px 间距) / 3。
            LayoutBuilder(builder: (_, cons) {
              final list = _sortedTools(c);
              final cellW = (cons.maxWidth - 12) / 3;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: list.length,
                // v1.7.0：用 mainAxisExtent 把格子高度**钉死**成 34，不再用
                // childAspectRatio —— 后者算出来的高度会随屏幕宽度变，
                // 「进一步压缩行距」就变成看运气了。间距 8 → 6。
                // v1.8.0 需求13：尺寸一个字没动（用户明确要求「框框大小不变」），
                // 放大的是里面的字，见 _toolCard。
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisExtent: 34,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemBuilder: (_, i) => _cell(c, list, i, cellW, scheme),
              );
            }),
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
                    '卡片描红边的是需要联网的工具，没描红边的都能离线用。\n'
                    '长按任意格子拖动可以换顺序，拖动只在同一类里生效；'
                    '想给工具改个显示名，点右上角那个按钮进自定义模式。\n'
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

  /// 自定义模式下的顶栏提示条
  Widget _editHint(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.drag_indicator, size: 17, color: scheme.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '现在点一下格子是「改名字」；点进去用工具请先点右上角 ✓ 退出。\n'
              '长按格子拖动可换顺序（任何时候都能用，只在同一类里换）。',
              style: TextStyle(
                  fontSize: 11.5, height: 1.65, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 一个格子。
  ///
  /// 拖动换顺序**任何时候都能用**（长按格子拖），不要求先点进自定义模式 ——
  /// 少一步就少一次抱怨；「改名」才需要进自定义模式，因为改名要抢「点一下」
  /// 这个手势，普通模式下点一下必须是打开工具。
  ///
  /// 用核心库的 `DragTarget` / `LongPressDraggable` 自己拼，而不是
  /// `ReorderableListView` —— 后者是**线性**列表，摆不出「一行三个」的网格
  /// （`GridView` 的 `.reorderable` 只支持动态列数，不支持
  /// `SliverGridDelegateWithFixedCrossAxisCount`）。
  Widget _cell(_Category c, List<_ToolDef> list, int i, double cellW,
      ColorScheme scheme) {
    final t = list[i];
    final label = _alias[t.name] ?? t.name;
    final inCat = <String>{for (final x in list) x.name};
    final onTap = _editing
        ? () => _rename(t)
        : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => toolPageOf(t.name)),
            );

    return DragTarget<String>(
      // 只接**同一类**里的小工具：跨类拖过来一律不收，
      // 否则会闪出一个「能放」的高亮，松手却什么也没发生。
      onWillAcceptWithDetails: (d) => d.data != t.name && inCat.contains(d.data),
      onAcceptWithDetails: (d) => _drop(c.name, d.data, t.name),
      builder: (ctx, cand, rejected) {
        final hot = cand.isNotEmpty;
        return LongPressDraggable<String>(
          data: t.name,
          // 自定义模式下用户已经明确知道自己在拖动，短一点更跟手；
          // 普通模式下要 400ms，否则一边滑一边就误触成拖动了。
          delay: Duration(milliseconds: _editing ? 160 : 400),
          // 让影子卡片跟着**手指**走（默认跟着按下点走，长按一会儿再拖会偏很远）
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: cellW,
              height: 34,
              // 影子卡片和「拖走后留下的空位」都不该响应点击
              child: _toolCard(context, t, label: label, onTap: () {}, shadow: true),
            ),
          ),
          childWhenDragging: Opacity(
              opacity: 0.25,
              child: _toolCard(context, t, label: label, onTap: () {})),
          child: DecoratedBox(
            // foreground：描边画在卡片**上面**，不占布局尺寸 ——
            // 格子高度是钉死的 34，加一圈 padding 会把它撑高、把行距改了。
            position: DecorationPosition.foreground,
            decoration: (_editing || hot)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: hot
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.32),
                      width: hot ? 2 : 1,
                    ),
                  )
                : const BoxDecoration(),
            child: _toolCard(context, t, label: label, onTap: onTap),
          ),
        );
      },
    );
  }

  Widget _toolCard(BuildContext context, _ToolDef t,
      {required String label, VoidCallback? onTap, bool shadow = false}) {
    final scheme = Theme.of(context).colorScheme;
    // v1.9.0 需求 7：联网工具的标识从「右上角蓝点」改成「整张卡片描红边」。
    // 原来那点太小，列表里一眼扫过去容易被忽略；
    // 改成 1.5 px 的红边之后，不用停下来凑近看也能扫到。
    // 颜色用 Color(0xFFB23A3A) —— 比纯红 #FF0000 略柔，
    // 在卡片背景下「醒目但不刺眼」。
    final onlineBorder = t.online
        ? Border.all(color: const Color(0xFFB23A3A), width: 1.5)
        : null;
    return Card(
      margin: EdgeInsets.zero,
      elevation: shadow ? 8 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: onlineBorder ?? BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // onTap 为 null（拖动影子、或者自定义模式下漏传）时 InkWell 不响应，
        // 正好是想要的效果。
        onTap: onTap ??
            () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => toolPageOf(t.name)),
                ),
        child: Stack(
          children: [
            Padding(
              // v1.9.0：取消原来给「联网蓝点」多留的 11 px 右边距
              // （蓝点已改为红框，整张卡片描边）。
              padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
              child: Row(
                children: [
                  // v1.7.0：图标和文字放进**同一排**（原来是图标在上、文字在下）。
                  // v1.8.0 需求13：字被放大之后 14 的图标显得太小，跟着提到 16。
                  Icon(t.icon, color: t.color, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FittedBox(
                      // v1.8.0 需求13：用户要求「字体放大到填充整个边框」。
                      //
                      // 做法是把基准字号直接提到 24 —— FittedBox 是 scaleDown，
                      // 只在放不下时缩小、绝不会放大，所以「基准字号」就是字号
                      // 上限。基准 12.5 的时候，不管格子多空，字永远只有 12.5；
                      // 提到 24 之后：
                      //   1~3 个字 → 顶到 24，把 34 高的格子填满（这才是用户要的）
                      //   4 个字   → 约 18
                      //   5 个字   → 约 15
                      //   6 个字   → 约 12.5（与改之前持平，不会更差）
                      // 宽屏（平板）上横向更宽，6 个字也能顶到 24。
                      // 想更整齐可以用「长按改名」把名字改短。
                      //
                      // height 给 1.05 而不是 1.0：CJK 字形顶到 em 框边缘，
                      // 行高太紧容易看到上下被切掉一点点的错觉。
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 24,
                          height: 1.05,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // v1.9.0：原来这里是「联网工具右上角蓝点」（v1.6.0 加的），
            // 整张卡片已改成红框描边（见 Card.shape），这里的小点删除。
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
    // ---- v1.9.0 数独大改 ----
    case '数独':
      return const SudokuPage();
    // ---- v1.9.0 路路词典 ----
    case '路路词典':
      return const DictPage();
    // ---- v1.8.0 ----
    case '单位换算':
      return const UnitConvertPage();
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
