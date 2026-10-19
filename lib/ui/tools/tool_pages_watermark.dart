import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// 水印相机（v2.2.2 重做）
///
/// 跟上一版的区别（用户逐条提的）：
///   * **去掉所有场景模板**：点「水印」不再先选模板，直接进编辑面板；
///   * 可编辑项只有：Logo、时间、地点、经纬度、海拔、文本，每项一个开关；
///   * 去掉「地图小图」和「天气」（那两项是上一版加的，用户不要了）；
///   * 地点优先定位、可从地图数据里搜出来选，也能直接改文字；
///   * 横屏时水印自动缩小、避开底部按钮栏和安全区。
///
/// 两个入口共用一个编辑面板：取景页底部的「水印」，以及编辑页顶部的
/// 「水印内容」。面板内容可滚动 + 键盘弹出时自动上移，不会被系统栏挡住。
///
/// 原生能力走 `studyhub/camera`：
///   * `location`  → 取一次定位（含海拔/精度）
///   * `geocode`   → 经纬度转中文地址（Geocoder，失败返回空串）
///   * `saveImage` → 把 Dart 合成好的图存进相册

// ============================================================== 数据模型

class WatermarkSettings {
  /// 总开关（关掉 = 拍出来没有水印）
  bool enabled = true;

  /// 自定义 Logo（PNG/JPG 字节）。为空表示还没传。
  Uint8List? logo;
  bool showLogo = false;

  /// Logo 大小倍率（1.0 = 默认高度 34，跟着整体 scale 走）
  double logoScale = 1.0;

  bool showTime = true;
  DateTime time = DateTime.now();

  bool showPlace = true;
  String place = '';

  bool showLatLng = true;
  double? lat;
  double? lng;

  bool showAlt = false;
  double? alt;

  bool showNote = false;
  String note = '';

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 大字时间「17:11」
  String get clockText => '${_two(time.hour)}:${_two(time.minute)}';

  /// 「2026-10-19」
  String get dateText => '${time.year}-${_two(time.month)}-${_two(time.day)}';

  static const _weekCn = [
    '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日',
  ];

  String get weekdayText => _weekCn[time.weekday - 1];

  /// 「30.828295°N,110.976382°E」—— 纬度在前
  String get latLngText {
    if (lat == null || lng == null) return '';
    final ns = lat! >= 0 ? 'N' : 'S';
    final ew = lng! >= 0 ? 'E' : 'W';
    return '${lat!.abs().toStringAsFixed(6)}°$ns,'
        '${lng!.abs().toStringAsFixed(6)}°$ew';
  }

  String get altText => alt == null ? '' : '海拔 ${alt!.toStringAsFixed(1)} m';

  WatermarkSettings copy() {
    return WatermarkSettings()
      ..enabled = enabled
      ..logo = logo
      ..showLogo = showLogo
      ..logoScale = logoScale
      ..showTime = showTime
      ..time = time
      ..showPlace = showPlace
      ..place = place
      ..showLatLng = showLatLng
      ..lat = lat
      ..lng = lng
      ..showAlt = showAlt
      ..alt = alt
      ..showNote = showNote
      ..note = note;
  }
}

// ============================================================== 水印渲染

/// 水印本体。取景页叠层、编辑页成片用的都是它，靠 [scale] 缩放
/// （1.0 = 手机屏幕基准；编辑页画布按短边放大）。
///
/// 版式：
///   [Logo]
///   17:11 │ 2026-10-19
///         │ 星期一
///   地点文字
///   经纬度：30.828295°N,110.976382°E
///   海拔 128.4 m
///   多行文本……
class WmView extends StatelessWidget {
  final WatermarkSettings s;
  final double scale;

  const WmView({super.key, required this.s, this.scale = 1.0});

  double f(double v) => v * scale;

