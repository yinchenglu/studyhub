import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_device_apps/flutter_device_apps.dart';
// 必须 hide TextDirection！intl 里也有一个同名的 TextDirection（用 LTR / RTL 大写），
// 它会把 Flutter 那个带 .ltr / .rtl 的 TextDirection 遮蔽掉，
// 于是文件里所有 TextDirection.ltr 都变成「getter 'ltr' isn't defined」。
import 'package:intl/intl.dart' hide TextDirection;
// 番茄时钟的铃声走 media_kit 播放 assets/sounds 里的 wav。
// 不另引音频包 —— 播放器内核本来就在树里，而每加一个包都可能
// 触发依赖冲突（这个项目历次构建失败几乎全是这个原因）。
import 'package:media_kit/media_kit.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
// 番茄时钟用 SharedPreferences 记住铃声选择
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torch_light/torch_light.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/display_metrics.dart';
import '../../core/downloader.dart';
import '../../core/permissions.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';

// ============================================================ 公共小工具

/// 保持屏幕常亮。
///
/// 原先这批工具页全都在调 `SystemChrome.setKeepScreenOn(...)` ——
/// 但 Flutter 的 SystemChrome 里**压根没有这个方法**，20 处调用没有一处能编译。
/// 「不熄屏」这件事只有一个正路：wakelock_plus。
///
/// 失败不抛出去：有些机型 / 省电策略下会拒绝，那是正常情况，
/// 不该因为它把工具页本身搞崩。
/// 返回 Future 但调用点（dispose / 按钮回调）直接忽略 ——
/// 本项目 analysis_options 用的是 flutter_lints 默认集，没开 unawaited_futures，不会报。
Future<void> keepScreenOn(bool on) async {
  try {
    await WakelockPlus.toggle(enable: on);
  } catch (_) {
    // 拿不到 wakelock 就算了，工具照常用
  }
}

/// 所有工具页共用的外壳：统一标题栏 + 背景
class ToolScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final Widget? bottom;

  const ToolScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const [],
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (subtitle != null)
              Text(subtitle!,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: actions,
      ),
      body: SafeArea(
        // 只处理底部：顶部有 AppBar 自己管，左右本来就是正常内容区。
        //
        // 为什么必须加（用户报的「颜色码转换最下面的内容被返回键遮挡」就是它）：
        //   Android 从 Flutter 3.27 起默认开 edge-to-edge 布局，
        //   系统返回键 / 手势条会**浮在** body 上面而不是把 body 顶上去。
        //   Scaffold 只会自动避开键盘，不会避开导航栏。
        //   于是页面最底下那一段（比如「常用色」色块）就被压住点不到了。
        //   加一层 SafeArea 之后，所有工具页一次性都修好。
        top: false,
        left: false,
        right: false,
        child: child,
      ),
      bottomNavigationBar: bottom,
    );
  }
}

void toast(BuildContext context, String s) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
}

void copyText(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  toast(context, '已复制：${text.length > 24 ? '${text.substring(0, 24)}…' : text}');
}

/// 把文本写进手机下载目录，返回路径
Future<File?> saveToDownload(String fileName, List<int> bytes) async {
  final dir = await downloadTargetDir();
  if (dir == null) return null;
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File(p.join(dir.path, Downloader.safeName(fileName)));
    await f.writeAsBytes(bytes);
    return f;
  } catch (_) {
    return null;
  }
}

Future<void> shareFiles(BuildContext context, List<File> files, {String? text}) async {
  try {
    final fs = files.where((f) => f.existsSync()).toList();
    if (fs.isEmpty) {
      toast(context, '文件不存在');
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: fs.map((f) => XFile(f.path)).toList(),
      text: text,
    ));
  } catch (e) {
    toast(context, '分享失败：$e');
  }
}

