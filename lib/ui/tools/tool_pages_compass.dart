import 'dart:async';
import 'dart:math' as math;
// FontFeature 是 dart:ui 的类。material.dart **不保证**把它带出来 ——
// tool_pages_v15.dart 里就为这件事留过说明，这里照做，别赌。
// 只 show FontFeature，免得把 dart:ui 的 TextDirection 也带进来
// （会和 material 的同名类打架，虽然本文件只用 TextDirection.ltr）。
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/location_service.dart';
import 'tool_pages.dart';

/// 指南针
///
/// 用户第 1 条第 ⑤ 项：「指南针：带经纬度，并且点击可以复制。带海拔高度识别。」
///
/// 页面里有**两套完全独立**的数据，来源不一样，千万别混：
///
///   1. **方向（方位角）** —— 来自地磁传感器 + 加速度计，**不用联网、不要权限**。
///      所以哪怕用户拒绝定位、或者飞行模式，罗盘照样转。
///      这也是为什么定位那一块失败时整个页面不该报错。
///
///   2. **经纬度 / 海拔 / 精度** —— 来自定位（Android 的 `LocationManager`），
///      走 `studyhub/location` EventChannel，要权限也真的要能收到卫星。
///
/// ── 方位角为什么不能只读磁力计 ──────────────────────────
/// 手机平放时确实 `atan2(-Hx, Hy)` 就够了。但人不会一直平放着看指南针 ——
/// 举起来斜着看是常态。一倾斜，磁力计的 x/y 分量就混进了重力方向的分量，
/// 读数会偏几十度，而且是**系统性**偏（不抖，所以看着像真的，最坑）。
///
/// 正确做法是先用重力把磁场向量「转平」再算角度。这里直接照搬 Android
/// 自己的 `SensorManager.getRotationMatrix()` 那套（AOSP 源码就是这么写的）：
///
///     H  = normalize(磁场 × 重力)      ← 指向「东」的向量
///     M' = 重力 × H                    ← 与重力、东都垂直 ⇒ 指向「北」
///     方位角 = atan2(H.y, M'.y)
///
/// 平放时它化简成 `atan2(-Hx, Hy)`，与直觉一致（见 `_headingFrom` 的注释）。
/// 好处是拿真机之前就能用纸笔验算，而不是等上机再试符号。
///
/// ── 关于「校准」 ────────────────────────────────────────
/// 手机磁力计受周围铁磁物影响（磁吸支架、喇叭、汽车 A 柱）会有硬磁偏差，
/// 表现为**数值稳定但差一个固定角度**。这是硬件问题，App 修不了 ——
/// 只能提示用户「拿手机在空中画几个 8 字」。页面底部有这条提示，
/// 并且用磁场总强度做一个粗判断：不在 25~65 µT 之间就明显有问题。
class CompassPage extends StatefulWidget {
  const CompassPage({super.key});

  @override
  State<CompassPage> createState() => _CompassPageState();
}

class _CompassPageState extends State<CompassPage> {
  // ---------------- 传感器 ----------------
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<AccelerometerEvent>? _accSub;

  double _mx = 0, _my = 0, _mz = 0; // 最新磁场（µT）
  double _ax = 0, _ay = 0, _az = 0; // 最新加速度（含重力，m/s²）
  bool _hasMag = false;
  bool _hasAcc = false;
  String? _sensorErr;

  /// 平滑后的方位角（0~360）。null 表示还没算出第一帧。
  double? _heading;

  /// 用「单位圆上做指数平滑」而不是直接对角度做平滑。
  /// 直接对角度平滑的经典 bug：359° 和 1° 平均出来是 180°（正好南辕北辙）。
  /// 先转成 (sin, cos) 再各自平滑，就没有跳变问题。
  double _sinS = 0;
  double _cosS = 0;
  bool _seeded = false;

  /// 手机倾斜角（0 = 完全平放）。超过 60° 时提示用户平放会更准。
  double _tilt = 0;

  // ---------------- 定位 ----------------
  StreamSubscription<GeoPoint>? _geoSub;
  GeoPoint? _pt;
  GeoError? _geoErr;
  bool _permDenied = false;

  @override
  void initState() {
    super.initState();
    // 看指南针时屏幕灭了最烦（还得多按一下才亮）
    keepScreenOn(true);
    _listenSensors();
    _startLocation();
  }

  @override
  void dispose() {
    _magSub?.cancel();
    _accSub?.cancel();
    _geoSub?.cancel();
    keepScreenOn(false);
    super.dispose();
  }

  // ==================================================== 传感器