  @override
  Widget build(BuildContext context) {
    // 深色照片上白字要有黑影，浅色照片也要看得清 —— 统一用暗阴影 + 微亮描边感
    final shadows = <Shadow>[
      Shadow(color: const Color(0xB3000000), blurRadius: f(6), offset: Offset(0, f(1))),
    ];
    TextStyle ts(double size, {FontWeight w = FontWeight.w500, double h = 1.3}) =>
        TextStyle(
          fontSize: size,
          height: h,
          fontWeight: w,
          color: Colors.white,
          shadows: shadows,
        );

    final hasLogo = s.showLogo && s.logo != null;
    final hasTime = s.showTime;
    final hasPlace = s.showPlace && s.place.trim().isNotEmpty;
    final hasLatLng = s.showLatLng && s.latLngText.isNotEmpty;
    final hasAlt = s.showAlt && s.altText.isNotEmpty;
    final hasNote = s.showNote && s.note.trim().isNotEmpty;

    if (!hasLogo && !hasTime && !hasPlace && !hasLatLng && !hasAlt && !hasNote) {
      return Text('（水印内容都是空的，点「水印」勾几个字段）', style: ts(f(13)));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasLogo)
          Padding(
            padding: EdgeInsets.only(bottom: f(6)),
            // 只给高度，宽度按比例 —— PNG 透明底能直接叠在照片上
            child: Image.memory(
              s.logo!,
              height: f(34) * s.logoScale,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        if (hasTime)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(s.clockText, style: ts(f(36), w: FontWeight.w800, h: 1.1)),
              SizedBox(width: f(9)),
              Container(width: f(3), height: f(32), color: const Color(0xFFFFC53D)),
              SizedBox(width: f(9)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s.dateText, style: ts(f(14), w: FontWeight.w600)),
                  Text(s.weekdayText, style: ts(f(12))),
                ],
              ),
            ],
          ),
        if (hasPlace)
          Padding(
            padding: EdgeInsets.only(top: f(4)),
            child: Text(s.place.trim(), style: ts(f(13.5), w: FontWeight.w600)),
          ),
        if (hasLatLng)
          Padding(
            padding: EdgeInsets.only(top: f(2)),
            child: Text('经纬度：${s.latLngText}', style: ts(f(12))),
          ),
        if (hasAlt)
          Padding(
            padding: EdgeInsets.only(top: f(2)),
            child: Text(s.altText, style: ts(f(12))),
          ),
        if (hasNote)
          Padding(
            padding: EdgeInsets.only(top: f(3)),
            child: Text(s.note.trim(), style: ts(f(12.5), h: 1.45)),
          ),
      ],
    );
  }
}

// ============================================================== 定位 / 地址

const MethodChannel _wmCh = MethodChannel('studyhub/camera');

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );
}

/// 申请定位权限并取一次坐标。成功返回 true。
///
/// 用户点名「点按钮就要弹权限菜单」，所以这里**先** request 再调原生通道。
Future<bool> wmLocate(
  BuildContext context,
  WatermarkSettings s, {
  VoidCallback? onChanged,
}) async {
  var st = await Permission.locationWhenInUse.status;
  if (!st.isGranted) {
    st = await Permission.locationWhenInUse.request();
  }
  if (!st.isGranted) {
    if (!context.mounted) return false;
    if (st.isPermanentlyDenied) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('定位权限被拒绝'),
          content: const Text('需要到系统设置里打开定位权限。\n\n'
              '路径：设置 → 应用 → 学聚 → 权限 → 位置信息。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('算了')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去设置')),
          ],
        ),
      );
      if (go == true) await openAppSettings();
    } else {
      _snack(context, '没有定位权限，地点可以手动输入');
    }
    return false;
  }

  Map<String, dynamic>? r;
  try {
    r = await _wmCh.invokeMapMethod<String, dynamic>('location');
  } catch (e) {
    if (context.mounted) _snack(context, '定位失败：$e');
    return false;
  }
  if (r == null || r['ok'] != true) {
    if (context.mounted) _snack(context, '${r?['msg'] ?? '拿不到位置'}');
    return false;
  }
  final lat = (r['lat'] as num?)?.toDouble();
  final lng = (r['lng'] as num?)?.toDouble();
  if (lat == null || lng == null) {
    if (context.mounted) _snack(context, '定位结果里没有经纬度');
    return false;
  }
  s.lat = lat;
  s.lng = lng;
  s.alt = (r['alt'] as num?)?.toDouble();
  s.showLatLng = true;
  if (s.place.trim().isEmpty) s.showPlace = true;
  onChanged?.call();

  // 逆地理编码（失败就只留经纬度）
  final addr = await wmReverseGeocode(lat, lng);
  if (addr.isNotEmpty) {
    s.place = addr;
    s.showPlace = true;
    onChanged?.call();
  }
  return true;
}

