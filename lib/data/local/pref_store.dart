import 'package:flutter/services.dart';

/// 本地键值存储 —— `shared_preferences` 插件的**平替实现**（v2.0.0+49）。
///
/// ## 为什么不再用官方插件
///
/// 插件由两半组成：Dart 侧（pub 包里的 pigeon 绑定）和 Android 侧
/// （Kotlin 实现）。两半的方法签名必须**严格一一对应**。本仓库的
/// `pubspec.lock` 不入库，CI 每次构建都重新解析 `^2.3.2`，只要 pub 解析出
/// 「Dart 新、原生旧」这样的组合，运行期就会直接抛：
///
/// ```
/// NoSuchMethodError: no non-static method
///   Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;
///   .getAll(Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;
/// ```
///
/// 而这一步正好在启动最早的 `SettingsStore.init()` 里，所以表现是**白屏**。
///
/// ## 现在的做法
///
/// 走自家原生通道 `studyhub/prefs`（见 `android_custom/MainActivity.kt`），
/// 底层仍然写系统 SharedPreferences，文件名 `FlutterSharedPreferences`、
/// 键名前缀 `flutter.` 都沿用插件的历史约定 —— 所以**老数据原样还在**，
/// 不需要迁移，也不会丢。
///
/// ## 用法与插件完全一致
///
/// ```dart
/// final sp = await SharedPreferences.getInstance();
/// final v = sp.getString('xxx');          // getter 同步读内存缓存
/// await sp.setString('xxx', 'yyy');       // setter 异步落盘
/// ```
///
/// getter 之所以能同步，是因为 [getInstance] 时已经把全量键值读进内存；
/// setter 先更新内存再写盘，读自己的写立刻可见。
class SharedPreferences {
  SharedPreferences._(this._cache);

  /// 通道名必须和 MainActivity.kt 里的 `PREFS_CHANNEL` 一致。
  static const MethodChannel _ch = MethodChannel('studyhub/prefs');

  static SharedPreferences? _inst;
  static Future<SharedPreferences>? _loading;

  final Map<String, Object?> _cache;

  /// 单例。并发调用只会真正加载一次（第二个调用拿到同一个 Future）。
  static Future<SharedPreferences> getInstance() {
    final cached = _inst;
    if (cached != null) return Future<SharedPreferences>.value(cached);
    return _loading ??= _load();
  }

  static Future<SharedPreferences> _load() async {
    final data = await _readAll();
    final p = SharedPreferences._(data);
    _inst = p;
    _loading = null;
    return p;
  }

  static Future<Map<String, Object?>> _readAll() async {
    try {
      final raw = await _ch.invokeMapMethod<String, Object?>('getAll');
      if (raw == null) return <String, Object?>{};
      return Map<String, Object?>.from(raw);
    } catch (_) {
      // 通道不可用（非 Android 平台、或原生侧没注册）时退化成纯内存存储。
      // 宁可这次不落盘，也不能让启动流程挂掉。
      return <String, Object?>{};
    }
  }

  // ---------- 读（同步，走内存缓存）----------

  Set<String> getKeys() => _cache.keys.toSet();

  bool containsKey(String key) => _cache.containsKey(key);

  String? getString(String key) {
    final v = _cache[key];
    return v is String ? v : null;
  }

  bool? getBool(String key) {
    final v = _cache[key];
    return v is bool ? v : null;
  }

  int? getInt(String key) {
    final v = _cache[key];
    if (v is int) return v;
    // 原生侧 SharedPreferences 里整数可能是 Long，经过通道会变成 int；
    // double 之类也顺手兜一下，避免调用方拿到 null。
    if (v is num) return v.toInt();
    return null;
  }

  double? getDouble(String key) {
    final v = _cache[key];
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return null;
  }

  List<String>? getStringList(String key) {
    final v = _cache[key];
    if (v is List) return v.map((e) => e.toString()).toList(growable: true);
    return null;
  }

  // ---------- 写（先改内存，再异步落盘）----------

  Future<bool> setString(String key, String value) => _put(key, value);

  Future<bool> setBool(String key, bool value) => _put(key, value);

  Future<bool> setInt(String key, int value) => _put(key, value);

  Future<bool> setDouble(String key, double value) => _put(key, value);

  Future<bool> setStringList(String key, List<String> value) =>
      _put(key, value);

  Future<bool> _put(String key, Object value) async {
    _cache[key] = value;
    try {
      await _ch.invokeMethod<bool>('set', <String, Object?>{
        'key': key,
        'value': value,
      });
    } catch (_) {
      // 写失败不影响本次会话（内存里已经是最新值），下次读仍是新值。
    }
    return true;
  }

  Future<bool> remove(String key) async {
    _cache.remove(key);
    try {
      await _ch.invokeMethod<bool>('remove', <String, Object?>{'key': key});
    } catch (_) {}
    return true;
  }

  Future<bool> clear() async {
    _cache.clear();
    try {
      await _ch.invokeMethod<bool>('clear');
    } catch (_) {}
    return true;
  }

  /// 从原生侧重新读一遍全量值（插件同名 API，目前没有调用方，留着保接口完整）。
  Future<void> reload() async {
    final data = await _readAll();
    _cache
      ..clear()
      ..addAll(data);
  }

  /// 单元测试用：直接灌初始值，不碰原生通道。
  static void setMockInitialValues(Map<String, Object> values) {
    _inst = SharedPreferences._(Map<String, Object?>.from(values));
    _loading = null;
  }
}
