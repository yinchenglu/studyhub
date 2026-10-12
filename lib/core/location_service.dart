import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 一次定位结果。
///
/// 对应 `MainActivity.kt` 里 `emitLocation()` 推过来的那个 map。
/// 那边的原则是「只推设备真的有的字段」——
/// `Location.hasAltitude()` / `hasAccuracy()` / `hasSpeed()` / `hasBearing()`
/// 为假时**根本不放这个 key**，而不是放一个 0。
/// 所以这里除了经纬度之外全是可空的：0 米海拔和「不知道海拔」是两回事。
class GeoPoint {
  /// 纬度，正数北纬。
  final double lat;

  /// 经度，正数东经。
  final double lon;

  /// 海拔（米，相对 WGS84 椭球）。
  ///
  /// 多数手机靠 GPS 解算，误差常在 ±10~30 米；带气压计的机型会准一些
  /// （气压计能给到 ±1 米左右的**相对**高度，但需要基准校准）。
  /// 拿不到就是 null —— 不要拿它当「海平面」。
  final double? alt;

  /// 水平精度（米）。含义是「有 68% 概率真值落在这个半径内」。
  /// 数字越小越可信：室外 GPS 一般 3~10，室内网络定位可能上百。
  final double? accuracy;

  /// 速度（米/秒）。静止时可能为 0 或 null。
  final double? speed;

  /// 行进方向（度，正北 0°，顺时针）。
  /// 注意这是**移动方向**，站着不动时它没意义（指南针用的是地磁，不是这个）。
  final double? bearing;

  /// 数据来源：`gps`（卫星）或 `network`（基站 / Wi-Fi）。
  final String provider;

  /// 这个定位结果的时刻（毫秒时间戳，系统时钟）。
  final int time;

  const GeoPoint({
    required this.lat,
    required this.lon,
    this.alt,
    this.accuracy,
    this.speed,
    this.bearing,
    this.provider = '',
    this.time = 0,
  });

  /// 从原生通道推过来的值构造；任何一项离谱就返回 null（宁可丢这一帧）。
  ///
  /// 为什么连经纬度都要校验范围：
  ///   `Location.getLatitude()` 在定位还没收敛时理论上应该是有效值，
  ///   但个别 ROM 在 provider 刚挂上时会推 (0, 0)。
  ///   (0, 0) 在地图上是个真实坐标（几内亚湾），画出来用户会以为 GPS 坏了。
  ///   这里**不**把 (0,0) 当成非法（那也太武断），只是把越界的挡掉。
  static GeoPoint? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lat = _toDouble(raw['lat']);
    final lon = _toDouble(raw['lon']);
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90) return null;
    if (lon < -180 || lon > 180) return null;
    final p = raw['provider'];
    return GeoPoint(
      lat: lat,
      lon: lon,
      alt: _toDouble(raw['alt']),
      accuracy: _toDouble(raw['accuracy']),
      speed: _toDouble(raw['speed']),
      bearing: _toDouble(raw['bearing']),
      provider: p is String ? p : '',
      time: _toInt(raw['time']) ?? 0,
    );
  }

  /// 海拔文本；没有海拔数据时给一句人话，而不是「0 m」。
  String get altText {
    final a = alt;
    if (a == null) return '不可用';
    return '${a.toStringAsFixed(a.abs() >= 100 ? 1 : 2)} m';
  }

  String get accuracyText {
    final a = accuracy;
    if (a == null) return '未知';
    return '±${a.toStringAsFixed(a >= 10 ? 0 : 1)} m';
  }

  String get providerText => provider == 'gps' ? 'GPS 卫星' : '网络（基站 / Wi-Fi）';

  String get timeText {
    if (time <= 0) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(time);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static double? _toDouble(Object? v) {
    if (v is num) {
      final d = v.toDouble();
      return d.isFinite ? d : null;
    }
    return null;
  }

  static int? _toInt(Object? v) => v is num ? v.toInt() : null;
}

