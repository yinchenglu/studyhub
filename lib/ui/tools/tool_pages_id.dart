import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'tool_pages.dart';

/// 身份证查户籍（v1.5.0 用户第 1 条第 ⑫ 项，App 版）。
///
/// 和「网页版小工具/身份证查户籍.html」「身份证户籍地批量匹配.xlsx」是**同一套判定逻辑**，
/// 三处结论必须一致，所以这里刻意照着网页版的 JS 一行行搬，不另起炉灶：
///   * 前 6 位 → GB/T 2260 区划码 → 户籍地，查不到就逐级退（区县 → 地级市 → 省级），
///     并明确说明「是区划变更，不是号码错」
///   * 校验位按 GB 11643-1999 的加权因子算（权重表 + CK 表）
///   * 15 位老号按规则补成 18 位（出生年补「19」+ 重算校验位）
///   * 出生日期合法性单独判（2 月 30 日这种会被算出来但明显不合法）
///
/// 数据来自 assets/data/id_region.json（2978 个区县 / 333 个地级 / 34 个省级），
/// 由 .workbuddy/build_id_region.py 从 pcas-code.json 生成，版本 2024-12。
class IdRegionData {
  final String ver;
  final String note;
  final Map<String, String> p;
  final Map<String, String> c;
  final Map<String, String> d;
  final Map<String, dynamic> history;

  const IdRegionData({
    required this.ver,
    required this.note,
    required this.p,
    required this.c,
    required this.d,
    this.history = const {},
  });

  static IdRegionData? _cache;

  static Future<IdRegionData> load() async {
    final hit = _cache;
    if (hit != null) return hit;
    final raw = await rootBundle.loadString('assets/data/id_region.json');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    String pick(dynamic v) => v == null ? '' : v.toString();
    Map<String, String> asMap(dynamic v) {
      final out = <String, String>{};
      if (v is Map) {
        v.forEach((k, val) => out[k.toString()] = pick(val));
      }
      return out;
    }

    final data = IdRegionData(
      ver: pick(m['ver']),
      note: pick(m['note']),
      p: asMap(m['p']),
      c: asMap(m['c']),
      d: asMap(m['d']),
      history: m['history'] is Map ? (m['history'] as Map).cast<String, dynamic>() : <String, dynamic>{},
    );
    _cache = data;
    return data;
  }
}

/// 解析结果。不抛异常，所有问题都放进 [err] / [notes]。
class IdInfo {
  final bool ok;
  final String err;
  final String input;

  /// 补全后的 18 位（15 位老号会被补全）
  final String id18;
  final String area;
  final String prov;
  final String city;
  final String dist;

  /// 直接给出的户籍地字符串（可能只到市 / 只到省）
  final String addr;

  /// district / city / province / none
  final String level;
  final bool changed;
  final bool history;
  final String birth;
  final String gender;
  final int? age;
  final bool checkOk;
  final String want;
  final String given;
  final List<String> notes;

  const IdInfo({
    required this.ok,
    this.err = '',
    this.input = '',
    this.id18 = '',
    this.area = '',
    this.prov = '',
    this.city = '',
    this.dist = '',
    this.addr = '',
    this.level = 'none',
    this.changed = false,
    this.history = false,
    this.birth = '',
    this.gender = '',
    this.age,
    this.checkOk = false,
    this.want = '',
    this.given = '',
    this.notes = const [],
  });

  bool get isOld15 => input.length == 15;

  /// 一行摘要，批量列表里用
  String get summary => ok ? '$addr · $birth · $gender' : err;
}

const List<int> _w = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const String _ck = '10X98765432';

String _checkDigit(String id17) {
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    final c = id17.codeUnitAt(i) - 48;
    sum += (c < 0 || c > 9 ? 0 : c) * _w[i];
  }
  return _ck[sum % 11];
}

bool _isValidDate(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1) return false;
  final dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
  final max = (m == 2 && leap) ? 29 : dim[m - 1];
  return d <= max;
}

/// 户籍地字符串是「省+市+区县」直接拼起来的，没有分隔符，这里只做展示上的粗切
Map<String, String> _splitAddr(String full) {
  final m = RegExp(r'^(.+?[省市区])(.+?[市州盟地区])?(.*)$').firstMatch(full);
  if (m == null) return {'prov': full, 'city': '', 'dist': ''};
  return {
    'prov': m.group(1) ?? '',
    'city': m.group(2) ?? '',
    'dist': m.group(3) ?? '',
  };
}

