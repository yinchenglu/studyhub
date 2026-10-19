import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// 水印相机（v2.2.0 按「今日水印相机」重做）
///
/// 归类：生活与娱乐。
///
/// 三个界面，跟「今日水印相机」一一对应（用户给了三张截图）：
///   1. 取景页（[WatermarkCameraPage]）：打开就是拍照画面，当前水印
///      **实时叠在画面左下角**——大字时间 + 日期星期天气 + 地点 + 经纬度。
///      底部三个键：本地照片 / 快门 / 水印；右侧「定位」。
///   2. 水印选择面板：底部弹出的模板卡片墙（⊘ 不加水印 + 各模板），
///      点卡片即时换水印，✕ 关闭。
///   3. 水印内容编辑面板：一排开关（真实时间 / 地点 / 经纬度 / 海拔 /
///      地图 / 快速备注），跟截图第三张一致，「完成」收起。
///
/// 快门 → [WatermarkEditorPage]（自动保存）：用 RepaintBoundary 把
/// 1080 逻辑宽的画布按 1.5 倍截成 PNG 存相册。
///
/// 原生通道 `studyhub/camera`：
///   location（取一次定位，含海拔）/ geocode（逆地理编码）/ saveImage（存相册）
///
/// 天气：定位成功后调 Open-Meteo 免费接口（不要 key）拿一句「阴 17°C」，
/// 拿不到就只显示星期几，不报错。
///
/// 地图小图：没有地图 SDK，用 OpenStreetMap 的单张瓦片（z=15）当底图，
/// 中间叠一个定位针。没网时自动降级成「坐标网格 + 定位针」。

// ----------------------------------------------------------------- 数据模型

/// 水印模板。第一项「时间地点天气」是今日水印相机的默认款。
enum WmScene { clock, punch, work, safety, training, custom }

class WmStyle {
  final String name;
  final String title; // 空串 = 不显示标题条
  final Color bg; // 底板色（alpha 0 = 透明底，时间地点天气就是透明）
  final Color accent; // 竖色条 / 标题色
  final Color fg;

  const WmStyle({
    required this.name,
    required this.title,
    required this.bg,
    required this.accent,
    required this.fg,
  });

  static const Map<WmScene, WmStyle> all = {
    WmScene.clock: WmStyle(
      name: '时间地点天气',
      title: '',
      bg: Colors.transparent,
      accent: Color(0xFFFFC53D),
      fg: Colors.white,
    ),
    WmScene.punch: WmStyle(
      name: '考勤打卡',
      title: '考勤打卡',
      bg: Color(0xB3000000),
      accent: Color(0xFF34C759),
      fg: Colors.white,
    ),
    WmScene.work: WmStyle(
      name: '工作记录',
      title: '工作记录',
      bg: Color(0xE60A2D4D),
      accent: Color(0xFF2F9BE0),
      fg: Colors.white,
    ),
    WmScene.safety: WmStyle(
      name: '安全生产',
      title: '安全生产',
      bg: Color(0xF2FFFFFF),
      accent: Color(0xFFD93025),
      fg: Color(0xFF1A1A1A),
    ),
    WmScene.training: WmStyle(
      name: '培训记录',
      title: '培训记录',
      bg: Color(0xE6123D2A),
      accent: Color(0xFF34C759),
      fg: Colors.white,
    ),
    WmScene.custom: WmStyle(
      name: '自定义',
      title: '',
      bg: Color(0x99000000),
      accent: Color(0xFF7F77DD),
      fg: Colors.white,
    ),
  };
}

enum WmCorner { bottomLeft, topLeft, bottomRight, topRight }

/// 水印的全部可变量。取景页、选择面板、编辑面板改的都是同一个对象，
/// 改完立刻反映到取景画面。
class WatermarkSettings {
  WmScene scene = WmScene.clock;

  /// ⊘ 不加水印（选择面板左上角那个圆圈斜杠）
  bool enabled = true;

  bool showTime = true;
  bool showPlace = true;
  bool showLatLng = true;
  bool showAlt = false;
  bool showMap = false;
  bool showNote = false;

  DateTime time = DateTime.now();
  String place = '';
  double? lat;
  double? lng;
  double? alt;
  String note = '';

  /// 「阴 17°C」这一句，定位成功后从 Open-Meteo 拿，拿不到就空着。
  String weather = '';

  WmCorner corner = WmCorner.bottomLeft;

  WmStyle get style => WmStyle.all[scene] ?? WmStyle.all[WmScene.clock]!;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 大字时间「17:11」
  String get clockText => '${_two(time.hour)}:${_two(time.minute)}';

  /// 「2026-10-19」
  String get dateText => '${time.year}-${_two(time.month)}-${_two(time.day)}';

  static const _weekCn = [
    '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日',
  ];

  String get weekdayText => _weekCn[time.weekday - 1];