/// 定位失败。`code` 就是原生侧 `sink.error()` 的第一个参数。
///
/// 为什么要把 code 单独留出来：三种失败的**处理办法完全不同** ——
///   * `denied`       —— 没权限，得去系统设置里给；
///   * `provider_off` —— 权限有，但系统的定位总开关关着，去设置里打开；
///   * `no_service`   —— 这台设备压根没有定位硬件（车机 / 模拟器）。
/// 混成一句「定位失败」用户不知道该点哪儿。
class GeoError implements Exception {
  final String code;
  final String message;

  const GeoError(this.code, this.message);

  /// 给用户看的中文说明。原生侧已经写好了人话，这里主要补兜底。
  String get hint {
    switch (code) {
      case 'denied':
        return '定位权限没开。点下面的按钮去系统设置里允许「位置信息」。';
      case 'provider_off':
        return '系统的位置开关没打开。下拉通知栏或去「设置 → 位置信息」打开它。';
      case 'no_service':
        return '这台设备没有可用的定位服务，经纬度和海拔拿不到（指南针本身仍然可以用）。';
      default:
        return message.isEmpty ? '定位不可用。' : message;
    }
  }

  /// 要不要给「去设置」按钮。`no_service` 是硬件问题，去了也没用。
  bool get canOpenSettings => code == 'denied' || code == 'provider_off';

  @override
  String toString() => 'GeoError($code): $message';
}

/// Android 定位的 Dart 侧封装。
///
/// 通道名和 `MainActivity.kt` 里的 `LOCATION_CHANNEL` 必须一致：
/// `studyhub/location`，EventChannel。
///
/// 为什么用 EventChannel 而不是「每隔几秒调一次 MethodChannel 问位置」：
///   轮询要么太密（耗电、页面还是卡的），要么太疏（读数一蹦一跳）。
///   EventChannel 是「原生那边有新位置就推」——
///   原生侧直接挂 `requestLocationUpdates`，只在真正变化时过通道，
///   空闲时一次通信都没有。`onListen` 开、`onCancel` 关，
///   页面一退订阅一取消，定位就停了，不用谁去记着关。
class LocationService {
  LocationService._();

  /// 与 `MainActivity.kt` 的 `LOCATION_CHANNEL` 必须逐字一致。
  static const EventChannel _ch = EventChannel('studyhub/location');

  /// 位置流。订阅即开始定位，取消订阅即停止。
  ///
  /// 原生侧的 `sink.error(code, msg, null)` 在这里会变成 [GeoError]
  /// （EventChannel 默认把 error 包成 `PlatformException`，这里转成自己的类型，
  /// 免得调用方到处 `catch (e) { if (e is PlatformException) ... }`）。
  static Stream<GeoPoint> stream() {
    return _ch.receiveBroadcastStream().transform(
          StreamTransformer<Object?, GeoPoint>.fromHandlers(
            handleData: (raw, sink) {
              final p = GeoPoint.fromMap(raw);
              // 解析不出就静默丢掉 —— 丢一帧比把类型错误抛给 UI 强
              if (p != null) sink.add(p);
            },
            handleError: (err, stack, sink) {
              if (err is PlatformException) {
                sink.addError(GeoError(err.code, err.message ?? ''));
              } else {
                sink.addError(GeoError('unknown', '$err'));
              }
            },
          ),
        );
  }

  /// 申请定位权限。
  ///
  /// 用 `Permission.location`（= Android 的 `ACCESS_FINE_LOCATION`，
  /// 也就是「精确位置」）。**不申请** `locationAlways`（后台位置）——
  /// 那需要额外的弹窗说明、上架审核也麻烦，而指南针只在打开页面时用，
  /// 页面在后台时定位本来就该停。
  ///
  /// 失败不抛异常：定位权限被拒是完全正常的用户选择，
  /// 页面要能照常显示（指南针靠地磁，没权限也能转）。
  static Future<bool> ensurePermission() async {
    try {
      if (await Permission.location.isGranted) return true;
      final r = await Permission.location.request();
      return r.isGranted;
    } catch (_) {
      // 非 Android 平台 / 没有这个权限项时走到这里
      return false;
    }
  }

  /// 去系统的应用设置页（用户在弹窗里选了「不再询问」之后的唯一出路）。
  static Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      // 打不开就算了，页面上的文字说明还在。
    }
  }
}