  void _listenSensors() {
    try {
      _magSub = magnetometerEventStream(samplingPeriod: const Duration(milliseconds: 100))
          .listen(
        (e) {
          _mx = e.x;
          _my = e.y;
          _mz = e.z;
          _hasMag = true;
          _recalc();
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() => _sensorErr = '读不到磁力计：$e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      _sensorErr = '这台设备没有磁力计，方向读不出来：$e';
    }

    try {
      _accSub = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 100))
          .listen(
        (e) {
          _ax = e.x;
          _ay = e.y;
          _az = e.z;
          _hasAcc = true;
          _recalc();
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() => _sensorErr = '读不到加速度计：$e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      _sensorErr = '这台设备没有加速度计，方向读不出来：$e';
    }
  }

  void _recalc() {
    if (!_hasMag || !_hasAcc) return;

    // 倾斜角：重力方向与设备 z 轴（屏幕法线）的夹角
    final g = math.sqrt(_ax * _ax + _ay * _ay + _az * _az);
    var tilt = 0.0;
    if (g > 0.01) {
      final cz = (_az / g).clamp(-1.0, 1.0).toDouble();
      tilt = math.acos(cz) * 180 / math.pi;
    }

    final h = _headingFrom(_mx, _my, _mz, _ax, _ay, _az);
    if (!mounted) return;

    if (h == null) {
      // 磁场和重力几乎共线（比如贴着磁铁），这一刻算不出方向，保留上一帧
      setState(() => _tilt = tilt);
      return;
    }

    final r = h * math.pi / 180;
    final s = math.sin(r);
    final c = math.cos(r);
    if (!_seeded) {
      _seeded = true;
      _sinS = s;
      _cosS = c;
    } else {
      const k = 0.22; // 平滑系数：小一点更稳、大一点跟手
      _sinS = _sinS * (1 - k) + s * k;
      _cosS = _cosS * (1 - k) + c * k;
    }
    var deg = math.atan2(_sinS, _cosS) * 180 / math.pi;
    if (deg < 0) deg += 360;
    if (deg >= 360) deg -= 360;

    setState(() {
      _heading = deg;
      _tilt = tilt;
    });
  }

  /// 由磁场 + 重力算方位角。算不出来返回 null。
  ///
  /// 与 AOSP `SensorManager.getRotationMatrix` / `getOrientation` 完全同构：
  ///   H  = normalize(M × A)    → 水平面内的「东」
  ///   M' = A × H               → 水平面内的「北」（A、H 都是单位向量且互相垂直，
  ///                              所以 A × H 本身就是单位长度，不用再归一化）
  ///   azimuth = atan2(H.y, M'.y)
  ///
  /// 平放验算（屏幕朝天，A = (0, 0, +g)）：
  ///   H = (My, -Mx, 0) / s，M' = (Mx, My, 0) / s，s = √(Mx²+My²)
  ///   ⇒ azimuth = atan2(-Mx, My)
  ///   手机顶部指北 ⇒ 磁场在设备系里就是 (0, +H, ·) ⇒ atan2(0, H) = 0° ✓
  ///   手机顶部指东 ⇒ 北在设备左手边 ⇒ (-H, 0, ·)   ⇒ atan2(H, 0) = 90° ✓
  ///
  /// 静态方法（不碰实例状态）纯粹是为了能单独验算 —— 它没有任何依赖。
  static double? headingFrom(
    double mx, double my, double mz,
    double ax, double ay, double az,
  ) {
    final m = _unit(mx, my, mz);
    final a = _unit(ax, ay, az);
    if (m == null || a == null) return null;

    // ★ v1.5.0 修的一个静默错答：
    //   手机顶边**几乎竖直**时（重力几乎全落在设备 +y 轴上），
    //   「顶边指向哪个方位」在数学上根本没有定义 —— 顶边在水平面上的投影长度趋近 0，
    //   于是 h[1] 与 mp[1] 双双变成 ±0.0，`atan2(0.0, -0.0)` 在 IEEE 里的取值是
    //   **π 而不是 0**，页面就会稳稳地报出「正南 180°」，看起来像个正常读数。
    //
    //   真机几乎撞不上（传感器总有噪声），但恰好量到 (0, ±g, 0) 时，
    //   指着正南比指着「不知道」更糟 —— 用户会照着它走反方向。
    //   这里按顶边偏离竖直的程度判退化：水平投影长度 < 1e-6 就当不知道。
    //   （1 - a[1]² 就是水平投影长度的平方；用平方是为了少开一次根号。）
    if (1 - a[1] * a[1] < 1e-12) return null;

    // H = M × A
    final h = _unit(
      m[1] * a[2] - m[2] * a[1],
      m[2] * a[0] - m[0] * a[2],
      m[0] * a[1] - m[1] * a[0],
    );
    if (h == null) return null;
    // M' = A × H
    final mp = _unit(
      a[1] * h[2] - a[2] * h[1],
      a[2] * h[0] - a[0] * h[2],
      a[0] * h[1] - a[1] * h[0],
    );
    if (mp == null) return null;
    var deg = math.atan2(h[1], mp[1]) * 180 / math.pi;
    if (deg < 0) deg += 360;
    if (deg >= 360) deg -= 360;
    return deg;
  }

  /// 上面的实例版本，转发到静态方法（让页面代码短一点）。
  double? _headingFrom(
    double mx, double my, double mz,
    double ax, double ay, double az,
  ) =>
      headingFrom(mx, my, mz, ax, ay, az);

  static List<double>? _unit(double x, double y, double z) {
    final n = math.sqrt(x * x + y * y + z * z);
    if (!n.isFinite || n < 1e-6) return null;
    return <double>[x / n, y / n, z / n];
  }

  /// 磁场总强度（µT）。地表正常值约 25~65，明显偏离就说明附近有铁磁干扰。
  double get _fieldStrength => math.sqrt(_mx * _mx + _my * _my + _mz * _mz);

  // ==================================================== 定位

  Future<void> _startLocation() async {
    final granted = await LocationService.ensurePermission();
    if (!mounted) return;
    setState(() {
      _permDenied = !granted;
      _geoErr = null;
    });

    await _geoSub?.cancel();
    // 没权限也照样订阅：原生侧会回一个 `denied` 错误，
    // 走统一的错误显示路径，这里就不用维护两套提示逻辑。
    _geoSub = LocationService.stream().listen(
      (p) {
        if (!mounted) return;
        setState(() {
          _pt = p;
          _geoErr = null;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _geoErr = e is GeoError ? e : GeoError('unknown', '$e');
        });
      },
      cancelOnError: false,
    );
  }

  // ==================================================== 展示用文本

  static const List<String> _dirs8 = <String>[
    '北', '东北', '东', '东南', '南', '西南', '西', '西北',
  ];

  /// 方位角 → 八方位名。用「区间中点最近」的写法：
  /// 北 = [337.5, 22.5)，其余每 45° 一格。
  static String cardinal(double deg) {
    final i = (((deg + 22.5) % 360) ~/ 45) % 8;
    return _dirs8[i];
  }

  /// 十进制度 → 度分秒。`116.397477, true` → `116°23′50.9″E`
  static String dms(double v, bool isLat) {
    final hemi = isLat ? (v >= 0 ? 'N' : 'S') : (v >= 0 ? 'E' : 'W');
    final a = v.abs();
    var d = a.floor();
    var m = ((a - d) * 60).floor();
    var s = (a - d - m / 60) * 3600;
    // 四舍五入到 0.1″ 之后可能会出现 60.0 —— 得往上一级进位，
    // 否则会出现「116°59′60.0″」这种东西。
    if (s >= 59.95) {
      s = 0;
      m += 1;
    }
    if (m >= 60) {
      m = 0;
      d += 1;
    }
    return '$d°$m′${s.toStringAsFixed(1)}″$hemi';
  }

  String get _allText {
    final b = StringBuffer();
    final h = _heading;
    b.writeln('方向：${h == null ? '—' : '${h.toStringAsFixed(0)}° ${cardinal(h)}'}');
    final p = _pt;
    if (p != null) {
      b.writeln('纬度：${p.lat.toStringAsFixed(6)}  (${dms(p.lat, true)})');
      b.writeln('经度：${p.lon.toStringAsFixed(6)}  (${dms(p.lon, false)})');
      b.writeln('海拔：${p.altText}');
      b.writeln('精度：${p.accuracyText}');
      b.writeln('来源：${p.providerText}');
    } else {
      b.writeln('经纬度：还没拿到');
    }
    return b.toString().trimRight();
  }

  // ==================================================== 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = _heading;

    return ToolScaffold(
      title: '指南针',
      subtitle: '方向 + 经纬度 + 海拔',
      actions: [
        IconButton(
          tooltip: '复制全部数据',
          onPressed: () => copyText(context, _allText),
          icon: const Icon(Icons.copy_all_outlined),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_sensorErr != null) _warn(scheme, _sensorErr!),

          // ---------------- 罗盘 ----------------
          Center(
            child: SizedBox(
              width: 286,
              height: 286,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size.square(286),
                    painter: CompassDialPainter(
                      heading: h ?? 0,
                      // 还没拿到方向时把刻度盘画淡一点，别让人以为已经准了
                      dim: h == null,
                      face: scheme.surfaceContainerHighest,
                      rim: scheme.primary,
                      tick: scheme.onSurfaceVariant,
                      label: scheme.onSurface,
                      north: scheme.error,
                      index: scheme.primary,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        h == null ? '--' : h.toStringAsFixed(0),
                        style: TextStyle(
                          fontSize: 56,
                          height: 1.0,
                          fontWeight: FontWeight.w300,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: scheme.onSurface,
                        ),
                      ),
                      Text('°',
                          style: TextStyle(fontSize: 18, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(
                        h == null ? '方向读取中' : cardinal(h),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: h == null ? scheme.onSurfaceVariant : scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          if (_hasMag && _hasAcc && _heading == null)
            _hint(scheme, '磁场读数异常（可能贴着磁铁或金属），方向暂时算不出来。'),

          if (_tilt > 60 && _heading != null)
            _hint(scheme, '手机倾斜 ${_tilt.toStringAsFixed(0)}°，已经做了倾斜补偿，'
                '但平放时读数最稳。'),

          const SizedBox(height: 6),

          // ---------------- 定位 ----------------
          ToolSection('定位'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: _geoRows(context, scheme),
              ),
            ),
          ),

          if (_geoErr != null) ...[
            const SizedBox(height: 10),
            _warn(scheme, _geoErr!.hint),
            if (_geoErr!.canOpenSettings || _permDenied)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => LocationService.openSettings(),
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        label: const Text('去系统设置'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _startLocation,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
          ],

          const SizedBox(height: 14),

          // ---------------- 说明 ----------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: scheme.primary),
                      const SizedBox(width: 7),
                      Text('怎么看这些数',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _note('方向靠手机里的磁力计，**不需要联网、也不需要定位权限**；'
                      '换成飞行模式它照样转。'),
                  _note('经纬度和海拔才是定位给的。室内常常只有「网络定位」，'
                      '精度可能上百米，海拔更是基本没有 —— 走到窗边或室外会明显变好。'),
                  _note('海拔多数机型靠 GPS 解算，误差常在 ±10~30 米，'
                      '带气压计的机型会准些。拿不到就显示「不可用」，'
                      '它**不会**拿 0 来冒充海平面。'),
                  _note('如果方向差一个固定角度（不是抖，是一直偏）：'
                      '多半是磁吸支架 / 扬声器 / 金属壳干扰了磁力计。'
                      '把手机拿在空中画几个「8」字再试。'),
                  if (_hasMag)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '当前磁场强度 ${_fieldStrength.toStringAsFixed(1)} µT'
                        '${_fieldStrength < 25 || _fieldStrength > 65 ? '（偏离地表正常范围 25~65，附近可能有铁磁干扰）' : '（正常）'}',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 定位那几行。放在单独方法里是因为 build 已经够长了。
  List<Widget> _geoRows(BuildContext context, ColorScheme scheme) {
    final p = _pt;
    if (p == null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
              ),
              const SizedBox(width: 11),
              Text(_permDenied ? '没有定位权限，拿不到经纬度 / 海拔' : '正在获取位置…',
                  style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ];
    }
    return <Widget>[
      _geoRow(context, '纬度', '${p.lat.toStringAsFixed(6)}', dms(p.lat, true)),
      _geoRow(context, '经度', '${p.lon.toStringAsFixed(6)}', dms(p.lon, false)),
      _geoRow(context, '海拔', p.altText, null),
      _geoRow(context, '水平精度', p.accuracyText, null),
      _geoRow(context, '数据来源', p.providerText, null),
      _geoRow(context, '更新时间', p.timeText, null,
          copyable: false, last: true),
    ];
  }

  Widget _geoRow(
    BuildContext context,
    String label,
    String value,
    String? sub, {
    bool copyable = true,
    bool last = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = sub == null ? value : '$value    $sub';
    return Column(
      children: [
        InkWell(
          onTap: copyable ? () => copyText(context, value) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(label,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 14.5,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (copyable)
                  Icon(Icons.copy, size: 14, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ],
    );
  }

  Widget _warn(ColorScheme scheme, String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onErrorContainer)),
      );

  Widget _hint(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant)),
      );

  /// 说明段落。`**粗体**` 手写成两段 TextSpan —— 只为这么几行引 markdown 包不值。
  Widget _note(String text) {
    final scheme = Theme.of(context).colorScheme;
    final parts = text.split('**');
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(
        text: parts[i],
        style: TextStyle(
          fontWeight: i.isOdd ? FontWeight.w600 : FontWeight.normal,
          color: i.isOdd ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· ', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          Expanded(
            child: Text.rich(TextSpan(
              style: TextStyle(fontSize: 12.5, height: 1.7, color: scheme.onSurfaceVariant),
              children: spans,
            )),
          ),
        ],
      ),
    );
  }
}

/// 罗盘刻度盘。
///
/// 用**转盘式**而不是指针式：刻度盘整体反向转 `heading` 度，
/// 顶上那个小三角是「手机顶部指向」的固定基准线。
/// 这样「把北转到该在的位置」这件事由刻度盘完成，
/// 用户看顶部基准线对着哪个数字就知道朝向 —— 和航海罗盘一个逻辑。
///
/// 为什么方位字要单独按角度算位置、再竖直画：
///   如果直接 `canvas.rotate()` 之后画字，转到 180° 时「南」就是**倒的**，
///   转到 90° 时「东」是躺着的。真实罗盘确实这样，但屏幕上很难读。
///   所以刻度线跟着转，字只跟着**挪位置**、始终正着。
class CompassDialPainter extends CustomPainter {
  final double heading;
  final bool dim;

  final Color face;
  final Color rim;
  final Color tick;
  final Color label;
  final Color north;
  final Color index;

  const CompassDialPainter({
    required this.heading,
    required this.face,
    required this.rim,
    required this.tick,
    required this.label,
    required this.north,
    required this.index,
    this.dim = false,
  });

  static const List<String> _labels8 = <String>[
    '北', '东北', '东', '东南', '南', '西南', '西', '西北',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 14;
    if (r <= 4) return;

    // 透明度统一在这里乘。
    // 注意：**不要**去读 `face.a` 再乘 —— Color 的 .a / .r / .g / .b 这几个
    // double 分量虽然新版 Flutter 有，但这个项目里别处一次都没用过，
    // 拿不到真机编译验证的东西不赌。传进来的颜色只当作「基色」，
    // 所有 alpha 都由下面这几个常数决定。
    final k = dim ? 0.45 : 1.0;

    // 盘面
    canvas.drawCircle(c, r, Paint()..color = face.withValues(alpha: 0.55 * k));

    // 外圈
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = rim.withValues(alpha: 0.6 * k),
    );

    // 刻度：每 5° 一条，15° 加长，45°（八个方位）最长
    for (var deg = 0; deg < 360; deg += 5) {
      final a = (deg - heading) * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      final major = deg % 45 == 0;
      final mid = deg % 15 == 0;
      final len = major ? 13.0 : (mid ? 8.5 : 4.5);
      final p1 = c + dir * (r - 2.5);
      final p2 = c + dir * (r - 2.5 - len);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = major ? 2.2 : (mid ? 1.3 : 0.9)
          ..color = (major && deg == 0 ? north : tick)
              .withValues(alpha: (major ? 0.95 : 0.5) * k),
      );
    }

    // 八个方位字，竖直绘制
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < 8; i++) {
      final deg = i * 45.0;
      final a = (deg - heading) * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      final pos = c + dir * (r - 34);
      final isNorth = i == 0;
      tp.text = TextSpan(
        text: _labels8[i],
        style: TextStyle(
          fontSize: isNorth ? 17 : 13,
          fontWeight: isNorth ? FontWeight.w700 : FontWeight.w500,
          color: (isNorth ? north : label).withValues(alpha: (isNorth ? 1.0 : 0.82) * k),
        ),
      );
      tp.layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }

    // 北针：在「北」的位置画一个指外的小红三角
    {
      final a = (0 - heading) * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      final tip = c + dir * (r - 5);
      final base = c + dir * (r - 17);
      final perp = Offset(-dir.dy, dir.dx) * 6.5;
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(base.dx + perp.dx, base.dy + perp.dy)
        ..lineTo(base.dx - perp.dx, base.dy - perp.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = north.withValues(alpha: k));
    }

    // 顶部固定基准三角（指向盘内）
    {
      final tip = Offset(c.dx, c.dy - r + 3);
      final base = Offset(c.dx, c.dy - r - 11);
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(base.dx + 7, base.dy)
        ..lineTo(base.dx - 7, base.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = index.withValues(alpha: k));
    }
  }

  @override
  bool shouldRepaint(CompassDialPainter old) =>
      old.heading != heading ||
      old.dim != dim ||
      old.face != face ||
      old.rim != rim ||
      old.tick != tick ||
      old.label != label ||
      old.north != north ||
      old.index != index;
}
