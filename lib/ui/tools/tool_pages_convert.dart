import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kin_data.dart';
import 'unit_data.dart';

/// 单位换算（v1.8.0 需求12）
///
/// 用户原话：「增加单位转换工具，各种换算集中在一个界面，点击进入……
/// 还要加入人民币大小写转换、称呼计算。」
///
/// 所以这一页 = **顶部一排分类 chip + 下面一整块结果区**：
///   * 长度/面积/体积/质量/温度/速度/时间/数据存储/角度/压力/能量/功率/
///     力/频率/密度/流量/光照度/配速 —— 共 18 类，全部走 [kUnitCategories]
///   * 人民币大写 —— 数字 ↔ 汉字双向，自动判方向
///   * 亲戚称呼 —— 查 assets/data/kin.json
///
/// 交互约定：输入一次，**下面把所有单位的结果全列出来**（不是「选两个单位
/// 做一次换算」那种一次一问的玩法）。想换基准单位点那一行的下拉就行。
/// 点结果行 = 复制。
class UnitConvertPage extends StatefulWidget {
  const UnitConvertPage({super.key});

  @override
  State<UnitConvertPage> createState() => _UnitConvertPageState();
}

class _UnitConvertPageState extends State<UnitConvertPage> {
  /// 分类名列表 = 18 个换算类 + 2 个特殊页
  static final List<String> _catNames = [
    for (final c in kUnitCategories) c.name,
    '人民币大写',
    '亲戚称呼',
  ];

  static int get _rmbIndex => kUnitCategories.length;
  static int get _kinIndex => kUnitCategories.length + 1;

  int _cat = 0;

  /// 每个换算类各记一个「基准单位下标」，切来切去不会串。
  final Map<int, int> _baseOf = {};

