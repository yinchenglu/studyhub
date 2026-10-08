import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// ------------------------------------------------------------------ 单位换算
class UnitConverterPage extends StatefulWidget {
  const UnitConverterPage({super.key});

  @override
  State<UnitConverterPage> createState() => _UnitConverterPageState();
}

class _Unit {
  final String name;
  final double factor; // 相对基准单位
  const _Unit(this.name, this.factor);
}

class _UnitConverterPageState extends State<UnitConverterPage> {
  static const _categories = <String, List<_Unit>>{
    '长度': [_Unit('毫米', 0.001), _Unit('厘米', 0.01), _Unit('米', 1), _Unit('千米', 1000), _Unit('英寸', 0.0254), _Unit('英尺', 0.3048), _Unit('里', 500)],
    '重量': [_Unit('毫克', 1e-6), _Unit('克', 0.001), _Unit('千克', 1), _Unit('吨', 1000), _Unit('斤', 0.5), _Unit('磅', 0.45359237)],
    '面积': [_Unit('平方米', 1), _Unit('平方厘米', 0.0001), _Unit('亩', 666.6667), _Unit('公顷', 10000), _Unit('平方千米', 1e6)],
    '体积': [_Unit('毫升', 0.001), _Unit('升', 1), _Unit('立方米', 1000)],
    '数据': [_Unit('B', 1), _Unit('KB', 1024), _Unit('MB', 1048576), _Unit('GB', 1073741824), _Unit('TB', 1099511627776)],
    '时间': [_Unit('秒', 1), _Unit('分钟', 60), _Unit('小时', 3600), _Unit('天', 86400)],
    '温度': [_Unit('摄氏度', 1), _Unit('华氏度', 1)],
  };

