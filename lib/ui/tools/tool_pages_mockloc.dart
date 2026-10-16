// ============================================================ 虚拟定位 v1.9.0+28
//
// 用户需求：「增加工具：虚拟定位。能够获取手机定位权限。」归类到生活与娱乐。
//
// 实现分两层：
//   * 原生（android_custom/MainActivity.kt 的 `studyhub/mockloc` 通道）
//       - 定位权限：checkSelfPermission / requestPermissions
//       - 模拟位置：LocationManager.addTestProvider + setTestProviderLocation（每秒刷）
//       - 真实定位：getLastKnownLocation（做「以我当前位置为起点」）
//   * Dart（本文件）：UI + 状态 + 错误提示
//
// 关键前提（页面上必须写清楚，否则用户会以为工具坏了）：
//   Android 只允许「被选为模拟位置信息应用」的 App 注入坐标，
//   路径：设置 → 开发者选项 → 选择模拟位置信息应用 → 学聚。
//   没选时原生会回 SecurityException，我们把原因原文 toast 出来。
//
// v1.9.0+32 修「开发者选项的列表里根本找不到学聚」：
//   那个列表筛的是「**清单里声明过 ACCESS_MOCK_LOCATION 的应用**」
//   （AOSP 的 MockLocationAppPreferenceController 遍历已安装应用的
//   requestedPermissions 来筛），而 AndroidManifest.xml 里一直没写这一条，
//   所以用户永远选不到本应用。已在清单里补上 ——
//   注意这条权限本身拿不到（signature 级），它纯粹是「报名」，见清单里的注释。
//   同时本页加了「已选中 / 还没选中」的实时状态（原生读 AppOps），
//   回到前台自动刷新，不用再让用户猜。
//
// 注：本工具只做本地模拟，不上报任何数据；停止模拟时会把 GPS / NETWORK
//     两个 provider 的测试提供者移除，恢复真实定位。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tool_pages.dart';

class MockLocPage extends StatefulWidget {
  const MockLocPage({super.key});

  @override
  State<MockLocPage> createState() => _MockLocPageState();
}

class _MockLocPageState extends State<MockLocPage> with WidgetsBindingObserver {
  static const MethodChannel _ch = MethodChannel('studyhub/mockloc');

  final TextEditingController _lat = TextEditingController(text: '39.9087');
  final TextEditingController _lng = TextEditingController(text: '116.3975');
  final TextEditingController _acc = TextEditingController(text: '5');

  bool _hasPerm = false;

  /// 本应用是不是已经被选为「模拟位置信息应用」（原生读 AppOps 得到）。
  /// v1.9.0+32 新增 —— 用户在这一步最容易卡住。
  bool _selected = false;
  bool _running = false;
  double _curLat = 0, _curLng = 0;
  bool _busy = false;
  String? _lastErr;

  /// 常用地点（纬度, 经度）
  static const Map<String, List<double>> _presets = {
    '北京·天安门': [39.9087, 116.3975],
    '上海·人民广场': [31.2304, 121.4737],
    '广州·广州塔': [23.1066, 113.3245],
    '深圳·市民中心': [22.5431, 114.0579],
    '杭州·西湖': [30.2489, 120.1551],
    '武汉·黄鹤楼': [30.5451, 114.2985],
    '成都·天府广场': [30.6570, 104.0657],
    '西安·钟楼': [34.2610, 108.9423],
    '重庆·解放碑': [29.5576, 106.5772],
    '南京·新街口': [32.0453, 118.7848],
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lat.dispose();
    _lng.dispose();
    _acc.dispose();
    super.dispose();
  }

