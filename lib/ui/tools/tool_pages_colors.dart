// ============================================================ 传统色卡
//
// v1.5.0 新增：配色助手里的「中国传统色 / 日本传统色」列表。
//
// 数据来源与加工（都在 .workbuddy/build_traditional_colors.py 里）：
//   * 中国传统色 161 色 / 9 大类，来自 .workbuddy/_data/cn_colors.json
//     （原始数据带 figure 图片字段，我们不用，生成时剔掉了）。
//   * 日本传统色 250 色，来自 nipponcolors 数据集
//     （汉字名 + 罗马音 + RGB + CMYK）。**色系是我们自己按 HSL 色相算的**，
//     原始数据里没有色系字段 —— 与其照抄一段查不到出处的硬分段，
//     不如按色值算，至少「同一色系里的色确实相近」这件事是成立的。
//   * 两边合成 assets/data/traditional_colors.json，实测 38 KB，
//     比拆成两个文件省一次 asset 声明。
//
// 关于 import 环：本文件要用 tool_pages.dart 里的 ToolScaffold / copyText，
// 而 tool_pages.dart 要用本文件的 TraditionalColorsPage，
// 于是两个文件互相 import。**这在 Dart 里是合法的**（语言规范只禁止
// 顶层常量之间循环初始化，不禁止 import 环），不会报错。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'tool_pages.dart';

/// 传统色卡。
///
/// [initialTab] 取 `'cn'` 或 `'jp'`，决定打开时停在哪个页签。
///
/// 这是个「挑色」页面：用户选中一个色之后，用 `Navigator.pop(color)`
/// 把颜色送回调用方（配色助手会拿它当主色）。
/// 直接点色块是看详情 + 复制，不会退出页面。
class TraditionalColorsPage extends StatefulWidget {
  const TraditionalColorsPage({super.key, this.initialTab = 'cn'});

  final String initialTab;

  @override
  State<TraditionalColorsPage> createState() => _TraditionalColorsPageState();
}

class _TraditionalColorsPageState extends State<TraditionalColorsPage> {
  bool _loading = true;
  String? _err;

  /// 整份 json：`{'cn': {...}, 'jp': {...}}`
  Map<String, dynamic> _all = const {};

  /// 当前页签：`cn` / `jp`。只放这两个值，别处一律用常量比较。
  String _tab = 'cn';