  String _cat = '长度';
  int _from = 2;
  int _to = 3;
  final _input = TextEditingController(text: '1');
  String _result = '0.01';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _calc() {
    final v = double.tryParse(_input.text.trim());
    if (v == null) {
      setState(() => _result = '请输入数字');
      return;
    }
    final units = _categories[_cat]!;
    if (_cat == '温度') {
      // 0 摄氏度，1 华氏度
      final celsius = _from == 0 ? v : (v - 32) * 5 / 9;
      final out = _to == 0 ? celsius : celsius * 9 / 5 + 32;
      setState(() => _result = out.toStringAsFixed(2));
      return;
    }
    final base = v * units[_from].factor;
    final out = base / units[_to].factor;
    setState(() => _result = out.toStringAsPrecision(out.abs() < 1e-6 || out.abs() > 1e9 ? 4 : 8).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''));
  }

  @override
  Widget build(BuildContext context) {
    final units = _categories[_cat]!;
    if (_from >= units.length) _from = 0;
    if (_to >= units.length) _to = 1;
    return Scaffold(
      appBar: AppBar(title: const Text('单位换算')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            children: _categories.keys
                .map((k) => ChoiceChip(label: Text(k), selected: _cat == k, onSelected: (_) => setState(() { _cat = k; _from = 0; _to = 1; _calc(); })))
                .toList(),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _input,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: '数值'),
            onChanged: (_) => _calc(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _from,
                  decoration: const InputDecoration(labelText: '从'),
                  items: [for (var i = 0; i < units.length; i++) DropdownMenuItem(value: i, child: Text(units[i].name))],
                  onChanged: (v) => setState(() { _from = v!; _calc(); }),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward)),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _to,
                  decoration: const InputDecoration(labelText: '到'),
                  items: [for (var i = 0; i < units.length; i++) DropdownMenuItem(value: i, child: Text(units[i].name))],
                  onChanged: (v) => setState(() { _to = v!; _calc(); }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                Text('结果', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                SelectableText(_result, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                Text('${units[_to].name}', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: _result)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制结果'),
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 二维码
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  final _c = TextEditingController(text: 'https://');
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('二维码生成')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _c,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '要生成二维码的内容（网址、文字、wifi 都行）'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: _c.text.trim().isEmpty
                  ? const SizedBox(width: 220, height: 220, child: Center(child: Text('输入内容后显示')))
                  : QrImageView(data: _c.text.trim(), version: QrVersions.auto, size: 220),
            ),
          ),
          const SizedBox(height: 16),
          const Text('提示：二维码只在本机生成，不上传任何服务器。', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 时间戳
class TimestampPage extends StatefulWidget {
  const TimestampPage({super.key});

  @override
  State<TimestampPage> createState() => _TimestampPageState();
}

class _TimestampPageState extends State<TimestampPage> {
  final _c = TextEditingController();
  String _out = '';

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _conv() {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    final n = int.tryParse(t);
    if (n == null) {
      final d = DateTime.tryParse(t);
      setState(() => _out = d == null ? '无法识别' : '${d.millisecondsSinceEpoch}（毫秒）\n${d.millisecondsSinceEpoch ~/ 1000}（秒）');
      return;
    }
    final ms = t.length >= 13 ? n : n * 1000;
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    setState(() => _out = DateFormat('yyyy-MM-dd HH:mm:ss').format(d) + '\n（本地时间）');
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('时间戳转换')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: const Text('当前时间戳'),
              subtitle: Text('${now.millisecondsSinceEpoch}（毫秒）\n${now.millisecondsSinceEpoch ~/ 1000}（秒）'),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${now.millisecondsSinceEpoch ~/ 1000}'));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制秒级时间戳')));
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _c,
            decoration: const InputDecoration(labelText: '输入时间戳或日期时间', hintText: '如 1730000000 或 2026-10-08 12:00:00'),
            onChanged: (_) => _conv(),
          ),
          const SizedBox(height: 16),
          if (_out.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(_out, style: const TextStyle(fontSize: 15, height: 1.6)),
            ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 取色器
class ColorPickerToolPage extends StatefulWidget {
  const ColorPickerToolPage({super.key});

  @override
  State<ColorPickerToolPage> createState() => _ColorPickerToolPageState();
}

class _ColorPickerToolPageState extends State<ColorPickerToolPage> {
  Color _color = const Color(0xFF185FA5);

  @override
  Widget build(BuildContext context) {
    final hex = '#${_color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    final r = (_color.value >> 16) & 0xFF;
    final g = (_color.value >> 8) & 0xFF;
    final b = _color.value & 0xFF;
    return Scaffold(
      appBar: AppBar(title: const Text('取色器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ColorPicker(
            pickerColor: _color,
            onColorChanged: (c) => setState(() => _color = c),
            labelTypes: const [],
            pickerAreaHeightPercent: 0.6,
          ),
          const SizedBox(height: 20),
          Container(height: 70, decoration: BoxDecoration(color: _color, borderRadius: BorderRadius.circular(12))),
          const SizedBox(height: 16),
          _row('HEX', hex),
          _row('RGB', 'rgb($r, $g, $b)'),
          _row('ARGB', '0xFF${hex.substring(1)}'),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(width: 60, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
            Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace'))),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
          ],
        ),
      );
}

/// ------------------------------------------------------------------ 随机抽签
class LotteryPage extends StatefulWidget {
  const LotteryPage({super.key});

  @override
  State<LotteryPage> createState() => _LotteryPageState();
}

class _LotteryPageState extends State<LotteryPage> {
  final _c = TextEditingController();
  int _count = 1;
  List<String> _result = const [];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _draw() {
    final items = _c.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (items.isEmpty) return;
    items.shuffle(Random());
    setState(() => _result = items.take(_count.clamp(1, items.length)).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('随机抽签')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _c,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '每行一个', hintText: '选项A\n选项B\n选项C'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('抽几个'),
              Expanded(
                child: Slider(value: _count.toDouble(), min: 1, max: 10, divisions: 9, label: '$_count', onChanged: (v) => setState(() => _count = v.round())),
              ),
              Text('$_count'),
            ],
          ),
          FilledButton.icon(onPressed: _draw, icon: const Icon(Icons.casino), label: const Text('开始抽签')),
          const SizedBox(height: 20),
          if (_result.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4), borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  const Text('抽签结果', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 10),
                  for (final r in _result)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(r, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 番茄钟
class PomodoroPage extends StatefulWidget {
  const PomodoroPage({super.key});

  @override
  State<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends State<PomodoroPage> {
  static const work = 25 * 60;
  static const rest = 5 * 60;
  int _left = work;
  bool _running = false;
  bool _isWork = true;
  int _rounds = 0;
  bool _timerOn = false;

  void _tick() {
    if (!_running) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !_running) return;
      setState(() {
        _left--;
        if (_left <= 0) {
          _isWork = !_isWork;
          if (_isWork) _rounds++;
          _left = _isWork ? work : rest;
        }
      });
      _tick();
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = (_left ~/ 60).toString().padLeft(2, '0');
    final s = (_left % 60).toString().padLeft(2, '0');
    final color = _isWork ? const Color(0xFFD85A30) : const Color(0xFF1D9E75);
    return Scaffold(
      appBar: AppBar(title: const Text('番茄钟')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 220,
              height: 220,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.1), border: Border.all(color: color.withOpacity(0.4), width: 3)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_isWork ? '专注' : '休息', style: TextStyle(fontSize: 14, color: color)),
                  Text('$m:$s', style: TextStyle(fontSize: 46, fontWeight: FontWeight.w600, color: color)),
                ],
              ),
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    setState(() => _running = !_running);
                    if (_running && !_timerOn) {
                      _timerOn = true;
                      _tick();
                    }
                  },
                  icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                  label: Text(_running ? '暂停' : '开始'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _running = false;
                    _isWork = true;
                    _left = work;
                  }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重置'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('已完成 $_rounds 个番茄', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            const Text('25 分钟专注 + 5 分钟休息', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// ------------------------------------------------------------------ 秒表
class StopwatchPage extends StatefulWidget {
  const StopwatchPage({super.key});

  @override
  State<StopwatchPage> createState() => _StopwatchPageState();
}

class _StopwatchPageState extends State<StopwatchPage> {
  final _sw = Stopwatch();
  final _laps = <int>[];
  bool _timerOn = false;

  void _tick() {
    if (!_sw.isRunning) return;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {});
        _tick();
      }
    });
  }

  String _fmt(int ms) {
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
    final t = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
    return '$m:$s.$t';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('秒表')),
      body: Column(
        children: [
          const SizedBox(height: 40),
          Text(_fmt(_sw.elapsedMilliseconds), style: const TextStyle(fontSize: 50, fontWeight: FontWeight.w600)),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    if (_sw.isRunning) {
                      _sw.stop();
                    } else {
                      _sw.start();
                      if (!_timerOn) {
                        _timerOn = true;
                        _tick();
                      }
                    }
                  });
                },
                icon: Icon(_sw.isRunning ? Icons.pause : Icons.play_arrow),
                label: Text(_sw.isRunning ? '暂停' : '开始'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _sw.reset();
                  _laps.clear();
                }),
                icon: const Icon(Icons.refresh),
                label: const Text('重置'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _laps.insert(0, _sw.elapsedMilliseconds)),
                icon: const Icon(Icons.flag_outlined),
                label: const Text('计次'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.builder(
              itemCount: _laps.length,
              itemBuilder: (context, i) => ListTile(dense: true, leading: Text('${_laps.length - i}'), title: Text(_fmt(_laps[i]))),
            ),
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 摩斯电码
class MorsePage extends StatefulWidget {
  const MorsePage({super.key});

  @override
  State<MorsePage> createState() => _MorsePageState();
}

class _MorsePageState extends State<MorsePage> {
  static const _map = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.', 'G': '--.', 'H': '....',
    'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---', 'P': '.--.',
    'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
    'Y': '-.--', 'Z': '--..', '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
  };

  final _in = TextEditingController();
  String _out = '';
  bool _toMorse = true;

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _conv() {
    final t = _in.text.trim();
    if (t.isEmpty) {
      setState(() => _out = '');
      return;
    }
    if (_toMorse) {
      setState(() {
        _out = t.toUpperCase().split('').map((ch) {
          if (ch == ' ') return '/';
          return _map[ch] ?? '';
        }).where((e) => e.isNotEmpty).join(' ');
      });
    } else {
      final rev = {for (final e in _map.entries) e.value: e.key};
      setState(() {
        _out = t.split(RegExp(r'\s+')).map((code) => code == '/' ? ' ' : (rev[code] ?? '?')).join();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('摩斯电码')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('文字 → 电码')), ButtonSegment(value: false, label: Text('电码 → 文字'))],
            selected: {_toMorse},
            onSelectionChanged: (s) => setState(() { _toMorse = s.first; _conv(); }),
          ),
          const SizedBox(height: 16),
          TextField(controller: _in, maxLines: 5, decoration: const InputDecoration(labelText: '输入内容'), onChanged: (_) => _conv()),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
            child: SelectableText(_out.isEmpty ? '结果会显示在这里' : _out, style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.7)),
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 加密编码
class CipherPage extends StatefulWidget {
  const CipherPage({super.key});

  @override
  State<CipherPage> createState() => _CipherPageState();
}

class _CipherPageState extends State<CipherPage> {
  final _in = TextEditingController();
  String _out = '';
  String _mode = 'base64Enc';

  void _run() {
    final t = _in.text;
    try {
      switch (_mode) {
        case 'base64Enc':
          setState(() => _out = base64Encode(utf8.encode(t)));
          break;
        case 'base64Dec':
          setState(() => _out = utf8.decode(base64Decode(t.trim())));
          break;
        case 'urlEnc':
          setState(() => _out = Uri.encodeComponent(t));
          break;
        case 'urlDec':
          setState(() => _out = Uri.decodeComponent(t.trim()));
          break;
        case 'md5':
          setState(() => _out = md5.convert(utf8.encode(t)).toString());
          break;
        case 'sha1':
          setState(() => _out = sha1.convert(utf8.encode(t)).toString());
          break;
        case 'sha256':
          setState(() => _out = sha256.convert(utf8.encode(t)).toString());
          break;
        case 'caesar':
          setState(() => _out = t.split('').map((ch) {
            final c = ch.codeUnitAt(0);
            if (c >= 65 && c <= 90) return String.fromCharCode((c - 65 + 3) % 26 + 65);
            if (c >= 97 && c <= 122) return String.fromCharCode((c - 97 + 3) % 26 + 97);
            if (c >= 48 && c <= 57) return String.fromCharCode((c - 48 + 3) % 10 + 48);
            return ch;
          }).join());
          break;
      }
    } catch (e) {
      setState(() => _out = '转换失败：$e');
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const modes = {
      'base64Enc': 'Base64 编码',
      'base64Dec': 'Base64 解码',
      'urlEnc': 'URL 编码',
      'urlDec': 'URL 解码',
      'md5': 'MD5',
      'sha1': 'SHA-1',
      'sha256': 'SHA-256',
      'caesar': '凯撒密码（+3）',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('加密与编码')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _mode,
            decoration: const InputDecoration(labelText: '方式'),
            items: modes.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) => setState(() { _mode = v!; _run(); }),
          ),
          const SizedBox(height: 14),
          TextField(controller: _in, maxLines: 4, decoration: const InputDecoration(labelText: '输入'), onChanged: (_) => _run()),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _run, icon: const Icon(Icons.play_arrow), label: const Text('转换')),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
            child: SelectableText(_out.isEmpty ? '结果' : _out, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.6)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _out.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _out)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制结果'),
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ 字数统计
class WordCountPage extends StatefulWidget {
  const WordCountPage({super.key});

  @override
  State<WordCountPage> createState() => _WordCountPageState();
}

class _WordCountPageState extends State<WordCountPage> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _c.text;
    final chars = t.length;
    final noSpace = t.replaceAll(RegExp(r'\s'), '').length;
    final cjk = RegExp(r'[\u4e00-\u9fa5]').allMatches(t).length;
    final words = t.trim().isEmpty ? 0 : t.trim().split(RegExp(r'\s+')).length;
    final lines = t.isEmpty ? 0 : t.split('\n').length;

    return Scaffold(
      appBar: AppBar(title: const Text('字数统计')),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _c,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(hintText: '把文字贴进来'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow),
            child: SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _stat('总字符', chars),
                  _stat('不含空格', noSpace),
                  _stat('汉字', cjk),
                  _stat('英文词', words),
                  _stat('行数', lines),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int v) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$v', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          Text(label, style: const TextStyle(fontSize: 11.5)),
        ],
      );
}