  /// 用户十有八九是「跳去开发者选项选完再回来」——回到前台就重读一次状态，
  /// 免得页面还在说「还没选中」，其实早就选好了。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('status');
      if (!mounted || r == null) return;
      setState(() {
        _hasPerm = r['hasPermission'] == true;
        _selected = r['selected'] == true;
        _running = r['running'] == true;
        _curLat = (r['lat'] as num?)?.toDouble() ?? 0;
        _curLng = (r['lng'] as num?)?.toDouble() ?? 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastErr = '$e');
    }
  }

  Future<void> _askPermission() async {
    try {
      await _ch.invokeMethod<bool>('requestPermission');
      // 系统弹窗是异步的，等 1 秒再读状态（不给用户错觉「点了没反应」）
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await _refresh();
      if (mounted) {
        toast(context, _hasPerm ? '已获得定位权限' : '还没给权限，请在弹出的系统窗口里点「允许」');
      }
    } catch (e) {
      if (mounted) toast(context, '申请权限失败：$e');
    }
  }

  Future<void> _start() async {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (lat == null || lng == null) {
      toast(context, '经纬度要填数字');
      return;
    }
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      toast(context, '纬度 -90~90，经度 -180~180');
      return;
    }
    final acc = double.tryParse(_acc.text.trim()) ?? 5;

    // 没被选为「模拟位置信息应用」的话，这条正路必然失败 —— 先说清楚，
    // 别让用户对着一句干巴巴的 SecurityException 发懵。
    // 但也不硬拦：个别定制 ROM 的 AppOps 读不准，留一条「仍然尝试」的路。
    if (!_selected) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('还没选「学聚」为模拟位置应用'),
          content: const Text(
            'Android 要求先到「开发者选项 → 选择模拟位置信息应用」里选中「学聚」，'
            '否则注入坐标会被系统直接拒绝。\n\n'
            '如果那个列表里根本没有「学聚」，说明装的是旧版本 —— '
            '旧包没向系统报名，装 1.9.0+32 及以后的版本就会出现。\n\n'
            '要现在去开发者选项吗？',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('仍然尝试'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (go == true) {
        await _openDev();
        return;
      }
    }

    setState(() {
      _busy = true;
      _lastErr = null;
    });
    try {
      await _ch.invokeMethod<bool>('start', {
        'lat': lat,
        'lng': lng,
        'acc': acc,
      });
      await _refresh();
      setState(() => _busy = false);
      if (mounted) {
        toast(context, '模拟定位已开启：$lat, $lng');
      }
    } on PlatformException catch (e) {
      setState(() {
        _busy = false;
        _lastErr = e.message ?? e.code;
      });
      if (mounted) toast(context, e.message ?? '开启失败');
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) toast(context, '开启失败：$e');
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await _ch.invokeMethod<bool>('stop');
      await _refresh();
      setState(() => _busy = false);
      if (mounted) toast(context, '已停止模拟，恢复真实定位');
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) toast(context, '停止失败：$e');
    }
  }

  /// 拿真实定位填进输入框（做「以我现在的位置为起点」）
  Future<void> _useReal() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('realLocation');
      if (!mounted) return;
      if (r == null || r['ok'] != true) {
        toast(context, (r?['msg'] as String?) ?? '拿不到当前定位');
        return;
      }
      final lat = (r['lat'] as num).toDouble();
      final lng = (r['lng'] as num).toDouble();
      setState(() {
        _lat.text = lat.toStringAsFixed(6);
        _lng.text = lng.toStringAsFixed(6);
        final a = (r['accuracy'] as num?)?.toDouble();
        if (a != null && a > 0) _acc.text = a.toStringAsFixed(0);
      });
      toast(context, '已填入当前定位');
    } catch (e) {
      if (mounted) toast(context, '获取当前定位失败：$e');
    }
  }

  Future<void> _openDev() async {
    try {
      await _ch.invokeMethod<bool>('openDevOptions');
    } catch (_) {}
  }

  void _pick(String name, List<double> l) {
    setState(() {
      _lat.text = l[0].toStringAsFixed(6);
      _lng.text = l[1].toStringAsFixed(6);
    });
    toast(context, '已选：$name');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '虚拟定位',
      subtitle: _running
          ? '模拟中 · ${_curLat.toStringAsFixed(5)}, ${_curLng.toStringAsFixed(5)}'
          : '把本机定位改成你指定的坐标',
      actions: [
        IconButton(
          tooltip: '刷新状态',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          // ---------- 状态 ----------
          Card(
            margin: EdgeInsets.zero,
            color: _running
                ? cs.primaryContainer.withValues(alpha: 0.5)
                : cs.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _running ? Icons.my_location : Icons.location_searching,
                        color: _running ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _running ? '模拟定位运行中' : '未开启模拟',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _running ? cs.primary : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _running
                        ? '当前对外坐标：${_curLat.toStringAsFixed(6)}, ${_curLng.toStringAsFixed(6)}'
                        : '点下面的「开始模拟」后，其他 App 读到的定位就是你填的坐标',
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _hasPerm ? '定位权限：已授予' : '定位权限：未授予',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _hasPerm ? const Color(0xFF1D9E75) : cs.error,
                    ),
                  ),
                  if (_lastErr != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.errorContainer.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _lastErr!,
                        style: const TextStyle(fontSize: 12.5, height: 1.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ---------- 前提说明 ----------
          const ToolSection('使用前提'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _selected ? const Color(0xFFE9F7EF) : const Color(0xFFFFF8E6),
              border: Border.all(
                  color: _selected ? const Color(0xFFB7E1C6) : const Color(0xFFF2E0B0)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _selected ? Icons.check_circle_outline : Icons.error_outline,
                      size: 16,
                      color: _selected ? const Color(0xFF1D9E75) : const Color(0xFFB7791F),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _selected ? '已选中「学聚」为模拟位置应用' : '还没把「学聚」选为模拟位置应用',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _selected ? const Color(0xFF16694F) : const Color(0xFF7A5C1E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _selected
                      ? 'Android 只允许「被选为模拟位置信息应用」的 App 修改定位，这一关已经过了 —— '
                          '填好坐标点「开始模拟」就行。'
                      : 'Android 只允许「被选为模拟位置信息应用」的 App 修改定位。\n'
                          '路径：设置 → 开发者选项 → 选择模拟位置信息应用 → 学聚。\n\n'
                          '列表里看不到「学聚」怎么办：说明装的是旧版本 —— '
                          '旧包没向系统报名，装 1.9.0+32 及以后的版本就会有；'
                          '装完重新打开一次开发者选项页面即可。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: _selected ? const Color(0xFF16694F) : const Color(0xFF7A5C1E),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openDev,
                  icon: const Icon(Icons.developer_mode, size: 17),
                  label: const Text('开发者选项', style: TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('刷新状态', style: TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _askPermission,
                  icon: const Icon(Icons.verified_user_outlined, size: 17),
                  label: const Text('定位权限', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),

          // ---------- 坐标 ----------
          const ToolSection('坐标'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: '纬度 lat',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _lng,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: '经度 lng',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _acc,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '精度（米，越小越「准」）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _useReal,
                  icon: const Icon(Icons.pin_drop_outlined, size: 18),
                  label: const Text('用我的当前定位'),
                ),
              ),
            ],
          ),

          // ---------- 常用地点 ----------
          const ToolSection('常用地点'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _presets.entries)
                ActionChip(
                  label: Text(e.key),
                  onPressed: () => _pick(e.key, e.value),
                ),
            ],
          ),

          // ---------- 开关 ----------
          const ToolSection('开始 / 停止'),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始模拟'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || !_running ? null : _stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止模拟'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '· 停止模拟会把 GPS / 网络定位的模拟提供者移除，恢复真实定位。\n'
            '· 重启手机后模拟会自动失效，需要重新点「开始模拟」。\n'
            '· 部分 App 用高德 / 腾讯定位 SDK 且做校验，可能不受影响（属正常现象）。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
        ],
      ),
    );
  }
}