/// 经纬度 → 中文地址。原生 `geocode` 直接回 String。
Future<String> wmReverseGeocode(double lat, double lng) async {
  try {
    final a = await _wmCh.invokeMethod<String>(
      'geocode',
      <String, dynamic>{'lat': lat, 'lng': lng},
    );
    return (a ?? '').trim();
  } catch (_) {
    return '';
  }
}

/// 地图数据里搜地点（OpenStreetMap Nominatim，免费、不要 key）。
///
/// 为什么用它：国内地图 SDK 都要 key 和签名包名，学聚是自签名的个人项目，
/// 加一套 SDK 太重。Nominatim 走 HTTPS，国内能连（不行就手动输入，不强求）。
Future<List<PlaceHit>> wmSearchPlaces(String q) async {
  final key = q.trim();
  if (key.isEmpty) return const <PlaceHit>[];
  try {
    final r = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      headers: const {'User-Agent': 'StudyHub/2.2 (Android)'},
    )).get<List<dynamic>>(
      'https://nominatim.openstreetmap.org/search',
      queryParameters: <String, dynamic>{
        'q': key,
        'format': 'json',
        'limit': 10,
        'accept-language': 'zh-CN',
      },
    );
    final list = r.data ?? const <dynamic>[];
    final out = <PlaceHit>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name = (e['display_name'] as String?)?.trim() ?? '';
      final lat = double.tryParse('${e['lat']}');
      final lng = double.tryParse('${e['lon']}');
      if (name.isEmpty) continue;
      out.add(PlaceHit(_shortAddress(name), lat, lng));
    }
    return out;
  } catch (_) {
    return const <PlaceHit>[];
  }
}

/// 把 Nominatim 的长地址截短：只留前 4 段（门牌/路/区/市）。
String _shortAddress(String full) {
  final parts = full.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (parts.length <= 4) return parts.join(' · ');
  return parts.take(4).join(' · ');
}

class PlaceHit {
  final String name;
  final double? lat;
  final double? lng;
  const PlaceHit(this.name, this.lat, this.lng);
}

// ============================================================== 编辑面板

