import 'dart:async';
import 'dart:convert';
// Platform 在这个文件里用来判断 Android/iOS（手电筒、相机权限那些）
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
// 时间戳转换要用 DateFormat。注意 Dart 的 import 不传递 ——
// tool_pages.dart 里引了 intl，这个文件也照样得自己引一份。
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';

import 'tool_pages.dart';

// ============================================================ 11. 简易画板

class _Stroke {
  final List<Offset> pts;
  final Color color;
  final double width;
  final bool erase;
  _Stroke({required this.pts, required this.color, required this.width, this.erase = false});
}

class SketchPadPage extends StatefulWidget {
  const SketchPadPage({super.key});

  @override
  State<SketchPadPage> createState() => _SketchPadPageState();
}

class _SketchPadPageState extends State<SketchPadPage> {
  final _strokes = <_Stroke>[];
  _Stroke? _current;
  final _boundary = GlobalKey();
  Color _color = Colors.black;
  double _width = 4;
  bool _erase = false;

  static const _palette = <Color>[
    Colors.black,
    Color(0xFFC0392B),
    Color(0xFFD85A30),
    Color(0xFFEF9F27),
    Color(0xFF1D9E75),
    Color(0xFF185FA5),
    Color(0xFF7F77DD),
    Color(0xFFD4537E),
    Colors.white,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '简易画板',
      subtitle: '指头画，可撤销、可保存成图片',
      actions: [
        IconButton(
          tooltip: '撤销',
          onPressed: _strokes.isEmpty
              ? null
              : () => setState(() => _strokes.removeLast()),
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: '清空',
          onPressed: _strokes.isEmpty ? null : () => setState(() => _strokes.clear()),
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        IconButton(
          tooltip: '保存 / 分享',
          onPressed: _save,
          icon: const Icon(Icons.ios_share),
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(10),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: RepaintBoundary(
                key: _boundary,
                child: GestureDetector(
                  onPanStart: (d) {
                    _current = _Stroke(
                      pts: [d.localPosition],
                      color: _color,
                      width: _width,
                      erase: _erase,
                    );
                    setState(() => _strokes.add(_current!));
                  },
                  onPanUpdate: (d) {
                    _current?.pts.add(d.localPosition);
                    setState(() {});
                  },
                  onPanEnd: (_) => _current = null,
                  child: CustomPaint(
                    painter: _SketchPainter(_strokes),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Column(
              children: [
                Row(
                  children: [
                    for (final c in _palette)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          onTap: () => setState(() {
                            _color = c;
                            _erase = false;
                          }),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: (!_erase && _color == c)
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                                width: (!_erase && _color == c) ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Text('粗细', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    Expanded(
                      child: Slider(value: _width, min: 1, max: 40, onChanged: (v) => setState(() => _width = v)),
                    ),
                    SizedBox(
                      width: 30,
                      child: Text('${_width.round()}', style: const TextStyle(fontSize: 11.5)),
                    ),
                    FilterChip(
                      label: const Text('橡皮', style: TextStyle(fontSize: 12)),
                      selected: _erase,
                      onSelected: (v) => setState(() => _erase = v),
                      visualDensity: VisualDensity.compact,
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

  Future<void> _save() async {
    try {
      final boundary = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final img = await boundary.toImage(pixelRatio: 2.5);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      final f = await saveToDownload('画板_${DateTime.now().millisecondsSinceEpoch}.png', bytes);
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败，检查存储权限');
        return;
      }
      await shareFiles(context, [f], text: '画板作品');
    } catch (e) {
      if (mounted) toast(context, '导出失败：$e');
    }
  }
}

class _SketchPainter extends CustomPainter {
  final List<_Stroke> strokes;
  _SketchPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = s.erase ? BlendMode.clear : BlendMode.srcOver;
      if (s.pts.isEmpty) continue;
      if (s.pts.length == 1) {
        canvas.drawCircle(s.pts.first, s.width / 2,
            Paint()..color = s.color..blendMode = paint.blendMode);
        continue;
      }
      final path = Path()..moveTo(s.pts.first.dx, s.pts.first.dy);
      for (var i = 1; i < s.pts.length; i++) {
        path.lineTo(s.pts[i].dx, s.pts[i].dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SketchPainter old) => true;
}

// ============================================================ 12. SOS 手电筒

class SosTorchPage extends StatefulWidget {
  const SosTorchPage({super.key});

  @override
  State<SosTorchPage> createState() => _SosTorchPageState();
}

class _SosTorchPageState extends State<SosTorchPage> {
  Timer? _timer;
  bool _on = false;
  String _mode = 'sos'; // sos / on / strobe / pulse
  bool _available = true;
  bool _denied = false;
  bool _screenMode = false; // 用屏幕闪光代替闪光灯
  bool _screenOn = false;
  int _step = 0;

  /// SOS 用到的节奏（毫秒）
  static const _sosDot = 220;
  static const _sosDash = 640;
  static const _sosGap = 220;
  static const _sosLetter = 660;
  static const _sosWord = 1500;
  static final _sos = <int>[
    _sosDot, _sosGap, _sosDot, _sosGap, _sosDot, _sosLetter,
    _sosDash, _sosGap, _sosDash, _sosGap, _sosDash, _sosLetter,
    _sosDot, _sosGap, _sosDot, _sosGap, _sosDot, _sosWord,
  ];

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _turnOff();
    keepScreenOn(false);
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final ok = await TorchLight.isTorchAvailable();
      if (!mounted) return;
      setState(() => _available = ok);
    } catch (_) {
      if (mounted) setState(() => _available = false);
    }
  }

  Future<void> _turnOff() async {
    try {
      await TorchLight.disableTorch();
    } catch (_) {}
  }

  Future<bool> _ensurePerm() async {
    if (Platform.isAndroid) {
      final st = await Permission.camera.status;
      if (st.isGranted) return true;
      final r = await Permission.camera.request();
      if (!mounted) return false;
      if (!r.isGranted) {
        setState(() => _denied = true);
        return false;
      }
    }
    return true;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _turnOff();
    keepScreenOn(false);
    if (mounted) setState(() => _on = false);
  }

  Future<void> _start(String mode) async {
    if (_screenMode) {
      _startScreen(mode);
      return;
    }
    final ok = await _ensurePerm();
    if (!ok) {
      if (!mounted) return;
      toast(context, '没有摄像头权限，闪光灯用不了。可以切到「屏幕闪光」模式。');
      return;
    }
    _stop();
    setState(() {
      _mode = mode;
      _on = true;
      _step = 0;
    });
    keepScreenOn(true);

    if (mode == 'on') {
      try {
        await TorchLight.enableTorch();
      } catch (e) {
        if (mounted) {
          setState(() {
            _on = false;
            _screenMode = true;
          });
          toast(context, '闪光灯打不开（$e），已切到屏幕闪光模式');
        }
      }
      return;
    }

    var visible = false;
    void tick() {
      if (!mounted) return;
      if (mode == 'sos') {
        final d = _sos[_step % _sos.length];
        // 偶数下标是「亮」，奇数是「灭」
        final shouldOn = _step.isEven;
        if (shouldOn != visible) {
          visible = shouldOn;
          shouldOn ? _torchOn() : _turnOff();
        }
        _step++;
        _timer = Timer(Duration(milliseconds: d), tick);
      } else if (mode == 'strobe') {
        visible = !visible;
        visible ? _torchOn() : _turnOff();
        _timer = Timer(const Duration(milliseconds: 90), tick);
      } else {
        // pulse：慢呼吸
        visible = !visible;
        visible ? _torchOn() : _turnOff();
        _timer = Timer(const Duration(milliseconds: 620), tick);
      }
    }

    _torchOn();
    visible = true;
    _timer = Timer(Duration(milliseconds: _sos[0]), tick);
  }

  Future<void> _torchOn() async {
    try {
      if (_available) await TorchLight.enableTorch();
    } catch (_) {}
  }

  /// 屏幕闪光模式：整屏黑白交替，没有闪光灯也能求救
  void _startScreen(String mode) {
    _stop();
    setState(() {
      _mode = mode;
      _on = true;
      _step = 0;
    });
    keepScreenOn(true);
    var visible = true;
    void tick() {
      if (!mounted) return;
      if (mode == 'on') return;
      if (mode == 'sos') {
        final d = _sos[_step % _sos.length];
        final shouldOn = _step.isEven;
        if (shouldOn != visible) {
          visible = shouldOn;
          setState(() => _screenOn = visible);
        }
        _step++;
        _timer = Timer(Duration(milliseconds: d), tick);
      } else if (mode == 'strobe') {
        visible = !visible;
        setState(() => _screenOn = visible);
        _timer = Timer(const Duration(milliseconds: 90), tick);
      } else {
        visible = !visible;
        setState(() => _screenOn = visible);
        _timer = Timer(const Duration(milliseconds: 620), tick);
      }
    }

    setState(() => _screenOn = true);
    if (mode != 'on') _timer = Timer(Duration(milliseconds: _sos[0]), tick);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flashing = _screenMode && _on;

    return Scaffold(
      backgroundColor: flashing ? (_screenOn ? Colors.white : Colors.black) : null,
      appBar: flashing
          ? null
          : AppBar(
              title: const Text('SOS 手电筒'),
              actions: [
                IconButton(
                  tooltip: '屏幕闪光模式',
                  onPressed: () {
                    _stop();
                    setState(() => _screenMode = !_screenMode);
                  },
                  icon: Icon(_screenMode ? Icons.flashlight_off : Icons.brightness_high_outlined),
                ),
              ],
            ),
      body: flashing
          ? GestureDetector(
              onTap: _stop,
              child: const SizedBox.expand(),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                if (!_available)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '这台设备检测不到闪光灯。可以打开右上角「屏幕闪光模式」，'
                      '用整屏闪烁代替，同样能引起注意。',
                      style: TextStyle(fontSize: 12.5, height: 1.6),
                    ),
                  ),
                if (_denied)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        '摄像头权限被拒绝了。控制闪光灯需要这个权限 —— '
                        '可以到系统设置里打开，或者用屏幕闪光模式。',
                        style: TextStyle(fontSize: 12.5, height: 1.6),
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Center(
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _on ? const Color(0xFFFFCC00) : scheme.surfaceContainerHighest,
                      boxShadow: _on
                          ? [
                              BoxShadow(
                                  color: const Color(0xFFFFCC00).withValues(alpha: 0.5),
                                  blurRadius: 34,
                                  spreadRadius: 6)
                            ]
                          : null,
                    ),
                    child: Icon(
                      _mode == 'sos' && _on ? Icons.sos : Icons.flashlight_on,
                      size: 54,
                      color: _on ? Colors.black87 : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    _on
                        ? (_screenMode ? '屏幕闪光中 · 点屏幕停止' : '工作中…')
                        : '选一个模式开始',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 18),
                if (!_on) ...[
                  _modeCard(
                    'SOS 求救',
                    '三短 · 三长 · 三短（国际通用求救信号）',
                    Icons.sos,
                    () => _start('sos'),
                    scheme,
                  ),
                  _modeCard('常亮照明', '当普通手电筒用', Icons.wb_sunny_outlined,
                      () => _start('on'), scheme),
                  _modeCard('爆闪提醒', '快速闪烁，适合引起注意', Icons.bolt_outlined,
                      () => _start('strobe'), scheme),
                  _modeCard('慢闪呼吸', '慢节奏闪烁，省电', Icons.waves_outlined,
                      () => _start('pulse'), scheme),
                ] else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止'),
                    ),
                  ),
                const ToolSection('使用提示'),
                Text(
                  '· SOS 是国际通用求救信号，闪灯和声音都适用。\n'
                  '· 长时间常亮会发热、耗电，注意别烫到手。\n'
                  '· 手电筒亮着的时候别的应用（比如相机）可能打不开，正常现象。',
                  style: TextStyle(fontSize: 12.5, height: 1.85, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }

  Widget _modeCard(String title, String sub, IconData icon, VoidCallback onTap, ColorScheme scheme) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFFFCC00).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: const Color(0xFFB8860B), size: 21),
            ),
            title: Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.play_arrow),
            onTap: onTap,
          ),
        ),
      );
}

// ============================================================ 13. 挂画助手

/// 挂画 / 挂电视助手：一个水平仪 + 一个等间距计算器
class LevelHelperPage extends StatefulWidget {
  const LevelHelperPage({super.key});

  @override
  State<LevelHelperPage> createState() => _LevelHelperPageState();
}

class _LevelHelperPageState extends State<LevelHelperPage> {
  StreamSubscription<AccelerometerEvent>? _sub;
  double _x = 0, _y = 0, _z = 0;
  bool _frozen = false;
  double _wallWidth = 300;
  int _count = 3;
  double _picWidth = 40;
  double _eyeHeight = 145;

  @override
  void initState() {
    super.initState();
    _sub = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 60)).listen(
      (e) {
        if (_frozen || !mounted) return;
        setState(() {
          _x = e.x;
          _y = e.y;
          _z = e.z;
        });
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

  /// 横向倾斜角（手机竖着拿，左右倾斜）
  double get _roll => math.atan2(_x, _y) * 180 / math.pi;

  /// 前后俯仰角（手机平放时的前后倾）
  double get _pitch => math.atan2(_z, _y) * 180 / math.pi;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roll = _roll;
    final pitch = _pitch;
    final levelH = roll.abs() < 1.2;
    final levelV = (roll.abs() - 90).abs() < 1.2;

    final gap = (_wallWidth - _count * _picWidth) / (_count + 1);
    final firstCenter = gap + _picWidth / 2;

    return ToolScaffold(
      title: '挂画助手',
      subtitle: '水平仪 + 等间距计算',
      actions: [
        IconButton(
          tooltip: _frozen ? '恢复实时' : '冻结读数',
          onPressed: () => setState(() => _frozen = !_frozen),
          icon: Icon(_frozen ? Icons.play_arrow : Icons.pause),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _bubble('横向水平', roll, levelH, '把手机横过来贴墙'),
                      ),
                      Container(width: 1, height: 96, color: scheme.outlineVariant),
                      Expanded(
                        child: _bubble('竖向垂直', roll - 90, levelV, '把手机竖着贴墙'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    levelH
                        ? '✓ 横向已水平'
                        : levelV
                            ? '✓ 竖向已垂直'
                            : '倾斜 ${roll.abs() < 90 ? roll.abs() : (roll.abs() - 90).abs()}°',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: (levelH || levelV) ? const Color(0xFF1D9E75) : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('前后俯仰 ${pitch.toStringAsFixed(1)}°（贴墙时越接近 0 越准）',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),

          const ToolSection('多幅画等间距（单位：厘米）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                children: [
                  _num('墙面宽度', _wallWidth, 50, 1000, (v) => setState(() => _wallWidth = v)),
                  _intNum('画的数量', _count, 1, 12, (v) => setState(() => _count = v)),
                  _num('每幅画宽度', _picWidth, 5, 300, (v) => setState(() => _picWidth = v)),
                  _num('挂画中心离地高度', _eyeHeight, 60, 220, (v) => setState(() => _eyeHeight = v)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          ResultBox(
            text: gap < 0
                ? '画太宽了，墙放不下 $_count 幅'
                : '画与画之间留空：${gap.toStringAsFixed(1)} cm\n'
                    '左右两边各留：${gap.toStringAsFixed(1)} cm\n'
                    '第 1 幅画的中心离墙左边缘：${firstCenter.toStringAsFixed(1)} cm\n'
                    '每隔 ${(_picWidth + gap).toStringAsFixed(1)} cm 挂一幅（这是中心点间距）\n'
                    '每幅画中心建议离地 ${_eyeHeight.toStringAsFixed(0)} cm',
            hint: '点一下复制尺寸',
          ),

          const ToolSection('怎么量'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '1. 先用卷尺量出墙面可用总宽度（扣除两边障碍物）。\n'
                '2. 按上面算出的「中心离墙左边缘」定第一个点，之后每隔「中心点间距」定一个点。\n'
                '3. 挂之前把手机贴墙，用上面的水平仪确认挂钉在同一高度。\n'
                '4. 一般画作中心离地 145cm 左右最舒服（大致平视高度），沙发上方可以再高 10~20cm。',
                style: TextStyle(fontSize: 12.5, height: 1.85, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(String label, double angle, bool ok, String hint) {
    final scheme = Theme.of(context).colorScheme;
    // 把 ±10° 映射到气泡位置
    final t = (angle / 12).clamp(-1.0, 1.0);
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Align(
            alignment: Alignment(t, 0),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? const Color(0xFF1D9E75) : const Color(0xFFEF9F27),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(ok ? '已水平' : angle.abs() < 90 ? '${angle.abs().toStringAsFixed(1)}°' : '${(angle.abs() - 90).abs().toStringAsFixed(1)}°',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _num(String label, double v, double min, double max, ValueChanged<double> onChanged) => Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          SizedBox(
            width: 62,
            child: Text('${v.toStringAsFixed(0)}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5)),
          ),
          Expanded(
            child: Slider(
              value: v.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      );

  Widget _intNum(String label, int v, int min, int max, ValueChanged<int> onChanged) => Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: v > min ? () => onChanged(v - 1) : null,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
          SizedBox(width: 24, child: Text('$v', textAlign: TextAlign.center)),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: v < max ? () => onChanged(v + 1) : null,
            icon: const Icon(Icons.add_circle_outline, size: 20),
          ),
          const Expanded(child: SizedBox()),
        ],
      );
}

// ============================================================ 14. 二维码生成

class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  final _text = TextEditingController(text: 'https://flutter.dev');
  final _ssid = TextEditingController();
  final _pwd = TextEditingController();
  final _boundary = GlobalKey();
  String _kind = 'text';
  int _level = QrErrorCorrectLevel.M;
  Color _fg = Colors.black;
  bool _colorful = false;

  static const _palette = <Color>[
    Colors.black,
    Color(0xFF185FA5),
    Color(0xFF1D9E75),
    Color(0xFF7F77DD),
    Color(0xFFD85A30),
    Color(0xFFD4537E),
  ];

  @override
  void dispose() {
    _text.dispose();
    _ssid.dispose();
    _pwd.dispose();
    super.dispose();
  }

  String get _payload {
    switch (_kind) {
      case 'wifi':
        final t = _pwd.text.isEmpty ? 'nopass' : 'WPA';
        return 'WIFI:T:$t;S:${_ssid.text};${_pwd.text.isEmpty ? '' : 'P:${_pwd.text};'};';
      case 'tel':
        return 'tel:${_text.text}';
      case 'sms':
        return 'smsto:${_text.text}';
      case 'mail':
        return 'mailto:${_text.text}';
      default:
        return _text.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = _payload;
    final valid = data.trim().isNotEmpty && (_kind != 'wifi' || _ssid.text.trim().isNotEmpty);

    return ToolScaffold(
      title: '二维码生成',
      subtitle: '文字 / 网址 / WiFi / 电话都能编',
      actions: [
        IconButton(
          tooltip: '换颜色',
          onPressed: () => setState(() {
            _colorful = !_colorful;
            _fg = _colorful ? _palette[1 + (_fg.hashCode.abs() % (_palette.length - 1))] : Colors.black;
          }),
          icon: const Icon(Icons.palette_outlined),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'text', label: Text('文字')),
              ButtonSegment(value: 'wifi', label: Text('WiFi')),
              ButtonSegment(value: 'tel', label: Text('电话')),
              ButtonSegment(value: 'mail', label: Text('邮箱')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 14),
          if (_kind == 'wifi') ...[
            TextField(
              controller: _ssid,
              decoration: const InputDecoration(
                  labelText: 'WiFi 名称（SSID）', isDense: true, border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pwd,
              decoration: const InputDecoration(
                  labelText: 'WiFi 密码（不填表示开放网络）',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ] else
            TextField(
              controller: _text,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                labelText: _kind == 'text' ? '要变成二维码的内容' : '号码 / 邮箱',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),

          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: RepaintBoundary(
                key: _boundary,
                child: valid
                    ? QrImageView(
                        data: data,
                        size: 240,
                        backgroundColor: Colors.white,
                        errorCorrectionLevel: _level,
                        eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: _fg),
                        dataModuleStyle: QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: _fg,
                        ),
                      )
                    : const SizedBox(
                        width: 240,
                        height: 240,
                        child: Center(child: Text('先填内容')),
                      ),
              ),
            ),
          ),

          const SizedBox(height: 16),
          Row(
            children: [
              const Text('容错', style: TextStyle(fontSize: 12.5)),
              const SizedBox(width: 10),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: QrErrorCorrectLevel.L, label: Text('低')),
                    ButtonSegment(value: QrErrorCorrectLevel.M, label: Text('中')),
                    ButtonSegment(value: QrErrorCorrectLevel.Q, label: Text('较高')),
                    ButtonSegment(value: QrErrorCorrectLevel.H, label: Text('高')),
                  ],
                  selected: {_level},
                  onSelectionChanged: (s) => setState(() => _level = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('容错越高越耐污损，但二维码会更密。日常用「中」就行。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),

          const SizedBox(height: 14),
          Row(
            children: [
              for (final c in _palette)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() => _fg = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _fg == c ? scheme.primary : scheme.outlineVariant,
                            width: _fg == c ? 3 : 1),
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: valid ? () => copyText(context, data) : null,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制内容'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: valid ? _saveQr : null,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('保存 / 分享'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveQr() async {
    try {
      final b = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (b == null) return;
      final img = await b.toImage(pixelRatio: 3);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final f = await saveToDownload('二维码_${DateTime.now().millisecondsSinceEpoch}.png',
          data.buffer.asUint8List());
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败，检查存储权限');
        return;
      }
      await shareFiles(context, [f], text: _payload);
    } catch (e) {
      if (mounted) toast(context, '保存失败：$e');
    }
  }
}

// ============================================================ 15. 时间戳转换

class TimestampPage extends StatefulWidget {
  const TimestampPage({super.key});

  @override
  State<TimestampPage> createState() => _TimestampPageState();
}

class _TimestampPageState extends State<TimestampPage> {
  final _input = TextEditingController();
  Timer? _t;
  DateTime _now = DateTime.now();
  DateTime _picked = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _input.dispose();
    super.dispose();
  }

  static DateTime? parseTimestamp(String s) {
    var t = s.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) {
      final d = DateTime.tryParse(t);
      return d;
    }
    // 按位数猜单位
    if (t.length <= 10) return DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return DateTime.fromMillisecondsSinceEpoch(n);
  }

  String _full(DateTime d) =>
      DateFormat('yyyy-MM-dd HH:mm:ss').format(d) + '（${_weekday(d)}）';

  String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = parseTimestamp(_input.text);
    final nowSec = _now.millisecondsSinceEpoch ~/ 1000;
    final baseSec = DateTime(_picked.year, _picked.month, _picked.day,
            _picked.hour, _picked.minute, _picked.second)
        .millisecondsSinceEpoch ~/ 1000;

    return ToolScaffold(
      title: '时间戳转换',
      subtitle: 'Unix 时间戳 ⇄ 日期时间',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          const ToolSection('现在'),
          ResultBox(
            text: '秒：$nowSec\n'
                '毫秒：${_now.millisecondsSinceEpoch}\n'
                '${_full(_now)}',
            hint: '点一下复制（复制的是整块内容）',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => copyText(context, '$nowSec'),
                child: const Text('复制秒'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => copyText(context, '${_now.millisecondsSinceEpoch}'),
                child: const Text('复制毫秒'),
              ),
            ],
          ),

          const ToolSection('时间戳 → 日期'),
          TextField(
            controller: _input,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '粘贴时间戳（自动识别秒 / 毫秒）',
              hintText: '例如 1735689600 或 1735689600000',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          ResultBox(
            text: parsed == null
                ? ''
                : '${_full(parsed)}\n'
                    'UTC：${DateFormat('yyyy-MM-dd HH:mm:ss').format(parsed.toUtc())}\n'
                    'ISO：${parsed.toIso8601String()}',
          ),

          const ToolSection('日期 → 时间戳'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('选一个日期时间', style: TextStyle(fontSize: 13)),
            trailing: TextButton.icon(
              onPressed: _pickDateTime,
              icon: const Icon(Icons.event, size: 17),
              label: Text(DateFormat('yyyy-MM-dd HH:mm').format(_picked)),
            ),
          ),
          ResultBox(
            text: '秒：$baseSec\n毫秒：${baseSec * 1000}',
            hint: '点一下复制',
          ),

          const ToolSection('小知识'),
          Text(
            '· 10 位数字是「秒」，13 位是「毫秒」，App 会自动判断。\n'
            '· 时间戳本身没有时区，下面的日期是按你手机所在时区换算的。\n'
            '· 需要给服务器 / 接口传时间，一般用秒。',
            style: TextStyle(fontSize: 12.5, height: 1.85, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _picked,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_picked),
    );
    if (!mounted) return;
    setState(() {
      _picked = DateTime(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0);
    });
  }
}

// ============================================================ 16. 摩斯电码

class MorsePage extends StatefulWidget {
  const MorsePage({super.key});

  @override
  State<MorsePage> createState() => _MorsePageState();
}

class _MorsePageState extends State<MorsePage> {
  final _input = TextEditingController(text: 'SOS');
  String _output = '';
  bool _toMorse = true;
  Timer? _flashTimer;
  bool _flashing = false;
  bool _light = false;

  static const _table = <String, String>{
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.',
    'G': '--.', 'H': '....', 'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..',
    'M': '--', 'N': '-.', 'O': '---', 'P': '.--.', 'Q': '--.-', 'R': '.-.',
    'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
    'Y': '-.--', 'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
    '.': '.-.-.-', ',': '--..--', '?': '..--..', '!': '-.-.--', "'": '.----.',
    '"': '.-..-.', '/': '-..-.', '(': '-.--.', ')': '-.--.-', '&': '.-...',
    ':': '---...', ';': '-.-.-.', '=': '-...-', '+': '.-.-.', '-': '-....-',
    // 注意 '$' 必须转义成 '\$'：Dart 里 $ 是字符串插值符号，
    // 裸写一个 $ 会直接报「A '$' has special meaning inside a string」。
    '_': '..--.-', '\$': '...-..-', '@': '.--.-.',
  };

  static final _reverse = {for (final e in _table.entries) e.value: e.key};

  @override
  void initState() {
    super.initState();
    _convert();
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _convert() {
    final t = _input.text;
    if (_toMorse) {
      final buf = StringBuffer();
      for (final ch in t.toUpperCase().split('')) {
        if (ch == '\n') {
          buf.write('\n');
          continue;
        }
        if (ch == ' ') {
          buf.write(' / ');
          continue;
        }
        final m = _table[ch];
        buf.write(m == null ? '?' : '$m ');
      }
      _output = buf.toString().trim();
    } else {
      final out = StringBuffer();
      final words = t.trim().split(RegExp(r'[/|]{1,2}'));
      for (var w = 0; w < words.length; w++) {
        if (w > 0) out.write(' ');
        for (final code in words[w].trim().split(RegExp(r'\s+'))) {
          if (code.isEmpty) continue;
          out.write(_reverse[code] ?? '?');
        }
      }
      _output = out.toString();
    }
  }

  /// 用整屏亮暗把摩斯码「闪」出来
  void _flash() {
    if (_flashing) {
      _flashTimer?.cancel();
      setState(() {
        _flashing = false;
        _light = false;
      });
      keepScreenOn(false);
      return;
    }
    final morse = _toMorse ? _output : _input.text.trim();
    if (morse.isEmpty) return;
    final timeline = <bool>[];
    for (final code in morse.split(RegExp(r'\s+'))) {
      if (code == '/' || code.isEmpty) continue;
      for (final c in code.split('')) {
        if (c == '.') {
          timeline..add(true)..add(false);
          timeline.add(false);
        } else if (c == '-') {
          timeline..add(true)..add(true)..add(true)..add(false);
          timeline.add(false);
        }
      }
      timeline.add(false);
      timeline.add(false);
    }
    setState(() {
      _flashing = true;
      _light = false;
    });
    keepScreenOn(true);
    var i = 0;
    void tick() {
      if (!mounted) return;
      if (i >= timeline.length) {
        _flashTimer?.cancel();
        setState(() {
          _flashing = false;
          _light = false;
        });
        keepScreenOn(false);
        return;
      }
      setState(() => _light = !_light);
      _flashTimer = Timer(const Duration(milliseconds: 140), tick);
      i++;
    }

    _flashTimer = Timer(const Duration(milliseconds: 140), tick);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: _light ? Colors.white : null,
      appBar: _flashing
          ? null
          : AppBar(
              title: const Text('摩斯电码'),
              actions: [
                IconButton(
                  tooltip: '用屏幕闪光把电码闪出来',
                  onPressed: _flash,
                  icon: const Icon(Icons.flash_on),
                ),
              ],
            ),
      body: _flashing
          ? GestureDetector(onTap: _flash, child: const SizedBox.expand())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('文字 → 电码')),
                    ButtonSegment(value: false, label: Text('电码 → 文字')),
                  ],
                  selected: {_toMorse},
                  onSelectionChanged: (s) => setState(() {
                    _toMorse = s.first;
                    _convert();
                  }),
                  showSelectedIcon: false,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _input,
                  maxLines: 4,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: _toMorse ? '输入文字' : '输入电码（点= . ，划= - ，字母间空格，单词用 / ）',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(_convert),
                ),
                const SizedBox(height: 12),
                ResultBox(text: _output, hint: '点一下复制电码'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _output.isEmpty ? null : _flash,
                        icon: const Icon(Icons.flash_on, size: 18),
                        label: const Text('闪光演示'),
                      ),
                    ),
                  ],
                ),

                const ToolSection('对照表（长按可复制）'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Table(
                      border: TableBorder.all(color: scheme.outlineVariant, width: 0.5),
                      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                      children: [
                        for (final chunk in _chunks(_table.entries.toList(), 4))
                          TableRow(
                            children: [
                              for (final e in chunk)
                                InkWell(
                                  onTap: () => copyText(context, '${e.key} = ${e.value}'),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                                    child: Column(
                                      children: [
                                        Text(e.key,
                                            style: const TextStyle(
                                                fontSize: 13.5, fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 2),
                                        Text(e.value,
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                letterSpacing: 1,
                                                color: scheme.onSurfaceVariant)),
                                      ],
                                    ),
                                  ),
                                ),
                              for (var i = chunk.length; i < 4; i++) const SizedBox(),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                const ToolSection('节奏规则'),
                Text(
                  '· 点（.）= 1 个单位，划（-）= 3 个单位\n'
                  '· 同一个字母内部，符号之间空 1 个单位\n'
                  '· 字母之间空 3 个单位（书写时用一个空格）\n'
                  '· 单词之间空 7 个单位（书写时用 /）\n'
                  '· SOS = ··· --- ··· ，是国际通用求救信号',
                  style: TextStyle(fontSize: 12.5, height: 1.9, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }

  static List<List<MapEntry<String, String>>> _chunks(
      List<MapEntry<String, String>> list, int n) {
    final out = <List<MapEntry<String, String>>>[];
    for (var i = 0; i < list.length; i += n) {
      out.add(list.sublist(i, math.min(i + n, list.length)));
    }
    return out;
  }
}

// ============================================================ 17. 加密编码

class CipherPage extends StatefulWidget {
  const CipherPage({super.key});

  @override
  State<CipherPage> createState() => _CipherPageState();
}

class _CipherPageState extends State<CipherPage> {
  final _input = TextEditingController(text: '学聚 StudyHub');
  String _op = 'b64e';
  String _out = '';
  String? _err;

  static const _ops = <String, String>{
    'b64e': 'Base64 编码',
    'b64d': 'Base64 解码',
    'urle': 'URL 编码',
    'urld': 'URL 解码',
    'hexe': '十六进制编码',
    'hexd': '十六进制解码',
    'rot13': 'ROT13 移位',
    'uni': 'Unicode 转义（\\uXXXX）',
    'unid': 'Unicode 转义还原',
    'md5': 'MD5 摘要',
    'sha1': 'SHA-1 摘要',
    'sha256': 'SHA-256 摘要',
    'reverse': '反转文本',
    'upper': '转大写',
    'lower': '转小写',
    'len': '统计字符 / 字节',
  };

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _run() {
    final s = _input.text;
    try {
      String r;
      switch (_op) {
        case 'b64e':
          r = base64Encode(utf8.encode(s));
          break;
        case 'b64d':
          r = utf8.decode(base64Decode(s.trim()));
          break;
        case 'urle':
          r = Uri.encodeComponent(s);
          break;
        case 'urld':
          r = Uri.decodeComponent(s.trim());
          break;
        case 'hexe':
          r = utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          break;
        case 'hexd':
          final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
          final bytes = <int>[];
          for (var i = 0; i + 1 < clean.length; i += 2) {
            bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
          }
          r = utf8.decode(bytes);
          break;
        case 'rot13':
          r = s.split('').map((c) {
            final code = c.codeUnitAt(0);
            if (code >= 65 && code <= 90) {
              return String.fromCharCode((code - 65 + 13) % 26 + 65);
            }
            if (code >= 97 && code <= 122) {
              return String.fromCharCode((code - 97 + 13) % 26 + 97);
            }
            return c;
          }).join();
          break;
        case 'uni':
          r = s.runes
              .map((c) => c > 127 ? '\\u${c.toRadixString(16).padLeft(4, '0')}' : String.fromCharCode(c))
              .join();
          break;
        case 'unid':
          r = s.replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'),
              (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
          break;
        case 'md5':
          r = md5.convert(utf8.encode(s)).toString();
          break;
        case 'sha1':
          r = sha1.convert(utf8.encode(s)).toString();
          break;
        case 'sha256':
          r = sha256.convert(utf8.encode(s)).toString();
          break;
        case 'reverse':
          r = String.fromCharCodes(s.runes.toList().reversed);
          break;
        case 'upper':
          r = s.toUpperCase();
          break;
        case 'lower':
          r = s.toLowerCase();
          break;
        default:
          final chars = s.runes.length;
          final bytes = utf8.encode(s).length;
          r = '字符数：$chars\nUTF-8 字节数：$bytes\n'
              '（中文一个字通常占 3 个字节，所以字节数会大于字符数）';
      }
      setState(() {
        _out = r;
        _err = null;
      });
    } catch (e) {
      setState(() {
        _out = '';
        _err = '这个内容没法用当前方式处理：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '加密编码',
      subtitle: '编码转换 + 常用摘要',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('选择处理方式', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.primary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final e in _ops.entries)
                ChoiceChip(
                  label: Text(e.value, style: const TextStyle(fontSize: 12)),
                  selected: _op == e.key,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    setState(() => _op = e.key);
                    _run();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _input,
            maxLines: 5,
            minLines: 3,
            decoration: InputDecoration(
              labelText: '输入内容',
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: _op == 'b64d' ? '粘贴 Base64 字符串' : null,
            ),
            onChanged: (_) => _run(),
          ),
          const SizedBox(height: 12),
          if (_err != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_err!, style: const TextStyle(fontSize: 12.5, height: 1.6)),
            )
          else
            ResultBox(text: _out, hint: '点一下复制结果'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _out.isEmpty ? null : () => copyText(context, _out),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制结果'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    _input.text = _out;
                    setState(() {});
                    _run();
                  },
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: const Text('结果填回输入'),
                ),
              ),
            ],
          ),
          const ToolSection('说明'),
          Text(
            '· Base64 / URL / 十六进制是「编码」，能还原，不是加密。\n'
            '· MD5 / SHA 是「摘要」，单向不可还原，常用来校验文件有没有损坏。\n'
            '· 想给文件传输做个指纹：把文件内容粘进来算 SHA-256 就行。',
            style: TextStyle(fontSize: 12.5, height: 1.85, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ============================================================ 18. 提词器

class TeleprompterPage extends StatefulWidget {
  const TeleprompterPage({super.key});

  @override
  State<TeleprompterPage> createState() => _TeleprompterPageState();
}

class _TeleprompterPageState extends State<TeleprompterPage> {
  final _script = TextEditingController(
      text: '大家好，今天我给大家讲一个知识点。\n\n把讲稿粘贴到这里，点「开始提词」就会自动往上滚。\n\n'
          '读稿的时候可以随时点屏幕暂停，再点一下继续。暂停的时候还能上下拖动。\n\n'
          '右上角可以调速度和字号，也可以开镜像 —— 用提词器玻璃的时候需要镜像。');
  final _scroll = ScrollController();
  Timer? _timer;
  bool _playing = false;
  double _speed = 40; // 逻辑像素 / 秒
  double _fontSize = 30;
  double _lineHeight = 1.9;
  bool _mirror = false;
  bool _verticalMirror = false;

  @override
  void dispose() {
    _timer?.cancel();
    _script.dispose();
    _scroll.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    super.dispose();
  }

  void _toggle() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      keepScreenOn(false);
      return;
    }
    setState(() => _playing = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    keepScreenOn(true);
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final next = _scroll.offset + _speed * 0.033;
      if (next >= max) {
        _timer?.cancel();
        setState(() => _playing = false);
        keepScreenOn(false);
        return;
      }
      _scroll.jumpTo(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('提词器'),
        actions: [
          IconButton(
            tooltip: '回到开头',
            onPressed: () {
              if (_scroll.hasClients) _scroll.jumpTo(0);
            },
            icon: const Icon(Icons.vertical_align_top),
          ),
          IconButton(
            tooltip: '镜像',
            onPressed: () => setState(() => _mirror = !_mirror),
            icon: Icon(_mirror ? Icons.flip : Icons.flip_outlined),
          ),
          IconButton(
            tooltip: '上下翻转',
            onPressed: () => setState(() => _verticalMirror = !_verticalMirror),
            icon: const Icon(Icons.swap_vert),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _toggle,
              child: Transform.scale(
                scaleX: _mirror ? -1.0 : 1.0,
                scaleY: _verticalMirror ? -1.0 : 1.0,
                child: Container(
                  color: Colors.black,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(22, 120, 22, 260),
                    child: Text(
                      _script.text,
                      style: TextStyle(
                        color: const Color(0xFFFFE08A),
                        fontSize: _fontSize,
                        height: _lineHeight,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            color: scheme.surface,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _toggle,
                        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                        label: Text(_playing ? '暂停（也可点屏幕）' : '开始提词'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () => _editScript(),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('改稿'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.speed, size: 17),
                    Expanded(
                      child: Slider(
                        value: _speed,
                        min: 8,
                        max: 200,
                        onChanged: (v) => setState(() => _speed = v),
                      ),
                    ),
                    SizedBox(
                        width: 46,
                        child: Text('${_speed.round()}', style: const TextStyle(fontSize: 11.5))),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.format_size, size: 17),
                    Expanded(
                      child: Slider(
                        value: _fontSize,
                        min: 16,
                        max: 90,
                        onChanged: (v) => setState(() => _fontSize = v),
                      ),
                    ),
                    SizedBox(
                        width: 46,
                        child: Text('${_fontSize.round()}', style: const TextStyle(fontSize: 11.5))),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.format_line_spacing, size: 17),
                    Expanded(
                      child: Slider(
                        value: _lineHeight,
                        min: 1.2,
                        max: 3.0,
                        onChanged: (v) => setState(() => _lineHeight = v),
                      ),
                    ),
                    SizedBox(
                        width: 46,
                        child: Text(_lineHeight.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 11.5))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editScript() async {
    _timer?.cancel();
    setState(() => _playing = false);
    final tmp = TextEditingController(text: _script.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('讲稿'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: tmp,
            maxLines: 14,
            minLines: 8,
            decoration: const InputDecoration(
                hintText: '把讲稿粘进来，多写几段，提词时更好读', border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (!mounted) {
      tmp.dispose();
      return;
    }
    if (ok == true) {
      setState(() => _script.text = tmp.text);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    // 这个 controller 是临时造的，用完必须自己回收，不然会一直漏
    tmp.dispose();
  }
}

// ============================================================ 19. 快递查询

class ExpressQueryPage extends StatefulWidget {
  const ExpressQueryPage({super.key});

  @override
  State<ExpressQueryPage> createState() => _ExpressQueryPageState();
}

class _ExpressQueryPageState extends State<ExpressQueryPage> {
  final _input = TextEditingController();
  List<String> _history = [];
  String _carrier = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _history = sp.getStringList('express_history') ?? []);
    } catch (_) {}
  }

  Future<void> _push(String no) async {
    final list = [no, ..._history.where((e) => e != no)].take(15).toList();
    setState(() => _history = list);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('express_history', list);
    } catch (_) {}
  }

  /// 按单号规则粗略猜快递公司
  static String guessCarrier(String no) {
    final s = no.trim().toUpperCase();
    if (RegExp(r'^SF\d{10,}$').hasMatch(s)) return '顺丰速运';
    if (RegExp(r'^JD[A-Z0-9]{10,}$').hasMatch(s)) return '京东物流';
    if (RegExp(r'^YT\d{10,}$').hasMatch(s)) return '圆通速递';
    if (RegExp(r'^1Z[0-9A-Z]{16}$').hasMatch(s)) return 'UPS';
    if (RegExp(r'^[A-Z]{2}\d{9}CN$').hasMatch(s)) return '中国邮政（国际）';
    if (RegExp(r'^EMS\d+').hasMatch(s)) return 'EMS';
    if (RegExp(r'^[A-Z]{2}\d{9}$').hasMatch(s)) return '国际件（DHL / FedEx 等）';
    if (RegExp(r'^\d{12}$').hasMatch(s)) return '中通 / 韵达 / 申通（12 位数字单号）';
    if (RegExp(r'^\d{13}$').hasMatch(s)) return '韵达 / 圆通（13 位数字单号）';
    if (RegExp(r'^\d{15}$').hasMatch(s)) return '菜鸟 / 邮政（15 位数字单号）';
    if (RegExp(r'^\d{10}$').hasMatch(s)) return '可能是顺丰（10 位数字）';
    return '不确定，建议用快递 100 综合查询';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final no = _input.text.trim();
    final carrier = no.isEmpty ? '' : guessCarrier(no);

    return ToolScaffold(
      title: '快递查询',
      subtitle: '识别单号 + 一键跳转查询',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          TextField(
            controller: _input,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '快递单号',
              hintText: '粘贴或输入快递单号',
              isDense: true,
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.local_shipping_outlined),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          if (no.isNotEmpty)
            ResultBox(
              text: '单号：$no\n可能是：$carrier',
              hint: '点一下只复制单号',
            ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: no.isEmpty ? null : () => _open('https://www.kuaidi100.com/chaxun?nu=$no'),
            icon: const Icon(Icons.travel_explore),
            label: const Text('去查询（打开浏览器）'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: no.isEmpty ? null : () => copyText(context, no),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制单号'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: no.isEmpty ? null : () => _push(no),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('记下来'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const ToolSection('直接去各家官网'),
          Card(
            child: Column(
              children: [
                for (final s in const [
                  ('顺丰速运', 'https://www.sf-express.com/chn/sc/waybill/list'),
                  ('中通快递', 'https://www.zto.com/'),
                  ('圆通速递', 'https://www.yto.net.cn/'),
                  ('韵达速递', 'https://www.yundaex.com/'),
                  ('申通快递', 'https://www.sto.cn/'),
                  ('京东物流', 'https://www.jdl.cn/'),
                  ('中国邮政 / EMS', 'https://www.ems.com.cn/'),
                  ('菜鸟（综合）', 'https://page.cainiao.com/guoguo/'),
                ])
                  ListTile(
                    dense: true,
                    title: Text(s.$1, style: const TextStyle(fontSize: 13.5)),
                    trailing: const Icon(Icons.open_in_new, size: 17),
                    onTap: () => _open(s.$2),
                  ),
              ],
            ),
          ),
          if (_history.isNotEmpty) ...[
            const ToolSection('查过的单号'),
            Card(
              child: Column(
                children: [
                  for (final h in _history)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(h, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(guessCarrier(h), style: const TextStyle(fontSize: 11)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () async {
                          final list = _history.where((e) => e != h).toList();
                          setState(() => _history = list);
                          try {
                            final sp = await SharedPreferences.getInstance();
                            await sp.setStringList('express_history', list);
                          } catch (_) {}
                        },
                      ),
                      onTap: () {
                        _input.text = h;
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            '说明：App 本身不直接查物流（各快递公司的接口大多要企业资质），'
            '所以这里做的是「识别单号 + 一键跳转官方查询页」，比你自己到处找官网快很多。',
            style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _open(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) toast(context, '没能打开浏览器，链接已复制');
      if (!ok) copyText(context, url);
    } catch (e) {
      if (mounted) toast(context, '打开失败：$e');
    }
  }
}

// ============================================================ 20. 屏幕坏点检测

class DeadPixelPage extends StatefulWidget {
  const DeadPixelPage({super.key});

  @override
  State<DeadPixelPage> createState() => _DeadPixelPageState();
}

class _DeadPixelPageState extends State<DeadPixelPage> {
  int _i = 0;
  bool _auto = false;
  bool _showHint = true;
  Timer? _t;

  static const _colors = <(String, Color)>[
    ('白', Colors.white),
    ('黑', Colors.black),
    ('红', Color(0xFFFF0000)),
    ('绿', Color(0xFF00FF00)),
    ('蓝', Color(0xFF0000FF)),
    ('青', Color(0xFF00FFFF)),
    ('品红', Color(0xFFFF00FF)),
    ('黄', Color(0xFFFFFF00)),
    ('灰', Color(0xFF808080)),
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    keepScreenOn(true);
  }

  @override
  void dispose() {
    _t?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    super.dispose();
  }

  void _toggleAuto() {
    setState(() => _auto = !_auto);
    _t?.cancel();
    if (!_auto) return;
    _t = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() => _i = (_i + 1) % _colors.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _colors[_i];
    final lightBg = c.$2.computeLuminance() > 0.5;
    return Scaffold(
      backgroundColor: c.$2,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _i = (_i + 1) % _colors.length;
          _showHint = true;
        }),
        onLongPress: _toggleAuto,
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: Text(
                  c.$1,
                  style: TextStyle(
                    fontSize: 22,
                    color: lightBg ? Colors.black.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
            if (_showHint)
              Positioned(
                left: 0,
                right: 0,
                bottom: 40,
                child: Column(
                  children: [
                    Text(
                      _auto ? '自动轮播中 · 长按停止' : '点屏幕换颜色 · 长按自动轮播 · 返回键退出',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: lightBg ? Colors.black54 : Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _colors.length; i++)
                          Container(
                            width: 9,
                            height: 9,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _i
                                  ? (lightBg ? Colors.black54 : Colors.white)
                                  : (lightBg ? Colors.black26 : Colors.white38),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => setState(() => _showHint = false),
                      child: Text('隐藏提示',
                          style: TextStyle(color: lightBg ? Colors.black54 : Colors.white70)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