  /// 「星期一  阴 17°C」（天气拿不到就只剩星期几）
  String get weekdayWeatherText => [
        weekdayText,
        if (weather.isNotEmpty) weather,
      ].join('  ');

  /// 「30.828295°N,110.976382°E」—— 纬度在前，跟今日水印相机一致
  String get latLngText {
    if (lat == null || lng == null) return '';
    final ns = lat! >= 0 ? 'N' : 'S';
    final ew = lng! >= 0 ? 'E' : 'W';
    return '${lat!.abs().toStringAsFixed(6)}°$ns,'
        '${lng!.abs().toStringAsFixed(6)}°$ew';
  }

  String get altText => alt == null ? '' : '海拔 ${alt!.toStringAsFixed(1)} m';

  WatermarkSettings copy() {
    final c = WatermarkSettings()
      ..scene = scene
      ..enabled = enabled
      ..showTime = showTime
      ..showPlace = showPlace
      ..showLatLng = showLatLng
      ..showAlt = showAlt
      ..showMap = showMap
      ..showNote = showNote
      ..time = time
      ..place = place
      ..lat = lat
      ..lng = lng
      ..alt = alt
      ..note = note
      ..weather = weather
      ..corner = corner;
    return c;
  }
}

// ----------------------------------------------------------------- 水印渲染

/// 水印渲染的**唯一**实现：取景页实时叠层、模板卡片小预览、编辑页成片
/// 用的都是它，靠 [scale] 缩放（1.0 = 手机屏幕基准，编辑页画布用大倍数）。
///
/// 版式对齐「今日水印相机」：
///   17:11 │ 2026-10-19
///         │ 星期一  阴 17°C
///   秭归县 · 秭归县疾病预防控制中心
///   经纬度：30.828295°N,110.976382°E
class WmView extends StatelessWidget {
  final WatermarkSettings s;
  final double scale;

  const WmView({super.key, required this.s, this.scale = 1.0});

  double f(double v) => v * scale;

  @override
  Widget build(BuildContext context) {
    final st = s.style;
    // 亮字配黑影、暗字配亮影，透明底也压得住各种照片
    final shadows = <Shadow>[
      if (st.fg.computeLuminance() > 0.6)
        Shadow(color: const Color(0x99000000), blurRadius: f(6), offset: Offset(0, f(1)))
      else
        Shadow(color: const Color(0x88FFFFFF), blurRadius: f(6), offset: Offset(0, f(1))),
    ];
    final textStyle = (double size, {FontWeight w = FontWeight.w500}) =>
        TextStyle(
          // 注意：字号由调用点自己套 f(...)，这里别再乘一次，否则 scale² 变大
          fontSize: size,
          height: 1.3,
          fontWeight: w,
          color: st.fg,
          shadows: shadows,
        );

    final hasTime = s.enabled && s.showTime;
    final hasPlace = s.showPlace && s.place.trim().isNotEmpty;
    final hasLatLng = s.showLatLng && s.latLngText.isNotEmpty;
    final hasAlt = s.showAlt && s.altText.isNotEmpty;
    final hasNote = s.showNote && s.note.trim().isNotEmpty;
    final hasAny = st.title.isNotEmpty ||
        hasTime ||
        hasPlace ||
        hasLatLng ||
        hasAlt ||
        hasNote;

    return Container(
      // 用值相等判断透明底（新 Flutter 的 Color.alpha 访问器已被弃用/移除，
      // 别拿它判 alpha；clock 模板的 bg 就是 Colors.transparent）
      padding: st.bg == Colors.transparent
          ? EdgeInsets.zero
          : EdgeInsets.symmetric(horizontal: f(14), vertical: f(9)),
      decoration: BoxDecoration(
        color: st.bg,
        borderRadius: BorderRadius.circular(f(8)),
      ),
      child: hasAny
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (st.title.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: f(4)),
                    child: Text(st.title,
                        style: textStyle(f(15), w: FontWeight.w700)),
                  ),
                if (hasTime)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(s.clockText,
                          style: textStyle(f(36), w: FontWeight.w800)),
                      SizedBox(width: f(9)),
                      Container(width: f(3), height: f(32), color: st.accent),
                      SizedBox(width: f(9)),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.dateText,
                              style: textStyle(f(14), w: FontWeight.w600)),
                          if (s.weekdayWeatherText.isNotEmpty)
                            Text(s.weekdayWeatherText, style: textStyle(f(12))),
                        ],
                      ),
                    ],
                  ),
                if (hasPlace)
                  Padding(
                    padding: EdgeInsets.only(top: f(3)),
                    child: Text(s.place.trim(),
                        style: textStyle(f(13), w: FontWeight.w600)),
                  ),
                if (hasLatLng)
                  Padding(
                    padding: EdgeInsets.only(top: f(2)),
                    child: Text('经纬度：${s.latLngText}', style: textStyle(f(12))),
                  ),
                if (hasAlt)
                  Padding(
                    padding: EdgeInsets.only(top: f(2)),
                    child: Text(s.altText, style: textStyle(f(12))),
                  ),
                if (hasNote)
                  Padding(
                    padding: EdgeInsets.only(top: f(2)),
                    child: Text(s.note.trim(), style: textStyle(f(12))),
                  ),
              ],
            )
          : Text(
              '（水印内容都是空的，点「水印」勾几个字段）',
              style: textStyle(f(13)),
            ),
    );
  }
}