  /// 色系筛选。'全部' 表示不筛。
  String _fam = '全部';

  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 只认 cn / jp，传别的就当 cn，免得 initialTab 写错时整页空着。
    _tab = widget.initialTab == 'jp' ? 'jp' : 'cn';
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await rootBundle.loadString('assets/data/traditional_colors.json');
      final m = jsonDecode(s);
      if (!mounted) return;
      setState(() {
        _all = (m as Map).cast<String, dynamic>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  Map<String, dynamic> get _cur => (_all[_tab] as Map?)?.cast<String, dynamic>() ?? const {};

  List<String> get _families =>
      ((_cur['families'] as List?) ?? const []).map((e) => '$e').toList();

  /// 当前页签下，过了色系 + 搜索两道筛的颜色。
  List<Map<String, dynamic>> get _shown {
    final raw = (_cur['colors'] as List?) ?? const [];
    final q = _search.text.trim().toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      final c = (e as Map).cast<String, dynamic>();
      if (_fam != '全部' && '${c['fam']}' != _fam) continue;
      if (q.isNotEmpty) {
        // CN 搜「名字 + HEX + 说明」，JP 额外搜罗马音 —— 罗马音是这份数据里
        // 唯一能用 ASCII 敲出来的字段，用英文键盘的人全靠它。
        final hay = '${c['name']} ${c['hex']} ${c['roma'] ?? ''} ${c['intro'] ?? ''}'
            .toLowerCase();
        if (!hay.contains(q)) continue;
      }
      out.add(c);
    }
    return out;
  }

  static Color _parseHex(String hex) {
    final v = int.tryParse(hex.replaceAll('#', ''), radix: 16) ?? 0;
    return Color(0xFF000000 | v);
  }

  static String _rgbText(Color c) =>
      '${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()}';

  /// 东方的 CMYK 串是 4 段各 3 位数字，例如 `002043003000`。
  /// 不是这个形状就原样返回，免得把脏数据算成一组假数字。
  static String _cmykText(String raw) {
    if (raw.length != 12) return raw;
    final p = [for (var i = 0; i < 12; i += 3) int.tryParse(raw.substring(i, i + 3))];
    if (p.any((e) => e == null)) return raw;
    return 'C${p[0]} M${p[1]} Y${p[2]} K${p[3]}';
  }

  void _switchTab(String t) {
    if (_tab == t) return;
    setState(() {
      _tab = t;
      // 色系是两套数据各自的，切页签必须把筛选清掉，
      // 否则会停在一个新页签里不存在的色系上，结果是空白页。
      _fam = '全部';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _loading ? const <Map<String, dynamic>>[] : _shown;

    return ToolScaffold(
      title: '传统色卡',
      subtitle: _loading
          ? '正在读取色卡…'
          : '${_cur['title'] ?? ''} · 共 ${(_cur['colors'] as List?)?.length ?? 0} 色'
              '${_fam == '全部' && _search.text.trim().isEmpty ? '' : '，当前 ${shown.length} 色'}',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: _tabButton('cn', '中国传统色', scheme),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _tabButton('jp', '日本传统色', scheme),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: _tab == 'jp' ? '名字 / 罗马音 / 色值' : '名字 / 色值 / 说明',
                border: const OutlineInputBorder(),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_families.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                children: [
                  for (final f in ['全部', ..._families])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(f, style: const TextStyle(fontSize: 12)),
                        selected: _fam == f,
                        onSelected: (_) => setState(() => _fam = f),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Expanded(child: _body(shown, scheme)),
        ],
      ),
    );
  }

  Widget _tabButton(String key, String label, ColorScheme scheme) {
    final on = _tab == key;
    return InkWell(
      onTap: () => _switchTab(key),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: on ? scheme.primaryContainer : null,
          border: Border.all(color: on ? scheme.primary : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _body(List<Map<String, dynamic>> shown, ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('色卡读不出来：$_err', textAlign: TextAlign.center),
        ),
      );
    }
    if (shown.isEmpty) {
      return Center(
        child: Text('没有匹配的颜色', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: shown.length,
      itemBuilder: (_, i) => _cell(shown[i], scheme),
    );
  }

  Widget _cell(Map<String, dynamic> c, ColorScheme scheme) {
    final col = _parseHex('${c['hex']}');
    final on = col.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
    return InkWell(
      onTap: () => _detail(c),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: col,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(5),
              child: Text(
                '${c['hex']}'.substring(1),
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: on,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${c['name']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  void _detail(Map<String, dynamic> c) {
    final col = _parseHex('${c['hex']}');
    final on = col.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
    final scheme = Theme.of(context).colorScheme;
    final rgb = _rgbText(col);
    final hex = '${c['hex']}';

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 88,
                  decoration: BoxDecoration(
                    color: col,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    hex,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: on,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('${c['name']}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if ('${c['roma'] ?? ''}'.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${c['roma']}',
                        style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1.1,
                            color: scheme.onSurfaceVariant)),
                  ),
                if ('${c['intro'] ?? ''}'.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${c['intro']}',
                        style: const TextStyle(fontSize: 12.5, height: 1.5)),
                  ),
                const Divider(height: 22),
                _kv(ctx, 'HEX', hex, hex),
                _kv(ctx, 'RGB', rgb, 'rgb($rgb)'),
                if ('${c['cmyk'] ?? ''}'.isNotEmpty)
                  _kv(ctx, 'CMYK', _cmykText('${c['cmyk']}'), ''),
                _kv(ctx, '色系', '${c['fam']}', ''),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => copyText(ctx, hex),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('复制 HEX'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).pop(col);
                        },
                        icon: const Icon(Icons.palette, size: 18),
                        label: const Text('用作主色'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一行「标签 + 值 + 复制图标」。值不为空且给得出复制内容时才可点。
  Widget _kv(BuildContext ctx, String label, String value, String copy) {
    final scheme = Theme.of(ctx).colorScheme;
    final canCopy = copy.isNotEmpty;
    return InkWell(
      onTap: canCopy ? () => copyText(ctx, copy) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 13.5, letterSpacing: 0.3)),
            ),
            if (canCopy) Icon(Icons.copy, size: 15, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