IdInfo parseIdCard(String raw, IdRegionData reg) {
  var s = raw.toUpperCase().replaceAll(RegExp(r'[^0-9X]'), '');
  if (s.isEmpty) {
    return const IdInfo(ok: false, err: '没有输入号码');
  }
  if (s.length != 15 && s.length != 18) {
    return IdInfo(ok: false, err: '位数不对：身份证是 18 位（老号 15 位），当前 ${s.length} 位');
  }

  final orig = s;
  final is15 = s.length == 15;
  if (is15) {
    if (!RegExp(r'^\d{15}$').hasMatch(s)) {
      return const IdInfo(ok: false, err: '15 位老号只能全是数字');
    }
    final id17 = '${s.substring(0, 6)}19${s.substring(6)}';
    s = id17 + _checkDigit(id17);
  } else if (!RegExp(r'^\d{17}[\dX]$').hasMatch(s)) {
    return const IdInfo(ok: false, err: '18 位号的最后一位只能是数字或 X');
  }

  final area = s.substring(0, 6);
  final y = int.tryParse(s.substring(6, 10)) ?? 0;
  final mo = int.tryParse(s.substring(10, 12)) ?? 0;
  final da = int.tryParse(s.substring(12, 14)) ?? 0;
  final given = s[17];
  final want = _checkDigit(s.substring(0, 17));

  final dateOk = y >= 1800 && y <= 2200 && _isValidDate(y, mo, da);
  final checkOk = given == want;

  // -------- 区划码 -> 户籍地：先查现行，再查历史码，最后逐级退 --------
  var level = 'none';
  var changed = false;
  var addr = '未知（区划码 $area 不在表里）';
  var prov = '';
  var city = '';
  var dist = '';
  var viaHistory = false;
  var histNote = '';
  final hitD = reg.d[area];
  if (hitD != null) {
    addr = hitD;
    final parts = _splitAddr(hitD);
    prov = parts['prov'] ?? '';
    city = parts['city'] ?? '';
    dist = parts['dist'] ?? '';
    level = 'district';
  } else {
    // 历史码：旧码 → 现归属（撤销 / 更名 / 合并）
    final hist = reg.history[area];
    if (hist is Map) {
      final nowList = (hist['now'] as List?)?.cast<Map>() ?? [];
      Map? pick;
      for (final n in nowList) {
        if (n['current'] == true) {
          pick = n;
          break;
        }
      }
      pick ??= nowList.isNotEmpty ? nowList.first : null;
      if (pick != null) {
        final addrStr = (pick['addr'] as String?) ?? '';
        final parts = _splitAddr(addrStr);
        prov = parts['prov'] ?? '';
        city = parts['city'] ?? '';
        dist = parts['dist'] ?? '';
        addr = addrStr;
        changed = true;
        level = dist.isNotEmpty ? 'district' : (city.isNotEmpty ? 'city' : 'province');
        final oldName = (hist['name'] as String?) ?? '';
        final lastYear = (hist['lastYear']?.toString()) ?? '';
        final desc = ((hist['desc'] as String?) ?? '').trim();
        final multi = hist['multi'] == true;
        final b = StringBuffer();
        b.write('前 6 位『$area』是历史区划码');
        if (oldName.isNotEmpty) b.write('（原 $oldName）');
        if (lastYear.isNotEmpty) b.write('，约 $lastYear 年发生变更');
        b.write('，现属 $addr。');
        if (multi) b.write('（原区划已撤销或拆分，辖区现分属该市多个区县）');
        if (desc.isNotEmpty) b.write(' 变更说明：$desc');
        histNote = b.toString();
        viaHistory = true;
      }
    }
    if (!viaHistory) {
      final c4 = area.substring(0, 4);
      final hitC = reg.c[c4];
      if (hitC != null) {
        addr = hitC;
        changed = true;
        level = 'city';
        prov = reg.p[area.substring(0, 2)] ?? '';
        city = hitC;
      } else {
        final p2 = reg.p[area.substring(0, 2)];
        if (p2 != null) {
          addr = p2;
          changed = true;
          level = 'province';
          prov = p2;
        } else {
          changed = true;
        }
      }
    }
  }

  int? age;
  if (dateOk) {
    final now = DateTime.now();
    var a = now.year - y;
    if (now.month < mo || (now.month == mo && now.day < da)) a -= 1;
    if (a >= 0 && a < 130) age = a;
  }

  final notes = <String>[];
  if (is15) {
    notes.add('这是 15 位老号，已按规则补成 18 位（出生年补「19」，重新计算校验位）后再解析；'
        '15 位号本身没有校验位，所以「校验位」这一栏说的是补全后的结果。');
  }
  if (!checkOk) {
    notes.add('校验位不对：算出来应该是「$want」，号码里写的是「$given」。'
        '说明这串号被敲错了或不是按国标生成的 —— 但户籍地仍然按前 6 位给出来供参考。');
  }
  if (!dateOk) {
    notes.add('出生日期 ${s.substring(6, 14)} 不是一个合法日期，请核对。');
  }
  if (viaHistory) {
    notes.add(histNote);
  } else {
    if (changed && level != 'none') {
      notes.add('前 6 位『$area』在现行区划表里查不到区县，只退到了'
          '${level == 'city' ? '地级市' : '省级'}。'
          '多半是这期间发生了撤县设区 / 撤地设市 / 更名，老号的区划码已经不在了。');
    }
    if (level == 'none') {
      notes.add('前 6 位『$area』完全查不到，可能不是大陆户籍身份证。');
    }
  }
  final p2 = area.substring(0, 2);
  if (p2 == '71' || p2 == '81' || p2 == '82') {
    notes.add('前两位是港澳台代码。港澳台居民一般不使用大陆版居民身份证号，'
        '出入境用的是通行证 / 居住证，号码规则不同。');
  }

  final yy = s.substring(6, 10);
  final mm = s.substring(10, 12);
  final dd = s.substring(12, 14);
  final seq = int.tryParse(s.substring(14, 17)) ?? 0;

  return IdInfo(
    ok: true,
    input: orig,
    id18: s,
    area: area,
    prov: prov,
    city: city,
    dist: dist,
    addr: addr,
    level: level,
    changed: changed,
    history: viaHistory,
    birth: '$yy-$mm-$dd',
    gender: seq % 2 == 1 ? '男' : '女',
    age: age,
    checkOk: checkOk,
    want: want,
    given: given,
    notes: notes,
  );
}

