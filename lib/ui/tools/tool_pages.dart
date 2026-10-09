import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_device_apps/flutter_device_apps.dart';
import 'package:intl/intl.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:torch_light/torch_light.dart';

import '../../core/downloader.dart';
import '../../core/permissions.dart';
import '../../core/utils.dart';
import '../../data/local/db.dart';

// ============================================================ 公共小工具

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
      body: child,
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

class RulerPage extends StatefulWidget {
  const RulerPage({super.key});

  @override
  State<RulerPage> createState() => _RulerPageState();
}

class _RulerPageState extends State<RulerPage> {
  /// 1 厘米 = 多少逻辑像素。Flutter 逻辑像素基准 160/英寸，
  /// 所以 160 / 2.54 ≈ 62.99。不同手机有偏差，用银行卡校准一下最准。
  double _lpcm = 160 / 2.54;
  bool _showCalib = false;

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: '直尺',
      subtitle: '按实际尺寸显示，可校准',
      actions: [
        IconButton(
          tooltip: '校准',
          onPressed: () => setState(() => _showCalib = !_showCalib),
          icon: Icon(_showCalib ? Icons.straighten : Icons.tune),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          if (_showCalib)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('校准屏幕比例',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text(
                        '拿一张银行卡横着比在下面的刻度上。卡的宽边标准是 85.6 mm，'
                        '拖动滑块让下方的校准条正好等于卡的宽度即可。',
                        style: TextStyle(fontSize: 12, height: 1.55),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text('细', style: TextStyle(fontSize: 12)),
                          Expanded(
                            child: Slider(
                              value: _lpcm,
                              min: 40,
                              max: 95,
                              onChanged: (v) => setState(() => _lpcm = v),
                            ),
                          ),
                          const Text('粗', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 62,
                            child: Text('${(_lpcm * 2.54).round()} px/in',
                                style: const TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                      // 85.6mm 校准条
                      CustomPaint(
                        size: Size(8.56 * _lpcm, 26),
                        painter: _CalibPainter(_lpcm),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('横尺（把手机横过来量更顺手）',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 108,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: CustomPaint(
                size: Size(30 * _lpcm, 108),
                painter: _RulerPainter(_lpcm, horizontal: true),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('竖尺', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: SingleChildScrollView(
              child: CustomPaint(
                size: Size(108, 30 * _lpcm),
                painter: _RulerPainter(_lpcm, horizontal: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final double lpcm;
  final bool horizontal;
  _RulerPainter(this.lpcm, {required this.horizontal});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFF7E9A0);
    canvas.drawRect(Offset.zero & size, bg);

    final line = Paint()
      ..color = const Color(0xFF3A3A3A)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;

    final totalCm = (horizontal ? size.width : size.height) / lpcm;
    final cross = horizontal ? size.height : size.width;

    for (var mm = 0; mm <= (totalCm * 10).floor(); mm++) {
      final pos = mm / 10 * lpcm;
      final isCm = mm % 10 == 0;
      final isHalf = mm % 5 == 0;
      final len = isCm ? cross * 0.42 : (isHalf ? cross * 0.28 : cross * 0.15);
      if (horizontal) {
        canvas.drawLine(Offset(pos, 0), Offset(pos, len), line);
      } else {
        canvas.drawLine(Offset(0, pos), Offset(len, pos), line);
      }
    }

    // 厘米数字
    for (var cm = 0; cm <= totalCm.floor(); cm++) {
      final pos = cm * lpcm;
      final tp = TextPainter(
        text: TextSpan(
            text: '$cm',
            style: const TextStyle(fontSize: 12, color: Color(0xFF3A3A3A), fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      if (horizontal) {
        tp.paint(canvas, Offset(pos + 3, cross * 0.46));
      } else {
        tp.paint(canvas, Offset(cross * 0.46, pos + 3));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.lpcm != lpcm || old.horizontal != horizontal;
}

class _CalibPainter extends CustomPainter {
  final double lpcm;
  _CalibPainter(this.lpcm);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0xFF1D9E75);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)), fill);
    final border = Paint()
      ..color = const Color(0xFF0F6E56)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)), border);
    final tp = TextPainter(
      text: const TextSpan(
          text: '85.6 mm',
          style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(_CalibPainter old) => old.lpcm != lpcm;
}

// ============================================================ 2. 量角器

/// 用重力传感器测倾斜角：屏幕贴合被测面，读数就是该面与水平面的夹角。
/// 支持「归零」——以任意面为 0 基准，测出相对夹角。
class ProtractorPage extends StatefulWidget {
  const ProtractorPage({super.key});

  @override
  State<ProtractorPage> createState() => _ProtractorPageState();
}

class _ProtractorPageState extends State<ProtractorPage> {
  StreamSubscription<AccelerometerEvent>? _sub;
  double _raw = 0; // 相对水平面的倾角（度）
  double _zero = 0;
  bool _locked = false;
  double _lockedValue = 0;

  @override
  void initState() {
    super.initState();
    _sub = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 60)).listen(
      (e) {
        if (_locked) return;
        // 手机竖着贴合被测面：绕屏幕法线的倾角 = atan2(x, y)
        var deg = math.atan2(e.x, e.y) * 180 / math.pi;
        if (deg < 0) deg += 360;
        setState(() => _raw = deg);
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 显示值：水平时 0 / 90 / 180 都要归成 0 附近的偏差
  double get _display {
    var d = _raw - _zero;
    while (d <= -180) {
      d += 360;
    }
    while (d > 180) {
      d -= 360;
    }
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = _locked ? _lockedValue : _display;
    final abs = v.abs();
    final near = abs < 1.0;

    return ToolScaffold(
      title: '量角器',
      subtitle: '把手机贴在被测面上读数',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                children: [
                  Text(
                    '${v.toStringAsFixed(1)}°',
                    style: TextStyle(
                      fontSize: 46,
                      fontWeight: FontWeight.w300,
                      color: near ? const Color(0xFF1D9E75) : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    near ? '已水平 / 垂直' : '${v >= 0 ? '向右' : '向左'}倾斜 $abs°',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 170,
                    width: 300,
                    child: CustomPaint(painter: _DialPainter(v)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _zero = _raw),
                  icon: const Icon(Icons.adjust, size: 18),
                  label: const Text('归零（设为基准）'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => setState(() {
                    if (_locked) {
                      _locked = false;
                      _zero = _raw - _lockedValue; // 保住读数
                    } else {
                      _lockedValue = _display;
                      _locked = true;
                    }
                  }),
                  icon: Icon(_locked ? Icons.lock_open : Icons.lock_outline, size: 18),
                  label: Text(_locked ? '解锁' : '锁定读数'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('怎么用', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  SizedBox(height: 6),
                  Text(
                    '1. 把手机侧面贴在被测的斜面 / 桌面上，读数就是它与水平面的夹角。\n'
                    '2. 想比较两个面之间的夹角：先贴第一个面点「归零」，再贴第二个面，读数就是两者夹角。\n'
                    '3. 挂电视、装支架时，「锁定读数」可以腾出手来照着装。',
                    style: TextStyle(fontSize: 12.5, height: 1.75),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final double value;
  _DialPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.9);
    final r = math.min(size.width / 2, size.height * 0.9) - 12;

    final arc = Paint()
      ..color = const Color(0xFF7F77DD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), math.pi, math.pi, false, arc);

    final tick = Paint()
      ..color = const Color(0xFF9AA0A6)
      ..strokeWidth = 1;
    for (var deg = -90; deg <= 90; deg += 5) {
      final a = (deg - 90) * math.pi / 180;
      final long = deg % 30 == 0;
      final p1 = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      final p2 = Offset(
        c.dx + (r - (long ? 12 : 6)) * math.cos(a),
        c.dy + (r - (long ? 12 : 6)) * math.sin(a),
      );
      canvas.drawLine(p1, p2, tick);
    }

    // 指针（value 为相对倾角，映射到 ±90 显示）
    final clamped = value.clamp(-90.0, 90.0);
    final a = (clamped - 90) * math.pi / 180;
    final needle = Paint()
      ..color = clamped.abs() < 1 ? const Color(0xFF1D9E75) : const Color(0xFFD85A30)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c, Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)), needle);
    canvas.drawCircle(c, 6, Paint()..color = needle.color);

    final tp = TextPainter(
      text: TextSpan(
          text: '0°', style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r - 18));
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.value != value;
}

// ============================================================ 3. 配色助手

class ColorSchemeHelperPage extends StatefulWidget {
  const ColorSchemeHelperPage({super.key});

  @override
  State<ColorSchemeHelperPage> createState() => _ColorSchemeHelperPageState();
}

class _ColorSchemeHelperPageState extends State<ColorSchemeHelperPage> {
  double _h = 210, _s = 0.65, _l = 0.5;

  Color get _base => HSLColor.fromAHSL(1, _h, _s, _l).toColor();

  String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

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
          const SizedBox(height: 12),
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
              label: const Text('复制明暗阶梯的 8 个色值'),
            ),
          ),
          const SizedBox(height: 6),
          Text('点任意色块也能单独复制它的色值。',
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

  @override
  void initState() {
    super.initState();
    _left = _work * 60;
  }

  @override
  void dispose() {
    _t?.cancel();
    SystemChrome.setKeepScreenOn(false);
    super.dispose();
  }

  void _start() {
    setState(() => _running = true);
    SystemChrome.setKeepScreenOn(true);
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
    SystemChrome.setKeepScreenOn(false);
  }

  void _reset() {
    _t?.cancel();
    setState(() {
      _running = false;
      _isWork = true;
      _left = _work * 60;
      _done = 0;
    });
    SystemChrome.setKeepScreenOn(false);
  }

  void _finishPhase() {
    HapticFeedback.heavyImpact();
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
    SystemChrome.setKeepScreenOn(false);
    final msg = wasWork
        ? '专注结束，休息 ${_done % _rounds == 0 ? _long : _short} 分钟'
        : '休息结束，开始下一个番茄';
    toast(context, msg);
  }

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
                              color: i < _done % _rounds || (_done > 0 && _done % _rounds == 0 && i < _rounds)
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
          Text('提示：计时期间会保持屏幕常亮。锁屏或切到后台，计时可能被系统暂停。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
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

  static final _fmt = DateFormat('yyyy-MM-dd');
  static final _fmtLong = DateFormat('yyyy年M月d日 EEEE', 'zh_CN');

  Future<DateTime?> _pick(DateTime init) => showDatePicker(
        context: context,
        initialDate: init,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final days = _to.difference(_from).inDays;
    final workDays = _countWorkDays(_from, _to);
    final basePlus = _shift(_base, _offset, _unit);

    return ToolScaffold(
      title: '日期计算',
      subtitle: DateFormat('yyyy年M月d日 EEEE', 'zh_CN').format(today),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const ToolSection('今天'),
          ResultBox(
            text: '${_fmtLong.format(today)}\n'
                '本年第 ${_dayOfYear(today)} 天 · 剩 ${_daysInYear(today.year) - _dayOfYear(today)} 天\n'
                '第 ${_isoWeek(today)} 周 · ${_daysAgoText(today)}',
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
                  if (days >= 0)
                    ResultBox(
                      text: '相差 $days 天\n'
                          '= ${(days / 7).toStringAsFixed(2)} 周'
                          '${days >= 30 ? ' = ${(days / 30.44).toStringAsFixed(2)} 个月' : ''}\n'
                          '工作日 $workDays 天（不含周六日）',
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
                    text: '$_base 的 $_offset $_unit 后是\n${_fmt.format(basePlus)}（${DateFormat('EEEE', 'zh_CN').format(basePlus)}）',
                  ),
                ],
              ),
            ),
          ),

          const ToolSection('常用倒计时'),
          Card(
            child: Column(
              children: [
                for (final item in _commonCountdowns(today))
                  ListTile(
                    dense: true,
                    title: Text(item.$1, style: const TextStyle(fontSize: 13.5)),
                    trailing: Text(
                      item.$2,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
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

  static int _isoWeek(DateTime d) {
    final thursday = d.add(Duration(days: 4 - (d.weekday == 7 ? 7 : d.weekday)));
    final firstThursday = DateTime(thursday.year, 1, 1)
        .add(Duration(days: (11 - DateTime(thursday.year, 1, 1).weekday) % 7));
    return ((thursday.difference(firstThursday).inDays) / 7).floor() + 1;
  }

  static int _countWorkDays(DateTime a, DateTime b) {
    var s = DateTime(a.year, a.month, a.day);
    var e = DateTime(b.year, b.month, b.day);
    var sign = 1;
    if (s.isAfter(e)) {
      final t = s;
      s = e;
      e = t;
      sign = -1;
    }
    var n = 0;
    var cur = s;
    while (cur.isBefore(e)) {
      if (cur.weekday != DateTime.saturday && cur.weekday != DateTime.sunday) n++;
      cur = cur.add(const Duration(days: 1));
    }
    return n * sign;
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

  static String _daysAgoText(DateTime today) {
    final d = DateTime(today.year, 1, 1);
    return '距元旦 ${today.difference(d).inDays} 天';
  }

  static List<(String, String)> _commonCountdowns(DateTime today) {
    final y = today.year;
    final items = <(String, DateTime)>[
      ('今年还剩', DateTime(y + 1, 1, 1)),
      ('下一个春节（约）', DateTime(y, 2, 10).isAfter(today) ? DateTime(y, 2, 10) : DateTime(y + 1, 2, 10)),
      ('暑假开始（7 月 1 日）', DateTime(y, 7, 1).isAfter(today) ? DateTime(y, 7, 1) : DateTime(y + 1, 7, 1)),
      ('元旦', DateTime(y + 1, 1, 1)),
    ];
    return items
        .map((e) => (
              e.$1,
              '${DateTime(e.$2.year, e.$2.month, e.$2.day).difference(DateTime(today.year, today.month, today.day)).inDays} 天'
            ))
        .toList();
  }
}

// ============================================================ 6. 颜色码转换

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

  static Color? parseColor(String s) {
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

  void _parse(String s) {
    final c = parseColor(s);
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
                        color: item.$2,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Text(
                        item.$1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: (parseColor(item.$2)?.computeLuminance() ?? 1) > 0.55
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

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: Duration(seconds: _speed.round()))
      ..repeat();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setKeepScreenOn(true);
  }

  @override
  void dispose() {
    _anim.dispose();
    _text.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setKeepScreenOn(false);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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

  @override
  Widget build(BuildContext context) {
    final color = _colors[_colorIndex % _colors.length];
    return Scaffold(
      backgroundColor: _invert ? Colors.white : Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 显示区
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() {
                  _scroll = !_scroll;
                  if (_scroll) {
                    _anim.repeat();
                  } else {
                    _anim.stop();
                  }
                }),
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

            // 控制区（收起全屏后可调）
            if (!_full)
              Container(
                color: _invert ? Colors.white : const Color(0xFF141414),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Column(
                  children: [
                    TextField(
                      controller: _text,
                      style: TextStyle(color: _invert ? Colors.black : Colors.white),
                      maxLines: 2,
                      minLines: 1,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '要显示的文字',
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('速度', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
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
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                      ],
                    ),
                    Row(
                      children: [
                        Text('字号', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                        Expanded(
                          child: Slider(
                            value: _fontSize,
                            min: 24,
                            max: 200,
                            onChanged: (v) => setState(() => _fontSize = v),
                          ),
                        ),
                        Text('${_fontSize.round()}',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
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
                                    color: _colorIndex == i ? Colors.white : Colors.transparent,
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        _chip(_scroll ? '滚动中' : '静止', () => setState(() {
                              _scroll = !_scroll;
                              if (_scroll) {
                                _anim.repeat();
                              } else {
                                _anim.stop();
                              }
                            })),
                        _chip(_mirror ? '镜像开' : '镜像关', () => setState(() => _mirror = !_mirror)),
                        _chip(_invert ? '白底黑字' : '黑底彩字',
                            () => setState(() => _invert = !_invert)),
                        _chip('横屏', () async {
                          await SystemChrome.setPreferredOrientations([
                            DeviceOrientation.landscapeLeft,
                            DeviceOrientation.landscapeRight,
                          ]);
                        }),
                        _chip('竖屏', () async {
                          await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                        }),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        backgroundColor: Colors.white24,
        onPressed: () => setState(() => _full = !_full),
        child: Icon(_full ? Icons.tune : Icons.fullscreen, color: Colors.white),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onTap) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
        backgroundColor: Colors.white24,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );

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
