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
//
// 必须 hide TextDirection！intl 也导出一个 TextDirection（用 LTR / RTL 大写），
// 不 hide 的话它会和 Flutter 那个带 .ltr / .rtl 的撞名字 ——
// 而挂画助手的绘制代码里要用 TextDirection.ltr，一撞就直接编译不过。
// 这个坑在 tool_pages.dart 里已经踩过一次，这里同样处理。
import 'package:intl/intl.dart' hide TextDirection;
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';

import 'tool_pages.dart';

// ============================================================ 11. 简易画板

/// 一笔画。
class _Stroke {
  final List<Offset> pts;
  final Color color;
  final double width;
  final bool erase;
  _Stroke({required this.pts, required this.color, required this.width, this.erase = false});
}

/// 简易画板。
///
/// v1.3.0 新增「另存为图片到本地」。
///   原来右上角只有一个「保存 / 分享」，它其实是「存到下载目录 + 顺手拉起分享面板」。
///   只想把图画存下来的人，每次都得再按一次返回键把分享面板关掉，很烦。
///   现在拆成两个动作：
///     * 「另存为图片」—— 安静地存进下载目录，只弹一句「已保存到 xxx」；
///     * 「保存并分享」—— 存完再拉分享面板，发微信 / QQ 用这个。
///   分类也从「生活与娱乐」挪到了「颜色与设计」。
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

  /// 导出中：避免连点两次产生两个文件
  bool _exporting = false;

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
      subtitle: '指头画，可撤销、可另存为图片',
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
          onPressed: _strokes.isEmpty ? null : _confirmClear,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        IconButton(
          tooltip: '另存为图片',
          onPressed: _strokes.isEmpty || _exporting ? null : _saveLocal,
          icon: const Icon(Icons.save_alt),
        ),
        PopupMenuButton<String>(
          tooltip: '导出',
          enabled: _strokes.isNotEmpty && !_exporting,
          onSelected: (v) {
            if (v == 'share') _saveAndShare();
          },
          itemBuilder: (ctx) => <PopupMenuEntry<String>>[
            const PopupMenuItem(
              value: 'share',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.ios_share, size: 20),
                title: Text('保存并分享', style: TextStyle(fontSize: 14)),
              ),
            ),
          ],
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
                      child: Slider(
                          value: _width,
                          min: 1,
                          max: 40,
                          onChanged: (v) => setState(() => _width = v)),
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

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空画板？'),
        content: const Text('这一笔一笔画的东西没法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _strokes.clear());
  }

  /// 把画布渲染成 PNG 字节。失败返回 null。
  ///
  /// pixelRatio 3：按屏幕密度的 3 倍导出。手指画的线是矢量描出来的，
  /// 放大到 3 倍仍然锐利；用 1 倍导出在电脑上看会糊。
  Future<List<int>?> _renderPng() async {
    try {
      final boundary = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final img = await boundary.toImage(pixelRatio: 3);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// 文件名带时间戳，避免连存多次互相覆盖。
  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  /// 另存为图片到本地。不弹分享面板。
  Future<void> _saveLocal() async {
    setState(() => _exporting = true);
    try {
      final bytes = await _renderPng();
      if (!mounted) return;
      if (bytes == null) {
        toast(context, '生成图片失败，再试一次看看');
        return;
      }
      final f = await saveToDownload('画板_${_stamp()}.png', bytes);
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败。到「设置 → 下载目录」看一眼，'
            '或者给 App 开一下存储权限。');
        return;
      }
      // 把完整路径报出来 —— 用户下一步就是要去找这个文件
      toast(context, '已保存到 ${f.path}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 保存后再拉起分享面板。
  Future<void> _saveAndShare() async {
    setState(() => _exporting = true);
    try {
      final bytes = await _renderPng();
      if (!mounted) return;
      if (bytes == null) {
        toast(context, '生成图片失败，再试一次看看');
        return;
      }
      final f = await saveToDownload('画板_${_stamp()}.png', bytes);
      if (!mounted) return;
      if (f == null) {
        toast(context, '保存失败，检查存储权限');
        return;
      }
      await shareFiles(context, [f], text: '画板作品');
    } finally {
      if (mounted) setState(() => _exporting = false);
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

/// 挂画助手（水平仪）。
///
/// v1.3.0 重新写成「摄像头 + 重力参考线」。
///
/// 老版本是一个纯色背景上的气泡水平仪 —— 得把手机侧面贴到画框上量，
/// 量完再挂、挂完再量，来回折腾；而且手机一离开就不知道准不准了。
///
/// 现在：摄像头画面铺满屏幕，上面叠一组**跟着重力实时转动的水平 / 垂直参考线**。
/// 把手机举起来对着墙，绿线永远代表真实水平 —— 于是看画的上下边跟绿线
/// 平不平行，就知道画挂正没有。
///
/// 屏幕上还额外画了一组**固定的灰色虚线**，代表「屏幕自己的水平 / 垂直」。
/// 两组线的夹角就是手机当前的倾角 —— 一眼就能看出手机歪了多少，
/// 而不只是看一个数字。底部读数会提示「先把自己摆正」。
///
/// 摆正之后可以点「锁定」，参考线就固定住，单手举着手机随意移动去看画，
/// 手抖也不会让线跟着晃。
class LevelHelperPage extends StatefulWidget {
  const LevelHelperPage({super.key});

  @override
  State<LevelHelperPage> createState() => _LevelHelperPageState();
}

class _LevelHelperPageState extends State<LevelHelperPage> {
  CameraController? _cam;
  StreamSubscription<AccelerometerEvent>? _acc;

  bool _busy = true;
  String? _err;

  /// 是否用前置摄像头。默认后置 —— 对着墙拍的时候手机背面朝墙，
  /// 人看的是屏幕，用后置更自然。
  bool _front = false;

  /// 绕屏幕法线的倾角（度）。读不到重力时为 null。
  ///
  /// 推导见 core/display_metrics.dart 里的注释：传感器静止时读数
  /// 指向「天」的方向，所以屏幕坐标下「天」= (x, -y)，
  /// 真实水平线垂直于它，化简后角度正好是 atan2(x, y)。
  double? _roll;

  /// 参考线锁定
  bool _locked = false;
  double _lockedRoll = 0;

  /// 是否同时画垂直线。有些人只想量水平，多一条线反而碍眼。
  bool _cross = true;

  /// 摆正在这个角度以内就算「正了」。1.2° 是手机上比较舒服的阈值 ——
  /// 再紧就很难靠手稳住，再松肉眼就能看出画是歪的。
  static const _tolerance = 1.2;

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
    final c = _cam;
    _cam = null;
    c?.dispose();
    keepScreenOn(false);
    super.dispose();
  }

  void _startSensor() {
    _acc = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 60)).listen(
      (e) {
        // 手机平放（屏幕朝天）时 x、y 都接近 0，atan2 会乱跳，
        // 而且这时候「水平线」在画面上也没有意义 —— 丢掉这帧。
        if (e.x.abs() + e.y.abs() < 1.5) return;
        if (!mounted) return;
        setState(() => _roll = math.atan2(e.x, e.y) * 180 / math.pi);
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

      final want = _front ? CameraLensDirection.front : CameraLensDirection.back;
      final hit = cams.where((d) => d.lensDirection == want);
      final desc = hit.isNotEmpty ? hit.first : cams.first;

      c = CameraController(desc, ResolutionPreset.high, enableAudio: false);
      await c.initialize();

      if (!mounted) {
        await c.dispose();
        return;
      }
      final old = _cam;
      setState(() {
        _cam = c;
        _busy = false;
      });
      if (old != null && old != c) old.dispose();
    } catch (e) {
      if (c != null) {
        try {
          await c.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = '相机启动失败：$e\n\n'
            '如果别的 App 正占着相机，先关掉再重试。';
      });
    }
  }

  /// 当前实际用于画线的角度（锁定后取冻结值）
  double get _useRoll => _locked ? _lockedRoll : (_roll ?? 0);

  /// 显示给用户的倾角：归一化到 -90~90。
  /// 直接显示 atan2 的原始值会在 180° 附近跳，很难看。
  double get _display {
    var d = _useRoll;
    while (d > 90) {
      d -= 180;
    }
    while (d <= -90) {
      d += 180;
    }
    return d;
  }

  bool get _level => _display.abs() <= _tolerance;

  void _toggleLock() {
    setState(() {
      if (_locked) {
        _locked = false;
      } else {
        _lockedRoll = _roll ?? 0;
        _locked = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '挂画助手',
      subtitle: '举起来对准画框，看边缘跟绿线平不平',
      actions: [
        if (_cam != null && _err == null) ...[
          IconButton(
            tooltip: _cross ? '只留水平线' : '显示水平 + 垂直线',
            onPressed: () => setState(() => _cross = !_cross),
            icon: Icon(_cross ? Icons.add : Icons.horizontal_rule, size: 20),
          ),
          IconButton(
            tooltip: _front ? '换成后置摄像头' : '换成前置摄像头',
            onPressed: () {
              setState(() => _front = !_front);
              _initCam();
            },
            icon: const Icon(Icons.cameraswitch_outlined, size: 21),
          ),
          IconButton(
            tooltip: _locked ? '解锁参考线' : '锁定参考线',
            onPressed: _toggleLock,
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

    return Stack(
      children: [
        Positioned.fill(child: _preview()),
        Positioned.fill(
          child: CustomPaint(
            painter: _LevelOverlay(
              roll: _useRoll,
              level: _level,
              cross: _cross,
              locked: _locked,
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
      ],
    );
  }

  Widget _preview() {
    final c = _cam!;
    final ps = c.value.previewSize;
    if (ps == null) return CameraPreview(c);

    // previewSize 是传感器原始尺寸（横向），竖屏时要交换宽高。
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final w = portrait ? ps.height : ps.width;
    final h = portrait ? ps.width : ps.height;

    // FittedBox(cover) 铺满且不变形，比手算 scale 靠谱
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: w, height: h, child: CameraPreview(c)),
      ),
    );
  }

  Widget _bottomBar() {
    final d = _display;
    final abs = d.abs();
    // 到位了用绿，否则用橙 —— 颜色比数字更快读懂
    final col = _level ? const Color(0xFF35D07F) : const Color(0xFFFFB020);

    final String hint;
    if (_locked) {
      hint = '参考线已锁定，可以随意移动手机去比对了';
    } else if (_roll == null) {
      hint = '把手机竖起来（屏幕朝自己）才能读到水平';
    } else if (_level) {
      hint = '手机已摆正 —— 看画的上下边有没有跟绿线平行';
    } else {
      hint = '手机歪了 ${abs.toStringAsFixed(1)}°，先把手机摆正（绿线会跟着转正）';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 30, 18, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.75),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${d >= 0 ? '' : '-'}${abs.toStringAsFixed(1)}°',
            style: TextStyle(
                fontSize: 40, fontWeight: FontWeight.w300, color: col, height: 1.1),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.white.withValues(alpha: 0.88)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _toggleLock,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: Icon(_locked ? Icons.lock_open : Icons.lock_outline, size: 18),
                  label: Text(_locked ? '解锁' : '锁定参考线'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _locked = false;
                    _roll = null;
                    // 先把旧的订阅收掉再重开 —— 不 cancel 的话
                    // 每点一次就多一条常驻的传感器订阅，越点越卡。
                    _acc?.cancel();
                    _acc = null;
                    _startSensor();
                  }),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('重新读取'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '灰虚线 = 屏幕自己的水平 / 垂直；彩色实线 = 真实水平。\n'
            '两者的夹角就是手机歪掉的角度。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Colors.white.withValues(alpha: 0.62)),
          ),
        ],
      ),
    );
  }
}

/// 水平仪叠加层：屏幕固定虚线 + 跟随重力的彩色实线。
class _LevelOverlay extends CustomPainter {
  final double roll;
  final bool level;
  final bool cross;
  final bool locked;

  const _LevelOverlay({
    required this.roll,
    required this.level,
    required this.cross,
    required this.locked,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final far = size.width + size.height;
    final rad = roll * math.pi / 180;

    // ---------- 屏幕自己的水平 / 垂直（灰色虚线，固定不动）----------
    final dashPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    _dashed(canvas, Offset(0, c.dy), Offset(size.width, c.dy), dashPaint, 9, 7);
    if (cross) {
      _dashed(canvas, Offset(c.dx, 0), Offset(c.dx, size.height), dashPaint, 9, 7);
    }

    // ---------- 真实水平 / 垂直（彩色实线，跟着重力转）----------
    final col = level ? const Color(0xFF35D07F) : const Color(0xFFFFB020);

    // 先画一层宽的半透明描边当「发光」，再画细的实线 ——
    // 不然在花花的摄像头画面里线会看不清。
    void glowLine(double ang) {
      final u = Offset(math.cos(ang), math.sin(ang));
      final a = c - u * far;
      final b = c + u * far;
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = col.withValues(alpha: 0.35)
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = col
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round,
      );
    }

    glowLine(rad);
    if (cross) glowLine(rad + math.pi / 2);

    // ---------- 中心标记 ----------
    canvas.drawCircle(c, 16, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawCircle(
      c,
      16,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = col,
    );
    canvas.drawCircle(c, 4, Paint()..color = const Color(0xFF222222));

    // ---------- 锁定时给个角标 ----------
    if (locked) {
      final tp = TextPainter(
        text: const TextSpan(
          text: '已锁定',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            shadows: [Shadow(color: Color(0xCC000000), blurRadius: 5)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = Offset(c.dx - tp.width / 2, c.dy + 24);
      // 底下垫一块深色，免得压在亮画面上读不出来
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(pos.dx - 8, pos.dy - 3, tp.width + 16, tp.height + 6),
          const Radius.circular(9),
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      tp.paint(canvas, pos);
    }
  }

  /// Canvas 没有原生虚线，只能按 dash / gap 一段段画
  void _dashed(Canvas canvas, Offset a, Offset b, Paint p, double dash, double gap) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final e = math.min(t + dash, total);
      canvas.drawLine(a + dir * t, a + dir * e, p);
      t = e + gap;
    }
  }

  @override
  bool shouldRepaint(_LevelOverlay old) =>
      old.roll != roll || old.level != level || old.cross != cross || old.locked != locked;
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

/// 提词器。
///
/// v1.3.0 新增四样东西（都是用户提的）：
///   * **横屏显示** —— 手机横过来稿子一行能放更多字，是提词器的标准用法。
///     入口在右上角「⋮」菜单里。退出页面时会自动锁回竖屏（整个 App
///     其他页面都是竖屏布局，不解锁回去会一转就乱）。
///   * **全屏显示** —— 把标题栏和底部控制区一起收起来，只留正文。
///     全屏时右上角浮一个小按钮用来退出，点屏幕仍然是暂停 / 继续。
///   * **文字颜色** —— 6 个预设色。原来是写死的琥珀黄。
///   * **背景颜色** —— 6 个预设。原来写死纯黑。
///     默认还是「琥珀黄 + 纯黑」，那是长时间盯着最不累的组合。
class TeleprompterPage extends StatefulWidget {
  const TeleprompterPage({super.key});

  @override
  State<TeleprompterPage> createState() => _TeleprompterPageState();
}

class _TeleprompterPageState extends State<TeleprompterPage> {
  final _script = TextEditingController(
      text: '大家好，今天我给大家讲一个知识点。\n\n把讲稿粘贴到这里，点「开始提词」就会自动往上滚。\n\n'
          '读稿的时候可以随时点屏幕暂停，再点一下继续。暂停的时候还能上下拖动。\n\n'
          '右上角可以调速度和字号、换文字和背景颜色、开镜像（用提词器玻璃时需要），'
          '还有横屏和全屏。');
  final _scroll = ScrollController();
  Timer? _timer;
  bool _playing = false;
  double _speed = 40; // 逻辑像素 / 秒
  double _fontSize = 30;
  double _lineHeight = 1.9;
  bool _mirror = false;
  bool _verticalMirror = false;

  /// 全屏：标题栏和底部控制区都收起来，只留正文
  bool _full = false;

  /// 是否已经切到横屏
  bool _landscape = false;

  /// 文字 / 背景颜色。默认沿用原来的「琥珀黄 on 纯黑」——
  /// 深色底 + 暖黄字是长时间盯稿最不容易累的组合。
  Color _fg = const Color(0xFFFFE08A);
  Color _bg = Colors.black;

  static const _fgPresets = <(String, Color)>[
    ('琥珀', Color(0xFFFFE08A)),
    ('纯白', Color(0xFFFFFFFF)),
    ('浅绿', Color(0xFFA8E6A0)),
    ('天青', Color(0xFF8ED8FF)),
    ('淡粉', Color(0xFFFFB3C7)),
    ('墨黑', Color(0xFF111111)),
  ];

  static const _bgPresets = <(String, Color)>[
    ('纯黑', Color(0xFF000000)),
    ('深灰', Color(0xFF1E1E1E)),
    ('墨绿', Color(0xFF0B2B22)),
    ('藏蓝', Color(0xFF0A1A33)),
    ('米白', Color(0xFFF5F0E1)),
    ('纯白', Color(0xFFFFFFFF)),
  ];

  @override
  void dispose() {
    _timer?.cancel();
    _script.dispose();
    _scroll.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    // 锁回竖屏。别写成 DeviceOrientation.values ——
    // 那样在这页转过横屏再退出去，整个 App 都变成能自动横屏，
    // 而其他页面全按竖屏设计的，一转就乱。
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _toggle() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      keepScreenOn(false);
      // 恢复系统栏。注意用的是 _full 而不是「一定恢复」——
      // 用户按的是「暂停」，不是「退出全屏」。
      SystemChrome.setEnabledSystemUIMode(
        _full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
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

  void _toggleFull() {
    setState(() => _full = !_full);
    SystemChrome.setEnabledSystemUIMode(
      _full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _toggleLandscape() async {
    final next = !_landscape;
    setState(() => _landscape = next);
    await SystemChrome.setPreferredOrientations(
      next
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
  }

  Future<void> _pickColors() async {
    // 弹窗开着的时候稿子还在跑会很别扭，先停一下。
    // 用户关掉弹窗后自己再点「开始」—— 不自动续播，
    // 免得他还在挑颜色稿子就跑了。
    if (_playing) _toggle();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('文字颜色',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in _fgPresets)
                      _swatch(p.$1, p.$2, _fg == p.$2, (c) {
                        setState(() => _fg = c);
                        setSheet(() {});
                      }),
                  ],
                ),
                const SizedBox(height: 22),
                const Text('背景颜色',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in _bgPresets)
                      _swatch(p.$1, p.$2, _bg == p.$2, (c) {
                        setState(() => _bg = c);
                        setSheet(() {});
                      }),
                  ],
                ),
                const SizedBox(height: 22),
                // 预览：直接看效果，比看色块准
                const Text('效果预览',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '大家好，今天我给大家讲一个知识点。',
                    style: TextStyle(color: _fg, fontSize: 17, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatch(String name, Color c, bool on, ValueChanged<Color> onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onTap(c),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 66,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: on ? scheme.primary : scheme.outlineVariant,
            width: on ? 3 : 1,
          ),
        ),
        child: Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            // 文字颜色跟着色块亮度走，否则白色块上写白字
            color: c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 全屏时整个标题栏都不出现
      appBar: _full
          ? null
          : AppBar(
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
                  tooltip: '文字 / 背景颜色',
                  onPressed: () => _pickColors(),
                  icon: const Icon(Icons.palette_outlined),
                ),
                IconButton(
                  tooltip: _full ? '退出全屏' : '全屏',
                  onPressed: _toggleFull,
                  icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (v) {
                    switch (v) {
                      case 'mirror':
                        setState(() => _mirror = !_mirror);
                        break;
                      case 'vmirror':
                        setState(() => _verticalMirror = !_verticalMirror);
                        break;
                      case 'landscape':
                        _toggleLandscape();
                        break;
                    }
                  },
                  itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                    CheckedPopupMenuItem(
                      value: 'mirror',
                      checked: _mirror,
                      child: const Text('左右镜像（用玻璃时开）'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'vmirror',
                      checked: _verticalMirror,
                      child: const Text('上下翻转'),
                    ),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(
                      value: 'landscape',
                      checked: _landscape,
                      child: const Text('横屏显示'),
                    ),
                  ],
                ),
              ],
            ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _toggle,
                  child: Transform.scale(
                    scaleX: _mirror ? -1.0 : 1.0,
                    scaleY: _verticalMirror ? -1.0 : 1.0,
                    child: Container(
                      color: _bg,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        // 上下留大边距：上面留出「读到哪里」的空白，
                        // 下面留出后面几行，视线不用正好卡在屏幕边缘。
                        padding: EdgeInsets.fromLTRB(22, _full ? 90 : 120, 22, 260),
                        child: Text(
                          _script.text,
                          style: TextStyle(
                            color: _fg,
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
              if (!_full)
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
                              child: Text('${_speed.round()}',
                                  style: const TextStyle(fontSize: 11.5))),
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
                              child: Text('${_fontSize.round()}',
                                  style: const TextStyle(fontSize: 11.5))),
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

          // 全屏时的退出按钮。放右上角而不是右下角 ——
          // 右下角是握手机时手指最常放的地方，容易误触。
          if (_full)
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black45,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggleFull,
                  child: const Padding(
                    padding: EdgeInsets.all(9),
                    child: Icon(Icons.fullscreen_exit, color: Colors.white70, size: 22),
                  ),
                ),
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

/// 屏幕坏点检测。
///
/// v1.3.0 改动（都是用户直接反馈的体验问题）：
///   1. **去掉屏幕正中的颜色汉字**（原来正中央写着一个「红」/「蓝」…）。
///      坏点检测是拿眼睛找异常亮点，屏幕中间杵着一个字最碍事。
///   2. **颜色挪到底部、用色圈表示**。原来底部那排小点是「当前色亮、
///      其余灰」，看不出有哪些颜色、更没法直接点。现在每个点就是它
///      本身的那个颜色（白圈黑边、黑圈白边……），点一下直接跳过去。
///   3. **加了「开始检测」按钮，一点下去提示自动收起**。以前要手动点
///      「隐藏提示」，而且收起后就没法再叫回来，很别扭。现在进入检测态
///      之后屏幕干净得只剩纯色和底部色圈，按返回键退出即可。
class DeadPixelPage extends StatefulWidget {
  const DeadPixelPage({super.key});

  @override
  State<DeadPixelPage> createState() => _DeadPixelPageState();
}

class _DeadPixelPageState extends State<DeadPixelPage> {
  int _i = 0;
  bool _auto = false;

  /// 是否已经点过「开始检测」。开始之后提示文字与按钮全部收起 ——
  /// 这时候屏幕上任何多余的东西都会干扰「找亮点」这件事。
  bool _started = false;

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
    // 全屏沉浸：坏点检测要把整个屏幕用起来，状态栏和导航栏都得让位。
    // immersiveSticky 比 immersive 好在用户一划它也会自己再收回去。
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

  /// 底部色圈。每个圈画成它代表的那个颜色本身，
  /// 当前选中的那个加粗描边 + 稍微放大。
  Widget _dot(int i, Color fg, bool compact) {
    final on = i == _i;
    final size = compact ? (on ? 16.0 : 12.0) : (on ? 20.0 : 15.0);
    return GestureDetector(
      onTap: () => setState(() => _i = i),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        margin: EdgeInsets.symmetric(horizontal: compact ? 4 : 5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _colors[i].$2,
          // 描边是必需的：白圈放在白底上、黑圈放在黑底上，
          // 不描边就彻底看不见了。
          border: Border.all(
            color: on ? fg : fg.withValues(alpha: 0.45),
            width: on ? 2.5 : 1,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final col = _colors[_i].$2;
    final lightBg = col.computeLuminance() > 0.5;
    // 前景色跟着背景走，保证在纯白和纯黑上都看得清
    final fg = lightBg ? Colors.black : Colors.white;

    return Scaffold(
      backgroundColor: col,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 点屏幕换下一个颜色。开始检测之后这是最主要的操作，
        // 所以不做任何额外的判定 —— 点哪儿都算。
        onTap: () => setState(() => _i = (_i + 1) % _colors.length),
        onLongPress: _toggleAuto,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 26,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _colors.length; i++) _dot(i, fg, _started),
                    ],
                  ),
                  if (!_started) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        '把屏幕调到最亮，盯着整块颜色找不对劲的亮点 / 暗点。\n'
                        '点屏幕换颜色，长按自动轮播。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, height: 1.7, color: fg.withValues(alpha: 0.6)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () => setState(() => _started = true),
                      style: FilledButton.styleFrom(
                        backgroundColor: fg,
                        foregroundColor: lightBg ? Colors.white : Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: const Text('开始检测'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