  final _input = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < kUnitCategories.length; i++) {
      // 默认基准：优先挑「米 / 千克 / 秒 / 字节」这类单位做基准，
      // 它们都在数组第 0 位（见 unit_data.dart 的约定），所以直接用 0。
      _baseOf[i] = 0;
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 解析输入框里的数字。允许千分位逗号和全角数字 —— 从别处粘过来的
  /// 「1,234.5」「１２３」都能认，不然用户会以为工具坏了。
  double? _parseInput() {
    var t = _input.text.trim();
    if (t.isEmpty) return null;
    const fullDigits = '０１２３４５６７８９';
    final buf = StringBuffer();
    for (final ch in t.split('')) {
      final i = fullDigits.indexOf(ch);
      if (i >= 0) {
        buf.write(i);
      } else {
        buf.write(ch);
      }
    }
    t = buf.toString().replaceAll(',', '').replaceAll('，', '').replaceAll(' ', '');
    return double.tryParse(t);
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 $label：$text'), duration: const Duration(milliseconds: 1200)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('单位换算'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _catNames.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final on = i == _cat;
                return ChoiceChip(
                  label: Text(_catNames[i], style: const TextStyle(fontSize: 13)),
                  selected: on,
                  onSelected: (_) => setState(() => _cat = i),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              },
            ),
          ),
        ),
      ),
      body: _cat == _kinIndex
          ? const _KinBody()
          : _cat == _rmbIndex
              ? const _RmbBody()
              : _unitBody(scheme),
    );
  }

  // ------------------------------------------------------------ 单位换算

  Widget _unitBody(ColorScheme scheme) {
    final c = kUnitCategories[_cat];
    final base = _baseOf[_cat] ?? 0;
    final v = _parseInput();
    final baseValue = v == null ? null : c.units[base].toBase(v);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: InputDecoration(
                    labelText: '输入数值',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: '清零',
                      icon: const Icon(Icons.backspace_outlined, size: 18),
                      onPressed: () {
                        setState(() => _input.text = '');
                      },
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              // 基准单位：直接放在输入框右边，「以什么为单位输入」一眼可见
              DropdownButton<int>(
                value: base,
                // ⚠️ itemHeight 有硬断言 >= kMinInteractiveDimension(48)，
                //    比自己想要的矮，但改小会直接断言崩溃，别动。
                items: [
                  for (var i = 0; i < c.units.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text('${c.units[i].name} ${c.units[i].symbol}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (i) => setState(() => _baseOf[_cat] = i ?? 0),
              ),
            ],
          ),
        ),
        if (v == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('输入一个数值，下面会列出全部单位的结果', style: TextStyle(fontSize: 13)),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 20),
              itemCount: c.units.length + (c.pace ? 2 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                if (c.pace && i >= c.units.length) {
                  // 配速跟时速是倒数关系，单独算
                  final minPerKm = baseValue == null ? 0.0 : baseValue;
                  final extra = i == c.units.length;
                  final text = extra
                      ? (minPerKm <= 0 ? '—' : '${fmtUnit(60 / minPerKm)} 千米/小时')
                      : (minPerKm <= 0 ? '—' : '${fmtUnit(1000 / (minPerKm * 60))} 米/秒');
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: Icon(Icons.directions_run, size: 18, color: Theme.of(context).colorScheme.primary),
                    title: Text(extra ? '折合时速（千米/小时）' : '折合速度（米/秒）',
                        style: const TextStyle(fontSize: 13)),
                    trailing: Text(text,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  );
                }
                final u = c.units[i];
                final out = baseValue == null ? null : u.fromBase(baseValue);
                final isBase = i == base;
                final text = out == null ? '—' : fmtUnit(out);
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  selected: isBase,
                  selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
                  title: Row(
                    children: [
                      Text(u.name, style: const TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 6),
                      Text(u.symbol,
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                      if (isBase) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('基准', style: TextStyle(fontSize: 9.5)),
                        ),
                      ],
                    ],
                  ),
                  trailing: Text(
                    text,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isBase ? FontWeight.w700 : FontWeight.w600,
                      color: isBase ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                  onTap: () => _copy(text, u.name),
                  onLongPress: () => setState(() => _baseOf[_cat] = i),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text(
            '点一行复制结果；长按一行把它设为基准单位。',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

// ============================================================ 人民币大写

class _RmbBody extends StatefulWidget {
  const _RmbBody();

  @override
  State<_RmbBody> createState() => _RmbBodyState();
}

class _RmbBodyState extends State<_RmbBody> {
  final _ctrl = TextEditingController(text: '1234.56');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = rmbConvert(_ctrl.text);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: [
        TextField(
          controller: _ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '金额',
            helperText: '填数字（1234.56）或汉字大写（壹仟贰佰叁拾肆元伍角陆分），自动识别方向',
            helperMaxLines: 3,
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        if (r.error != null)
          Card(
            color: scheme.errorContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(r.error!, style: text.bodySmall)),
                ],
              ),
            ),
          )
        else ...[
          _resultCard(
            context,
            title: '汉字大写',
            value: r.upper,
            mono: false,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: r.upper));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制汉字大写'), duration: Duration(milliseconds: 1200)),
              );
            },
          ),
          const SizedBox(height: 10),
          _resultCard(
            context,
            title: '数字金额（元）',
            value: r.value == null ? '—' : r.value!.toStringAsFixed(2),
            mono: true,
            onCopy: () {
              final s = r.value?.toStringAsFixed(2) ?? '';
              Clipboard.setData(ClipboardData(text: s));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制数字金额'), duration: Duration(milliseconds: 1200)),
              );
            },
          ),
        ],
        const SizedBox(height: 16),
        Card(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('写成什么样才对', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const _Tip('整数金额末尾补「整」：100 → 壹佰元整'),
                const _Tip('有分无角，中间补「零」：107.05 → 壹佰零柒元零伍分'),
                const _Tip('有角无分，末尾补「整」：107.5 → 壹佰零柒元伍角整'),
                const _Tip('不足一元不写「零元」：0.5 → 伍角整；0.05 → 伍分'),
                const _Tip('连续多个 0 只写一个「零」：100000001 → 壹亿零壹'),
                const _Tip('整节全是 0 不写节名：100010000 → 壹亿零壹万'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _resultCard(
    BuildContext context, {
    required String title,
    required String value,
    required bool mono,
    required VoidCallback onCopy,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  SelectableText(
                    value,
                    style: TextStyle(
                      fontSize: mono ? 20 : 19,
                      height: 1.45,
                      fontWeight: FontWeight.w700,
                      fontFamily: mono ? 'monospace' : null,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '复制',
              icon: const Icon(Icons.content_copy, size: 18),
              onPressed: onCopy,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  final String text;
  const _Tip(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 6, right: 7), child: Icon(Icons.circle, size: 4)),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

// ============================================================ 亲戚称呼

class _KinBody extends StatefulWidget {
  const _KinBody();

  @override
  State<_KinBody> createState() => _KinBodyState();
}

class _KinBodyState extends State<_KinBody> {
  /// 关系链，用下标存（见 kin_data.dart）
  final List<int> _chain = [];
  bool _male = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<KinTable>(
      future: KinTable.load(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('称呼表读不出来：${snap.error}', textAlign: TextAlign.center),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final t = snap.data!;
        final key = _chain.join();
        final fwd = t.forward(key, male: _male);
        final rev = t.reverse(key, male: _male);
        final desc = KinTable.describe(key);

        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            // ---- 我是男 / 我 是女 ----
            Row(
              children: [
                Text('我是', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('男'), icon: Icon(Icons.male, size: 16)),
                    ButtonSegment(value: false, label: Text('女'), icon: Icon(Icons.female, size: 16)),
                  ],
                  selected: {_male},
                  onSelectionChanged: (s) => setState(() => _male = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ---- 关系链 + 结果 ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _chain.isEmpty ? '我' : '我的$desc',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600, color: scheme.primary),
                          ),
                        ),
                        if (_chain.isNotEmpty) ...[
                          IconButton(
                            tooltip: '退一步',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.backspace_outlined, size: 18),
                            onPressed: () => setState(() => _chain.removeLast()),
                          ),
                          IconButton(
                            tooltip: '清空',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _chain.clear()),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (_chain.isEmpty)
                      Text('从下面点一个关系开始',
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))
                    else ...[
                      Text('他是我什么人', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      SelectableText(
                        fwd.isEmpty ? '（这个组合查不到）' : fwd.join(' / '),
                        style: TextStyle(
                          fontSize: 24,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: fwd.isEmpty ? scheme.onSurfaceVariant : scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('我是什么人（他怎么叫我）',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(
                        rev.isEmpty ? '（这个组合查不到）' : rev.join(' / '),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ---- 十个基本关系按钮 ----
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < kKinRels.length; i++)
                  ActionChip(
                    label: Text(kKinRels[i], style: const TextStyle(fontSize: 13.5)),
                    onPressed: () {
                      // 到第 4 层就停：全表只算到深度 4，再往下查不到
                      if (_chain.length >= 4) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('最多拼 4 层关系（如「爸爸的哥哥的儿子」）'),
                            duration: Duration(milliseconds: 1500),
                          ),
                        );
                        return;
                      }
                      setState(() => _chain.add(i));
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '顺着点就是「A 的 B 的 C」：先点「爸爸」再点「哥哥」= 爸爸的哥哥。\n'
              '称呼按标准普通话；各地叫法差别很大（比如外公/姥爷、外婆/姥姥），'
              '这里只给一种最通用的写法。',
              style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}
