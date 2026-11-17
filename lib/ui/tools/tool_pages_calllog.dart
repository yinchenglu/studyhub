import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 通话记录生成（v2.0.0+37）
///
/// 归类：生活与娱乐。
///
/// 原生通道 `studyhub/calllog`（android_custom/MainActivity.kt）：
///   status / requestPermissions / contacts / sims / insert
///
/// 需要 WRITE_CALL_LOG 权限（dangerous，运行时弹窗授权）。
/// 写入走系统 CallLog.Calls 内容提供者，一条一条 insert；
/// 几十条在主线程会卡，原生那边是子线程 + Handler 回主线程。
///
/// 「呼出未接」的说明：Android 的通话记录只有 呼入(1) / 呼出(2) / 未接(3)
/// 三种 type，**没有「呼出未接」**（真实情况下呼出未接本来也不进记录）。
/// 这里做成「呼出 + 0 秒」，并在界面上写明，避免用户以为是 bug。
class CallLogToolPage extends StatefulWidget {
  const CallLogToolPage({super.key});

  @override
  State<CallLogToolPage> createState() => _CallLogToolPageState();
}

class _CallLogToolPageState extends State<CallLogToolPage> {
  static const MethodChannel _ch = MethodChannel('studyhub/calllog');

  final TextEditingController _numbers = TextEditingController();
  // v2.4.0（用户：「默认间隔改成3-5分钟」）
  final TextEditingController _gapMin = TextEditingController(text: '3');
  final TextEditingController _gapMax = TextEditingController(text: '5');
  final TextEditingController _durMin = TextEditingController(text: '30');
  final TextEditingController _durMax = TextEditingController(text: '60');

  bool _writeOk = false;
  bool _contactsOk = false;
  List<Map<String, dynamic>> _sims = const [];

  /// true = 呼出（默认），false = 呼入
  bool _outgoing = true;

  /// true = 接通（默认），false = 未接
  bool _connected = true;

  DateTime _start = DateTime.now();

  /// v2.4.0：随机未接（默认开）—— 随机挑 15%~20% 的号码，
  /// 在正式通话前补 1~3 条「未接」，并把该号码的正式通话往后挪 3~5 个顺序。
  bool _missed = true;

  /// v2.4.0：号码随机顺序（默认关）
  bool _shuffle = false;

  /// -1 = 默认卡；否则是 sims 的下标
  int _simIndex = -1;

  bool _busy = false;
  String? _result;
  String? _err;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _numbers.dispose();
    _gapMin.dispose();
    _gapMax.dispose();
    _durMin.dispose();
    _durMax.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('status');
      if (!mounted || r == null) return;
      final sims = (r['sims'] as List?)
              ?.whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          const <Map<String, dynamic>>[];
      setState(() {
        _writeOk = r['writeCallLog'] == true;
        _contactsOk = r['readContacts'] == true;
        _sims = sims;
        if (sims.isEmpty) _simIndex = -1;
        if (_simIndex >= sims.length) _simIndex = -1;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  Future<void> _askPerm() async {
    try {
      await _ch.invokeMethod('requestPermissions');
      // 系统弹窗是异步的，稍等一下再查状态（用户点完就回来了）
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  // ------------------------------------------------------------------ 号码

  /// 从文本框里解析号码。
  ///
  /// v2.4.0（用户：「要能自动识别每行的电话号码，自动去除电话号码
  /// 同一行的汉字和符号」）：按行扫描，每行抓**第一个 6 位以上的数字串**
  /// （数字之间允许夹空格 / 横线 / 全角横线），再把夹的符号去掉 ——
  /// 「张三 138 0013 8000 办公」「13800138000（移动）」都能认出
  /// 13800138000。行里没有像样的数字串就整行只留数字兜底。
  List<String> _parseNumbers() {
    final seen = <String>{};
    final out = <String>[];
    final lines = _numbers.text.split(RegExp(r'[\n,，;；]+'));
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = RegExp(r'\d[\d\s\-－—]{5,}').firstMatch(t);
      final String num;
      if (m != null) {
        num = m.group(0)!.replaceAll(RegExp(r'[\s\-－—]'), '');
      } else {
        num = t.replaceAll(RegExp(r'[^0-9+]'), '');
      }
      if (num.isEmpty) continue;
      if (seen.add(num)) out.add(num);
    }
    return out;
  }

  Future<void> _importContacts() async {
    if (!_contactsOk) {
      await _askPerm();
      if (!_contactsOk) return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ContactPickerSheet(channel: _ch),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final cur = _numbers.text.trimRight();
    setState(() {
      _numbers.text = cur.isEmpty ? picked : '$cur\n$picked';
    });
  }

  // ------------------------------------------------------------------ 时间

  String get _startText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${_start.year}-${two(_start.month)}-${two(_start.day)} '
        '${two(_start.hour)}:${two(_start.minute)}';
  }

  Future<void> _pickStartDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, _start.hour, _start.minute));
  }