/// 水印内容编辑面板。取景页和编辑页共用。
///
/// 面板内容放在 SingleChildScrollView 里、整体限高 86% 屏高，
/// 键盘弹出时按 viewInsets 上移 —— 选项不会被底部导航栏或输入法挡住。
Future<void> showWatermarkSheet(
  BuildContext context,
  WatermarkSettings s, {
  VoidCallback? onChanged,
}) async {
  final scheme = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx2, setSheet) {
          Future<void> doLocate() async {
            final ok = await wmLocate(ctx2, s, onChanged: () {
              setSheet(() {});
              onChanged?.call();
            });
            if (ok) {
              setSheet(() {});
              onChanged?.call();
              if (ctx2.mounted) _snack(ctx2, '定位完成');
            }
          }

          Future<void> pickLogo() async {
            try {
              final f = await ImagePicker().pickImage(source: ImageSource.gallery);
              if (f == null) return;
              final bytes = await f.readAsBytes();
              setSheet(() {
                s.logo = bytes;
                s.showLogo = true;
              });
              onChanged?.call();
            } catch (e) {
              if (ctx2.mounted) _snack(ctx2, '选择图片失败：$e');
            }
          }

          Future<void> editTime() async {
            final d = await showDatePicker(
              context: ctx2,
              initialDate: s.time,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (d == null || !ctx2.mounted) return;
            final t = await showTimePicker(
              context: ctx2,
              initialTime: TimeOfDay(hour: s.time.hour, minute: s.time.minute),
            );
            setSheet(() {
              s.time = DateTime(d.year, d.month, d.day, t?.hour ?? s.time.hour,
                  t?.minute ?? s.time.minute, s.time.second);
              s.showTime = true;
            });
            onChanged?.call();
          }

          Future<void> editPlace() async {
            final hit = await Navigator.of(ctx2).push<PlaceHit>(
              MaterialPageRoute(
                builder: (_) => WatermarkPlacePage(
                  init: s.place,
                  lat: s.lat,
                  lng: s.lng,
                ),
              ),
            );
            if (hit == null || !ctx2.mounted) return;
            setSheet(() {
              s.place = hit.name;
              s.showPlace = true;
              if (hit.lat != null && hit.lng != null) {
                s.lat = hit.lat;
                s.lng = hit.lng;
                s.showLatLng = true;
              }
            });
            onChanged?.call();
          }

          Future<void> editNote() async {
            final ctrl = TextEditingController(text: s.note);
            final ok = await showDialog<bool>(
              context: ctx2,
              builder: (ctx3) => AlertDialog(
                title: const Text('文本'),
                content: TextField(
                  controller: ctrl,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: '可以输入多行，如：\n三号车间设备巡检\n现场已确认',
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx3, false), child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx3, true), child: const Text('确定')),
                ],
              ),
            );
            if (ok != true || !ctx2.mounted) return;
            setSheet(() {
              s.note = ctrl.text.trimRight();
              s.showNote = true;
            });
            onChanged?.call();
          }

          Widget switchRow({
            required IconData icon,
            required String label,
            required bool on,
            required ValueChanged<bool> onToggle,
            String? value,
            VoidCallback? onTap,
            Widget? trailing,
          }) {
            return InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
                child: Row(
                  children: [
                    Icon(icon, size: 19, color: on ? scheme.primary : scheme.outline),
                    const SizedBox(width: 10),
                    Text(label, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        value ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    if (trailing != null) trailing,
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: on,
                        onChanged: (v) {
                          setSheet(() => onToggle(v));
                          onChanged?.call();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx2).viewInsets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx2).size.height * 0.86,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ---------- 头部 ----------
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
                    child: Row(
                      children: [
                        const Text('水印内容',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(ctx2),
                          icon: const Icon(Icons.close, size: 22),
                        ),
                      ],
                    ),
                  ),
                  // ---------- 可滚动的内容 ----------
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        children: [
                          switchRow(
                            icon: Icons.water_drop_outlined,
                            label: '启用水印',
                            on: s.enabled,
                            onToggle: (v) => s.enabled = v,
                            value: s.enabled ? '' : '不加水印',
                          ),
                          const Divider(height: 12),

                          // ---- Logo ----
                          switchRow(
                            icon: Icons.image_outlined,
                            label: 'Logo',
                            on: s.showLogo,
                            onToggle: (v) {
                              s.showLogo = v;
                              if (v && s.logo == null) pickLogo();
                            },
                            value: s.logo == null ? '未上传' : '',
                            trailing: s.logo == null
                                ? null
                                : IconButton(
                                    tooltip: '换一张',
                                    icon: const Icon(Icons.swap_horiz, size: 20),
                                    onPressed: pickLogo,
                                  ),
                          ),
                          if (s.logo == null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(44, 0, 14, 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  onPressed: pickLogo,
                                  icon: const Icon(Icons.upload_file, size: 17),
                                  label: const Text('上传 PNG 图片',
                                      style: TextStyle(fontSize: 12.5)),
                                ),
                              ),
                            ),
                          if (s.logo != null && s.showLogo) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(44, 0, 14, 0),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Image.memory(s.logo!,
                                        height: 34, fit: BoxFit.contain),
                                  ),
                                  const SizedBox(width: 10),
                                  const Text('大小', style: TextStyle(fontSize: 12.5)),
                                  Expanded(
                                    child: Slider(
                                      value: s.logoScale.clamp(0.4, 3.0).toDouble(),
                                      min: 0.4,
                                      max: 3.0,
                                      divisions: 26,
                                      label: '${s.logoScale.toStringAsFixed(1)}×',
                                      onChanged: (v) {
                                        setSheet(() => s.logoScale = v);
                                        onChanged?.call();
                                      },
                                    ),
                                  ),
                                  SizedBox(
                                    width: 36,
                                    child: Text('${s.logoScale.toStringAsFixed(1)}×',
                                        style: const TextStyle(fontSize: 11.5)),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // ---- 时间 ----
                          switchRow(
                            icon: Icons.schedule,
                            label: '时间',
                            on: s.showTime,
                            onToggle: (v) => s.showTime = v,
                            value: '${s.dateText} ${s.clockText}',
                            onTap: editTime,
                          ),

                          // ---- 地点 ----
                          switchRow(
                            icon: Icons.place_outlined,
                            label: '地点',
                            on: s.showPlace,
                            onToggle: (v) => s.showPlace = v,
                            value: s.place.trim().isEmpty ? '未设置，点这里选' : s.place,
                            onTap: editPlace,
                          ),

                          // ---- 经纬度 ----
                          switchRow(
                            icon: Icons.my_location,
                            label: '经纬度',
                            on: s.showLatLng,
                            onToggle: (v) {
                              s.showLatLng = v;
                              if (v && s.lat == null) doLocate();
                            },
                            value: s.latLngText.isEmpty ? '未定位' : s.latLngText,
                            trailing: IconButton(
                              tooltip: '重新定位',
                              icon: const Icon(Icons.refresh, size: 19),
                              onPressed: doLocate,
                            ),
                          ),

                          // ---- 海拔 ----
                          switchRow(
                            icon: Icons.terrain_outlined,
                            label: '海拔',
                            on: s.showAlt,
                            onToggle: (v) {
                              s.showAlt = v;
                              if (v && s.alt == null) doLocate();
                            },
                            value: s.altText.isEmpty ? '未定位' : s.altText,
                          ),

                          // ---- 文本 ----
                          switchRow(
                            icon: Icons.notes_outlined,
                            label: '文本',
                            on: s.showNote,
                            onToggle: (v) => s.showNote = v,
                            value: s.note.trim().isEmpty
                                ? '未填写，点这里输入'
                                : s.note.replaceAll('\n', ' / '),
                            onTap: editNote,
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '开关打开即显示在照片上；点整行可以改内容。\n'
                                '没有定位权限时，地点可以手动输入或从搜索里选。',
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.5,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ---------- 底部 ----------
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx2),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('完成'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

// ============================================================== 地点选择页

/// 地点选择：优先定位，其次地图数据里搜，最后可以手动输入。
///
/// 单独一页而不是弹窗，是因为要放搜索框 + 结果列表 + 键盘，
/// 弹窗里塞这些很容易被输入法挡住（用户明确说过别遮挡）。
class WatermarkPlacePage extends StatefulWidget {
  final String init;
  final double? lat;
  final double? lng;

  const WatermarkPlacePage({
    super.key,
    this.init = '',
    this.lat,
    this.lng,
  });

  @override
  State<WatermarkPlacePage> createState() => _WatermarkPlacePageState();
}

class _WatermarkPlacePageState extends State<WatermarkPlacePage> {
  late final TextEditingController _q = TextEditingController(text: widget.init);
  List<PlaceHit> _hits = const <PlaceHit>[];
  bool _busy = false;
  String? _msg;
  String _current = '';

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// 已有坐标就先把「当前位置」的中文地址取回来当第一候选。
  Future<void> _loadCurrent() async {
    final lat = widget.lat;
    final lng = widget.lng;
    if (lat == null || lng == null) return;
    final a = await wmReverseGeocode(lat, lng);
    if (!mounted) return;
    if (a.isNotEmpty) setState(() => _current = a);
  }

  Future<void> _search() async {
    final key = _q.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final hits = await wmSearchPlaces(key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hits = hits;
      _msg = hits.isEmpty ? '没搜到（可能没网 / 地图服务连不上），可以直接用输入的文字' : null;
    });
  }

  Future<void> _useHere() async {
    final s = WatermarkSettings();
    final ok = await wmLocate(context, s);
    if (!mounted) return;
    if (!ok) return;
    setState(() {
      _current = s.place;
      if (s.place.isNotEmpty) _q.text = s.place;
    });
    if (s.place.isNotEmpty) {
      Navigator.pop(context, PlaceHit(s.place, s.lat, s.lng));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择地点'),
        actions: [
          TextButton.icon(
            onPressed: _useHere,
            icon: const Icon(Icons.my_location, size: 17),
            label: const Text('当前位置'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '搜地点，如：秭归县疾病预防控制中心',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 19),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _search,
                  child: Text(_busy ? '…' : '搜索'),
                ),
              ],
            ),
          ),
          if (_current.isNotEmpty)
            ListTile(
              dense: true,
              leading: Icon(Icons.place, color: scheme.primary, size: 20),
              title: Text(_current, style: const TextStyle(fontSize: 13.5)),
              subtitle: const Text('当前位置', style: TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.pop(
                context,
                PlaceHit(_current, widget.lat, widget.lng),
              ),
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_msg!,
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: _hits.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final h = _hits[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_on_outlined, size: 19),
                  title: Text(h.name, style: const TextStyle(fontSize: 13.5)),
                  subtitle: (h.lat != null && h.lng != null)
                      ? Text(
                          '${h.lat!.toStringAsFixed(5)}, ${h.lng!.toStringAsFixed(5)}',
                          style: const TextStyle(fontSize: 10.5))
                      : null,
                  onTap: () => Navigator.pop(context, h),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    final t = _q.text.trim();
                    if (t.isEmpty) return;
                    Navigator.pop(context, PlaceHit(t, null, null));
                  },
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44)),
                  child: const Text('就用输入的文字（不改经纬度）'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================== 编辑页

class WatermarkEditorPage extends StatefulWidget {
  final List<String> paths;
  final WatermarkSettings settings;

  /// 相机页拍完直接进来时置 true：画面渲染好就自动存一张。
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

  /// 把当前这张照片解码进图片缓存，保证截图时**画面已经画上去**。
  ///
  /// 只等 endOfFrame 不够：手机拍的 4000×3000 照片解码要几百毫秒，
  /// 截早了保存下来的就是一块灰色底。
  Future<void> _precacheCurrent() async {
    if (_isPreviewOnly || !mounted) return;
    try {
      await precacheImage(FileImage(File(_curPath)), context);
    } catch (_) {
      // 解码失败也让后面的截图流程继续（至少水印是画好的）
    }
  }

  /// 拍完直接进来：等照片和解码都排好版，自动存一张。
  Future<void> _autoSaveOnce() async {
    await WidgetsBinding.instance.endOfFrame;
    await _precacheCurrent();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));
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
    await _wmCh.invokeMethod('saveImage', {
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
      if (ok && widget.autoSave) {
        // 拍完自动存完就退回取景页，别把人困在编辑页
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (mounted) Navigator.of(context).maybePop();
      }
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
        await _precacheCurrent();
        if (!mounted) return;
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
          IconButton(
            tooltip: '水印内容',
            onPressed: () => showWatermarkSheet(context, _s, onChanged: () {
              if (mounted) setState(() {});
            }),
            icon: const Icon(Icons.branding_watermark_outlined, size: 21),
          ),
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
                          if (_s.enabled) _watermarkPositioned(canvasH),
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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            color: scheme.surface,
            child: SafeArea(
              top: false,
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
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => showWatermarkSheet(context, _s, onChanged: () {
                            if (mounted) setState(() {});
                          }),
                          icon: const Icon(Icons.tune, size: 18),
                          label: const Text('水印内容'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving || _isPreviewOnly ? null : _saveCurrent,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44)),
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                  if (!_isPreviewOnly && widget.paths.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          onPressed: _saving ? null : _saveAll,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(42)),
                          child: Text('全部保存（${widget.paths.length} 张）'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 水印位置

  Widget _watermarkPositioned(double canvasH) {
    // 边距按画布宽度的 3% 走
    const pad = _canvasW * 0.03;
    // 缩放按**短边**算：竖图水印不至于太小，横图也不至于把画面盖住一半
    final shortSide = canvasH < _canvasW ? canvasH : _canvasW;
    final scale = (shortSide / _baseW).clamp(0.55, 3.2).toDouble();
    return Positioned(
      left: pad,
      bottom: pad,
      child: WmView(s: _s, scale: scale),
    );
  }
}

// ============================================================== 取景页

/// 水印相机主界面。
///
/// * 打开就是取景画面，水印实时叠在左下角（时间每秒自己走）
/// * 底部三键：本地照片 / 快门 / 水印
/// * 「水印」直接进水印内容面板（没有场景模板这一步）
/// * 横屏时水印整体缩小、避让底部按钮栏和安全区
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
  bool _locating = false;
  String? _err;

  /// 每秒把时间拨到「现在」—— 取景页的水印是真实时间。
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

  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    _snack(context, '正在定位…');
    try {
      final ok = await wmLocate(context, _s, onChanged: () {
        if (mounted) setState(() {});
      });
      if (ok && mounted) _snack(context, '定位完成');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---------------------------------------------------------------- 拍照

  Future<void> _shoot() async {
    final c = _cam;
    if (_shooting) return;
    if (c == null || !c.value.isInitialized) {
      _snack(context, '相机还没就绪，稍等一下再按');
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
      _snack(context, '拍照失败：$e');
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
      _snack(context, '选择照片失败：$e');
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: OrientationBuilder(
        builder: (context, orientation) {
          final landscape = orientation == Orientation.landscape;
          return Stack(
            fit: StackFit.expand,
            children: [
              _preview(),
              if (_s.enabled) _watermarkOverlay(landscape),
              _rightRail(landscape),
              _topBar(),
              _bottomBar(landscape),
              if (_err != null) _errorLayer(),
            ],
          );
        },
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

  /// 取景画面上叠加的水印。
  ///
  /// 竖屏贴左下角、躲开底部三键；横屏整体缩到 0.82 倍、抬高一点，
  /// 并且左右各多留一点，避开刘海 / 挖孔 / 手势条。
  Widget _watermarkOverlay(bool landscape) {
    final safe = MediaQuery.of(context).padding;
    final size = MediaQuery.of(context).size;
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.only(
          left: (landscape ? 26 : 16) + safe.left,
          right: (landscape ? 26 : 16) + safe.right,
          bottom: landscape ? 126 : 152,
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: size.width * (landscape ? 0.55 : 0.86),
            ),
            child: WmView(s: _s, scale: landscape ? 0.82 : 1.0),
          ),
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
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
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

  /// 右侧悬浮栏：定位。横屏时往上挪一点，别被底部按钮压住。
  Widget _rightRail(bool landscape) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: EdgeInsets.only(
          right: 10 + MediaQuery.of(context).padding.right,
          bottom: landscape ? 136 : 166,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _roundIcon(Icons.my_location, '取当前地点', _locate, busy: _locating),
          ],
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

  Widget _bottomBar(bool landscape) {
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
            padding: EdgeInsets.fromLTRB(24, landscape ? 10 : 22, 24, 10),
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
                    width: landscape ? 62 : 74,
                    height: landscape ? 62 : 74,
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
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.black54),
                            )
                          : null,
                    ),
                  ),
                ),
                // 右：水印（直接进内容编辑，没有模板这一步）
                _bottomKey(
                  Icons.branding_watermark_outlined,
                  '水印',
                  () => showWatermarkSheet(context, _s, onChanged: () {
                    if (mounted) setState(() {});
                  }),
                ),
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
