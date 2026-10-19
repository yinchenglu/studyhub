import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// 水印相机（v2.0.0+37）
///
/// 归类：生活与娱乐。
///
/// 两部分：
///   1. 设置页（[WatermarkPage]）：选模板、勾字段、填内容、定位置，
///      然后「拍照」或「从相册选」（支持批量）
///   2. 编辑页（[WatermarkEditorPage]）：所见即所得预览，
///      保存时用 RepaintBoundary 把 1080 逻辑宽的画布按 1.5 倍截成 PNG
///
/// 原生通道 `studyhub/camera`：
///   location（取一次定位，含海拔）/ geocode（逆地理编码）/ saveImage（存相册）
///
/// 地图小图：没有地图 SDK，用 OpenStreetMap 的单张瓦片（z=15）当底图，
/// 中间叠一个定位针 —— 误差在一条街以内，做水印足够，且不需要任何 key。
/// 没网时自动降级成「坐标网格 + 定位针」，不会白块。

// ----------------------------------------------------------------- 数据模型

enum WmScene { work, life, safety, training, custom }

enum WmCorner { bottomLeft, topLeft, bottomRight, topRight }

class WmStyle {
  final String name;
  final String title; // 空串 = 不显示标题条
  final Color bg;
  final Color accent;
  final Color fg;

  const WmStyle({
    required this.name,
    required this.title,
    required this.bg,
    required this.accent,
    required this.fg,
  });