/// ------------------------------------------------------------------ 计算器
class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final _c = TextEditingController(text: '1+2*3');
  String _result = '7';

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _calc() {
    final r = _evaluate(_c.text);
    setState(() => _result = r == null ? '无法计算' : r.toString());
  }

  /// 支持 + - * / % ( ) 与 ^ 的简单表达式求值
  double? _evaluate(String s) {
    try {
      final tokens = _tokenize(s.replaceAll(' ', ''));
      final p = _Parser(tokens);
      final v = p.parseExpr();
      return p.pos >= tokens.length ? v : null;
    } catch (_) {
      return null;
    }
  }

  List<String> _tokenize(String s) {
    final out = <String>[];
    var num = '';
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (RegExp(r'[0-9.]').hasMatch(ch)) {
        num += ch;
      } else {
        if (num.isNotEmpty) {
          out.add(num);
          num = '';
        }
        out.add(ch);
      }
    }
    if (num.isNotEmpty) out.add(num);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('计算器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _c,
            decoration: const InputDecoration(labelText: '表达式', hintText: '如 (1+2)*3/4'),
            onChanged: (_) => _calc(),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35), borderRadius: BorderRadius.circular(14)),
            child: SelectableText(_result, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ['7', '8', '9', '/', '4', '5', '6', '*', '1', '2', '3', '-', '0', '.', '(', ')', '+', '^']
                .map((k) => SizedBox(
                      width: 62,
                      child: OutlinedButton(
                        onPressed: () {
                          _c.text += k;
                          _calc();
                        },
                        child: Text(k, style: const TextStyle(fontSize: 17)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _c.text = _c.text.isEmpty ? '' : _c.text.substring(0, _c.text.length - 1);
                    _calc();
                  },
                  child: const Text('退格'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    _c.clear();
                    setState(() => _result = '');
                  },
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Parser {
  final List<String> tokens;
  int pos = 0;
  _Parser(this.tokens);

  double parseExpr() {
    var v = parseTerm();
    while (pos < tokens.length && (tokens[pos] == '+' || tokens[pos] == '-')) {
      final op = tokens[pos++];
      final r = parseTerm();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double parseTerm() {
    var v = parseFactor();
    while (pos < tokens.length && (tokens[pos] == '*' || tokens[pos] == '/' || tokens[pos] == '%')) {
      final op = tokens[pos++];
      final r = parseFactor();
      if (op == '*') v *= r;
      if (op == '/') v /= r;
      if (op == '%') v %= r;
    }
    return v;
  }

  double parseFactor() {
    if (pos < tokens.length && tokens[pos] == '-') {
      pos++;
      return -parseFactor();
    }
    if (pos < tokens.length && tokens[pos] == '(') {
      pos++;
      final v = parseExpr();
      if (pos < tokens.length && tokens[pos] == ')') pos++;
      return v;
    }
    final base = double.parse(tokens[pos++]);
    if (pos < tokens.length && tokens[pos] == '^') {
      pos++;
      return pow(base, parseFactor()).toDouble();
    }
    return base;
  }
}