/// 小标题
class ToolSection extends StatelessWidget {
  final String text;
  const ToolSection(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Text(text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}

/// 结果展示框（可点一下复制）
class ResultBox extends StatelessWidget {
  final String text;
  final String? hint;
  const ResultBox({super.key, required this.text, this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: text.trim().isEmpty ? null : () => copyText(context, text),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              text.isEmpty ? '（这里会显示结果）' : text,
              style: const TextStyle(fontSize: 14.5, height: 1.55),
            ),
            if (text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(hint ?? '点一下即可复制',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================ 1. 直尺

/// 只有竖尺。
///
/// v1.3.0 改动：
///   1. **删掉了横尺**。原来横竖各一把，实际用起来横尺要先把手机转过去，
///      转屏之后刻度定位又变了，反而添乱。用户要求只留竖尺。
///   2. **删掉了手动校准**。原来要拿银行卡去对 85.6 mm 那条线、拖滑块，
///      本质是让用户替 App 猜屏幕 DPI。现在改成进页面自动问系统要
///      `DisplayMetrics.xdpi`（见 core/display_metrics.dart），
///      拿不到才回退到 Flutter 的 160/in 近似。
///      仍然留了一个折叠的「微调」入口 —— 万一某台机器报的 DPI 离谱，
///      用户还有个后路，但默认不打扰。
class RulerPage extends StatefulWidget {
  const RulerPage({super.key});

  @override
  State<RulerPage> createState() => _RulerPageState();
}

class _RulerPageState extends State<RulerPage> with WidgetsBindingObserver {
  /// 1 厘米 = 多少逻辑像素。先用 Flutter 的近似值兜底，
  /// 拿到真实物理 DPI 后立刻换成实测值。
  double _lpcm = kFallbackLpcm;

  /// 是否用上了真实 DPI。false 表示这台机器读不到，正在用近似值。
  bool _auto = false;

  /// 是否已经问过系统了（用来区分「还没测」和「测了但拿不到」）
  bool _probed = false;

  /// 微调面板是否展开
  bool _showFine = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    keepScreenOn(true);
    // 校准要读 MediaQuery（拿 devicePixelRatio），首帧才有，
    // 所以挂到 postFrameCallback 上，不能在 initState 里直接调。
    WidgetsBinding.instance.addPostFrameCallback((_) => _calibrate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    keepScreenOn(false);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 转屏 / 分屏 / 改显示大小之后 dpr 可能变，重量一次。
    // 注意不能在 metrics 回调里直接 setState，得排到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) => _calibrate());
  }

  Future<void> _calibrate() async {
    if (!mounted) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final dpi = await readPhysicalDpi();
    if (!mounted) return;
    setState(() {
      _probed = true;
      if (dpi != null) {
        _lpcm = lpcmFromDpi(dpi, dpr);
        _auto = true;
      } else {
        _lpcm = kFallbackLpcm;
        _auto = false;
      }
      _showFine = false; // 重新自动测过之后就把微调面板收起来
    });
  }

  /// 屏幕上能放下的刻度总长（厘米）。用来决定尺子画多长。
  double get _totalCm {
    // 减掉标题栏 / 状态条 / 底部留白占掉的高度
    final h = MediaQuery.of(context).size.height - 250;
    final cm = h / _lpcm;
    return cm < 5 ? 5 : cm; // 极端小屏也别少于 5 cm
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '直尺',
      subtitle: _probed
          ? (_auto ? '已按屏幕实际尺寸自动校准' : '按标准比例显示（本机读不到屏幕参数）')
          : '正在校准…',
      actions: [
        IconButton(
          tooltip: _showFine ? '收起微调' : '微调（一般用不着）',
          onPressed: () => setState(() => _showFine = !_showFine),
          icon: Icon(_showFine ? Icons.close : Icons.tune),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          // ---------- 自动校准状态条 ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: (_auto ? const Color(0xFF1D9E75) : scheme.surfaceContainerHighest)
                    .withValues(alpha: _auto ? 0.12 : 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(_auto ? Icons.check_circle_outline : Icons.info_outline,
                      size: 16,
                      color: _auto ? const Color(0xFF1D9E75) : scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _auto
                          ? '刻度已对齐真实尺寸（每厘米 ${_lpcm.toStringAsFixed(1)} 像素）'
                          : '本机拿不到屏幕物理参数，按 1 英寸 = 160 像素的通用值显示，'
                              '可能有几个百分点的偏差，可用右上角微调。',
                      style: TextStyle(
                          fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------- 折叠的微调面板 ----------
          if (_showFine)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Card(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('微调屏幕比例',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text(
                        '自动值通常够用。如果拿实体尺比着看还有肉眼可见的偏差，'
                        '可以在这里小幅修正 —— 下面那条标尺会跟着变。',
                        style: TextStyle(fontSize: 11.5, height: 1.5),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('短', style: TextStyle(fontSize: 12)),
                          Expanded(
                            child: Slider(
                              value: _lpcm,
                              min: kFallbackLpcm * 0.7,
                              max: kFallbackLpcm * 1.4,
                              onChanged: (v) => setState(() {
                                _lpcm = v;
                                _auto = false; // 手动介入之后就不能再自称「自动」了
                              }),
                            ),
                          ),
                          const Text('长', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 74,
                            child: Text('${(_lpcm * 2.54).round()} px/in',
                                style: const TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                      // 10 cm 实体标尺，拿来跟真尺对着看
                      CustomPaint(
                        size: Size(10 * _lpcm, 34),
                        painter: _RulerPainter(_lpcm),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => _calibrate(),
                            child: const Text('恢复自动'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ---------- 竖尺本体 ----------
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('竖尺 · 0 ~ ${_totalCm.floor()} cm',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CustomPaint(
                size: Size(96, _totalCm * _lpcm),
                painter: _RulerPainter(_lpcm),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 竖尺的刻度绘制。0 点在上，往下递增。
///
/// 刻度线长度分三档：整厘米最长、半厘米中等、毫米最短 ——
/// 这也是实体尺的通行画法，扫一眼就能定位。
class _RulerPainter extends CustomPainter {
  final double lpcm;

  _RulerPainter(this.lpcm);

  @override
  void paint(Canvas canvas, Size size) {
    // 尺身底色。用暖米黄而不是纯白 —— 对着实物量的时候不刺眼，
    // 也跟实体尺的观感接近。
    final bg = Paint()..color = const Color(0xFFF7E9A0);
    canvas.drawRect(Offset.zero & size, bg);

    final line = Paint()
      ..color = const Color(0xFF3A3A3A)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;

    final h = size.height;
    final w = size.width;

    // 毫米刻度
    final totalMm = (h / lpcm * 10).floor();
    for (var mm = 0; mm <= totalMm; mm++) {
      final pos = mm / 10 * lpcm;
      if (pos > h) break;
      final isCm = mm % 10 == 0;
      final isHalf = mm % 5 == 0;
      final len = isCm ? w * 0.52 : (isHalf ? w * 0.34 : w * 0.18);
      canvas.drawLine(Offset(0, pos), Offset(len, pos), line);
    }

    // 厘米数字，贴在刻度线右侧
    final totalCm = (h / lpcm).floor();
    for (var cm = 0; cm <= totalCm; cm++) {
      final pos = cm * lpcm;
      if (pos > h - 8) break;
      final tp = TextPainter(
        text: TextSpan(
            text: '$cm',
            style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF3A3A3A),
                fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w * 0.56, pos + 3));
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.lpcm != lpcm;
}

// ============================================================ 2. 量角器

/// 摄像头量角器。
///
/// v1.3.0 重做。老版本是「重力传感器测倾角」—— 只能量手机自己的姿势，
/// 必须把手机侧面贴到被测面上才行。可现实里要量的通常是**画面里的东西**：
/// 墙上两幅画之间的夹角、切菜时刀口和砧板的角度、柜门开了多少度……
/// 这些根本没法贴。所以改成：摄像头取景 + 在画面上叠两条可拖动的直线。
///
/// 用法：拖线头把手，让 A 线贴住一条边、B 线贴住另一条边，
/// 屏幕下方直接读出夹角。底部的「对齐真实水平」会借重力传感器把 A 线
/// 掰到真正的水平位置 —— 于是量到的是相对水平面的绝对角度，
/// 而不只是相对画面的角度。
class ProtractorPage extends StatefulWidget {
  const ProtractorPage({super.key});

  @override
  State<ProtractorPage> createState() => _ProtractorPageState();
}

class _ProtractorPageState extends State<ProtractorPage> {
  CameraController? _cam;
  StreamSubscription<AccelerometerEvent>? _acc;

  bool _busy = true;
  String? _err;

  /// 是否用前置摄像头。默认后置（量外部的东西顺手），
  /// 量自己身上的东西时切前置。
  bool _front = false;

  // ---------- 几何状态：全部用归一化坐标（0~1），跟着屏幕尺寸走 ----------

  /// 两条射线的共同起点
  Offset _center = const Offset(0.5, 0.52);

  /// A / B 两条线的方向角（度）。屏幕坐标系：0° 指向右，顺时针为正。
  double _angA = -35;
  double _angB = 35;

  /// 正在拖谁：null 没在拖；0 拖交点；1 拖 A 端；2 拖 B 端
  int? _drag;

  /// 锁定后禁止拖动 —— 腾出手去对着实物比划时有用
  bool _locked = false;

  /// 真实水平方向在屏幕坐标里的角度（度）。读不到重力时为 null。
  double? _horizon;

  @override
  void initState() {
    super.initState();
    keepScreenOn(true);
    _initCam();
    _startSensor();
  }

  @override
  void dispose() {
    _acc?.cancel();
    // dispose 返回 Future，但这里没法 await，也不该 await ——
    // 相机控制器自己会收尾，等它反而会拖住页面退出。
    final c = _cam;
    _cam = null;
    c?.dispose();
    keepScreenOn(false);
    super.dispose();
  }

  void _startSensor() {
    _acc = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 80)).listen(
      (e) {
        // 手机平放（屏幕朝天）时 x、y 都接近 0，atan2 会乱跳；
        // 而且这时候「哪边是水平」本身也没意义 —— 直接丢掉这帧。
        if (e.x.abs() + e.y.abs() < 1.5) return;
        if (!mounted) return;
        // 屏幕坐标里「天」的方向：设备 +y 在屏幕上是**向上**的，
        // 而屏幕 y 轴向下，所以分量取反 ⇒ u_up = (x, -y)。
        // 水平线垂直于 u_up，转 90° 之后正好化简成 atan2(x, y)。
        setState(() => _horizon = math.atan2(e.x, e.y) * 180 / math.pi);
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _initCam() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    CameraController? c;
    try {
      final st = await Permission.camera.request();
      if (!st.isGranted) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _err = '没有相机权限。\n\n到「系统设置 → 应用 → 学聚 → 权限」里'
              '把相机打开，再回来点重试。';
        });
        return;
      }

      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _err = '这台设备上没找到可用的摄像头。';
        });
        return;
      }

      // 想用哪个方向就优先挑哪个；挑不到就退而求其次用第一个，
      // 总比直接报错好 —— 有些机型上报的 lensDirection 不太准。
      final want = _front ? CameraLensDirection.front : CameraLensDirection.back;
      final hit = cams.where((d) => d.lensDirection == want);
      final desc = hit.isNotEmpty ? hit.first : cams.first;

      c = CameraController(
        desc,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await c.initialize();

      if (!mounted) {
        // 初始化期间用户已经退出页面了，别把控制器泄漏在这儿
        await c.dispose();
        return;
      }
      // 换镜头时可能上一个还没销毁，这里统一收掉
      final old = _cam;
      setState(() {
        _cam = c;
        _busy = false;
      });
      if (old != null && old != c) old.dispose();
    } catch (e) {
      // 初始化失败也要把半成品控制器关掉，不然相机资源会一直被占着
      if (c != null) {
        try {
          await c.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = '相机启动失败：$e\n\n'
            '如果这台手机上别的 App 正占着相机，先关掉再重试。';
      });
    }
  }

  // ---------------------------------------------------------------- 几何换算

  /// 线头把手离交点的距离（像素）。
  /// 取屏幕短边的 30%，并且不小于 84 —— 太小了手指点不准，
  /// 太大了在小屏上会顶到边。
  double _handleR(Size s) => math.max(84.0, math.min(s.width, s.height) * 0.30);

  Offset _centerPx(Size s) => Offset(_center.dx * s.width, _center.dy * s.height);

  Offset _handlePx(double ang, Size s) {
    final r = _handleR(s);
    final a = ang * math.pi / 180;
    return _centerPx(s) + Offset(math.cos(a) * r, math.sin(a) * r);
  }

  /// 手指位置相对交点的方位角（度）
  double _angleTo(Offset p, Size s) {
    final d = p - _centerPx(s);
    return math.atan2(d.dy, d.dx) * 180 / math.pi;
  }

  /// A 与 B 之间的夹角，归一化到 0~180。小于 180 的那个角才是「夹角」，
  /// 所以超过 180 就取补角。
  double get _included {
    var d = _angB - _angA;
    while (d > 180) {
      d -= 360;
    }
    while (d <= -180) {
      d += 360;
    }
    return d.abs();
  }

  // ---------------------------------------------------------------- 手势

  void _onDown(Offset p, Size s) {
    // 判定半径 46 逻辑像素 ≈ 成年人手指肚的半径。再小就不好点了。
    const tol = 46.0;
    final dA = (p - _handlePx(_angA, s)).distance;
    final dB = (p - _handlePx(_angB, s)).distance;
    final dC = (p - _centerPx(s)).distance;

    // 线头优先于交点：它们本身就在交点附近，不先判的话
    // 想把线头拽出来时会变成一直在拖交点。
    if (dA <= tol && dA <= dB) {
      setState(() => _drag = 1);
    } else if (dB <= tol) {
      setState(() => _drag = 2);
    } else if (dC <= tol) {
      setState(() => _drag = 0);
    } else {
      _drag = null;
    }
  }

  void _onMove(Offset p, Size s) {
    switch (_drag) {
      case 0:
        // 拖交点。限制在屏幕内留一点边距，免得两条线整个跑出可视区。
        setState(() {
          _center = Offset(
            (p.dx / s.width).clamp(0.12, 0.88),
            (p.dy / s.height).clamp(0.12, 0.88),
          );
        });
        break;
      case 1:
        setState(() => _angA = _angleTo(p, s));
        break;
      case 2:
        setState(() => _angB = _angleTo(p, s));
        break;
      default:
        break;
    }
  }

  void _alignHorizon() {
    final h = _horizon;
    if (h == null) {
      // 手机平放时读不到水平方向，或者传感器还没出数据
      toast(context, '请把手机竖起来对着被测物体，稍等一下再试');
      return;
    }
    setState(() => _angA = h);
  }

  void _reset() {
    setState(() {
      _center = const Offset(0.5, 0.52);
      _angA = -35;
      _angB = 35;
      _drag = null;
    });
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '量角器',
      subtitle: _horizon == null ? '用摄像头对准要量的两条边' : '拖动 A / B 线头贴合被测的两条边',
      actions: [
        if (_cam != null && _err == null) ...[
          IconButton(
            tooltip: _front ? '换成后置摄像头' : '换成前置摄像头',
            onPressed: () {
              setState(() => _front = !_front);
              _initCam();
            },
            icon: const Icon(Icons.cameraswitch_outlined, size: 21),
          ),
          IconButton(
            tooltip: _locked ? '解锁拖动' : '锁定（腾出手来比划）',
            onPressed: () => setState(() => _locked = !_locked),
            icon: Icon(_locked ? Icons.lock : Icons.lock_open, size: 20),
          ),
        ],
      ],
      child: _body(scheme),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, size: 46, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(_err!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13.5, height: 1.75, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _initCam,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_busy || _cam == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (ctx, cons) {
        final s = Size(cons.maxWidth, cons.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _locked ? null : (d) => _onDown(d.localPosition, s),
          onPanUpdate: _locked ? null : (d) => _onMove(d.localPosition, s),
          onPanEnd: _locked ? null : (_) => setState(() => _drag = null),
          onPanCancel: _locked ? null : () => setState(() => _drag = null),
          child: Stack(
            children: [
              Positioned.fill(child: _preview()),
              Positioned.fill(
                child: CustomPaint(
                  painter: _AngleOverlay(
                    center: _center,
                    angA: _angA,
                    angB: _angB,
                    included: _included,
                    horizon: _horizon,
                    handleR: _handleR(s),
                    hideHandles: _locked,
                  ),
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(scheme)),
            ],
          ),
        );
      },
    );
  }

  Widget _preview() {
    final c = _cam!;
    final ps = c.value.previewSize;
    if (ps == null) return CameraPreview(c);

    // previewSize 是**传感器原始**尺寸（横向），竖屏时要交换宽高，
    // 否则画出来的比例是躺着的。
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final w = portrait ? ps.height : ps.width;
    final h = portrait ? ps.width : ps.height;

    // 用 FittedBox(cover) 让画面铺满并且不变形：
    // 它会按比例放大到刚好盖住父容器，多出来的部分裁掉。
    // 比自己算 scale 靠谱 —— 手算漏掉一个旋转就是拉伸变形。
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: w,
          height: h,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  Widget _bottomBar(ColorScheme scheme) {
    final btnStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
      padding: const EdgeInsets.symmetric(vertical: 11),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.72),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_included.toStringAsFixed(1)}°',
            style: const TextStyle(
                fontSize: 42, fontWeight: FontWeight.w300, color: Colors.white, height: 1.1),
          ),
          const SizedBox(height: 2),
          Text(
            _locked ? '已锁定 · 点右上角解锁' : '拖动 A / B 线头贴合两条边，按住交点可以整体移动',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _locked ? null : _alignHorizon,
                  style: btnStyle,
                  icon: const Icon(Icons.horizontal_rule, size: 18),
                  label: const Text('对齐真实水平'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _reset,
                  style: btnStyle,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('重置'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 盖在相机画面上的量角线：两条射线 + 夹角扇形 + 线头把手 + 真实水平虚线。
class _AngleOverlay extends CustomPainter {
  final Offset center;
  final double angA;
  final double angB;
  final double included;
  final double? horizon;
  final double handleR;
  final bool hideHandles;

  const _AngleOverlay({
    required this.center,
    required this.angA,
    required this.angB,
    required this.included,
    required this.horizon,
    required this.handleR,
    required this.hideHandles,
  });

  static const _colA = Color(0xFF2EC4B6);
  static const _colB = Color(0xFFFF9F1C);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(center.dx * size.width, center.dy * size.height);
    // 射线要伸出屏幕，长度随便取个大值就行，超出的部分自然被裁掉
    final far = size.width + size.height;

    // ---------- 真实水平参考虚线 ----------
    final h = horizon;
    if (h != null) {
      final a = h * math.pi / 180;
      final u = Offset(math.cos(a), math.sin(a));
      final dash = Paint()
        ..color = const Color(0xFF8ED8FF).withValues(alpha: 0.6)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      _dashedLine(canvas, c - u * far, c + u * far, dash, 12, 9);
    }

    // ---------- 夹角扇形 ----------
    var sweep = angB - angA;
    while (sweep > 180) {
      sweep -= 360;
    }
    while (sweep <= -180) {
      sweep += 360;
    }
    final rSector = math.min(size.width, size.height) * 0.26;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: rSector),
      angA * math.pi / 180,
      sweep * math.pi / 180,
      true,
      Paint()..color = const Color(0xFF7F77DD).withValues(alpha: 0.24),
    );

    // ---------- 两条射线 ----------
    void ray(double deg, Color col) {
      final a = deg * math.pi / 180;
      final u = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c - u * far,
        c + u * far,
        Paint()
          ..color = col
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
    }

    ray(angA, _colA);
    ray(angB, _colB);

    // ---------- 夹角数值（放在扇形里） ----------
    final mid = (angA + sweep / 2) * math.pi / 180;
    final tp = TextPainter(
      text: TextSpan(
        text: '${included.toStringAsFixed(1)}°',
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          shadows: [Shadow(color: Color(0xCC000000), blurRadius: 6)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lp = c + Offset(math.cos(mid), math.sin(mid)) * (rSector * 0.62);
    tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));

    // ---------- 交点 ----------
    canvas.drawCircle(c, 15, Paint()..color = Colors.white.withValues(alpha: 0.88));
    canvas.drawCircle(
      c,
      15,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF3A3A3A),
    );
    canvas.drawCircle(c, 4, Paint()..color = const Color(0xFF3A3A3A));

    if (hideHandles) return;

    // ---------- 两个线头把手 ----------
    void handle(double deg, Color col, String label) {
      final a = deg * math.pi / 180;
      final p = c + Offset(math.cos(a), math.sin(a)) * handleR;
      canvas.drawCircle(p, 19, Paint()..color = Colors.white.withValues(alpha: 0.92));
      canvas.drawCircle(
        p,
        19,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..color = col,
      );
      final t = TextPainter(
        text: TextSpan(
            text: label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: col)),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, p - Offset(t.width / 2, t.height / 2));
    }

    handle(angA, _colA, 'A');
    handle(angB, _colB, 'B');
  }

  /// 画虚线。Canvas 没有原生虚线，只能自己按 dash / gap 一段段画。
  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, double dash, double gap) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final e = math.min(t + dash, total);
      canvas.drawLine(a + dir * t, a + dir * e, paint);
      t = e + gap;
    }
  }

  @override
  bool shouldRepaint(_AngleOverlay old) =>
      old.center != center ||
      old.angA != angA ||
      old.angB != angB ||
      old.included != included ||
      old.horizon != horizon ||
      old.handleR != handleR ||
      old.hideHandles != hideHandles;
}

// ============================================================ 3. 配色助手

/// 配色助手。
///
/// v1.3.0 新增 RGB 的输入与输出：
///   * **输出** —— 主色下面多了一行 `RGB 59, 130, 246`，点一下直接复制。
///     以前只有 HEX，但设计师给的颜色经常是 RGB 三元组。
///   * **输入** —— 顶部加了一个框，可以把 RGB 直接粘进来，
///     滑块和整套色板会立刻跳到那个颜色。
///     除了标准写法，额外认「59,130,246」这种最朴素的三个数字
///     （从设计稿 / 取色器里抄出来就是这形态，逗号、空格、斜杠都吃）。
class ColorSchemeHelperPage extends StatefulWidget {
  const ColorSchemeHelperPage({super.key});

  @override
  State<ColorSchemeHelperPage> createState() => _ColorSchemeHelperPageState();
}

class _ColorSchemeHelperPageState extends State<ColorSchemeHelperPage> {
  double _h = 210, _s = 0.65, _l = 0.5;

  final _input = TextEditingController();
  String? _inputErr;

  Color get _base => HSLColor.fromAHSL(1, _h, _s, _l).toColor();

  String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 0~255 的 RGB 三元组文本，例如「59, 130, 246」
  String _rgb(Color c) =>
      '${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()}';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 同色系明暗阶梯
  List<Color> _tints(int n) {
    final out = <Color>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final l = 0.95 - t * 0.75;
      out.add(HSLColor.fromAHSL(1, _h, _s * (0.6 + 0.4 * t), l.clamp(0.05, 0.98)).toColor());
    }
    return out;
  }

  List<Color> _harmony(double offset, {int n = 3, double spread = 30}) => List.generate(
        n,
        (i) => HSLColor.fromAHSL(1, (_h + offset + (i - (n - 1) / 2) * spread) % 360, _s, _l)
            .toColor(),
      );

  /// 解析用户输入的颜色。
  ///
  /// 先试「三个 0~255 的数字」这种朴素写法，再交给
  /// _parseColorText 处理 HEX / rgb() / hsl()。
  Color? _parseInput(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;

    final lower = t.toLowerCase();
    final plain = !t.startsWith('#') && !lower.startsWith('rgb') && !lower.startsWith('hsl');
    if (plain) {
      final nums = RegExp(r'\d+').allMatches(t).map((m) => int.parse(m.group(0)!)).toList();
      if (nums.length == 3 && nums.every((n) => n >= 0 && n <= 255)) {
        return Color.fromARGB(255, nums[0], nums[1], nums[2]);
      }
    }

    // 复用颜色码转换那边的解析器 —— 两个页面对「什么算合法颜色」
    // 的判断必须一致，不然用户会觉得其中一个坏了。
    // 注意：_parseColorText 是**文件顶层**的私有函数，
    // 直接不带类名调用（早先写 `ColorConvertPage.parseColor` 编译不过）。
    return _parseColorText(t);
  }

  void _applyInput(String s) {
    if (s.trim().isEmpty) {
      setState(() => _inputErr = null);
      return;
    }
    final c = _parseInput(s);
    if (c == null) {
      setState(() => _inputErr = '认不出来，试试 59,130,246 或 #3B82F6');
      return;
    }
    final hsl = HSLColor.fromColor(c);
    setState(() {
      _h = hsl.hue;
      _s = hsl.saturation;
      // 明度滑块的下限是 0.05，纯黑/纯白进来时会超出范围，
      // 不夹一下 Slider 会直接抛 assert。
      _l = hsl.lightness.clamp(0.05, 0.95);
      _inputErr = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '配色助手',
      subtitle: '拖出主色，自动配出整套色板',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            height: 92,
            decoration: BoxDecoration(
              color: _base,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              _hex(_base),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: _base.computeLuminance() > 0.55 ? Colors.black87 : Colors.white,
              ),
            ),
          ),

          // ---------- RGB 输出 ----------
          const SizedBox(height: 8),
          InkWell(
            onTap: () => copyText(context, _rgb(_base)),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                children: [
                  Text('RGB',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_rgb(_base),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
                  ),
                  Icon(Icons.copy, size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),

          // ---------- RGB 输入 ----------
          const SizedBox(height: 4),
          TextField(
            controller: _input,
            decoration: InputDecoration(
              isDense: true,
              labelText: '输入颜色直接跳过去',
              hintText: '59,130,246 或 #3B82F6 或 rgb(59,130,246)',
              errorText: _inputErr,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _input.clear();
                  _applyInput('');
                },
              ),
            ),
            onChanged: _applyInput,
          ),

          const SizedBox(height: 10),
          _slider('色相', _h, 0, 360, (v) => setState(() => _h = v)),
          _slider('饱和度', _s, 0, 1, (v) => setState(() => _s = v)),
          _slider('明度', _l, 0.05, 0.95, (v) => setState(() => _l = v)),

          const ToolSection('明暗阶梯（做主色 / 背景 / 边框都好用）'),
          _row(_tints(8)),

          const ToolSection('互补色（对面 180°，做强调色）'),
          _row(_harmony(180, n: 3, spread: 18)),

          const ToolSection('邻近色（±30°，柔和过渡）'),
          _row(_harmony(0, n: 5, spread: 22)),

          const ToolSection('三角配色（120° 间隔，对比强）'),
          _row([
            _base,
            HSLColor.fromAHSL(1, (_h + 120) % 360, _s, _l).toColor(),
            HSLColor.fromAHSL(1, (_h + 240) % 360, _s, _l).toColor(),
          ]),

          const ToolSection('四角配色（90° 间隔）'),
          _row([
            _base,
            HSLColor.fromAHSL(1, (_h + 90) % 360, _s, _l).toColor(),
            HSLColor.fromAHSL(1, (_h + 180) % 360, _s, _l).toColor(),
            HSLColor.fromAHSL(1, (_h + 270) % 360, _s, _l).toColor(),
          ]),

          const ToolSection('一键复制'),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final tints = _tints(8).map(_hex).join(', ');
                copyText(context, tints);
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制明暗阶梯的 8 个色值（HEX）'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final rgbs = _tints(8).map((c) => 'rgb(${_rgb(c)})').join('\n');
                copyText(context, rgbs);
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制明暗阶梯的 8 个色值（RGB）'),
            ),
          ),
          const SizedBox(height: 6),
          Text('点任意色块也能单独复制它的 HEX；主色那行的 RGB 点一下也能复制。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> onChanged) =>
      Row(
        children: [
          SizedBox(width: 46, child: Text(label, style: const TextStyle(fontSize: 12.5))),
          Expanded(
            child: Slider(value: v.clamp(min, max), min: min, max: max, onChanged: onChanged),
          ),
          SizedBox(
            width: 46,
            child: Text(
              label == '色相' ? '${v.round()}°' : '${(v * 100).round()}%',
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      );

  Widget _row(List<Color> colors) => SizedBox(
        height: 60,
        child: Row(
          children: [
            for (final c in colors)
              Expanded(
                child: InkWell(
                  onTap: () => copyText(context, _hex(c)),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _hex(c).substring(1),
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

// ============================================================ 4. 番茄时钟

/// 番茄时钟。
///
/// v1.3.0 新增铃声：一个阶段结束时响铃，可以从 7 种里挑。
///   * 音频走 media_kit 的 asset:// scheme 播放 —— 项目里本来就有它，
///     不必为了几个提示音再引一个音频包（这个 App 历次构建翻车
///     全是因为依赖冲突，能不加包就不加）。
///   * 铃声文件是 .workbuddy/gen_sounds.py 合成出来的正弦波，
///     无版权风险，7 个一共 340 KB。
///   * 选择记在 SharedPreferences 里，下次进来还在。
///
/// 铃声只负责「响一声」，不负责把 App 从后台叫起来 ——
/// 前台计时器被系统挂起时它也响不了。这点在页面底部写了说明。
class PomodoroPage extends StatefulWidget {
  const PomodoroPage({super.key});

  @override
  State<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends State<PomodoroPage> {
  int _work = 25, _short = 5, _long = 15, _rounds = 4;
  bool _running = false;
  bool _isWork = true;
  int _left = 25 * 60;
  int _done = 0; // 已完成番茄数
  Timer? _t;

  /// 铃声播放器。懒建 —— 大部分人不开铃声，没必要一进页面就占一份
  /// 播放器资源。dispose 里会收掉。
  Player? _player;

  /// 当前铃声的 assets 路径。空串 = 静音。
  String _bell = 'assets/sounds/bell_dingdong.wav';

  /// 音量（0~1）。做得比系统铃声轻一点，默认 0.75。
  double _bellVol = 0.75;

  static const _kBellKey = 'pomodoro_bell';
  static const _kBellVolKey = 'pomodoro_bell_vol';

  /// 可选铃声。顺序按「最常用」排，静音放第一个方便一键关掉。
  static const _bells = <(String, String)>[
    ('静音', ''),
    ('叮咚', 'assets/sounds/bell_dingdong.wav'),
    ('清脆提示', 'assets/sounds/bell_tip.wav'),
    ('上课铃', 'assets/sounds/bell_class.wav'),
    ('下课铃', 'assets/sounds/bell_break.wav'),
    ('轻柔三音', 'assets/sounds/bell_soft.wav'),
    ('深钟', 'assets/sounds/bell_deep.wav'),
    ('闹钟', 'assets/sounds/bell_alarm.wav'),
  ];

  @override
  void initState() {
    super.initState();
    _left = _work * 60;
    _restoreBell();
  }

  @override
  void dispose() {
    _t?.cancel();
    _player?.dispose();
    keepScreenOn(false);
    super.dispose();
  }

  // ------------------------------------------------------------ 铃声

  Future<void> _restoreBell() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final b = sp.getString(_kBellKey);
      final v = sp.getDouble(_kBellVolKey);
      if (!mounted) return;
      setState(() {
        if (b != null && _bells.any((e) => e.$2 == b)) _bell = b;
        if (v != null) _bellVol = v.clamp(0.0, 1.0);
      });
    } catch (_) {
      // 读不到配置就用默认的，不该因此影响计时功能
    }
  }

  Future<void> _saveBell() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kBellKey, _bell);
      await sp.setDouble(_kBellVolKey, _bellVol);
    } catch (_) {}
  }

  /// 放某个铃声。空路径直接忽略。
  ///
  /// 这个函数**不碰 _bell** —— 试听按钮不该顺手把选中项也改掉。
  /// （一开始写成「试听即选中」，结果点第二个的试听按钮时
  ///   选中标记还停在第一个上，看着像坏了。）
  Future<void> _play(String path) async {
    if (path.isEmpty) return;
    try {
      _player ??= Player();
      // media_kit 的 setVolume 取值 0~100，不是 0~1
      await _player!.setVolume(_bellVol * 100);
      // media_kit 约定：asset:/// 后面跟 pubspec 里写的相对路径。
      // 三个斜杠不是笔误 —— 前两个是 scheme 的分隔符，第三个开始才是路径。
      await _player!.open(Media('asset:///$path'));
    } catch (_) {
      // 放不出来就算了。铃声是锦上添花，绝不能因此把计时器搞崩。
    }
  }

  /// 阶段结束时响铃
  Future<void> _ring() => _play(_bell);

  // ------------------------------------------------------------ 计时

  void _start() {
    setState(() => _running = true);
    keepScreenOn(true);
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        _finishPhase();
      } else {
        setState(() => _left--);
      }
    });
  }

  void _pause() {
    _t?.cancel();
    setState(() => _running = false);
    keepScreenOn(false);
  }

  void _reset() {
    _t?.cancel();
    setState(() {
      _running = false;
      _isWork = true;
      _left = _work * 60;
      _done = 0;
    });
    keepScreenOn(false);
  }

  void _finishPhase() {
    HapticFeedback.heavyImpact();
    // 铃声和震动同时来，隔着口袋也能察觉
    _ring();

    final wasWork = _isWork;
    setState(() {
      if (wasWork) {
        _done++;
        _isWork = false;
        _left = (_done % _rounds == 0 ? _long : _short) * 60;
      } else {
        _isWork = true;
        _left = _work * 60;
      }
    });
    _t?.cancel();
    setState(() => _running = false);
    keepScreenOn(false);
    final msg = wasWork
        ? '专注结束，休息 ${_done % _rounds == 0 ? _long : _short} 分钟'
        : '休息结束，开始下一个番茄';
    toast(context, msg);
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = (_isWork ? _work : (_done % _rounds == 0 ? _long : _short)) * 60;
    final ratio = total == 0 ? 0.0 : 1 - _left / total;
    final mm = (_left ~/ 60).toString().padLeft(2, '0');
    final ss = (_left % 60).toString().padLeft(2, '0');
    final accent = _isWork ? const Color(0xFFD85A30) : const Color(0xFF1D9E75);

    return ToolScaffold(
      title: '番茄时钟',
      subtitle: '专注 $_work 分钟 / 休息 $_short 分钟，每 $_rounds 个番茄长休 $_long 分钟',
      actions: [
        IconButton(tooltip: '重置', onPressed: _reset, icon: const Icon(Icons.restart_alt)),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Column(
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: ratio,
                            strokeWidth: 10,
                            backgroundColor: accent.withValues(alpha: 0.15),
                            valueColor: AlwaysStoppedAnimation(accent),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$mm:$ss',
                                style: const TextStyle(
                                    fontSize: 42,
                                    fontWeight: FontWeight.w300,
                                    fontFeatures: [ui.FontFeature.tabularFigures()])),
                            Text(_isWork ? '专注中' : '休息中',
                                style: TextStyle(fontSize: 13, color: accent)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _rounds; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < _done % _rounds ||
                                      (_done > 0 && _done % _rounds == 0 && i < _rounds)
                                  ? accent
                                  : accent.withValues(alpha: 0.2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('今天已专注 $_done 个番茄',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _running ? _pause : _start,
                  icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                  label: Text(_running ? '暂停' : '开始'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  _t?.cancel();
                  setState(() {
                    _running = false;
                    _isWork = !_isWork;
                    _left = (_isWork ? _work : _short) * 60;
                  });
                },
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('切换阶段'),
              ),
            ],
          ),

          // -------------------- 铃声 --------------------
          const ToolSection('铃声（一个阶段结束时响）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: Column(
                children: [
                  for (final b in _bells)
                    // 没用 RadioListTile：它的 groupValue / onChanged 在新版
                    // Flutter 里被标记弃用、转向 RadioGroup 那套新 API，
                    // 而这里是锁 3.47.6 编译的，跨版本行为不好保证。
                    // 一个选中圆点而已，自己画最稳。
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      onTap: () {
                        setState(() => _bell = b.$2);
                        _saveBell();
                        // 选中即试听 —— 光看「深钟」「叮咚」这些名字
                        // 根本猜不出区别，不试听就得一个个点过去听。
                        _play(b.$2);
                      },
                      leading: Icon(
                        _bell == b.$2
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: _bell == b.$2 ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      title: Text(b.$1, style: const TextStyle(fontSize: 13.5)),
                      trailing: b.$2.isEmpty
                          ? Icon(Icons.volume_off_outlined,
                              size: 19, color: scheme.onSurfaceVariant)
                          : IconButton(
                              tooltip: '试听',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.play_circle_outline, size: 21),
                              onPressed: () => _play(b.$2),
                            ),
                    ),
                  const Divider(height: 6),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 4, 8, 6),
                    child: Row(
                      children: [
                        Text('音量', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                        Expanded(
                          child: Slider(
                            value: _bellVol,
                            min: 0,
                            max: 1,
                            onChanged: _bell.isEmpty
                                ? null
                                : (v) => setState(() => _bellVol = v),
                            onChangeEnd: (_) => _saveBell(),
                          ),
                        ),
                        Text('${(_bellVol * 100).round()}%',
                            style: const TextStyle(fontSize: 11.5)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const ToolSection('时长设置（分钟）'),
          _num('专注', _work, 5, 120, (v) {
            setState(() {
              _work = v;
              if (!_running && _isWork) _left = v * 60;
            });
          }),
          _num('短休', _short, 1, 30, (v) => setState(() => _short = v)),
          _num('长休', _long, 5, 60, (v) => setState(() => _long = v)),
          _num('每几个番茄长休', _rounds, 2, 8, (v) => setState(() => _rounds = v)),
          const SizedBox(height: 10),
          Text(
            '提示：计时期间会保持屏幕常亮。\n'
            '铃声只在 App 停在前台时有效 —— 锁屏或切后台后系统会挂起计时，'
            '到点也响不了，这不是 App 能控制的。真要长时间离开，'
            '建议用系统自带的闹钟兜底。',
            style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _num(String label, int v, int min, int max, ValueChanged<int> onChanged) => Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: v > min ? () => onChanged(v - 1) : null,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
          SizedBox(width: 26, child: Text('$v', textAlign: TextAlign.center)),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: v < max ? () => onChanged(v + 1) : null,
            icon: const Icon(Icons.add_circle_outline, size: 20),
          ),
        ],
      );
}

// ============================================================ 5. 日期计算

/// 日期计算。
///
/// v1.3.0 改动：
///   * 删掉「常用倒计时」整块 —— 春节 / 暑假 / 元旦那几条是硬编码的，
///     每年都得手改，而且跟「日期计算」这个定位本来就不搭。
///   * 「今天」里删掉「距元旦 N 天」。它跟紧挨着的「本年第 N 天」是同一件事，
///     两个数并排放着只会让人犹豫该看哪个。
///   * 差值结果只留**天数**和**日期**，去掉「= x 周 = y 个月」「工作日 z 天」。
///     用户明确说了这些不要 —— 周和月是估出来的（/7、/30.44），
///     看着精确其实不准；工作日还要考虑法定节假日才算得对。
///   * 新增「把开始那天也算进去」开关。1 月 1 日到 1 月 3 日，
///     不含首日是 2 天、含首日是 3 天 —— 两种口径日常都会用到
///     （数请假天数要含首日，数间隔天数不含），所以做成可切换。
///   * 日期选择器现在是中文的 —— 由 MaterialApp 的
///     GlobalMaterialLocalizations 统一处理，这里不用再管。
class DateCalcPage extends StatefulWidget {
  const DateCalcPage({super.key});

  @override
  State<DateCalcPage> createState() => _DateCalcPageState();
}

class _DateCalcPageState extends State<DateCalcPage> {
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now().add(const Duration(days: 30));
  DateTime _base = DateTime.now();
  int _offset = 30;
  String _unit = '天';

  /// 区间天数是否把开始那天也算进去。默认不含（这是「相差多少天」的通行口径）。
  bool _includeStart = false;

  static final _fmt = DateFormat('yyyy-MM-dd');
  static final _fmtLong = DateFormat('yyyy年M月d日 EEEE', 'zh_CN');

  Future<DateTime?> _pick(DateTime init) => showDatePicker(
        context: context,
        initialDate: init,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200),
      );

  /// 把时间部分抹掉，只留年月日。
  /// 不抹的话 DateTime.now() 带时分秒，两个日期相减的 inDays 会因为
  /// 几小时之差少算一天 —— 这是日期计算里最经典的坑。
  static DateTime _d0(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();

    final rawDays = _d0(_to).difference(_d0(_from)).inDays;
    // 只有顺着数（结束 >= 开始）时，「含首日」才是 +1。
    // 反着数的时候加 1 反而更难解释，所以不动。
    final days = rawDays + (_includeStart && rawDays >= 0 ? 1 : 0);

    final basePlus = _shift(_base, _offset, _unit);

    return ToolScaffold(
      title: '日期计算',
      subtitle: _fmtLong.format(today),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const ToolSection('今天'),
          ResultBox(
            text: '${_fmtLong.format(today)}\n'
                '本年第 ${_dayOfYear(today)} 天 · 剩 ${_daysInYear(today.year) - _dayOfYear(today)} 天\n'
                '第 ${_isoWeek(today)} 周',
            hint: '点一下复制日期',
          ),

          const ToolSection('两个日期之间差多少'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Column(
                children: [
                  _dateRow('开始', _from, (d) => setState(() => _from = d)),
                  _dateRow('结束', _to, (d) => setState(() => _to = d)),
                  const Divider(height: 18),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _includeStart,
                    onChanged: (v) => setState(() => _includeStart = v),
                    title: const Text('把开始那天也算进去', style: TextStyle(fontSize: 13)),
                    subtitle: Text(
                      _includeStart
                          ? '例：1 月 1 日 → 1 月 3 日，算 3 天（含首尾）'
                          : '例：1 月 1 日 → 1 月 3 日，算 2 天（不含首日）',
                      style: TextStyle(fontSize: 11.5, height: 1.4, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const Divider(height: 18),
                  if (rawDays >= 0)
                    ResultBox(
                      text: '相差 $days 天\n'
                          '${_fmt.format(_d0(_from))}  →  ${_fmt.format(_d0(_to))}',
                    )
                  else
                    const ResultBox(text: '结束日期比开始日期早，把两个日期换一下顺序'),
                ],
              ),
            ),
          ),

          const ToolSection('从某天往前 / 往后推'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Column(
                children: [
                  _dateRow('基准日', _base, (d) => setState(() => _base = d)),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '偏移量（可为负）',
                            isDense: true,
                          ),
                          controller: TextEditingController(text: '$_offset'),
                          onChanged: (v) => setState(() => _offset = int.tryParse(v) ?? 0),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: _unit,
                        items: const [
                          DropdownMenuItem(value: '天', child: Text('天')),
                          DropdownMenuItem(value: '周', child: Text('周')),
                          DropdownMenuItem(value: '月', child: Text('月')),
                          DropdownMenuItem(value: '年', child: Text('年')),
                        ],
                        onChanged: (v) => setState(() => _unit = v ?? '天'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ResultBox(
                    text: '$_base 的 $_offset $_unit 后是\n'
                        '${_fmt.format(_d0(basePlus))}（${DateFormat('EEEE', 'zh_CN').format(basePlus)}）',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateRow(String label, DateTime d, ValueChanged<DateTime> onChanged) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 12.5)),
        trailing: TextButton.icon(
          onPressed: () async {
            final r = await _pick(d);
            if (r != null) onChanged(r);
          },
          icon: const Icon(Icons.event, size: 17),
          label: Text(DateFormat('yyyy-MM-dd EEE', 'zh_CN').format(d)),
        ),
      );

  static int _dayOfYear(DateTime d) => d.difference(DateTime(d.year, 1, 1)).inDays + 1;

  static int _daysInYear(int y) => DateTime(y, 12, 31).difference(DateTime(y, 1, 1)).inDays + 1;

  /// ISO 8601 周号：第 1 周是含当年第一个星期四的那一周。
  static int _isoWeek(DateTime d) {
    final thursday = d.add(Duration(days: 4 - (d.weekday == 7 ? 7 : d.weekday)));
    final firstThursday = DateTime(thursday.year, 1, 1)
        .add(Duration(days: (11 - DateTime(thursday.year, 1, 1).weekday) % 7));
    return ((thursday.difference(firstThursday).inDays) / 7).floor() + 1;
  }

  static DateTime _shift(DateTime d, int n, String unit) {
    switch (unit) {
      case '周':
        return d.add(Duration(days: n * 7));
      case '月':
        return DateTime(d.year, d.month + n, d.day);
      case '年':
        return DateTime(d.year + n, d.month, d.day);
      default:
        return d.add(Duration(days: n));
    }
  }
}

// ============================================================ 6. 颜色码转换

/// 解析用户手打的各种颜色写法。
///
/// 提到顶层是有原因的：配色助手那边也要解析用户输入，两个页面
/// 对「什么算合法颜色」必须完全一致 —— 否则用户会觉得其中一个坏了。
/// 早先写成 _ColorConvertPageState 的静态方法，结果私有类从外面
/// 根本引用不到（`ColorConvertPage.parseColor` 编译报 Member not found）。
///
/// 支持：`#RGB` / `#RRGGBB` / `#AARRGGBB`（不带 # 也行）、`rgb(r,g,b[,a])`、
/// `hsl(h,s%,l%)`。认不出来返回 null。
Color? _parseColorText(String s) {
  var t = s.trim().replaceAll('#', '').replaceAll(' ', '');
  if (t.isEmpty) return null;
  if (t.toLowerCase().startsWith('rgb')) {
    final nums = RegExp(r'[\d.]+').allMatches(t).map((m) => double.tryParse(m.group(0)!) ?? 0).toList();
    if (nums.length >= 3) {
      final a = nums.length >= 4 ? nums[3].clamp(0, 1) : 1.0;
      return Color.fromARGB(
        (a * 255).round(),
        nums[0].clamp(0, 255).round(),
        nums[1].clamp(0, 255).round(),
        nums[2].clamp(0, 255).round(),
      );
    }
    return null;
  }
  if (t.toLowerCase().startsWith('hsl')) {
    final nums = RegExp(r'[\d.]+').allMatches(t).map((m) => double.tryParse(m.group(0)!) ?? 0).toList();
    if (nums.length >= 3) {
      return HSLColor.fromAHSL(1, nums[0] % 360, (nums[1] / 100).clamp(0, 1), (nums[2] / 100).clamp(0, 1))
          .toColor();
    }
    return null;
  }
  if (t.length == 3) t = '${t[0]}${t[0]}${t[1]}${t[1]}${t[2]}${t[2]}';
  if (t.length == 6) t = 'FF$t';
  if (t.length == 8) {
    final v = int.tryParse(t, radix: 16);
    if (v == null) return null;
    // 用户一般是 RRGGBBAA 习惯还是 AARRGGBB？这里按 AARRGGBB 解析（Flutter 习惯）
    return Color(v);
  }
  return null;
}

class ColorConvertPage extends StatefulWidget {
  const ColorConvertPage({super.key});

  @override
  State<ColorConvertPage> createState() => _ColorConvertPageState();
}

class _ColorConvertPageState extends State<ColorConvertPage> {
  final _input = TextEditingController(text: '#3B82F6');
  Color? _color;
  String? _error;

  @override
  void initState() {
    super.initState();
    _parse(_input.text);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _parse(String s) {
    final c = _parseColorText(s);
    setState(() {
      _color = c;
      _error = c == null ? '识别不了这个颜色，试试 #RRGGBB 或 rgb(59,130,246)' : null;
    });
  }

  String _hex(Color c, {bool withAlpha = false}) {
    final v = c.toARGB32();
    if (withAlpha) return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
    return '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = _color;

    return ToolScaffold(
      title: '颜色码转换',
      subtitle: 'HEX / RGB / HSL / ARGB 互转',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          TextField(
            controller: _input,
            decoration: InputDecoration(
              labelText: '输入任意格式的颜色',
              hintText: '#3B82F6 / 3B82F6 / rgb(59,130,246) / hsl(217,91%,60%)',
              errorText: _error,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _input.clear();
                  _parse('');
                },
              ),
            ),
            onChanged: _parse,
          ),
          const SizedBox(height: 16),
          if (c != null) ...[
            Container(
              height: 110,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: Text(
                _hex(c),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _row('HEX', _hex(c)),
            _row('HEX（带透明度）', _hex(c, withAlpha: true)),
            _row('RGB', 'rgb(${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()})'),
            _row('RGBA',
                'rgba(${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()}, ${c.a.toStringAsFixed(2)})'),
            _row('ARGB（Flutter）', '0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}'),
            _row('整数 RGB', '${((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round()}'),
            () {
              final hsl = HSLColor.fromColor(c);
              return _row('HSL',
                  'hsl(${hsl.hue.round()}, ${(hsl.saturation * 100).round()}%, ${(hsl.lightness * 100).round()}%)');
            }(),
            _row('明度（是否偏亮）',
                '${(c.computeLuminance() * 100).toStringAsFixed(1)}% —— 数值大于 50% 建议用深色文字'),
            const SizedBox(height: 14),
            const ToolSection('常用色'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in _presets)
                  InkWell(
                    onTap: () {
                      _input.text = item.$2;
                      _parse(item.$2);
                    },
                    child: Container(
                      width: 62,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        // 这里原本直接写 item.$2 —— 但那是 '#EF4444' 这种字符串，
                        // BoxDecoration.color 要的是 Color，编不过。
                        // 下面一行取亮度时已经用了 _parseColorText()，这里补上。
                        color: _parseColorText(item.$2),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Text(
                        item.$1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: (_parseColorText(item.$2)?.computeLuminance() ?? 1) > 0.55
                              ? Colors.black87
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static const _presets = <(String, String)>[
    ('红', '#EF4444'),
    ('橙', '#F97316'),
    ('黄', '#EAB308'),
    ('绿', '#22C55E'),
    ('青', '#06B6D4'),
    ('蓝', '#3B82F6'),
    ('紫', '#8B5CF6'),
    ('粉', '#EC4899'),
    ('灰', '#6B7280'),
    ('黑', '#111827'),
    ('白', '#FFFFFF'),
    ('品牌蓝', '#185FA5'),
  ];

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(fontSize: 12)),
          subtitle: SelectableText(value, style: const TextStyle(fontSize: 13.5)),
          trailing: IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => copyText(context, value),
          ),
        ),
      );
}

// ============================================================ 7. 噪声测量

class NoiseMeterPage extends StatefulWidget {
  const NoiseMeterPage({super.key});

  @override
  State<NoiseMeterPage> createState() => _NoiseMeterPageState();
}

class _NoiseMeterPageState extends State<NoiseMeterPage> {
  NoiseMeter? _meter;
  StreamSubscription<NoiseReading>? _sub;
  bool _running = false;
  bool _denied = false;
  double _db = 0;
  double _peak = 0;
  double _sum = 0;
  int _n = 0;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_running) {
      await _stop();
      return;
    }
    final st = await Permission.microphone.request();
    // 权限弹窗期间用户完全可能退出去
    if (!mounted) return;
    if (!st.isGranted) {
      setState(() => _denied = true);
      toast(context, '没有麦克风权限，测不了噪声');
      return;
    }
    setState(() {
      _denied = false;
      _running = true;
      _peak = 0;
      _sum = 0;
      _n = 0;
    });
    try {
      _meter = NoiseMeter();
      _sub = _meter!.noise.listen(
        (r) {
          if (!mounted) return;
          setState(() {
            _db = r.meanDecibel;
            if (r.maxDecibel > _peak) _peak = r.maxDecibel;
            _sum += r.meanDecibel;
            _n++;
          });
        },
        onError: (_) => _stop(),
        cancelOnError: true,
      );
    } catch (e) {
      setState(() => _running = false);
      toast(context, '麦克风打不开：$e');
    }
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    if (mounted) setState(() => _running = false);
  }

  String get _level {
    final v = _db;
    if (v <= 0) return '—';
    if (v < 35) return '很安静（图书馆、深夜卧室）';
    if (v < 55) return '安静（正常说话、办公室）';
    if (v < 70) return '有点吵（街道、吸尘器）';
    if (v < 85) return '很吵（马路边、地铁）';
    if (v < 100) return '非常吵（工地、音响旁）';
    return '极端噪音（可能伤听力）';
  }

  Color _levelColor() {
    final v = _db;
    if (v < 55) return const Color(0xFF1D9E75);
    if (v < 70) return const Color(0xFFEF9F27);
    if (v < 85) return const Color(0xFFD85A30);
    return const Color(0xFFC0392B);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avg = _n == 0 ? 0.0 : _sum / _n;
    final ratio = ((_db - 20) / 100).clamp(0.0, 1.0);

    return ToolScaffold(
      title: '噪声测量',
      subtitle: '用麦克风估算环境音量（dB）',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
              child: Column(
                children: [
                  Text(
                    _running ? '${_db.toStringAsFixed(1)}' : '--.-',
                    style: TextStyle(
                      fontSize: 60,
                      fontWeight: FontWeight.w300,
                      color: _running ? _levelColor() : scheme.onSurfaceVariant,
                    ),
                  ),
                  const Text('分贝 dB', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _running ? ratio : 0,
                      minHeight: 12,
                      valueColor: AlwaysStoppedAnimation(_levelColor()),
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('20 极静', style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                      Text('120 震耳', style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(_running ? _level : '点下面的按钮开始测量',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13.5, height: 1.5)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _toggle,
                  icon: Icon(_running ? Icons.stop : Icons.mic_none),
                  label: Text(_running ? '停止' : '开始测量'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () => setState(() {
                  _peak = 0;
                  _sum = 0;
                  _n = 0;
                }),
                child: const Text('清零'),
              ),
            ],
          ),
          const ToolSection('这次测量'),
          ResultBox(
            text: '当前 ${_db.toStringAsFixed(1)} dB\n'
                '最高 ${_peak.toStringAsFixed(1)} dB\n'
                '平均 ${avg.toStringAsFixed(1)} dB\n'
                '采样 ${_n} 次',
            hint: '点一下复制',
          ),
          const ToolSection('参考'),
          Card(
            child: Column(
              children: [
                for (final r in const [
                  ('20 dB', '树叶沙沙声、呼吸'),
                  ('40 dB', '安静的图书馆'),
                  ('60 dB', '正常交谈'),
                  ('70 dB', '吸尘器、街道噪音'),
                  ('85 dB', '长时间暴露会损伤听力'),
                  ('100 dB', '电钻、夜店音响'),
                  ('120 dB', '飞机起飞，立刻不适'),
                ])
                  ListTile(
                    dense: true,
                    title: Text(r.$1, style: const TextStyle(fontSize: 13)),
                    trailing: Text(r.$2,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '说明：手机麦克风不是专业声级计，读数只能做相对比较（比如判断房间是不是太吵、'
            '孩子练琴音量够不够）。手机壳、手挡住麦克风都会影响读数。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ============================================================ 8. 应用管理

class AppManagerPage extends StatefulWidget {
  const AppManagerPage({super.key});

  @override
  State<AppManagerPage> createState() => _AppManagerPageState();
}

class _AppManagerPageState extends State<AppManagerPage> {
  List<AppInfo> _apps = const [];
  List<AppInfo> _filtered = const [];
  bool _loading = false;
  String? _error;
  bool _system = false;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await FlutterDeviceApps.listApps(
        includeSystem: _system,
        onlyLaunchable: true,
        includeIcons: true,
      );
      list.sort((a, b) => (a.appName ?? a.packageName ?? '')
          .toLowerCase()
          .compareTo((b.appName ?? b.packageName ?? '').toLowerCase()));
      if (!mounted) return;
      setState(() {
        _apps = list;
        _filtered = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读不到应用列表：$e\n\n'
            'Android 11 以上需要在系统设置里允许本应用「查看已安装的应用」。'
            '如果列表是空的，去设置里打开「应用管理 / 查询所有应用」权限再回来刷新。';
        _loading = false;
      });
    }
  }

  void _filter(String q) {
    final t = q.trim().toLowerCase();
    setState(() {
      _filtered = t.isEmpty
          ? _apps
          : _apps
              .where((a) =>
                  (a.appName ?? '').toLowerCase().contains(t) ||
                  (a.packageName ?? '').toLowerCase().contains(t))
              .toList();
    });
  }

  String _size(int? b) => b == null || b <= 0 ? '未知' : formatBytes(b);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '应用管理',
      subtitle: '${_filtered.length} 个应用 · 可提取安装包分享',
      actions: [
        IconButton(
          tooltip: _system ? '只看用户应用' : '显示系统应用',
          onPressed: () {
            setState(() => _system = !_system);
            _load();
          },
          icon: Icon(_system ? Icons.phone_android : Icons.filter_alt_off_outlined),
        ),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      ],
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: '搜索应用名或包名',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: _filter,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          Icon(Icons.info_outline, size: 40, color: scheme.onSurfaceVariant),
                          const SizedBox(height: 14),
                          Text(_error!, style: const TextStyle(fontSize: 13, height: 1.7)),
                          const SizedBox(height: 16),
                          Center(
                            child: OutlinedButton(
                              onPressed: () => setState(() => _error = null),
                              child: const Text('知道了'),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                        itemBuilder: (_, i) {
                          final a = _filtered[i];
                          return ListTile(
                            leading: _icon(a),
                            title: Text(a.appName ?? a.packageName ?? '未知应用',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${a.packageName ?? ''}\n${a.versionName ?? '?'} · ${_size(a.apkSizeBytes)}',
                              style: const TextStyle(fontSize: 11.5, height: 1.4),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            isThreeLine: true,
                            onTap: () => _sheet(a),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _icon(AppInfo a) {
    final bytes = a.iconBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.memory(Uint8List.fromList(bytes), width: 40, height: 40, fit: BoxFit.cover),
      );
    }
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(Icons.android, size: 22),
    );
  }

  void _sheet(AppInfo a) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: _icon(a),
                title: Text(a.appName ?? a.packageName ?? ''),
                subtitle: Text('${a.packageName ?? ''}\n版本 ${a.versionName ?? '?'}',
                    style: const TextStyle(fontSize: 11.5)),
                isThreeLine: true,
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('提取为安装包（APK）'),
                subtitle: const Text('复制到手机下载目录，可以分享给朋友或备份'),
                onTap: () {
                  Navigator.pop(context);
                  _extract(a);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('提取并直接分享'),
                onTap: () {
                  Navigator.pop(context);
                  _extract(a, share: true);
                },
              ),
              if ((a.packageName ?? '').isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('打开应用'),
                  onTap: () {
                    Navigator.pop(context);
                    FlutterDeviceApps.openApp(a.packageName!);
                  },
                ),
              if ((a.packageName ?? '').isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('打开应用信息（改权限 / 卸载）'),
                  onTap: () {
                    Navigator.pop(context);
                    FlutterDeviceApps.openAppSettings(a.packageName!);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _extract(AppInfo a, {bool share = false}) async {
    final src = a.apkPath;
    if (src == null || src.isEmpty) {
      toast(context, '这个应用没有暴露安装包路径（多半是系统应用）');
      return;
    }
    if (Platform.isAndroid) {
      final ok = await ensureStoragePermission();
      if (!ok) toast(context, '没有存储权限，将保存到应用专属目录');
    }
    try {
      final f = File(src);
      if (!await f.exists()) {
        toast(context, '读不到安装包文件（部分机型 / 系统应用不允许读取）');
        return;
      }
      final name = Downloader.safeName(
          '${a.appName ?? a.packageName ?? 'app'}-${a.versionName ?? ''}.apk');
      final dir = await downloadTargetDir();
      if (dir == null) {
        toast(context, '找不到可写的目录');
        return;
      }
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = File(p.join(dir.path, name));
      await f.copy(out.path);
      if (!mounted) return;
      if (share) {
        await shareFiles(context, [out], text: a.appName ?? '');
      } else {
        toast(context, '已提取到 ${out.path}');
      }
    } catch (e) {
      if (!mounted) return;
      toast(context, '提取失败：$e');
    }
  }
}

// ============================================================ 9. LED 手机屏幕

/// LED 滚动屏（v1.3.0 修了两处用户报的问题）。
///
/// **1. 「横屏 / 竖屏」等按钮看不见字**
///   原来用的是 ActionChip。Material 3 的 Chip 自带一套 labelStyle 和
///   背景色（white24），配上写死的白色文字 —— 在「白底黑字」模式下
///   就变成白底上的白字，彻底看不见。而且 fontSize 只有 11.5，
///   即使看得见也费劲。
///   现在改成自己画的按钮，前景 / 背景色跟着当前主题走（见 _chip）。
///
/// **2. 竖屏时控制按钮被设置按钮压住**
///   原来设置开关是右下角的 FloatingActionButton。竖屏时控制面板很高，
///   最后一行按钮正好落在 FAB 底下，点不到。
///   现在把开关挪到**右上角**悬浮 —— 控制面板永远在底部，
///   两者再也不可能重叠。
///
/// 附带把退出时的屏幕方向恢复改成「锁回竖屏」（跟媒体播放器页一致）：
/// 原来写的是 DeviceOrientation.values（全方向），
/// 结果在这页点过「横屏」再退出去，整个 App 就变成可以横屏了，
/// 而其他页面全是按竖屏设计的，一转就乱。
class LedMarqueePage extends StatefulWidget {
  const LedMarqueePage({super.key});

  @override
  State<LedMarqueePage> createState() => _LedMarqueePageState();
}

class _LedMarqueePageState extends State<LedMarqueePage> with SingleTickerProviderStateMixin {
  final _text = TextEditingController(text: '学聚 · 考试加油！');
  late AnimationController _anim;
  bool _scroll = true;
  bool _mirror = false;
  bool _full = true;
  double _speed = 12; // 秒 / 圈
  double _fontSize = 88;
  int _colorIndex = 0;
  bool _invert = false;
  double _textWidth = 400;

  static const _colors = <Color>[
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C7BE),
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFFFF2D55),
    Colors.white,
  ];

  /// 控制面板上的前景色。跟着底/字反色一起翻，否则白底上写白字。
  Color get _fg => _invert ? Colors.black87 : Colors.white;
  Color get _fgDim => _invert ? Colors.black54 : const Color(0xFFB0B0B0);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: Duration(seconds: _speed.round()))
      ..repeat();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    keepScreenOn(true);
  }

  @override
  void dispose() {
    _anim.dispose();
    _text.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    // 锁回竖屏，不是「全方向」—— 整个 App 只设计了竖屏布局。
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _measure(double w) {
    final tp = TextPainter(
      text: TextSpan(
          text: _text.text,
          style: TextStyle(fontSize: _fontSize, fontWeight: FontWeight.w700, letterSpacing: 2)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _textWidth = tp.width;
  }

  void _toggleScroll() {
    setState(() {
      _scroll = !_scroll;
      if (_scroll) {
        _anim.repeat();
      } else {
        _anim.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _colors[_colorIndex % _colors.length];
    return Scaffold(
      backgroundColor: _invert ? Colors.white : Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // ---------- 显示区 ----------
                Expanded(
                  child: GestureDetector(
                    onTap: _toggleScroll,
                    child: LayoutBuilder(
                      builder: (ctx, c) {
                        _measure(c.maxWidth);
                        return ClipRect(
                          child: _scroll
                              ? _marquee(color)
                              : Center(
                                  child: Transform.scale(
                                    scaleX: _mirror ? -1 : 1,
                                    child: _static(color),
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
                ),

                // ---------- 控制区（收起全屏后可调）----------
                if (!_full)
                  Container(
                    color: _invert ? Colors.white : const Color(0xFF141414),
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    child: Column(
                      children: [
                        TextField(
                          controller: _text,
                          style: TextStyle(color: _fg),
                          maxLines: 2,
                          minLines: 1,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '要显示的文字',
                            hintStyle: TextStyle(color: _fgDim),
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text('速度', style: TextStyle(fontSize: 12, color: _fgDim)),
                            Expanded(
                              child: Slider(
                                value: _speed,
                                min: 3,
                                max: 40,
                                onChanged: (v) {
                                  setState(() => _speed = v);
                                  _anim.duration = Duration(milliseconds: (v * 1000).round());
                                  if (_scroll) _anim.repeat();
                                },
                              ),
                            ),
                            Text('${_speed.round()}s',
                                style: TextStyle(fontSize: 11, color: _fgDim)),
                          ],
                        ),
                        Row(
                          children: [
                            Text('字号', style: TextStyle(fontSize: 12, color: _fgDim)),
                            Expanded(
                              child: Slider(
                                value: _fontSize,
                                min: 24,
                                max: 200,
                                onChanged: (v) => setState(() => _fontSize = v),
                              ),
                            ),
                            Text('${_fontSize.round()}',
                                style: TextStyle(fontSize: 11, color: _fgDim)),
                          ],
                        ),
                        Row(
                          children: [
                            for (var i = 0; i < _colors.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 7),
                                child: InkWell(
                                  onTap: () => setState(() => _colorIndex = i),
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: _colors[i],
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        // 选中圈跟背景反着来 —— 白底模式下调成深色，
                                        // 否则「白」那个色块选中后看不出来。
                                        color: _colorIndex == i
                                            ? (_invert ? Colors.black87 : Colors.white)
                                            : (_invert ? Colors.black26 : Colors.transparent),
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _chip(_scroll ? '滚动中' : '静止', _toggleScroll),
                            _chip(_mirror ? '镜像开' : '镜像关',
                                () => setState(() => _mirror = !_mirror)),
                            _chip(_invert ? '白底黑字' : '黑底彩字',
                                () => setState(() => _invert = !_invert)),
                            _chip('横屏', () async {
                              await SystemChrome.setPreferredOrientations([
                                DeviceOrientation.landscapeLeft,
                                DeviceOrientation.landscapeRight,
                              ]);
                            }),
                            _chip('竖屏', () async {
                              await SystemChrome.setPreferredOrientations(
                                  [DeviceOrientation.portraitUp]);
                            }),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),

            // ---------- 右上角的设置开关 ----------
            // 放右上而不是右下角：控制面板在底部，竖屏时面板很高，
            // 右下角的悬浮按钮必然压到最后一行按钮上。
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: _invert ? Colors.black12 : Colors.white24,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _full = !_full),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      _full ? Icons.tune : Icons.fullscreen,
                      size: 22,
                      color: _fg,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 控制按钮。
  ///
  /// 为什么不用 ActionChip：M3 的 Chip 自带 labelStyle / 背景，
  /// 在「白底黑字」模式下会把白字压在白底上，等于隐形。
  /// 自己画一个 Container，颜色对比完全可控，成本还更低。
  Widget _chip(String label, VoidCallback onTap) {
    return Material(
      color: _invert ? Colors.black12 : Colors.white24,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _fg),
          ),
        ),
      ),
    );
  }

  Widget _static(Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          _text.text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: _fontSize,
            fontWeight: FontWeight.w700,
            color: _invert ? Colors.black : color,
            letterSpacing: 2,
          ),
        ),
      );

  /// 跑马灯：把文字放三份排一行，整体向左平移一个「文字宽 + 间距」的周期，
  /// 循环到 0 的时候第二份正好接上第一份，看起来就是无缝连续滚动。
  Widget _marquee(Color color) {
    const gap = 140.0;
    final cycle = _textWidth + gap;
    // OverflowBox 负责给 Row 无限宽（不然长文本会被约束住报溢出），
    // alignment: centerLeft 让 Row 的左边缘贴在屏幕左边。
    return OverflowBox(
      maxWidth: double.infinity,
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, __) {
          final dx = -(_anim.value * cycle);
          return Transform.translate(
            offset: Offset(dx, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _chunk(color),
                const SizedBox(width: gap),
                _chunk(color),
                const SizedBox(width: gap),
                _chunk(color),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _chunk(Color color) => Text(
        _text.text,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: _fontSize,
          fontWeight: FontWeight.w700,
          color: _invert ? Colors.black : color,
          letterSpacing: 2,
        ),
      );
}

// ============================================================ 10. 抛硬币

class CoinFlipPage extends StatefulWidget {
  const CoinFlipPage({super.key});

  @override
  State<CoinFlipPage> createState() => _CoinFlipPageState();
}

class _CoinFlipPageState extends State<CoinFlipPage> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  final _rnd = math.Random();
  bool? _result; // true = 正面
  int _heads = 0, _tails = 0;
  bool _flipping = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _flip() async {
    if (_flipping) return;
    setState(() => _flipping = true);
    final r = _rnd.nextBool();
    try {
      await _c.forward(from: 0).orCancel;
    } catch (_) {
      // 动画被打断（比如退出了页面），忽略即可
    }
    if (!mounted) return;
    setState(() {
      _result = r;
      if (r) {
        _heads++;
      } else {
        _tails++;
      }
      _flipping = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '抛硬币',
      subtitle: '拿不定主意的时候，交给它',
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _flip,
              child: Center(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, __) {
                    final t = Curves.easeOut.transform(_c.value);
                    final angle = t * math.pi * 6;
                    final showHeads = (_result ?? true);
                    final face = (angle / math.pi).floor().isEven ? showHeads : !showHeads;
                    final scale = 1 - 0.25 * math.sin(t * math.pi);
                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0012)
                        ..rotateY(angle)
                        ..scale(scale),
                      child: _coin(face),
                    );
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              children: [
                Text(
                  _result == null
                      ? '点一下硬币，或点下面的按钮'
                      : (_result! ? '正面朝上' : '反面朝上'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: _result == null
                        ? scheme.onSurfaceVariant
                        : (_result! ? const Color(0xFFD85A30) : const Color(0xFF185FA5)),
                  ),
                ),
                const SizedBox(height: 6),
                Text('正面 $_heads 次 · 反面 $_tails 次',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _flip,
                        icon: const Icon(Icons.casino_outlined),
                        label: const Text('抛硬币'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: _heads + _tails == 0
                          ? null
                          : () => setState(() {
                                _heads = 0;
                                _tails = 0;
                                _result = null;
                              }),
                      child: const Text('清零'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coin(bool heads) => Container(
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: heads
                ? const [Color(0xFFFFD86B), Color(0xFFE0A020)]
                : const [Color(0xFFBFD7F5), Color(0xFF4A7BB5)],
          ),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 18,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Center(
          child: Text(
            heads ? '正' : '反',
            style: TextStyle(
              fontSize: 68,
              fontWeight: FontWeight.w700,
              color: heads ? const Color(0xFF7A5200) : const Color(0xFF123A66),
            ),
          ),
        ),
      );
}