  static const Map<WmScene, WmStyle> all = {
    WmScene.work: WmStyle(
      name: '工作',
      title: '工作记录',
      bg: Color(0xE60A2D4D),
      accent: Color(0xFF2F9BE0),
      fg: Colors.white,
    ),
    WmScene.life: WmStyle(
      name: '生活',
      title: '生活记录',
      bg: Color(0x99000000),
      accent: Color(0xFFFFB300),
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
      name: '培训',
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

/// 水印的全部可变量。编辑页拿的是同一个对象，改完立刻反映到预览。
class WatermarkSettings {
  WmScene scene = WmScene.work;

  bool showTime = true;
  bool showPlace = true;
  bool showLatLng = false;
  bool showAlt = false;
  bool showMap = false;
  bool showNote = false;

  DateTime time = DateTime.now();
  String place = '';
  double? lat;
  double? lng;
  double? alt;
  String note = '';

  WmCorner corner = WmCorner.bottomLeft;

  WmStyle get style => WmStyle.all[scene] ?? WmStyle.all[WmScene.work]!;

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String get latLngText {
    if (lat == null || lng == null) return '';
    final ns = lat! >= 0 ? 'N' : 'S';
    final ew = lng! >= 0 ? 'E' : 'W';
    return '${lng!.abs().toStringAsFixed(6)}°$ew  '
        '${lat!.abs().toStringAsFixed(6)}°$ns';
  }

  String get altText => alt == null ? '' : '海拔 ${alt!.toStringAsFixed(1)} m';

  WatermarkSettings copy() {
    final c = WatermarkSettings()
      ..scene = scene
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
      ..corner = corner;
    return c;
  }
}

// ----------------------------------------------------------------- 设置页

class WatermarkPage extends StatefulWidget {
  /// 从相机页进来时传**同一个** settings 对象：改完返回，取景画面的水印立刻变。
  final WatermarkSettings? settings;

  /// 直接进设置页时叫「水印相机」，从相机里点「水印」进来时叫「水印样式」。
  final String title;

  const WatermarkPage({super.key, this.settings, this.title = '水印相机'});

  @override
  State<WatermarkPage> createState() => _WatermarkPageState();
}

class _WatermarkPageState extends State<WatermarkPage> {
  static const MethodChannel _ch = MethodChannel('studyhub/camera');

  late final WatermarkSettings _s = widget.settings ?? WatermarkSettings();

  final TextEditingController _place = TextEditingController();
  final TextEditingController _note = TextEditingController();

  bool _locating = false;
  bool _locatingError = false;

  @override
  void initState() {
    super.initState();
    _place.text = _s.place;
    _note.text = _s.note;
    _place.addListener(() => _s.place = _place.text);
    _note.addListener(() => _s.note = _note.text);
  }

  @override
  void dispose() {
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 定位

  Future<void> _locate() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locatingError = false;
    });
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('location');
      if (!mounted) return;
      if (r == null || r['ok'] != true) {
        setState(() {
          _locating = false;
          _locatingError = true;
        });
        _toast('${r?['msg'] ?? '定位失败'}（可以手动输入地点）');
        return;
      }
      final lat = (r['lat'] as num?)?.toDouble();
      final lng = (r['lng'] as num?)?.toDouble();
      final alt = (r['alt'] as num?)?.toDouble();
      // 逆地理编码：失败就留空，用户自己填
      String addr = '';
      if (lat != null && lng != null) {
        try {
          addr = await _ch.invokeMethod<String>('geocode', {'lat': lat, 'lng': lng}) ?? '';
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _s.lat = lat;
        _s.lng = lng;
        _s.alt = alt;
        if (addr.isNotEmpty) {
          _s.place = addr;
          _place.text = addr;
        }
        _s.showLatLng = true;
        if (alt != null) _s.showAlt = true;
        _locating = false;
      });
      if (addr.isEmpty) _toast('拿到坐标了，但没解析出地址（没网？）可以手动填地点');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _locatingError = true;
      });
      _toast('定位失败：$e');
    }
  }

  // ---------------------------------------------------------------- 时间

  String get _timeText => _s.timeText;

  Future<void> _pickTime() async {
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
      _s.time = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _s.time.hour,
        t?.minute ?? _s.time.minute,
        _s.time.second,
      );
    });
  }

  // ---------------------------------------------------------------- 拍照 / 选图

  Future<void> _shoot() async {
    try {
      final f = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 95,
        maxWidth: 4096,
      );
      if (f == null || !mounted) return;
      _openEditor([f.path]);
    } catch (e) {
      _toast('打开相机失败：$e');
    }
  }

  Future<void> _pickPhotos() async {
    try {
      final list = await ImagePicker().pickMultiImage(imageQuality: 95, maxWidth: 4096);
      if (list.isEmpty || !mounted) return;
      _openEditor(list.map((e) => e.path).toList());
    } catch (e) {
      _toast('选择照片失败：$e');
    }
  }

  void _openEditor(List<String> paths) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WatermarkEditorPage(paths: paths, settings: _s.copy()),
    ));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '预览效果',
            onPressed: _previewOnly,
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          // ---------- 模板 ----------
          const _Title('水印模板'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in WmStyle.all.entries)
                ChoiceChip(
                  label: Text(e.value.name, style: const TextStyle(fontSize: 12.5)),
                  selected: _s.scene == e.key,
                  selectedColor: e.value.accent.withValues(alpha: 0.22),
                  onSelected: (_) => setState(() => _s.scene = e.key),
                ),
            ],
          ),
          if (_s.scene == WmScene.safety)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '安全生产模板：白底 + 红色标题条，适合检查、巡检留证。',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),

          const SizedBox(height: 16),

          // ---------- 字段 ----------
          Row(
            children: [
              const _Title('水印内容'),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  final allOn = _s.showTime &&
                      _s.showPlace &&
                      _s.showLatLng &&
                      _s.showAlt &&
                      _s.showMap &&
                      _s.showNote;
                  _s.showTime = !allOn;
                  _s.showPlace = !allOn;
                  _s.showLatLng = !allOn;
                  _s.showAlt = !allOn;
                  _s.showMap = !allOn;
                  _s.showNote = !allOn;
                }),
                child: const Text('全选 / 清空', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),

          _fieldRow(
            label: '时间',
            value: _timeText,
            on: _s.showTime,
            onToggle: (v) => setState(() => _s.showTime = v),
            trailing: IconButton(
              tooltip: '修改时间',
              onPressed: _pickTime,
              icon: const Icon(Icons.edit_calendar_outlined, size: 19),
            ),
          ),
          _fieldRow(
            label: '地点',
            on: _s.showPlace,
            onToggle: (v) => setState(() => _s.showPlace = v),
            trailing: TextButton.icon(
              onPressed: _locating ? null : _locate,
              icon: _locating
                  ? const SizedBox(
                      width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(
                      _locatingError ? Icons.location_off_outlined : Icons.my_location,
                      size: 16),
              label: Text(_locating ? '定位中' : '定位', style: const TextStyle(fontSize: 12)),
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: _place,
                enabled: _s.showPlace,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '自动定位或手动输入，如：杭州市西湖区文三路 90 号',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          _fieldRow(
            label: '经纬度',
            value: _s.latLngText.isEmpty ? '（先点上面的「定位」）' : _s.latLngText,
            on: _s.showLatLng,
            onToggle: (v) => setState(() => _s.showLatLng = v),
          ),
          _fieldRow(
            label: '海拔',
            value: _s.altText.isEmpty ? '（定位后自动填入）' : _s.altText,
            on: _s.showAlt,
            onToggle: (v) => setState(() => _s.showAlt = v),
          ),
          _fieldRow(
            label: '地图小图',
            value: '勾选后右上角显示位置小图',
            on: _s.showMap,
            onToggle: (v) => setState(() => _s.showMap = v),
          ),
          _fieldRow(
            label: '备注',
            on: _s.showNote,
            onToggle: (v) => setState(() => _s.showNote = v),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: _note,
                enabled: _s.showNote,
                maxLines: 3,
                minLines: 1,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '如：三号车间设备巡检，现场已确认',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ---------- 位置 ----------
          const _Title('水印位置'),
          const SizedBox(height: 8),
          Row(
            children: [
              _cornerBtn('左上', WmCorner.topLeft),
              const SizedBox(width: 8),
              _cornerBtn('右上', WmCorner.topRight),
              const SizedBox(width: 8),
              _cornerBtn('左下', WmCorner.bottomLeft),
              const SizedBox(width: 8),
              _cornerBtn('右下', WmCorner.bottomRight),
            ],
          ),

          const SizedBox(height: 20),

          // ---------- 入口 ----------
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _shoot,
                  icon: const Icon(Icons.photo_camera_outlined, size: 19),
                  label: const Text('拍照加水印'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickPhotos,
                  icon: const Icon(Icons.photo_library_outlined, size: 19),
                  label: const Text('选照片（可批量）'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),
          Text(
            '· 拍照：调用系统相机，拍完立刻进水印编辑页\n'
            '· 选照片：可一次选多张，同一套水印批量盖上去\n'
            '· 保存结果在「相册 → Pictures/学聚水印」\n'
            '· 定位用来填地点/经纬度/海拔，没网也能手输',
            style: TextStyle(fontSize: 11.5, height: 1.8, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 不拍照，直接用一张纯色示意图预览水印排版
  void _previewOnly() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WatermarkEditorPage(paths: const [], settings: _s.copy()),
    ));
  }

  Widget _cornerBtn(String label, WmCorner c) {
    final scheme = Theme.of(context).colorScheme;
    final on = _s.corner == c;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _s.corner = c),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: on ? scheme.primary.withValues(alpha: 0.55) : scheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              color: on ? scheme.onPrimaryContainer : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldRow({
    required String label,
    required bool on,
    required ValueChanged<bool> onToggle,
    String? value,
    Widget? trailing,
    Widget? child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 26,
                height: 30,
                child: Checkbox(
                  value: on,
                  onChanged: (v) => onToggle(v == true),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: on ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: on ? scheme.onSurfaceVariant : scheme.outline,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          if (child != null)
            Padding(
              padding: const EdgeInsets.only(left: 30, right: 4, bottom: 6),
              child: child,
            ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
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

  /// 画布逻辑宽度：所有字号按这个基准设计，截屏时按 1.5 倍输出
  static const double _canvasW = 1080;
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
  /// 用户从相机页按快门之后不用再点「保存」，真正做到「拍完即成片」。
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
                          if (_s.showMap && _s.lat != null && _s.lng != null)
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
    if (c != null && mounted) setState(() => _s.scene = c);
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

  // ---------------------------------------------------------------- 水印绘制

  Widget _watermarkPositioned(double canvasH) {
    // 边距按画布宽度的 3% 走，换分辨率看着也协调
    const pad = _canvasW * 0.03;
    final child = _watermarkBox();

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

  Widget _watermarkBox() {
    final st = _s.style;
    final rows = <String>[
      if (_s.showTime) _s.timeText,
      if (_s.showPlace && _s.place.trim().isNotEmpty) _s.place.trim(),
      if (_s.showLatLng && _s.latLngText.isNotEmpty) _s.latLngText,
      if (_s.showAlt && _s.altText.isNotEmpty) _s.altText,
      if (_s.showNote && _s.note.trim().isNotEmpty) _s.note.trim(),
    ];
    final hasTitle = st.title.isNotEmpty;
    // 背景透明之后，文字得自己带投影才压得住各种照片：
    // 亮字配黑影、暗字配亮影。
    final shadows = <Shadow>[
      if (st.fg.computeLuminance() > 0.6)
        const Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1))
      else
        const Shadow(color: Color(0x88FFFFFF), blurRadius: 6, offset: Offset(0, 1)),
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _canvasW * 0.72),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 12, 26, 12),
        decoration: BoxDecoration(
          // v2.1.0：水印**不要底板**（用户明确要求「水印背景透明」），
          // 只保留左侧色条 + 文字本身。
          color: Colors.transparent,
          border: Border(
            left: BorderSide(color: st.accent, width: 7),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasTitle)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  st.title,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: st.fg,
                    letterSpacing: 1.5,
                    shadows: shadows,
                  ),
                ),
              ),
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                child: Text(
                  rows[i],
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.35,
                    color: st.fg,
                    fontWeight: FontWeight.w500,
                    shadows: shadows,
                  ),
                ),
              ),
            if (!hasTitle && rows.isEmpty)
              Text(
                '（水印内容都是空的，勾几个字段）',
                style: TextStyle(fontSize: 22, color: st.fg.withValues(alpha: 0.7)),
              ),
          ],
        ),
      ),
    );
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