  Future<void> _pickStartTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _start.hour, minute: _start.minute),
      helpText: '选第一条通话的时刻',
    );
    if (t == null || !mounted) return;
    setState(() => _start = DateTime(_start.year, _start.month, _start.day, t.hour, t.minute));
  }

  /// v2.1.0：一次把日期 + 时间都改掉。
  /// 以前只接了 `_pickStartDate`，`_pickStartTime` 写好了却没挂到界面上，
  /// 所以用户只能改日期、改不了时分。
  Future<void> _pickStartDateTime() async {
    await _pickStartDate();
    if (!mounted) return;
    await _pickStartTime();
  }

  // ------------------------------------------------------------------ 生成

  int _rangeInt(TextEditingController minC, TextEditingController maxC, int defMin, int defMax) {
    var a = int.tryParse(minC.text.trim()) ?? defMin;
    var b = int.tryParse(maxC.text.trim()) ?? defMax;
    if (a < 0) a = 0;
    if (b < a) b = a;
    return a + Random().nextInt(b - a + 1);
  }

  Future<void> _generate() async {
    if (_busy) return;
    if (!_writeOk) {
      await _askPerm();
      if (!_writeOk) {
        setState(() => _err = '还没拿到「写入通话记录」权限，点上面的按钮再授权一次');
        return;
      }
    }
    var nums = _parseNumbers();
    if (nums.isEmpty) {
      setState(() => _err = '先在「通话号码」里填号码，或用「从通讯录导入」');
      return;
    }

    // v2.4.0：号码随机顺序（默认关，按输入顺序生成）
    if (_shuffle) {
      nums.shuffle(Random());
    }

    // type：1 呼入 / 2 呼出 / 3 未接
    final int type;
    if (_connected) {
      type = _outgoing ? 2 : 1;
    } else {
      type = _outgoing ? 2 : 3;
    }

    final simId = (_simIndex >= 0 && _simIndex < _sims.length)
        ? ((_sims[_simIndex]['id'] as num?)?.toInt() ?? -1)
        : -1;

    // ---------- v2.4.0：随机未接（默认开） ----------
    // 随机挑 15%~20% 的号码，每个补 1~3 条「未接」记录；这些号码的
    // 正式通话往后挪 3~5 个顺序（等别的号码先打）。
    // 生成顺序表：每项 = (号码, 是否未接)。
    final extra = <String, int>{};
    if (_missed) {
      final p = 0.15 + Random().nextDouble() * 0.05; // 15%~20%
      for (final n in nums) {
        if (Random().nextDouble() < p) {
          extra[n] = 1 + Random().nextInt(3); // 1~3 条
        }
      }
    }
    final plan = <({String num, bool missed})>[];
    // 延迟队列：正式通话等 3~5 个「位置」再排进去
    final waiting = <({String num, int left})>[];
    void appendPlan(String num, bool missed) {
      plan.add((num: num, missed: missed));
      // 每排进一条，等待中的正式通话就近一步，到点的直接排入
      for (var i = 0; i < waiting.length;) {
        final w = waiting[i];
        if (w.left <= 1) {
          waiting.removeAt(i);
          plan.add((num: w.num, missed: false));
        } else {
          waiting[i] = (num: w.num, left: w.left - 1);
          i++;
        }
      }
    }

    for (final n in nums) {
      final k = extra[n] ?? 0;
      for (var j = 0; j < k; j++) {
        appendPlan(n, true); // 未接在前
      }
      if (k > 0) {
        // 正式通话往后排 3~5 个顺序（在下一次 appendPlan 时倒数）
        waiting.add((num: n, left: 3 + Random().nextInt(3)));
      } else {
        appendPlan(n, false);
      }
    }
    // 号码太少时可能等不到倒计时结束，收尾全部排入
    for (final w in waiting) {
      plan.add((num: w.num, missed: false));
    }

    final items = <Map<String, dynamic>>[];
    var cursor = _start.millisecondsSinceEpoch;
    for (var i = 0; i < plan.length; i++) {
      if (i > 0) {
        cursor += _rangeInt(_gapMin, _gapMax, 3, 5) * 60 * 1000;
      }
      final e = plan[i];
      final dur = e.missed ? 0 : (_connected ? _rangeInt(_durMin, _durMax, 30, 60) : 0);
      // v2.4.0（用户：「秒/微秒默认是0，改成随机」）：每条记录的秒和
      // 毫秒都随机 —— 不再全是「xx:xx:00.000」这种一眼假的整齐时间。
      // 随机量最大 60s，远小于最小间隔 3 分钟，顺序不会乱。
      final ts = cursor + Random().nextInt(60) * 1000 + Random().nextInt(1000);
      items.add({
        'number': e.num,
        'type': e.missed ? 3 : type,
        'date': ts,
        'duration': dur,
        if (simId >= 0) 'simId': simId,
      });
    }

    setState(() {
      _busy = true;
      _err = null;
      _result = null;
    });
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('insert', {'items': items});
      if (!mounted) return;
      final ok = (r?['ok'] as num?)?.toInt() ?? 0;
      final fail = (r?['fail'] as num?)?.toInt() ?? 0;
      final errs = (r?['errors'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final missedCount = plan.where((e) => e.missed).length;
      setState(() {
        _busy = false;
        _result = '已写入 $ok 条通话记录' +
            (_missed && missedCount > 0 ? '（含随机未接 $missedCount 条）' : '') +
            (fail > 0 ? '，$fail 条失败' : '') +
            (errs.isEmpty ? '' : '\n失败原因：${errs.join('；')}');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = '$e';
      });
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = _parseNumbers().length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('通话记录生成'),
        actions: [
          IconButton(
            tooltip: '刷新权限状态',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          // ---------- 权限 ----------
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: (_writeOk ? const Color(0xFF1D9E75) : const Color(0xFFE08A00))
                  .withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (_writeOk ? const Color(0xFF1D9E75) : const Color(0xFFE08A00))
                    .withValues(alpha: 0.30),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _writeOk ? Icons.verified_outlined : Icons.warning_amber_rounded,
                      size: 18,
                      color: _writeOk ? const Color(0xFF1D9E75) : const Color(0xFFE08A00),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _writeOk ? '已获得「写入通话记录」权限' : '还缺「写入通话记录」权限',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _writeOk
                      ? '同意授权后，本工具只会往系统通话记录里写你点「生成」的那几条，'
                          '不会读取你原有的通话记录。'
                      : 'Android 把「写入通话记录」归为敏感权限。点下面的按钮授权；'
                          '如果系统不再弹窗，需要到「设置 → 应用 → 学聚 → 权限」里手动打开。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _askPerm,
                      icon: const Icon(Icons.verified_user_outlined, size: 17),
                      label: Text(_writeOk ? '重新检查' : '申请权限'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _importContacts,
                      icon: const Icon(Icons.contacts_outlined, size: 17),
                      label: Text(_contactsOk ? '从通讯录导入' : '授权并导入通讯录'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ---------- 通话类型 ----------
          const _SectionTitle('通话类型'),
          _SegRow(
            children: [
              _seg('呼出', _outgoing, () => setState(() => _outgoing = true)),
              _seg('呼入', !_outgoing, () => setState(() => _outgoing = false)),
            ],
          ),
          const SizedBox(height: 8),
          _SegRow(
            children: [
              _seg('接通', _connected, () => setState(() => _connected = true)),
              _seg('未接', !_connected, () => setState(() => _connected = false)),
            ],
          ),
          if (!_connected && _outgoing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '注意：Android 没有「呼出未接」这个类型，会写成「呼出 · 0 秒」。',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),

          // ---------- v2.4.0：随机未接 / 随机顺序 ----------
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _missed,
            onChanged: (v) => setState(() => _missed = v),
            activeColor: scheme.primary,
            title: const Text('随机未接（默认开）',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '随机挑 15%~20% 的号码，在正式通话前补 1~3 条「未接」，'
              '并把该号码的正式通话往后挪 3~5 个顺序。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _shuffle,
            onChanged: (v) => setState(() => _shuffle = v),
            activeColor: scheme.primary,
            title: const Text('号码随机顺序（默认关）',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '打开后打乱号码先后顺序；关闭则按输入顺序依次生成。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 14),

          // ---------- 号码 ----------
          Row(
            children: [
              const _SectionTitle('通话号码'),
              const Spacer(),
              Text('$n 个', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _numbers,
            minLines: 4,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '一行一个号码；同一行的姓名、备注、符号会自动去掉\n例如：\n张三 138 0013 8000 办公\n13900139000（移动）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),

          const SizedBox(height: 14),

          // ---------- 时间 ----------
          const _SectionTitle('通话时间（第一条）'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // 点一下先选日期、再选时刻
                  onPressed: _pickStartDateTime,
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(_startText, style: const TextStyle(fontSize: 13)),
                ),
              ),
              IconButton(
                tooltip: '只改时刻',
                onPressed: _pickStartTime,
                icon: const Icon(Icons.schedule, size: 20),
              ),
              IconButton(
                tooltip: '改成现在',
                onPressed: () => setState(() => _start = DateTime.now()),
                icon: const Icon(Icons.restore, size: 20),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '后面的每一条按「通话间隔」往后顺延。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 14),

          // ---------- 间隔 / 时长 ----------
          const _SectionTitle('通话间隔（分钟）'),
          const SizedBox(height: 6),
          _RangeRow(min: _gapMin, max: _gapMax, hintMin: '1', hintMax: '3'),

          const SizedBox(height: 14),

          const _SectionTitle('通话时长（秒）'),
          const SizedBox(height: 6),
          _RangeRow(min: _durMin, max: _durMax, hintMin: '30', hintMax: '60'),

          if (_sims.length >= 2) ...[
            const SizedBox(height: 14),
            const _SectionTitle('拨号卡'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _sims.length; i++)
                  ChoiceChip(
                    label: Text(
                      '卡${i + 1} · ${_sims[i]['label'] ?? ''}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    selected: _simIndex == i,
                    onSelected: (_) => setState(() => _simIndex = i),
                  ),
                ChoiceChip(
                  label: const Text('默认卡', style: TextStyle(fontSize: 12.5)),
                  selected: _simIndex < 0,
                  onSelected: (_) => setState(() => _simIndex = -1),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '部分机型不认卡号标记（记录能写进去，只是卡1/卡2 的标签可能不显示）。',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],

          const SizedBox(height: 18),

          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.playlist_add_check, size: 19),
            label: Text(_busy ? '正在写入…' : '生成 ${n == 0 ? '' : '$n 条'}通话记录'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),

          if (_result != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1D9E75).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _result!,
                style: const TextStyle(fontSize: 12.5, height: 1.6, color: Color(0xFF116B4F)),
              ),
            ),
          if (_err != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _err!,
                style: TextStyle(fontSize: 12.5, height: 1.6, color: scheme.onErrorContainer),
              ),
            ),

          const SizedBox(height: 18),
          Text(
            '说明：写进系统通话记录后，可在「电话 → 通话记录」里看到。'
            '生成的记录与真实记录在数据库层面无法区分，请自行判断使用场合。'
            '每条记录的秒和毫秒会随机抖动，不会全是整分整秒。',
            style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? scheme.primary.withValues(alpha: 0.55) : scheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _SegRow extends StatelessWidget {
  final List<Widget> children;
  const _SegRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

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

class _RangeRow extends StatelessWidget {
  final TextEditingController min;
  final TextEditingController max;
  final String hintMin;
  final String hintMax;

  const _RangeRow({
    required this.min,
    required this.max,
    required this.hintMin,
    required this.hintMax,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(TextEditingController c, String hint) => SizedBox(
          width: 86,
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        );
    return Row(
      children: [
        box(min, hintMin),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('至', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
        box(max, hintMax),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '区间内随机',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 通讯录多选：带搜索框，勾完返回「换行分隔的号码串」
class _ContactPickerSheet extends StatefulWidget {
  final MethodChannel channel;
  const _ContactPickerSheet({required this.channel});

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  List<Map<String, dynamic>> _all = const [];
  final Set<String> _picked = <String>{};
  String _kw = '';
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.channel.invokeListMethod<dynamic>('contacts') ?? const [];
      if (!mounted) return;
      setState(() {
        _all = list
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kw = _kw.trim().toLowerCase();
    final shown = kw.isEmpty
        ? _all
        : _all
            .where((e) =>
                ('${e['name'] ?? ''}'.toLowerCase().contains(kw)) ||
                ('${e['number'] ?? ''}'.contains(kw)))
            .toList();

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _kw = v),
                    decoration: const InputDecoration(
                      hintText: '搜索姓名或号码',
                      prefixIcon: Icon(Icons.search, size: 19),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => Navigator.pop(context, _picked.join('\n')),
                  child: Text('加入 ${_picked.length}'),
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (_err != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_err!, style: TextStyle(color: scheme.error)),
            )
          else if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _all.isEmpty ? '通讯录是空的，或者没给权限' : '没找到匹配的联系人',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final e = shown[i];
                  final num = '${e['number'] ?? ''}';
                  final name = '${e['name'] ?? ''}';
                  final on = _picked.contains(num);
                  return CheckboxListTile(
                    dense: true,
                    value: on,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _picked.add(num);
                      } else {
                        _picked.remove(num);
                      }
                    }),
                    title: Text(name.isEmpty ? num : name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                    subtitle: name.isEmpty ? null : Text(num, style: const TextStyle(fontSize: 11.5)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