// ----------------------------------------------------------------- 天气

/// WMO 天气代码 → 中文。Open-Meteo 的 current.weather_code。
String _wmoText(int? code) {
  if (code == null) return '';
  if (code == 0) return '晴';
  if (code <= 2) return '多云';
  if (code == 3) return '阴';
  if (code == 45 || code == 48) return '雾';
  if (code >= 51 && code <= 57) return '毛毛雨';
  if (code >= 61 && code <= 67) return '雨';
  if (code >= 71 && code <= 77) return '雪';
  if (code >= 80 && code <= 82) return '阵雨';
  if (code == 85 || code == 86) return '阵雪';
  if (code >= 95) return '雷雨';
  return '';
}

/// Open-Meteo 免费当前天气（不要 key）。失败返回空串（没网是常态，
/// 静默降级成只显示星期几）。
Future<String> fetchWeatherText(double lat, double lng) async {
  try {
    final r = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    )).get<dynamic>(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: <String, dynamic>{
        'latitude': lat.toStringAsFixed(4),
        'longitude': lng.toStringAsFixed(4),
        'current': 'temperature_2m,weather_code',
      },
    );
    final data = r.data;
    final cur = data is Map ? data['current'] : null;
    if (cur is! Map) return '';
    final t = (cur['temperature_2m'] as num?)?.round();
    final code = cur['weather_code'];
    final w = _wmoText(code is int ? code : null);
    return [if (w.isNotEmpty) w, if (t != null) '$t°C'].join(' ');
  } catch (_) {
    return '';
  }
}

// ----------------------------------------------------------------- 编辑页

class WatermarkEditorPage extends StatefulWidget {
  final List<String> paths;
  final WatermarkSettings settings;

  /// 相机页拍完直接进来时置 true：画面一渲染好就自动存一张，
  /// 用户不用再点「保存」（对应「拍完即成片」）。
  final bool autoSave;

  const WatermarkEditorPage({
    super.key,
    required this.paths,
    required this.settings,
    this.autoSave = false,
  });

  @override
  State<WatermarkEditorPage> createState() => _WatermarkEditorPageState();
}

class _WatermarkEditorPageState extends State<WatermarkEditorPage> {
  static const MethodChannel _ch = MethodChannel('studyhub/camera');

  /// 画布逻辑宽度：水印字号按 390 基准设计，渲染时整体放大到 1080
  static const double _canvasW = 1080;
  static const double _baseW = 390;
  static const double _pixelRatio = 1.5;

  final GlobalKey _boundary = GlobalKey();

  late WatermarkSettings _s = widget.settings;
  int _idx = 0;
  double _aspect = 4 / 3;
  bool _saving = false;
  String _progressText = '';
  String? _msg;

  bool get _isPreviewOnly => widget.paths.isEmpty;

  String get _curPath => _isPreviewOnly ? '' : widget.paths[_idx];

  @override
  void initState() {
    super.initState();
    _loadAspect();
    if (widget.autoSave) _autoSaveOnce();
  }