// ============================================================ 相机页（v2.1.0）

/// 水印相机主界面：**打开就是取景画面**（对齐「今日水印相机」的用法）。
///
/// * 当前水印**实时叠在取景画面上**：换模板、改时间地点，当场能看到效果
/// * 顶部「水印」→ 换样式 / 改时间地点（复用 [WatermarkPage] 的整套设置）
/// * 底部左边「照片」→ 从相册选（可多选）加同一套水印
/// * 中间大圆键 = 快门：拍完**自动合成水印并保存**，回到取景继续拍
///
/// 相机的启停跟着生命周期走：切后台立刻 release（否则回来黑屏），
/// 回到前台自动重开。
class WatermarkCameraPage extends StatefulWidget {
  const WatermarkCameraPage({super.key});

  @override
  State<WatermarkCameraPage> createState() => _WatermarkCameraPageState();
}

class _WatermarkCameraPageState extends State<WatermarkCameraPage>
    with WidgetsBindingObserver {
  final WatermarkSettings _s = WatermarkSettings();

  CameraController? _cam;
  bool _starting = false;
  bool _shooting = false;
  bool _front = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      // 同一个 settings 对象：返回后取景画面的水印立刻更新
      builder: (_) => WatermarkPage(settings: _s, title: '水印样式'),
    ));
    if (mounted) setState(() {});
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
          _watermarkOverlay(),
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

  /// 取景画面上叠加的水印：**透明背景**，只有左侧色条 + 文字。
  Widget _watermarkOverlay() {
    final st = _s.style;
    final shadows = <Shadow>[
      if (st.fg.computeLuminance() > 0.6)
        const Shadow(color: Color(0x99000000), blurRadius: 5, offset: Offset(0, 1))
      else
        const Shadow(color: Color(0x88FFFFFF), blurRadius: 5, offset: Offset(0, 1)),
    ];
    final rows = <String>[
      if (_s.showTime) _s.timeText,
      if (_s.showPlace && _s.place.trim().isNotEmpty) _s.place.trim(),
      if (_s.showLatLng && _s.latLngText.isNotEmpty) _s.latLngText,
      if (_s.showAlt && _s.altText.isNotEmpty) _s.altText,
      if (_s.showNote && _s.note.trim().isNotEmpty) _s.note.trim(),
    ];
    final box = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(width: 3.5, height: 12.0 + rows.length * 18.0, color: st.accent),
        const SizedBox(width: 7),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (st.title.isNotEmpty)
                Text(
                  st.title,
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: st.fg,
                    letterSpacing: 1.0,
                    shadows: shadows,
                  ),
                ),
              for (final r in rows)
                Text(
                  r,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: st.fg,
                    fontWeight: FontWeight.w500,
                    shadows: shadows,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    Alignment align;
    switch (_s.corner) {
      case WmCorner.topLeft:
        align = Alignment.topLeft;
        break;
      case WmCorner.topRight:
        align = Alignment.topRight;
        break;
      case WmCorner.bottomRight:
        align = Alignment.bottomRight;
        break;
      case WmCorner.bottomLeft:
        align = Alignment.bottomLeft;
        break;
    }
    return IgnorePointer(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Align(alignment: align, child: box),
        ),
      ),
    );
  }

  Widget _roundIcon(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: 24),
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
            FilledButton.tonalIcon(
              onPressed: _openSettings,
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: const Text('水印'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.92),
                foregroundColor: Colors.black87,
              ),
            ),
            const SizedBox(width: 8),
            _roundIcon(Icons.cameraswitch_outlined, '前后镜头', _flip),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.only(bottom: 6),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0x99000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左：本地照片加水印
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _roundIcon(Icons.photo_library_outlined, '选照片加水印', _pickPhotos),
                    const SizedBox(height: 3),
                    const Text('照片',
                        style: TextStyle(color: Colors.white, fontSize: 11.5)),
                  ],
                ),
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
                // 右：再点一次「水印」也能改，这里放定位，拍之前先把地点拿到
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _roundIcon(Icons.my_location, '取当前地点', _locateHere),
                    const SizedBox(height: 3),
                    const Text('定位',
                        style: TextStyle(color: Colors.white, fontSize: 11.5)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 直接在取景页定位：地点 / 经纬度 / 海拔一次拿到，水印立刻更新。
  Future<void> _locateHere() async {
    _toast('正在定位…');
    try {
      final r = await const MethodChannel('studyhub/camera')
          .invokeMapMethod<String, dynamic>('location');
      if (r == null || r['ok'] != true) {
        _toast('定位失败：${r?['msg'] ?? '拿不到位置'}');
        return;
      }
      final lat = (r['lat'] as num).toDouble();
      final lng = (r['lng'] as num).toDouble();
      final alt = r['alt'];
      if (!mounted) return;
      setState(() {
        _s.lat = lat;
        _s.lng = lng;
        _s.alt = alt is num ? alt.toDouble() : null;
        _s.showLatLng = true;
      });
      // 逆地理编码换成中文地址（失败就留着经纬度）
      try {
        final g = await const MethodChannel('studyhub/camera').invokeMapMethod<String, dynamic>(
            'geocode', <String, dynamic>{'lat': lat, 'lng': lng});
        final addr = g?['address'] as String?;
        if (addr != null && addr.isNotEmpty && mounted) {
          setState(() {
            _s.place = addr;
            _s.showPlace = true;
          });
        }
      } catch (_) {}
    } catch (e) {
      _toast('定位失败：$e');
    }
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
                '相机不可用时，下面「照片」按钮仍然可以给本地照片加水印',
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
