import 'dart:math' as math;
// FontFeature 是 dart:ui 的类。material.dart 不一定把它带出来，
// 显式 import 一次最稳（同一元素重复导入不冲突）。
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/permissions.dart';
import 'tool_pages.dart';

// ===========================================================================
// v1.5.0 新增工具（第一批）
//
// 这一批全都是「纯本地逻辑」：不联网、不申请权限、不引第三方包。
// 项目对依赖极其敏感（历史上几次云端构建翻车都是加包引起的），
// 所以凡是能自己算的都自己算，pubspec 保持零变更。
//
//   * CidrCalcPage           CIDR 子网计算（IPv4 + IPv6）
//   * CoordinateConvertPage  地图坐标转换（WGS84 / GCJ02 / BD09）
// ===========================================================================

/// 结果表格里的一行（左标签、右值）
class _Kv {
  final String k;
  final String v;
  const _Kv(this.k, this.v);
}

/// 统一样式的结果表（各工具复用）
class _KvTable extends StatelessWidget {
  final List<_Kv> rows;
  /// 可复制的那几行（按标签匹配，点一下复制值）
  final Set<String> copyable;
  const _KvTable({required this.rows, this.copyable = const <String>{}});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            InkWell(
              onTap: copyable.contains(rows[i].k)
                  ? () {
                      Clipboard.setData(ClipboardData(text: rows[i].v));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已复制 ${rows[i].v}'), duration: const Duration(seconds: 1)),
                      );
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(rows[i].k,
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: SelectableText(
                        rows[i].v,
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                      ),
                    ),
                    if (copyable.contains(rows[i].k))
                      Icon(Icons.copy_rounded, size: 15, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 2. CIDR 子网计算（IPv4 + IPv6）
// ===========================================================================

/// CIDR 子网掩码计算：输入 192.168.1.10/24 或 2001:db8::1/48，
/// 给出网络号、广播地址、可用范围、主机数、地址类型。
class CidrCalcPage extends StatefulWidget {
  const CidrCalcPage({super.key});

  @override
  State<CidrCalcPage> createState() => _CidrCalcPageState();
}

class _CidrCalcPageState extends State<CidrCalcPage> {
  final _input = TextEditingController(text: '192.168.1.10/24');
  List<_Kv> _rows = const [];
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _calc() {
    final t = _input.text.trim();
    if (t.isEmpty) {
      setState(() {
        _rows = const [];
        _error = null;
      });
      return;
    }
    try {
      setState(() {
        _rows = _cidrCalc(t);
        _error = null;
      });
    } catch (e) {
      setState(() {
        _rows = const [];
        _error = e is FormatException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: 'CIDR 子网计算',
      subtitle: 'IPv4 与 IPv6 都支持',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          TextField(
            controller: _input,
            onChanged: (_) => _calc(),
            decoration: InputDecoration(
              labelText: '地址 / 前缀长度',
              hintText: '例如 192.168.1.10/24 或 2001:db8::1/48',
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _input.clear();
                  _calc();
                },
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in const [
                '192.168.1.10/24',
                '10.0.0.0/8',
                '172.16.5.5/12',
                '2001:db8::1/48',
                'fe80::1/64',
              ])
                ActionChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _input.text = s;
                    _calc();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: scheme.errorContainer.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 9),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            )
          else if (_rows.isNotEmpty)
            _KvTable(rows: _rows, copyable: const {'网络地址', '广播地址', '可用范围', '子网掩码', '反掩码'}),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(
                '说明：\n'
                '• 支持缩写写法（IPv6 的 :: 、省略的前缀位数默认按主机算 /32、/128）\n'
                '• IPv4 的 /31 与 /32 按 RFC 3021 处理，不像传统教材那样减 2\n'
                '• 复制：点表格里有复制图标的行',
                style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 算出 CIDR 的各项数值。IPv4 与 IPv6 自动分流。
List<_Kv> _cidrCalc(String raw) {
  var t = raw.trim();
  String ipPart;
  String? prefixPart;
  final slash = t.indexOf('/');
  if (slash >= 0) {
    ipPart = t.substring(0, slash).trim();
    prefixPart = t.substring(slash + 1).trim();
  } else {
    ipPart = t;
    prefixPart = null;
  }
  if (ipPart.isEmpty) throw const FormatException('请填写 IP 地址');

  final isV6 = ipPart.contains(':');
  final maxBits = isV6 ? 128 : 32;
  var bits = maxBits;
  if (prefixPart != null && prefixPart.isNotEmpty) {
    final n = int.tryParse(prefixPart);
    // 这条不能写 const：字符串里有 $prefixPart 插值，const 要求编译期常量
    if (n == null) throw FormatException('“/$prefixPart”里的前缀长度不是数字');
    bits = n;
  }
  if (bits < 0 || bits > maxBits) {
    throw FormatException('${isV6 ? 'IPv6' : 'IPv4'} 的前缀长度要在 0~$maxBits 之间');
  }

  if (isV6) return _cidrV6(ipPart, bits);
  return _cidrV4(ipPart, bits);
}

List<_Kv> _cidrV4(String ip, int bits) {
  final parts = ip.split('.');
  if (parts.length != 4) throw const FormatException('IPv4 要写成 4 段，例如 192.168.1.10');
  var v = 0;
  for (final p in parts) {
    final b = int.tryParse(p);
    if (b == null || b < 0 || b > 255) throw FormatException('“$p”不是合法的 0~255');
    v = (v << 8) | b;
  }
  const all = 0xFFFFFFFF;
  final mask = bits == 0 ? 0 : ((all << (32 - bits)) & all);
  final network = v & mask;
  final broadcast = network | (~mask & all);
  final total = _ipow(32 - bits);

  String hosts;
  if (bits == 32) {
    hosts = '1（单主机）';
  } else if (bits == 31) {
    hosts = '2（点对点链路，RFC 3021）';
  } else {
    final h = total - 2;
    hosts = h <= 0 ? '0' : _group(h);
    hosts = '$hosts（去掉网络号与广播地址）';
  }

  final firstHost = bits >= 31 ? network : network + 1;
  final lastHost = bits >= 31 ? broadcast : broadcast - 1;

  return [
    _Kv('输入', ip),
    _Kv('地址族', 'IPv4'),
    _Kv('前缀长度', '/$bits'),
    _Kv('网络地址', '${_v4(network)}/${bits}'),
    _Kv('广播地址', _v4(broadcast)),
    _Kv('子网掩码', _v4(mask)),
    _Kv('反掩码', _v4(~mask & all)),
    _Kv('可用范围', bits >= 31 ? _v4(network) : '${_v4(firstHost)} ~ ${_v4(lastHost)}'),
    _Kv('总地址数', _group(total)),
    _Kv('可用主机数', hosts),
    _Kv('地址类型', _v4Type(network)),
  ];
}

List<_Kv> _cidrV6(String ip, int bits) {
  final v = _parseV6(ip);
  final network = v & _v6Mask(bits);
  final last = network | _v6HostMask(bits);
  final total = BigInt.one << (128 - bits);

  return [
    _Kv('输入', ip),
    _Kv('地址族', 'IPv6'),
    _Kv('前缀长度', '/$bits'),
    _Kv('完整展开', _v6Full(network)),
    _Kv('网络地址', '${_v6Str(network)}/$bits'),
    _Kv('末地址', _v6Str(last)),
    _Kv('地址范围', '${_v6Str(network)} ~ ${_v6Str(last)}'),
    _Kv('总地址数', '2^${128 - bits} = ${_groupBig(total)}'),
    _Kv('地址类型', _v6Type(network)),
  ];
}

/// 2 的 e 次方。Dart 的 int 在移动端是 64 位，2^32 放得下，不会溢出。
int _ipow(int e) => 1 << e;

BigInt _v6Mask(int bits) {
  if (bits == 0) return BigInt.zero;
  return ((BigInt.one << bits) - BigInt.one) << (128 - bits);
}

BigInt _v6HostMask(int bits) {
  if (bits == 128) return BigInt.zero;
  return (BigInt.one << (128 - bits)) - BigInt.one;
}

String _v4(int v) => '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';

String _v4Type(int network) {
  final a = (network >> 24) & 0xFF;
  final b = (network >> 16) & 0xFF;
  if (a == 10) return '私有地址（10.0.0.0/8）';
  if (a == 172 && b >= 16 && b <= 31) return '私有地址（172.16.0.0/12）';
  if (a == 192 && b == 168) return '私有地址（192.168.0.0/16）';
  if (a == 127) return '环回地址（127.0.0.0/8）';
  if (a == 169 && b == 254) return '链路本地（169.254.0.0/16）';
  if (a >= 224 && a <= 239) return '组播地址（224.0.0.0/4）';
  if (a >= 240) return '保留地址（240.0.0.0/4）';
  if (a == 100 && b >= 64 && b <= 127) return '运营商级 NAT（100.64.0.0/10）';
  return '公网地址';
}

String _v6Type(BigInt network) {
  final f = (network >> 120).toInt() & 0xFF;
  if (network == BigInt.zero) return '未指定地址（::）';
  if (network == BigInt.one) return '环回地址（::1）';
  if ((f & 0xFE) == 0xFC) return '唯一本地地址（fc00::/7）';
  if (f == 0xFE && ((network >> 112).toInt() & 0xFF) >= 0x80) return '链路本地（fe80::/10）';
  if (f == 0xFF) return '组播地址（ff00::/8）';
  if (f == 0x20) return '全球单播（2000::/3）';
  return '其他';
}

/// 解析 IPv6（支持 :: 缩写）
BigInt _parseV6(String ip) {
  final s = ip.trim();
  if (s.contains('.')) throw const FormatException('暂不支持 IPv4 内嵌的 IPv6 写法');
  final doubleColon = s.split('::');
  if (doubleColon.length > 2) throw const FormatException('“::”最多只能出现一次');
  final left = doubleColon[0].isEmpty ? <String>[] : doubleColon[0].split(':');
  final right = doubleColon.length == 2
      ? (doubleColon[1].isEmpty ? <String>[] : doubleColon[1].split(':'))
      : <String>[];

  List<String> all;
  if (doubleColon.length == 2) {
    final fill = 8 - left.length - right.length;
    if (fill < 0) throw const FormatException('IPv6 最多 8 段');
    all = [...left, ...List<String>.filled(fill, '0'), ...right];
  } else {
    all = left;
    if (all.length != 8) throw const FormatException('不写“::”时必须写满 8 段');
  }

  var v = BigInt.zero;
  for (final seg in all) {
    if (seg.isEmpty) throw const FormatException('出现了空字段，检查一下冒号');
    if (seg.length > 4) throw FormatException('“$seg”超过 4 位十六进制');
    final g = int.tryParse(seg, radix: 16);
    if (g == null) throw FormatException('“$seg”不是合法的十六进制');
    v = (v << 16) | BigInt.from(g);
  }
  return v;
}

/// IPv6 压缩写法（把最长的连续 0 段缩成 ::）
String _v6Str(BigInt v) {
  final segs = <int>[];
  var x = v;
  for (var i = 0; i < 8; i++) {
    segs.insert(0, (x & BigInt.from(0xFFFF)).toInt());
    x = x >> 16;
  }
  var bestStart = -1, bestLen = 0;
  var curStart = -1, curLen = 0;
  for (var i = 0; i < 8; i++) {
    if (segs[i] == 0) {
      if (curStart < 0) {
        curStart = i;
        curLen = 0;
      }
      curLen++;
      if (curLen > bestLen) {
        bestLen = curLen;
        bestStart = curStart;
      }
    } else {
      curStart = -1;
      curLen = 0;
    }
  }
  if (bestLen < 2) {
    return segs.map((e) => e.toRadixString(16)).join(':');
  }
  final head = segs.sublist(0, bestStart).map((e) => e.toRadixString(16)).join(':');
  final tail = segs.sublist(bestStart + bestLen).map((e) => e.toRadixString(16)).join(':');
  return '$head::$tail';
}

/// IPv6 完整展开（每段 4 位）
String _v6Full(BigInt v) {
  final segs = <String>[];
  var x = v;
  for (var i = 0; i < 8; i++) {
    segs.insert(0, (x & BigInt.from(0xFFFF)).toInt().toRadixString(16).padLeft(4, '0'));
    x = x >> 16;
  }
  return segs.join(':');
}

/// 千分位
String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _groupBig(BigInt n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

// ===========================================================================
// 3. 地图坐标转换（WGS84 / GCJ02 / BD09）
// ===========================================================================

/// 地图坐标转换：GPS 原始坐标(WGS84)、国测局火星坐标(GCJ02)、
/// 百度坐标(BD09) 三者互转。
///
/// 离线算法，不调任何接口 —— 出差没网也能用。
class CoordinateConvertPage extends StatefulWidget {
  const CoordinateConvertPage({super.key});

  @override
  State<CoordinateConvertPage> createState() => _CoordinateConvertPageState();
}

class _CoordinateConvertPageState extends State<CoordinateConvertPage> {
  final _lat = TextEditingController(text: '39.908692');
  final _lon = TextEditingController(text: '116.397477');

  /// 输入那一串坐标**属于哪个坐标系**。
  /// 不给出这个选择，就等于假定输入永远是 GPS 原始值 ——
  /// 可用户从高德/百度复制的坐标是 GCJ02 / BD09，直接当 WGS84 算会整体偏 300~600 米。
  int _src = 0;
  String? _error;

  /// 正在取当前位置（按钮转圈用）。
  ///
  /// v2.2.0：用户要求加一个「当前地址」按钮，直接把 GPS 定位填进输入框，
  /// 省得对着地图 App 挨个抄坐标。
  bool _locating = false;

  /// 输入格式：false = 十进制度（39.908692），true = 度分秒（39°54′31.3″N）。
  ///
  /// v2.1.0 新增：以前只能填小数度，可现场拿到的坐标条、纸质记录
  /// 大多是「39°54′31.3″N」这种写法，还得自己拿计算器换算。
  bool _dmsIn = false;

  /// 申请定位权限：已授权直接过；没授权就弹系统窗；永久拒绝则引导去设置。
  ///
  /// 注意 `Permission.locationWhenInUse` 在 Android 上映射到
  /// ACCESS_FINE_LOCATION/ACCESS_COARSE_LOCATION（清单里两个都声明了）。
  Future<bool> _ensureLocationPermission() async {
    var st = await Permission.locationWhenInUse.status;
    if (st.isGranted) return true;
    if (st.isDenied) {
      st = await Permission.locationWhenInUse.request();
      if (st.isGranted) return true;
    }
    if (!mounted) return false;
    // 只是这次拒绝（还能再弹系统窗）：提示一句就结束，别用对话框挡路
    if (!st.isPermanentlyDenied) {
      toast(context, '没有定位权限，可以在输入框里手动填坐标');
      return false;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('定位权限被拒绝'),
        content: const Text('需要到系统设置里手动打开定位权限。\n\n'
            '路径：设置 → 应用 → 学聚 → 权限 → 位置信息。\n'
            '打开后回到这里再点一次「当前位置」。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('算了')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('去设置')),
        ],
      ),
    );
    if (go == true) await openPermissionSettings();
    return false;
  }

  /// 取当前定位并填入。走 `studyhub/camera` 原生通道的 `location` 方法
  /// （和指南针、水印相机同一个），拿回来的是 GPS 原始坐标 —— 也就是 WGS84，
  /// 所以顺手把「输入坐标系」切到 WGS84，用户不用再手动选一遍。
  ///
  /// v2.2.2：先主动申请定位权限。之前直接调通道，没权限时原生只回一句
  /// 「还没给定位权限」，系统弹窗根本不出现 —— 用户点名要求点击时就弹菜单。
  Future<void> _useMyLocation() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final ok = await _ensureLocationPermission();
      if (!mounted) return;
      if (!ok) return;
      final r = await const MethodChannel('studyhub/camera')
          .invokeMapMethod<String, dynamic>('location');
      if (!mounted) return;
      if (r == null || r['ok'] != true) {
        toast(context, '${r?['msg'] ?? '定位失败'}（可以手动输入坐标）');
        return;
      }
      final lat = (r['lat'] as num?)?.toDouble();
      final lon = (r['lng'] as num?)?.toDouble();
      if (lat == null || lon == null) {
        toast(context, '定位结果里没有经纬度');
        return;
      }
      setState(() {
        _src = 0; // GPS 原始 = WGS84
        _lat.text = _dmsIn ? _dms(lat, true) : lat.toStringAsFixed(6);
        _lon.text = _dmsIn ? _dms(lon, false) : lon.toStringAsFixed(6);
        _pick();
      });
      toast(context, '已填入当前位置（WGS84）');
    } catch (e) {
      if (!mounted) return;
      toast(context, '定位失败：$e（检查定位权限）');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  static const _srcLabels = <String>['WGS84', 'GCJ02', 'BD09'];
  static const _srcHints = <String>[
    'GPS 原始 / 海外地图（OSM、Google 海外）',
    '火星坐标（高德、腾讯、Google 中国）',
    '百度坐标',
  ];

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  /// 校验输入。通过返回 true，并在 _error 里留下 null。
  bool _pick() {
    final lat = _parseCoord(_lat.text);
    final lon = _parseCoord(_lon.text);
    if (lat == null || lon == null) {
      _error = _dmsIn
          ? '格式示例：39°54′31.3″N  /  116°23′50.9″E（也可以写 39 54 31.3）'
          : '纬度 / 经度得是数字';
      return false;
    }
    if (!lat.isFinite || !lon.isFinite) {
      _error = '纬度 / 经度不是有限数';
      return false;
    }
    if (lat.abs() > 90 || lon.abs() > 180) {
      _error = '纬度范围 -90~90，经度范围 -180~180';
      return false;
    }
    _error = null;
    return true;
  }

  /// 解析一个坐标字符串，十进制度和度分秒都认。
  ///
  /// 认得的写法：
  ///   `39.908692` / `39°54′31.3″N` / `N39°54'31.3"` / `39 54 31.3` / `39:54:31.3`
  /// 带 S / W 的按负数处理（南纬、西经）。
  static double? _parseCoord(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // 1) 半球字母 → 符号
    var sign = 1.0;
    final upper = s.toUpperCase();
    if (upper.contains('S') || upper.contains('W')) sign = -1;
    s = s.replaceAll(RegExp('[NSEWnsew]'), ' ');
    // 2) 各种度分秒符号统一成空格（逐个替换，避免正则里的引号转义踩坑）
    for (final ch in const ['°', 'º', '˚', '度', '分', '秒', '′', '″', "'", '"', '’', '”', '“']) {
      s = s.replaceAll(ch, ' ');
    }
    s = s.replaceAll(RegExp('[,，;；:：]'), ' ');
    final parts = s
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .map(double.tryParse)
        .toList();
    if (parts.isEmpty || parts.any((e) => e == null)) return null;
    final first = parts[0]!;
    final negative = first < 0 || sign < 0;
    var abs = first.abs();
    if (parts.length > 1) abs += parts[1]!.abs() / 60;
    if (parts.length > 2) abs += parts[2]!.abs() / 3600;
    return negative ? -abs : abs;
  }

  /// 切换输入格式时，把框里已有的值换算成对应写法，方便只改一两个数字。
  void _setDmsIn(bool v) {
    final lat = _parseCoord(_lat.text);
    final lon = _parseCoord(_lon.text);
    setState(() {
      _dmsIn = v;
      if (lat != null) _lat.text = v ? _dms(lat, true) : lat.toStringAsFixed(6);
      if (lon != null) _lon.text = v ? _dms(lon, false) : lon.toStringAsFixed(6);
      _pick();
    });
  }

  /// 复制一行的值
  void _copy(BuildContext context, String label, double lat, double lon) {
    final text = '$lat,$lon';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 $label：$text'), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '地图坐标转换',
      subtitle: 'WGS84 / 火星坐标 / 百度坐标 互转',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          // ---- 输入格式：小数度 / 度分秒（v2.1.0 新增）----
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                  value: false, label: Text('十进制度'), icon: Icon(Icons.tag, size: 16)),
              ButtonSegment<bool>(
                  value: true, label: Text('度分秒'), icon: Icon(Icons.straighten, size: 16)),
            ],
            selected: <bool>{_dmsIn},
            showSelectedIcon: false,
            onSelectionChanged: (s) => _setDmsIn(s.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  keyboardType: _dmsIn
                      ? TextInputType.text
                      : const TextInputType.numberWithOptions(decimal: true, signed: true),
                  onChanged: (_) => setState(_pick),
                  decoration: InputDecoration(
                    labelText: '纬度',
                    hintText: _dmsIn ? '39°54′31.3″N' : '39.908692',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _lon,
                  keyboardType: _dmsIn
                      ? TextInputType.text
                      : const TextInputType.numberWithOptions(decimal: true, signed: true),
                  onChanged: (_) => setState(_pick),
                  decoration: InputDecoration(
                    labelText: '经度',
                    hintText: _dmsIn ? '116°23′50.9″E' : '116.397477',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ---- 当前位置（v2.2.0）：一键把 GPS 定位填进来 ----
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _locating ? null : _useMyLocation,
                icon: _locating
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location, size: 17),
                label: Text(_locating ? '定位中…' : '当前位置',
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('取 GPS 原始坐标（WGS84），自动填入',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('输入坐标属于哪个坐标系',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            segments: [
              for (var i = 0; i < _srcLabels.length; i++)
                ButtonSegment<int>(value: i, label: Text(_srcLabels[i])),
            ],
            selected: <int>{_src},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              _src = s.first;
              _pick();
            }),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child:
                Text(_srcHints[_src], style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => setState(_pick),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('换算'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in const [
                ['天安门', '39.908692', '116.397477'],
                ['东方明珠', '31.239666', '121.499809'],
                ['广州塔', '23.106600', '113.324500'],
              ])
                ActionChip(
                  label: Text(p[0], style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _lat.text = p[1];
                    _lon.text = p[2];
                    setState(_pick);
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: scheme.errorContainer.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!, style: const TextStyle(fontSize: 13)),
              ),
            )
          else
            _resultBlock(context),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(
                '说明：\n'
                '• WGS84：GPS / 国际标准（Google 海外、OSM 用它）\n'
                '• GCJ02：国测局「火星坐标」（高德、腾讯、Google 中国区）\n'
                '• BD09：百度坐标（在 GCJ02 上又做了一次偏移）\n'
                '• 在中国大陆以外，三者基本重合，偏差可忽略\n'
                '• 点任意一行可复制「纬度,经度」',
                style: TextStyle(fontSize: 11.5, height: 1.75, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultBlock(BuildContext context) {
    final lat = _parseCoord(_lat.text);
    final lon = _parseCoord(_lon.text);
    if (lat == null || lon == null || _error != null) {
      return const SizedBox.shrink();
    }
    final src = _Coord(lat, lon);
    // 先把它归一到 WGS84，再从 WGS84 推到另外两个 —— 这样无论输入是哪个系，
    // 三个结果都自洽（而不是只做单向：WGS84 进、另外两个出）。
    final _Coord wgs;
    switch (_src) {
      case 1:
        wgs = _CoordTransform.gcj02ToWgs84(src);
        break;
      case 2:
        wgs = _CoordTransform.gcj02ToWgs84(_CoordTransform.bd09ToGcj02(src));
        break;
      default:
        wgs = _Coord.wgs84(lat, lon);
    }
    final gcj = _CoordTransform.wgs84ToGcj02(wgs);
    final bd = _CoordTransform.gcj02ToBd09(gcj);
    final out = _CoordTransform.outOfChina(wgs.lat, wgs.lon);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _coordCard(context, 'WGS84（GPS 原始）', wgs, '标准坐标', _src == 0),
        const SizedBox(height: 8),
        _coordCard(context, 'GCJ02（火星坐标）', gcj, '高德 / 腾讯 / Google 中国', _src == 1),
        const SizedBox(height: 8),
        _coordCard(context, 'BD09（百度坐标）', bd, '百度地图', _src == 2),
        if (out) ...[
          const SizedBox(height: 8),
          Text(
            '注意：该点在「中国大陆粗略范围」之外，三系坐标不做偏移（三者数值相近是正常的）。',
            style: TextStyle(fontSize: 11, height: 1.6, color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _coordCard(
      BuildContext context, String title, _Coord c, String note, bool isSource) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSource ? BorderSide(color: scheme.primary, width: 1.4) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _copy(context, title, c.lat, c.lon),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  if (isSource) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('输入',
                          style: TextStyle(fontSize: 10, color: scheme.primary)),
                    ),
                  ],
                  const Spacer(),
                  Icon(Icons.copy_rounded, size: 15, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                '${c.lat.toStringAsFixed(6)}, ${c.lon.toStringAsFixed(6)}',
                style: TextStyle(
                  fontSize: 15,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 3),
              Text('${_dms(c.lat, true)}   ${_dms(c.lon, false)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 3),
              Text(note, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  /// 十进制度 → 度分秒（导航 / 测绘里常用写法）。
  /// 分秒用 Unicode 的撇号 ′ ″，这样字符串里不用转义引号。
  static String _dms(double v, bool isLat) {
    final hemi = isLat ? (v >= 0 ? 'N' : 'S') : (v >= 0 ? 'E' : 'W');
    final a = v.abs();
    final d = a.floor();
    final mFull = (a - d) * 60;
    final m = mFull.floor();
    final s = (mFull - m) * 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toStringAsFixed(1).padLeft(4, '0');
    return '$d°$mm′$ss″$hemi';
  }
}

/// 一对经纬度
class _Coord {
  final double lat;
  final double lon;
  const _Coord(this.lat, this.lon);
  static _Coord wgs84(double lat, double lon) => _Coord(lat, lon);
}

/// 坐标系互转（都是离线公式）
class _CoordTransform {
  static const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
  static const double _ee = 0.00669342162296594323; // 第一偏心率平方

  /// 中国大陆粗略范围判断（这个范围外不做偏移）
  static bool outOfChina(double lat, double lon) {
    return !(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55);
  }

  static double _transLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double _transLon(double x, double y) {
    var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
  }

  /// WGS84 → GCJ02
  static _Coord wgs84ToGcj02(_Coord c) {
    if (outOfChina(c.lat, c.lon)) return c;
    var dLat = _transLat(c.lon - 105.0, c.lat - 35.0);
    var dLon = _transLon(c.lon - 105.0, c.lat - 35.0);
    final radLat = c.lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return _Coord(c.lat + dLat, c.lon + dLon);
  }

  /// GCJ02 → WGS84（用一次反算 + 一次迭代，精度到厘米级）
  static _Coord gcj02ToWgs84(_Coord c) {
    if (outOfChina(c.lat, c.lon)) return c;
    final g = wgs84ToGcj02(c);
    final dLat = g.lat - c.lat;
    final dLon = g.lon - c.lon;
    var lat = c.lat - dLat;
    var lon = c.lon - dLon;
    // 再迭代一轮，抵消非线性误差
    final again = wgs84ToGcj02(_Coord(lat, lon));
    lat -= again.lat - c.lat;
    lon -= again.lon - c.lon;
    return _Coord(lat, lon);
  }

  static const double _xPi = math.pi * 3000.0 / 180.0;

  /// GCJ02 → BD09
  static _Coord gcj02ToBd09(_Coord c) {
    final z = math.sqrt(c.lon * c.lon + c.lat * c.lat) + 0.00002 * math.sin(c.lat * _xPi);
    final theta = math.atan2(c.lat, c.lon) + 0.000003 * math.cos(c.lon * _xPi);
    return _Coord(z * math.sin(theta) + 0.006, z * math.cos(theta) + 0.0065);
  }

  /// BD09 → GCJ02
  static _Coord bd09ToGcj02(_Coord c) {
    final x = c.lon - 0.0065;
    final y = c.lat - 0.006;
    final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * _xPi);
    final theta = math.atan2(y, x) - 0.000003 * math.cos(x * _xPi);
    return _Coord(z * math.sin(theta), z * math.cos(theta));
  }
}