  /// 拍完直接进来：等照片和解码都排好版，自动存一张。
  Future<void> _autoSaveOnce() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _saving) return;
    await _saveCurrent();
  }

  Future<void> _loadAspect() async {
    if (_isPreviewOnly) return;
    try {
      final bytes = await File(_curPath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble();
      final h = frame.image.height.toDouble();
      frame.image.dispose();
      if (!mounted || w <= 0 || h <= 0) return;
      setState(() => _aspect = w / h);
    } catch (_) {
      // 读不出尺寸就用 4:3，预览会有点拉伸，但不影响保存
    }
  }

  // ---------------------------------------------------------------- 保存

  Future<Uint8List?> _capture() async {
    final obj = _boundary.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) return null;
    final img = await obj.toImage(pixelRatio: _pixelRatio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }

  String _fileName(int i) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = DateTime.now();
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    return widget.paths.length > 1 ? 'wm_${stamp}_${i + 1}.png' : 'wm_$stamp.png';
  }

  Future<bool> _saveOne(int i) async {
    final bytes = await _capture();
    if (bytes == null) return false;
    await _ch.invokeMethod('saveImage', {
      'bytes': bytes,
      'name': _fileName(i),
      'mime': 'image/png',
    });
    return true;
  }

  Future<void> _saveCurrent() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _progressText = '正在保存…';
      _msg = null;
    });
    try {
      if (_isPreviewOnly) {
        setState(() {
          _saving = false;
          _msg = '这是排版预览（没有照片）。点下面的「拍照」或「选照片」再保存。';
        });
        return;
      }
      final ok = await _saveOne(_idx);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _msg = ok ? '已保存到相册（Pictures/学聚水印）' : '保存失败：截图没拿到';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _msg = '保存失败：$e';
      });
    }
  }

  Future<void> _saveAll() async {
    if (_saving || _isPreviewOnly) return;
    setState(() {
      _saving = true;
      _msg = null;
      _progressText = '准备中…';
    });
    var ok = 0;
    final errs = <String>[];
    for (var i = 0; i < widget.paths.length; i++) {
      if (!mounted) return;
      setState(() {
        _idx = i;
        _progressText = '正在处理 ${i + 1} / ${widget.paths.length}';
      });
      try {
        // 切图要重新量比例 + 等一帧把新图渲染出来，否则截到的是上一张
        final bytes = await File(widget.paths[i]).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
        final frame = await codec.getNextFrame();
        final w = frame.image.width.toDouble();
        final h = frame.image.height.toDouble();
        frame.image.dispose();
        if (w > 0 && h > 0 && mounted) {
          setState(() => _aspect = w / h);
        }
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (await _saveOne(i)) {
          ok++;
        } else {
          errs.add('第 ${i + 1} 张截图失败');
        }
      } catch (e) {
        errs.add('第 ${i + 1} 张：$e');
      }
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _idx = 0;
      _progressText = '';
      _msg = '已保存 $ok / ${widget.paths.length} 张到相册' +
          (errs.isEmpty ? '' : '\n${errs.join('\n')}');
    });
  }

  // ---------------------------------------------------------------- 编辑

  Future<void> _editTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _s.time,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _s.time.hour, minute: _s.time.minute),
    );
    if (!mounted) return;
    setState(() {
      _s.time = DateTime(d.year, d.month, d.day, t?.hour ?? _s.time.hour,
          t?.minute ?? _s.time.minute, _s.time.second);
      _s.showTime = true;
    });
  }

  Future<void> _editPlace() async {
    final c = TextEditingController(text: _s.place);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('地点'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: '手动输入地点'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _s.place = c.text.trim();
        _s.showPlace = _s.place.isNotEmpty || _s.showPlace;
      });
    }
  }

  Future<void> _editNote() async {
    final c = TextEditingController(text: _s.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备注'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(hintText: '如：设备巡检，现场已确认'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _s.note = c.text.trim();
        _s.showNote = _s.note.isNotEmpty;
      });
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canvasH = _canvasW / _aspect;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isPreviewOnly
            ? '水印预览'
            : widget.paths.length > 1
                ? '水印编辑 · ${_idx + 1}/${widget.paths.length}'
                : '水印编辑'),
        actions: [
          if (!_isPreviewOnly)
            IconButton(
              tooltip: '换成当前时间',
              onPressed: () => setState(() => _s.time = DateTime.now()),
              icon: const Icon(Icons.restore, size: 20),
            ),
        ],
      ),
      body: Column(
        children: [
          // ---------- 预览 ----------
          Expanded(
            child: Container(
              color: const Color(0xFF1A1A1A),
              padding: const EdgeInsets.all(12),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: _canvasW,
                    height: canvasH,
                    // RepaintBoundary 在 FittedBox 内部 —— 截出来的是
                    // 1080 逻辑宽的原尺寸画面，不受屏幕缩放影响。
                    child: RepaintBoundary(
                      key: _boundary,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_isPreviewOnly)
                            Container(
                              color: const Color(0xFF3A3A3A),
                              child: Center(
                                child: Text(
                                  '拍照后可在这里看到成片',
                                  style: TextStyle(
                                    fontSize: 34,
                                    color: Colors.white.withValues(alpha: 0.45),
                                  ),
                                ),
                              ),
                            )
                          else
                            Image.file(
                              File(_curPath),
                              fit: BoxFit.cover,
                              cacheWidth: 1620,
                              gaplessPlayback: true,
                            ),
                          if (_s.enabled &&
                              _s.showMap &&
                              _s.lat != null &&
                              _s.lng != null)
                            Positioned(
                              top: 24,
                              right: 24,
                              child: _MiniMap(lat: _s.lat!, lng: _s.lng!),
                            ),
                          _watermarkPositioned(canvasH),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ---------- 底部操作 ----------
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            color: scheme.surface,
            child: Column(
              children: [
                if (_saving && _progressText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(_progressText, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                if (_msg != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _msg!,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: scheme.primary),
                    ),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _chip('时间', Icons.schedule, _editTime),
                      _chip('地点', Icons.place_outlined, _editPlace),
                      _chip('备注', Icons.notes_outlined, _editNote),
                      _chip('位置', Icons.open_with, _pickCorner),
                      _chip('模板', Icons.style_outlined, _pickScene),
                      _chip('字段', Icons.checklist, _pickFields),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (!_isPreviewOnly)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : _saveCurrent,
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('保存这张'),
                        ),
                      ),
                    if (!_isPreviewOnly) const SizedBox(width: 10),
                    if (!_isPreviewOnly && widget.paths.length > 1)
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving ? null : _saveAll,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: Text('全部保存（${widget.paths.length}）'),
                        ),
                      )
                    else if (_isPreviewOnly)
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('返回调整'),
                        ),
                      )
                    else
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving ? null : _saveCurrent,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('保存到相册'),
                        ),
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

  Widget _chip(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: _saving ? null : onTap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _pickCorner() async {
    final c = await showModalBottomSheet<WmCorner>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in const {
              WmCorner.topLeft: '左上角',
              WmCorner.topRight: '右上角',
              WmCorner.bottomLeft: '左下角（默认）',
              WmCorner.bottomRight: '右下角',
            }.entries)
              ListTile(
                dense: true,
                leading: Icon(
                  _s.corner == e.key ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 19,
                ),
                title: Text(e.value),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (c != null && mounted) setState(() => _s.corner = c);
  }

  Future<void> _pickScene() async {
    final c = await showModalBottomSheet<WmScene>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in WmStyle.all.entries)
              ListTile(
                dense: true,
                leading: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: e.value.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                title: Text(e.value.name),
                trailing: _s.scene == e.key
                    ? Icon(Icons.check, size: 18, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (c != null && mounted) {
      setState(() {
        _s.scene = c;
        _s.enabled = true;
      });
    }
  }

  Future<void> _pickFields() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) {
          Widget sw(String label, bool v, ValueChanged<bool> f) => SwitchListTile(
                dense: true,
                title: Text(label, style: const TextStyle(fontSize: 13.5)),
                value: v,
                onChanged: (x) {
                  setSheet(() {});
                  setState(() => f(x));
                },
              );
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  dense: true,
                  title: const Text('启用水印', style: TextStyle(fontSize: 13.5)),
                  value: _s.enabled,
                  onChanged: (x) {
                    setSheet(() {});
                    setState(() => _s.enabled = x);
                  },
                ),
                sw('时间', _s.showTime, (v) => _s.showTime = v),
                sw('地点', _s.showPlace, (v) => _s.showPlace = v),
                sw('经纬度', _s.showLatLng, (v) => _s.showLatLng = v),
                sw('海拔', _s.showAlt, (v) => _s.showAlt = v),
                sw('地图小图（右上角）', _s.showMap, (v) => _s.showMap = v),
                sw('备注', _s.showNote, (v) => _s.showNote = v),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- 水印位置

  Widget _watermarkPositioned(double canvasH) {
    // 边距按画布宽度的 3% 走，换分辨率看着也协调
    const pad = _canvasW * 0.03;
    final child = WmView(s: _s, scale: _canvasW / _baseW);

    switch (_s.corner) {
      case WmCorner.topLeft:
        return Positioned(left: pad, top: pad, child: child);
      case WmCorner.topRight:
        return Positioned(right: pad, top: pad, child: child);
      case WmCorner.bottomRight:
        return Positioned(right: pad, bottom: pad, child: child);
      case WmCorner.bottomLeft:
        return Positioned(left: pad, bottom: pad, child: child);
    }
  }
}