// ============================================================ 页面

class IdCardPage extends StatefulWidget {
  const IdCardPage({super.key});

  @override
  State<IdCardPage> createState() => _IdCardPageState();
}

class _IdCardPageState extends State<IdCardPage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  final _one = TextEditingController();
  final _many = TextEditingController();

  IdRegionData? _reg;
  String? _regErr;

  IdInfo? _res;
  List<IdInfo> _list = const [];

  @override
  void initState() {
    super.initState();
    _loadReg();
  }

  Future<void> _loadReg() async {
    try {
      final r = await IdRegionData.load();
      if (!mounted) return;
      setState(() => _reg = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _regErr = '$e');
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _one.dispose();
    _many.dispose();
    super.dispose();
  }

  void _queryOne() {
    final reg = _reg;
    if (reg == null) return;
    setState(() => _res = parseIdCard(_one.text, reg));
  }

  void _queryMany() {
    final reg = _reg;
    if (reg == null) return;
    final lines = _many.text
        .split(RegExp(r'[\n,，、;；\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      toast(context, '先粘贴一批身份证号（一行一个）');
      return;
    }
    setState(() => _list = lines.map((e) => parseIdCard(e, reg)).toList());
  }

  @override
  Widget build(BuildContext context) {
    final reg = _reg;
    return ToolScaffold(
      title: '身份证查户籍',
      subtitle: reg == null
          ? '正在读取区划码表…'
          : '区划码表 ${reg.ver} · 现行 ${reg.d.length} 区县 + ${reg.history.length} 历史码',
      actions: [
        IconButton(
          tooltip: '说明',
          icon: const Icon(Icons.help_outline),
          onPressed: _showHelp,
        ),
      ],
      bottom: TabBar(
        controller: _tab,
        tabs: const [Tab(text: '单个查询'), Tab(text: '批量查询')],
      ),
      child: _regErr != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('区划码表读不出来：$_regErr')))
          : reg == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tab,
                  children: [_oneView(reg), _manyView(reg)],
                ),
    );
  }

  Widget _oneView(IdRegionData reg) {
    final r = _res;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        TextField(
          controller: _one,
          keyboardType: TextInputType.text,
          maxLength: 18,
          decoration: const InputDecoration(
            labelText: '身份证号（18 位；15 位老号也能认）',
            hintText: '110101199003070011',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (_) => _queryOne(),
          onChanged: (v) {
            // 够 18 位（或 15 位）就自动算，省得再点一下
            final s = v.trim();
            if (s.length == 18 || s.length == 15) _queryOne();
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _queryOne,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('查户籍地'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '清空',
              onPressed: () => setState(() {
                _one.clear();
                _res = null;
              }),
              icon: const Icon(Icons.backspace_outlined),
            ),
          ],
        ),
        if (r != null && r.ok) ...[
          const SizedBox(height: 14),
          _resultCard(reg, r),
        ],
      ],
    );
  }

  Widget _resultCard(IdRegionData reg, IdInfo r) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.addr,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.4),
                  ),
                ),
                IconButton(
                  tooltip: '复制户籍地',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => copyText(context, r.addr),
                ),
              ],
            ),
            if (r.history)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '历史区划码 · 已顺着变更链查到现属',
                  style: TextStyle(fontSize: 12, color: scheme.tertiary),
                ),
              )
            else if (r.changed && r.level != 'none')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  r.level == 'city' ? '区划码已变更，只查到地级市' : '区划码已变更，只查到省级',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            const Divider(height: 22),
            _kv('省 / 直辖市', r.prov.isEmpty ? '—' : r.prov),
            _kv('市 / 州', r.city.isEmpty ? '—' : r.city),
            _kv('区 / 县', r.dist.isEmpty ? '—' : r.dist),
            _kv('区划码', r.area),
            _kv('出生日期', r.age == null ? r.birth : '${r.birth}（$r.age 岁）'),
            _kv('性别', r.gender),
            _kv('校验位', r.checkOk ? '${r.given} ✓ 通过' : '${r.given} ✗ 应为「${r.want}」'),
            if (r.isOld15) _kv('补全后', r.id18),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => copyText(
                      context,
                      '${r.input}\t${r.addr}\t${r.birth}\t${r.gender}\t'
                      '${r.prov}\t${r.city}\t${r.dist}\t${r.checkOk ? '校验通过' : '校验位不符'}',
                    ),
                    icon: const Icon(Icons.copy_all, size: 18),
                    label: const Text('复制全部结果'),
                  ),
                ),
              ],
            ),
            for (final n in r.notes)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('· $n',
                    style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(k, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13.5, height: 1.45))),
        ],
      ),
    );
  }

  Widget _manyView(IdRegionData reg) {
    final okCount = _list.where((e) => e.ok).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        TextField(
          controller: _many,
          maxLines: 6,
          minLines: 4,
          decoration: const InputDecoration(
            labelText: '一行一个身份证号（也可以逗号分隔）',
            hintText: '110101199003070011\n310115198812120025\n440305199507180013',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _queryMany,
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: Text(_list.isEmpty ? '批量解析' : '重新解析（${_list.length} 条）'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '清空',
              onPressed: () => setState(() {
                _many.clear();
                _list = const [];
              }),
              icon: const Icon(Icons.backspace_outlined),
            ),
          ],
        ),
        if (_list.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Text('共 ${_list.length} 条 · 能解析 $okCount 条',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => copyText(
                  context,
                  _list
                      .map((e) => e.ok
                          ? '${e.input}\t${e.addr}\t${e.birth}\t${e.gender}\t'
                              '${e.prov}\t${e.city}\t${e.dist}\t${e.checkOk ? '校验通过' : '校验位不符'}'
                          : '${e.input}\t${e.err}')
                      .join('\n'),
                ),
                icon: const Icon(Icons.copy_all, size: 16),
                label: const Text('复制结果'),
              ),
            ],
          ),
          const Divider(height: 12),
          for (final e in _list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                e.ok ? (e.checkOk ? Icons.check_circle_outline : Icons.error_outline) : Icons.cancel_outlined,
                size: 20,
                color: e.ok
                    ? (e.checkOk ? const Color(0xFF1D9E75) : const Color(0xFFD4537E))
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text(e.input.isEmpty ? '（空）' : e.input,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(e.summary, style: const TextStyle(fontSize: 12)),
              onTap: () => copyText(context, e.ok ? '${e.input}\t${e.addr}' : e.err),
            ),
        ],
      ],
    );
  }

  void _showHelp() {
    final reg = _reg;
    final text = [
      '这个工具怎么算的',
      '',
      '· 户籍地只看身份证的前 6 位（GB/T 2260 行政区划代码）。'
          '查得到区县就给到区县；查不到就逐级退到地级市、再退到省，并明确标注。',
      '· 校验位按 GB 11643-1999 的加权因子算，最后一位 X 是合法的（代表 10）。',
      '· 15 位老号会先补成 18 位（出生年补「19」，重算校验位），前 6 位不动。',
      '',
      '查不到 / 对不上是正常的',
      '· 行政区划会撤并改名，老号码里的区划码在现行表里可能已经不存在。'
          '本工具内置了 1981–2025 全量变更数据，绝大多数历史码（如秭归县旧码 422727）'
          '都能顺着变更链查到现属哪里，并附上变更说明（批复文号 / 日期）。',
      '· 极少数无权威记录的旧码仍可能只退到上一级，已明确标注，不会假装知道。',
      '· 查得到也不代表这个号码真实存在，只说明格式和校验位合法。',
      '· 港澳台前两位是 71 / 81 / 82，不适用大陆居民身份证号规则。',
      '',
      reg == null ? '' : '· 区划码表版本：${reg.ver}',
      reg == null ? '' : '· ${reg.note}',
    ].where((e) => e.isNotEmpty).join('\n');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('说明'),
        content: SingleChildScrollView(child: Text(text, style: const TextStyle(height: 1.65, fontSize: 13.5))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
      ),
    );
  }
}