// ----------------------------------------------------------------- 地图小图

/// 220×220 的位置小图。
///
/// 底图用 OSM 的单张瓦片（z=15，约 1.2km 见方），不需要任何 key；
/// 加载失败（没网 / 被墙）就画坐标网格 —— 至少能看出「有位置」。
class _MiniMap extends StatelessWidget {
  final double lat;
  final double lng;

  const _MiniMap({required this.lat, required this.lng});

  static const int _z = 15;
  static const double _size = 220;

  int get _tx => ((lng + 180) / 360 * (1 << _z)).floor();
  int get _ty {
    final r = lat * math.pi / 180;
    final v = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
    return (v * (1 << _z)).floor();
  }

  @override
  Widget build(BuildContext context) {
    final url = 'https://tile.openstreetmap.org/$_z/$_tx/$_ty.png';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const _GridFallback(),
              loadingBuilder: (_, child, p) =>
                  p == null ? child : const _GridFallback(),
            ),
            // 定位针
            Center(
              child: Icon(
                Icons.location_on,
                size: 46,
                color: const Color(0xFFD93025),
                shadows: const [Shadow(color: Colors.black45, blurRadius: 6)],
              ),
            ),
            // 底部信息条（OSM 要求署名）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)} · © OSM',
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridFallback extends StatelessWidget {
  const _GridFallback();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3E4A44));
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    for (var i = 1; i < 5; i++) {
      final x = size.width * i / 5;
      final y = size.height * i / 5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ============================================================ 取景页

/// 水印相机主界面（v2.2.0 按「今日水印相机」重做）。
///
/// * 打开就是取景画面，当前水印**实时叠在左下角**（时间每秒自己走）
/// * 底部三键：本地照片 / 快门 / 水印；快门拍完自动合成保存
/// * 「水印」→ 模板卡片选择面板 →「编辑内容」→ 字段开关面板
/// * 右侧「定位」：一次拿到经纬度 + 中文地址 + 天气
class WatermarkCameraPage extends StatefulWidget {
  const WatermarkCameraPage({super.key});

  @override
  State<WatermarkCameraPage> createState() => _WatermarkCameraPageState();
}

class _WatermarkCameraPageState extends State<WatermarkCameraPage>
    with WidgetsBindingObserver {
  static const MethodChannel _ch = MethodChannel('studyhub/camera');

  final WatermarkSettings _s = WatermarkSettings();

  CameraController? _cam;
  bool _starting = false;
  bool _shooting = false;
  bool _front = false;
  bool _locating = false;
  String? _err;

  /// 每秒把时间拨到「现在」—— 取景页的水印是真实时间。
  /// 拍照那一瞬间会再取一次 `DateTime.now()`，误差不超过 1 秒。
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCam();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _shooting) return;
      setState(() => _s.time = DateTime.now());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    final c = _cam;
    _cam = null;
    c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final c = _cam;
      _cam = null;
      c?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      if (_cam == null && !_starting) _initCam();
    }
  }

  Future<void> _initCam() async {
    if (_starting) return;
    _starting = true;
    if (mounted) setState(() => _err = null);
    CameraController? c;
    try {
      final st = await Permission.camera.request();
      if (!st.isGranted) {
        if (!mounted) return;
        setState(() => _err =
            '没有相机权限。\n到「系统设置 → 应用 → 学聚 → 权限」把相机打开，再回来点重试。');
        return;
      }
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (!mounted) return;
        setState(() => _err = '这台设备上没找到可用的摄像头。');
        return;
      }
      final want = _front ? CameraLensDirection.front : CameraLensDirection.back;
      final hit = cams.where((d) => d.lensDirection == want);
      final desc = hit.isNotEmpty ? hit.first : cams.first;
      c = CameraController(desc, ResolutionPreset.veryHigh, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final old = _cam;
      setState(() => _cam = c);
      if (old != null && old != c) old.dispose();
    } catch (e) {
      if (c != null) {
        try {
          await c.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _err = '相机启动失败：$e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _flip() async {
    if (_shooting) return;
    _front = !_front;
    final c = _cam;
    _cam = null;
    if (mounted) setState(() {});
    await c?.dispose();
    await _initCam();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- 定位

  /// 一次拿到：经纬度 + 海拔 + 中文地址 + 天气，水印立刻刷新。
  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    _toast('正在定位…');
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('location');
      if (!mounted) return;
      if (r == null || r['ok'] != true) {
        _toast('定位失败：${r?['msg'] ?? '拿不到位置'}');
        return;
      }
      final lat = (r['lat'] as num?)?.toDouble();
      final lng = (r['lng'] as num?)?.toDouble();
      final alt = (r['alt'] as num?)?.toDouble();
      if (lat == null || lng == null) {
        _toast('定位结果里没有经纬度');
        return;
      }
      setState(() {
        _s.lat = lat;
        _s.lng = lng;
        _s.alt = alt;
        _s.showLatLng = true;
        if (alt != null) _s.showAlt = true;
      });
      // 逆地理编码换成中文地址（失败就留着经纬度）
      try {
        // 原生 geocode 直接回一个 String（地址串），不是 Map —— 早先写成
        // invokeMapMethod 会静默抛类型错，地址永远填不上。这里用 String。
        final addr = await _ch.invokeMethod<String>(
            'geocode', <String, dynamic>{'lat': lat, 'lng': lng});
        if (addr != null && addr.isNotEmpty && mounted) {
          setState(() {
            _s.place = addr;
            _s.showPlace = true;
          });
        }
      } catch (_) {}
      // 天气：拿不到就只显示星期几
      final w = await fetchWeatherText(lat, lng);
      if (w.isNotEmpty && mounted) {
        setState(() => _s.weather = w);
      }
      if (mounted) _toast('定位完成');
    } catch (e) {
      _toast('定位失败：$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---------------------------------------------------------------- 拍照

  Future<void> _shoot() async {
    final c = _cam;
    if (_shooting) return;
    if (c == null || !c.value.isInitialized) {
      _toast('相机还没就绪，稍等一下再按');
      return;
    }
    setState(() => _shooting = true);
    try {
      // 水印上的时间 = 按快门的这一刻
      _s.time = DateTime.now();
      final shot = await c.takePicture();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WatermarkEditorPage(
          paths: <String>[shot.path],
          // 传副本：编辑页里改时间地点不会污染取景画面的水印
          settings: _s.copy(),
          autoSave: true,
        ),
      ));
    } catch (e) {
      _toast('拍照失败：$e');
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _pickPhotos() async {
    try {
      final list =
          await ImagePicker().pickMultiImage(imageQuality: 95, maxWidth: 4096);
      if (list.isEmpty || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WatermarkEditorPage(
          paths: list.map((e) => e.path).toList(),
          settings: _s.copy(),
        ),
      ));
      if (mounted) setState(() {});
    } catch (e) {
      _toast('选择照片失败：$e');
    }
  }

  // ---------------------------------------------------------------- 面板

  /// 模板小卡片的演示数据（固定一套好看的样例，跟今日水印相机一样）
  WatermarkSettings _demo(WmScene scene) {
    final d = WatermarkSettings()
      ..scene = scene
      ..enabled = true
      ..time = DateTime(2026, 8, 8, 8, 30)
      ..place = '北京市 · 天安门'
      ..lat = 39.908692
      ..lng = 116.397477
      ..weather = '晴 26°C'
      ..showTime = true
      ..showPlace = true
      ..showLatLng = true
      ..showAlt = false
      ..showMap = false
      ..showNote = scene == WmScene.work;
    if (scene == WmScene.work) d.note = '现场已确认';
    return d;
  }

  /// 水印选择面板（截图第二张）：⊘ 不加水印 + 模板卡片墙 + 编辑内容入口
  void _showPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) {
          final cs = Theme.of(ctx2).colorScheme;
          Widget tile(String name, Widget preview, bool selected, VoidCallback onTap) {
            return InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? cs.primary : cs.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        color: const Color(0xFF3A3A3A),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.all(6),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: preview,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: selected ? cs.primary : cs.onSurface,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w400)),
                  ],
                ),
              ),
            );
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx2).size.height * 0.72,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ---------- 头部 ----------
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                    child: Row(
                      children: [
                        const Text('水印',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(ctx2),
                          icon: const Icon(Icons.close, size: 22),
                        ),
                      ],
                    ),
                  ),
                  // ---------- 卡片墙 ----------
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GridView.count(
                            crossAxisCount: 2,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1.55,
                            children: [
                              // ⊘ 不加水印
                              tile(
                                '不加水印',
                                Icon(Icons.block_rounded,
                                    size: 34, color: Colors.white54),
                                !_s.enabled,
                                () {
                                  setSheet(() => _s.enabled = false);
                                  setState(() {});
                                },
                              ),
                              for (final e in WmStyle.all.entries)
                                tile(
                                  e.value.name,
                                  WmView(s: _demo(e.key)),
                                  _s.enabled && _s.scene == e.key,
                                  () {
                                    setSheet(() {
                                      _s.scene = e.key;
                                      _s.enabled = true;
                                    });
                                    setState(() {});
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // ---------- 编辑内容入口 ----------
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx2);
                                _showEdit();
                              },
                              icon: const Icon(Icons.tune, size: 18),
                              label: const Text('编辑水印内容'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 水印内容编辑面板（截图第三张）：一排开关，行尾显示当前值，
  /// 点行可以改（时间选择器 / 重新定位 / 备注输入框）。
  void _showEdit() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) {
          final cs = Theme.of(ctx2).colorScheme;
          Widget row({
            required String label,
            required bool on,
            required ValueChanged<bool> onToggle,
            String? value,
            VoidCallback? onTap,
            Color dot = Colors.transparent,
          }) {
            return InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Row(
                  children: [
                    // 缩到 0.85 否则 M3 的 Switch 在行高里显得很大
                    Transform.scale(
                      scale: 0.85,
                      child: Switch(
                        value: on,
                        onChanged: (v) {
                          setSheet(() => onToggle(v));
                          setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(
                            fontSize: 14,
                            color: on ? cs.onSurface : cs.onSurfaceVariant)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        value ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 12.5, color: cs.onSurfaceVariant),
                      ),
                    ),
                    if (dot != Colors.transparent) ...[
                      const SizedBox(width: 4),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: dot),
                      ),
                    ],
                    if (onTap != null) ...[
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 18, color: cs.onSurfaceVariant),
                    ],
                  ],
                ),
              ),
            );
          }

          Future<void> pickTime() async {
            final d = await showDatePicker(
              context: ctx2,
              initialDate: _s.time,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (d == null || !ctx2.mounted) return;
            final t = await showTimePicker(
              context: ctx2,
              initialTime: TimeOfDay(hour: _s.time.hour, minute: _s.time.minute),
            );
            if (!ctx2.mounted) return;
            setSheet(() {
              _s.time = DateTime(d.year, d.month, d.day,
                  t?.hour ?? _s.time.hour, t?.minute ?? _s.time.minute);
              _s.showTime = true;
            });
            setState(() {});
          }

          Future<void> editNote() async {
            final c = TextEditingController(text: _s.note);
            final ok = await showDialog<bool>(
              context: ctx2,
              builder: (ctx3) => AlertDialog(
                title: const Text('快速备注'),
                content: TextField(
                  controller: c,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(hintText: '如：三号车间设备巡检'),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx3, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx3, true),
                      child: const Text('确定')),
                ],
              ),
            );
            if (ok != true || !ctx2.mounted) return;
            setSheet(() {
              _s.note = c.text.trim();
              _s.showNote = _s.note.isNotEmpty || _s.showNote;
            });
            setState(() {});
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ---------- 头部 ----------
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      Text(_s.style.name,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const Icon(Icons.edit_outlined,
                          size: 15, color: Colors.grey),
                      const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(ctx2),
                        icon: const Icon(Icons.close, size: 22),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                row(
                  label: '真实时间',
                  value: '${_s.dateText} ${_s.clockText}',
                  on: _s.showTime,
                  onToggle: (v) => _s.showTime = v,
                  onTap: pickTime,
                ),
                row(
                  label: '地点',
                  value: _s.place.isEmpty
                      ? '（未定位，点行定位）'
                      : _s.place,
                  on: _s.showPlace,
                  onToggle: (v) => _s.showPlace = v,
                  onTap: () async {
                    Navigator.pop(ctx2);
                    await _locate();
                    if (mounted) _showEdit(); // 拿到新数据后重开面板
                  },
                ),
                row(
                  label: '经纬度',
                  value: _s.latLngText.isEmpty ? '（定位后自动填入）' : _s.latLngText,
                  on: _s.showLatLng,
                  onToggle: (v) => _s.showLatLng = v,
                ),
                row(
                  label: '海拔',
                  value: _s.altText.isEmpty ? '（定位后自动填入）' : _s.altText,
                  on: _s.showAlt,
                  onToggle: (v) => _s.showAlt = v,
                ),
                row(
                  label: '地图',
                  value: '显示在照片右上角',
                  on: _s.showMap,
                  onToggle: (v) => _s.showMap = v,
                ),
                row(
                  label: '快速备注',
                  value: _s.note.isEmpty ? '（未填写，点行输入）' : _s.note,
                  on: _s.showNote,
                  onToggle: (v) => _s.showNote = v,
                  onTap: editNote,
                  dot: _s.note.isEmpty ? const Color(0xFFE5484D) : Colors.transparent,
                ),
                const SizedBox(height: 10),
                // ---------- 底部按钮 ----------
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx2),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('完成'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          if (_s.enabled) _watermarkOverlay(),
          _rightRail(),
          _topBar(),
          _bottomBar(),
          if (_err != null) _errorLayer(),
        ],
      ),
    );
  }

  Widget _preview() {
    final c = _cam;
    if (c != null && c.value.isInitialized) {
      return Center(child: CameraPreview(c));
    }
    return Container(
      color: const Color(0xFF141414),
      child: const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
        ),
      ),
    );
  }

  /// 取景画面上叠加的水印（左下角，底栏上方）。
  Widget _watermarkOverlay() {
    return IgnorePointer(
      child: Padding(
        // 底部留出三键栏 + 模式条的高度
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 150),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: WmView(s: _s),
        ),
      ),
    );
  }

  Widget _roundIcon(IconData icon, String tip, VoidCallback onTap,
      {bool busy = false}) {
    return IconButton(
      tooltip: tip,
      onPressed: busy ? null : onTap,
      icon: busy
          ? SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : Icon(icon, color: Colors.white, size: 24),
      style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.35)),
    );
  }

  Widget _topBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        child: Row(
          children: [
            _roundIcon(Icons.close, '退出', () => Navigator.of(context).maybePop()),
            const Spacer(),
            _roundIcon(Icons.cameraswitch_outlined, '前后镜头', _flip),
          ],
        ),
      ),
    );
  }

  /// 右侧悬浮栏：定位（截图右下的靶心按钮）
  Widget _rightRail() {
    return IgnorePointer(
      ignoring: false,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 10, 160),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _roundIcon(Icons.my_location, '取当前地点', _locate, busy: _locating),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomKey(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.16),
                border: Border.all(color: Colors.white70, width: 1),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 11.5)),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xB3000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左：本地照片加水印
                _bottomKey(Icons.photo_library_outlined, '本地照片', _pickPhotos),
                // 中：快门
                GestureDetector(
                  onTap: _shooting ? null : _shoot,
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: Container(
                      margin: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _shooting ? Colors.white54 : Colors.white,
                      ),
                      child: _shooting
                          ? const Padding(
                              padding: EdgeInsets.all(17),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.black54),
                            )
                          : null,
                    ),
                  ),
                ),
                // 右：水印（选择模板 / 编辑内容）
                _bottomKey(Icons.branding_watermark_outlined, '水印', _showPicker),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorLayer() {
    return Container(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white54, size: 44),
              const SizedBox(height: 12),
              Text(
                _err ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _initCam,
                child: const Text('重试'),
              ),
              const SizedBox(height: 6),
              const Text(
                '相机不可用时，「本地照片」仍然可以给本地照片加水印',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
