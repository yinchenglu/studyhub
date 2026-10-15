// 在线字典 / 在线词典（v1.8.0 新增，对应用户第 9 / 10 / 11 条）。
//
// ── 需求原文 ────────────────────────────────────────────
//   9.  增加在线字典，也可以添加多个接口供选择，参考 https://www.sojson.com/word/
//   10. 增加在线词典，也可以添加多个接口供选择，参考 https://www.sojson.com/term/
//   11. 翻译增加一个词典的接口，参考 https://www.sojson.com/danci/；
//       翻译、在线字典、在线词典**可以放一个界面一起，进行切换**。
//
// ── 关于 sojson（先说明，免得以后又去试一遍）────────────
// 那三个链接是**网页**，不是 API：直接请求 `www.sojson.com/api/word/人`
// 和 `/api/danci/hello` 都是 **404**（实测），它的开放接口要注册 key。
// 所以这里没有照搬 sojson，而是找了三个**免 key、可直接请求**的源，
// 数据反而更全。要接 sojson 的话得让用户自己填 key，见文件末尾的说明。
//
// ── 三个源（全部实测过，不是照文档抄的）────────────────
//   * **百度汉语**  `hanyu.baidu.com/hanyu/ajax/search_list?wd=…&pn=0`
//     返回 JSON。单字给：拼音 / 部首 / 总笔画 / 五笔 / 笔顺 / 字形结构 /
//     繁体 / 组词 / 近反义词 / 笔顺动画；词语给：拼音 / 释义 / 出处 /
//     例句 / 近反义词 / 接龙。**内容最全，设为默认。**
//   * **汉典**      `www.zdic.net/hans/<词>`
//     返回 HTML，但结构很规整：`meta-badge`+`meta-value` 成对出现，
//     部首 / 部外 / 总笔画 / 统一码 / 笔顺 / 字形结构 / 字形分析 /
//     五笔 / 仓颉 / 郑码 / 四角号码 全都在；
//     `meta-pinyin` 里还带**真人发音 mp3 地址**（img.zdic.net，要 Referer）。
//   * **有道**      `dict.youdao.com/jsonapi?q=…`
//     中文查 `newhh.dataList[]`（现代汉语规范词典：拼音 + 词性 + 释义 + 例句），
//     英文查 `ec.word[0]`（英/美音标 + 释义 + 词形变化）。
//
// ── 为什么不复用 `tool_pages_translate.dart` 里的解析 ──────
// 那边那套是给「整句翻译 + 英汉词典」用的（私有的 `_Youdao`，
// 两百多行、专攻音标/词形变化/双语例句/网络释义）。这里的诉求完全不同：
// 中文单字和词语的**字形信息**（部首、笔画、笔顺、结构）那边根本不涉及。
// 硬合并会把两个都搞乱，所以这里另写一套，只共用「发音」那一个套路。
//
// ⚠️ HTML 版（`网页版小工具/在线字典.html`）里有一份**同逻辑的 JS 实现**，
//    改这里记得同步改那边。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tool_pages.dart';

/// 查的是「字」还是「词」。
///
/// 两者用的接口和解析完全一样（三个源都同时支持单字和词语），
/// 差别只有输入框提示、标题和一个「单字时把字形信息顶到最前」的细节，
/// 所以不写两套页面，只用一个枚举区分。
enum DictMode {
  hanzi('在线字典', '查单个汉字的读音、部首、笔画、字形、释义'),
  ci('在线词典', '查词语的意思、出处、例句、近反义词');

  const DictMode(this.title, this.hint);

  final String title;
  final String hint;
}

/// 可用数据源。顺序就是界面上 Chip 的顺序。
enum DictSource {
  baidu('百度汉语'),
  zdic('汉典'),
  youdao('有道');

  const DictSource(this.label);

  final String label;
}

/// 一个释义分块（标题 + 若干行）。
class DictBlock {
  const DictBlock(this.title, this.lines);

  final String title;
  final List<String> lines;
}

/// 一次查询的结果。三个源的原始返回差别很大，都归一到这里，
/// 界面只认这一个形状 —— 加新源就只需再写一个 parse 函数。
class DictResult {
  DictResult({
    required this.source,
    required this.title,
    this.pinyin,
    this.audio,
    List<(String, String)>? meta,
    List<DictBlock>? blocks,
  })  : meta = meta ?? <(String, String)>[],
        blocks = blocks ?? <DictBlock>[];

  final String source;
  final String title;

  /// 拼音（汉语）或音标（英文）
  String? pinyin;

  /// 发音文件地址，没有就不显示喇叭
  String? audio;

  /// 字形信息这类「短键值对」：部首 / 总笔画 / 五笔 …
  final List<(String, String)> meta;

  /// 释义、例句之类的长内容
  final List<DictBlock> blocks;

  bool get isEmpty => meta.isEmpty && blocks.isEmpty && pinyin == null;
}

// ===========================================================================
// 解析
// ===========================================================================

/// JSON 里的值可能是 Map / List / String 三种形状，统一取字符串列表。
///
/// 为什么要这么啰嗦：这几个接口都是「同一个字段有时给字符串、
/// 有时给对象、有时给数组」，写死一种一定会在某个词上崩。
List<String> flatStrings(Object? v) {
  final out = <String>[];
  if (v == null) return out;
  if (v is String) {
    final t = v.trim();
    if (t.isNotEmpty) out.add(t);
  } else if (v is num || v is bool) {
    out.add('$v');
  } else if (v is List) {
    for (final e in v) {
      out.addAll(flatStrings(e));
    }
  } else if (v is Map) {
    // 形状一：{"#text": "person", "@action": "link"}
    final t = v['#text'];
    if (t is String && t.trim().isNotEmpty) {
      out.add(t.trim());
    } else {
      // 形状二：{"l": {"i": [...]}}
      // 形状三（把 l 那层剥掉之后剩下的）：{"i": [...]}
      // 有道的释义就套在这两种里，少认一层就一个释义都取不到
      // （这一条是 test_dict_parse.py 拿真响应试出来的，别删）。
      final l = asMap(v['l']);
      out.addAll(flatStrings(l != null ? l['i'] : v['i']));
    }
  }
  return out;
}

/// 剥掉 HTML 标签。
///
/// 百度汉语 `add_mean[].definition` 长这样：
///   `能制造工具并使用工具进行劳动的高等动物<span>：男～。女～。</span>`
/// 不剥的话标签会原样画在界面上。这几个字段里也不需要还原 HTML 实体，
/// 所以只做剥标签这一件事，不引 HTML 包。
///
/// 限定标签长度 ≤40，避免把正文里出现的 `<` 当成标签起点吃掉一大段。
String stripTags(String s) => s.replaceAll(RegExp(r'<[^>]{1,40}>'), '').trim();


/// 把 Map 动态取出来，避免到处写 `as Map` 崩掉。
Map<String, Object?>? asMap(Object? v) => v is Map ? v.cast<String, Object?>() : null;

List<Object?> asList(Object? v) => v is List ? v : const <Object?>[];

String? str(Object? v) {
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  if (v is num) return '$v';
  return null;
}

/// 百度汉语：`hanyu.baidu.com/hanyu/ajax/search_list?wd=…&pn=0`
///
/// ⚠️ 这个接口的字段形状**很不整齐**，下面每一条都是拿真响应试出来的，
///    改的时候别凭直觉「规整化」：
///   * `radicals` / `stroke_count` / `wubi` / `word_wubi` / `struct_type` /
///     `traditional` 全都是**数组**（`["WWWW"]`、`["单一结构"]`），
///     不是字符串 —— 直接 `as String` 会拿到 null，界面上这几项就凭空消失。
///   * `stroke_order` 是**笔顺图的 SVG 路径**（`[{img, pic, …}]`），
///     不是笔顺编号，别当编号显示（会画出一串坐标）。
///   * `riddle` 是一串**谜语对象**（`[{riddle_class, question, …}]`）。
///   * `zuci_array` 是对象 `{ret_num, ret_array:[{name:[…]}]}`，不是数组。
///   * `mean_list` 只在**词语**上有，单字没有。
///   * 释义最干净的来源是 **`add_mean`**：每项是
///     `{pinyin, voice, definition[]}`，其中 `voice` 是百度 CDN 上的
///     **真人发音 mp3**（人 → …/ren2.mp3），`definition` 里带 `<span>` 标签。
///     ⚠️ 但**词语的 `add_mean` 是空数组**（字段在、里面没东西）——
///     别以为「有字段就有数据」。词语要退回 `definition` / `mean_list`，
///     而这两个来源给的常常是**同一份**内容，所以兜底那条路必须去重，
///     否则界面上会出现两块一模一样的释义（「学习」实测就是这样）。
DictResult? parseBaidu(Map<String, Object?> json) {
  final arr = asList(json['ret_array']);
  if (arr.isEmpty) return null;
  final it = asMap(arr.first);
  if (it == null) return null;

  final py = flatStrings(it['pinyin']);
  // ⚠️ `name` / `word_name` 也可能给数组（这个接口就是这么随性），一律走
  //    flatStrings。而且 title 要在这里**定下来**再拿去比繁体 —— 否则
  //    简繁同形（「人」的繁体还是「人」）时会多出一行没意义的「繁体 人」。
  final nameAny = flatStrings(it['name']);
  final wnameAny = flatStrings(it['word_name']);
  final title = (nameAny.isNotEmpty ? nameAny.first : null) ??
      (wnameAny.isNotEmpty ? wnameAny.first : null) ??
      (py.isNotEmpty ? py.first : '');
  final meta = <(String, String)>[];
  final blocks = <DictBlock>[];

  // ---- 字形信息（单字才有实质内容；词语这几项要么空、要么是 0）----
  final rad = flatStrings(it['radicals']);
  if (rad.isNotEmpty) meta.add(('部首', rad.join('、')));
  final sc = flatStrings(it['stroke_count']);
  // 词语的 stroke_count 会给一个 0，那是「没有」的意思，别显示成「总笔画 0」
  if (sc.isNotEmpty && sc.first != '0') meta.add(('总笔画', sc.join('、')));
  final wubi = flatStrings(it['word_wubi']);
  final wubiAny = wubi.isNotEmpty ? wubi : flatStrings(it['wubi']);
  if (wubiAny.isNotEmpty) meta.add(('五笔', wubiAny.join(' ').toUpperCase()));
  final st = flatStrings(it['struct_type']);
  if (st.isNotEmpty) meta.add(('字形结构', st.join('、')));
  final trad = flatStrings(it['word_traditional']);
  final tradAny = trad.isNotEmpty ? trad : flatStrings(it['traditional']);
  // 简繁同形（「人」的繁体还是「人」）时不必显示，那是纯噪音
  if (tradAny.isNotEmpty && tradAny.first != title) {
    meta.add(('繁体', tradAny.join('、')));
  }

  // ---- 释义：优先 add_mean（单字 / 词语都有，还捎带真人发音）----
  // 按**读音**聚合，而不是按 add_mean 的条数判断：
  // 实测「学习」的 add_mean 有两条、但读音是同一个，按条数判断会
  // 把同一段释义原样显示两遍。多音字（比如「行」「长」）才该分开摆。
  String? audio;
  final byPy = <String, List<String>>{};
  final noPy = <String>[];
  final am = asList(it['add_mean']);
  for (final a in am) {
    final aa = asMap(a);
    if (aa == null) continue;
    // 发音地址只取第一个：多音字会给好几条，播放器也只有一个
    audio ??= str(aa['voice']);
    final defs = <String>[];
    for (final d in flatStrings(aa['definition'])) {
      final t = stripTags(d);
      if (t.isNotEmpty) defs.add(t);
    }
    if (defs.isEmpty) continue;
    final apy = str(aa['pinyin']);
    if (apy == null) {
      noPy.addAll(defs);
    } else {
      byPy.putIfAbsent(apy, () => <String>[]).addAll(defs);
    }
  }
  if (byPy.length <= 1) {
    // 只有一个读音（或压根没有读音）→ 合成一块「释义」
    final all = <String>[];
    for (final v in byPy.values) {
      all.addAll(v);
    }
    all.addAll(noPy);
    if (all.isNotEmpty) blocks.insert(0, DictBlock('释义', _dedup(all)));
  } else {
    for (final e in byPy.entries) {
      blocks.add(DictBlock('读音 ${e.key}', _dedup(e.value)));
    }
    if (noPy.isNotEmpty) blocks.add(DictBlock('释义', _dedup(noPy)));
  }

  // ---- 兜底：add_mean 为空时走这里（**词语就是这种情况**，见上面的说明）----
  // 顶层 `definition` 和 `mean_list[].definition` 经常给的是同一份内容，
  // 所以先把两边都收进池子、最后统一去重，而不是各出一块。
  if (blocks.isEmpty) {
    final byPy2 = <String, List<String>>{};
    final noPy2 = <String>[];
    for (final d in flatStrings(it['definition'])) {
      final t = stripTags(d);
      if (t.isNotEmpty) noPy2.add(t);
    }
    for (final m in asList(it['mean_list'])) {
      final mm = asMap(m);
      if (mm == null) continue;
      final pys = flatStrings(mm['pinyin']);
      final ds = <String>[];
      for (final d in flatStrings(mm['definition'])) {
        final t = stripTags(d);
        if (t.isNotEmpty) ds.add(t);
      }
      if (ds.isEmpty) continue;
      if (pys.isEmpty) {
        noPy2.addAll(ds);
      } else {
        byPy2.putIfAbsent(pys.first, () => <String>[]).addAll(ds);
      }
    }
    if (byPy2.length <= 1) {
      final all = <String>[];
      for (final v in byPy2.values) {
        all.addAll(v);
      }
      all.addAll(noPy2);
      if (all.isNotEmpty) blocks.add(DictBlock('释义', _dedup(all)));
    } else {
      for (final e in byPy2.entries) {
        blocks.add(DictBlock('读音 ${e.key}', _dedup(e.value)));
      }
      if (noPy2.isNotEmpty) blocks.add(DictBlock('释义', _dedup(noPy2)));
    }
  }

  // ---- 百科释义（是**纯文本**，比 detail_mean 那段 HTML 好处理得多）----
  final bm = str(asMap(it['baike_info'])?['baike_mean']);
  if (bm != null && bm.length > 8) blocks.add(DictBlock('百科释义', [bm]));

  _addIfAny(blocks, '出处', it['story']);
  _addIfAny(blocks, '典故', it['legend']);
  _addIfAny(blocks, '例句', it['liju']);
  _addIfAny(blocks, '近义词', it['synonym']);
  _addIfAny(blocks, '反义词', it['antonym']);
  _addIfAny(blocks, '接龙', it['jielong']);

  final src = flatStrings(it['source']);
  if (src.isNotEmpty) blocks.add(DictBlock('来源', src));

  // ---- 组词：结构是 {ret_num, ret_array:[{name:[…]}]} ----
  // 「人」这个字有 4000 多条组词，全列出来是一面墙，截到 30 条
  final za = asMap(it['zuci_array']);
  final words = <String>[];
  for (final z in asList(za?['ret_array'])) {
    words.addAll(flatStrings(asMap(z)?['name']));
    if (words.length >= 40) break;
  }
  if (words.isNotEmpty) {
    final uniq = _dedup(words);
    blocks.add(DictBlock(
      '组词（共 ${za?['ret_num'] ?? uniq.length} 条，列出前 ${uniq.length > 30 ? 30 : uniq.length} 条）',
      uniq.length > 30 ? uniq.sublist(0, 30) : uniq,
    ));
  }

  return DictResult(
    source: DictSource.baidu.label,
    title: title.isEmpty ? (py.isNotEmpty ? py.first : '（无结果）') : title,
    pinyin: py.isEmpty ? null : py.join(' / '),
    audio: audio,
    blocks: blocks,
    meta: meta,
  );
}

void _addIfAny(List<DictBlock> out, String title, Object? v) {
  final ls = flatStrings(v);
  if (ls.isNotEmpty) out.add(DictBlock(title, _dedup(ls)));
}

List<String> _dedup(List<String> xs) {
  final seen = <String>{};
  final out = <String>[];
  for (final x in xs) {
    if (seen.add(x)) out.add(x);
  }
  return out;
}

/// 汉典：`www.zdic.net/hans/<词>` 的 HTML。
///
/// 它没有 API，但页面上那对 `meta-badge` / `meta-value` 是**规整的**，
/// 抽出来正好是「部首 / 总笔画 / 五笔 / 郑码…」这张表；
/// `meta-pinyin` 里还带真人发音的 mp3 地址。
/// 用正则而不是 XML 解析器：这页 HTML 里有一堆没闭合的标签，
/// 塞给严格解析器会直接抛异常，正则反而更稳。
DictResult? parseZdic(String html) {
  if (html.isEmpty) return null;

  // ---- 拼音 + 发音 ----
  String? pinyin;
  String? audio;
  final mPy = RegExp(r'class="meta-pinyin"[^>]*>([^<]{1,40})').firstMatch(html);
  if (mPy != null) pinyin = mPy.group(1)?.trim();
  final mAu = RegExp(r'data-audio="([^"]+\.mp3)"').firstMatch(html);
  if (mAu != null) audio = _unescape(mAu.group(1)!);

  // ---- 键值对 ----
  final meta = <(String, String)>[];
  final re = RegExp(
      r'meta-badge"[^>]*>([^<]{1,12})</span><span class="meta-value[^"]*">([^<]{0,80})<');
  for (final m in re.allMatches(html)) {
    final k = m.group(1)?.trim() ?? '';
    final v = m.group(2)?.trim() ?? '';
    if (k.isEmpty || v.isEmpty) continue;
    if (k == '统一码') continue; // 对用户没意义
    meta.add((k, _unescape(v)));
  }
  // 部首是单独一段（它是链接不是 meta-value），补进来
  final mRad = RegExp(r'meta-radical"[^>]*>([^<]{1,4})<').firstMatch(html);
  if (mRad != null && mRad.group(1) != null) {
    meta.insert(0, ('部首', mRad.group(1)!.trim()));
  }

  if (meta.isEmpty && pinyin == null) return null;
  return DictResult(
    source: DictSource.zdic.label,
    title: '',
    pinyin: pinyin,
    audio: audio,
    meta: meta,
  );
}

/// 有道：`dict.youdao.com/jsonapi?q=…`
///
/// 中文用 `newhh`（现代汉语规范词典），英文用 `ec`。
/// `newhh` 的形状是 `dataList[] = {pinyin, sense[] = {def[], examples[], cat}}`，
/// 比 `ce` / `web_trans` 那种混着对象和字符串的好解得多。
DictResult? parseYoudao(Map<String, Object?> json) {
  final meta = <(String, String)>[];
  final blocks = <DictBlock>[];
  String? title;
  String? pinyin;
  String? audio;

  // ---- ① 汉语（现代汉语规范词典）----
  final hh = asMap(json['newhh']);
  if (hh != null) {
    final dl = asList(hh['dataList']);
    for (final d in dl) {
      final dd = asMap(d);
      if (dd == null) continue;
      final py = str(dd['pinyin']);
      if (py != null) {
        title ??= str(dd['name']);
        pinyin ??= py;
      }
      final senses = asList(dd['sense']);
      final lines = <String>[];
      for (final s in senses) {
        final ss = asMap(s);
        if (ss == null) continue;
        final cat = str(ss['cat']);
        for (final def in flatStrings(ss['def'])) {
          lines.add(cat == null ? def : '【$cat】$def');
        }
        final ex = flatStrings(ss['examples']);
        if (ex.isNotEmpty) lines.add('例：${ex.join('；')}');
      }
      if (lines.isNotEmpty) {
        blocks.add(DictBlock('汉语释义${py == null ? '' : '（$py）'}', lines));
      }
    }
  }

  // ---- ② 英文（音标 + 释义 + 词形变化）----
  final ec = asMap(json['ec']);
  if (ec != null) {
    final words = asList(ec['word']);
    if (words.isNotEmpty) {
      final w = asMap(words.first);
      if (w != null) {
        // `return-phrase` 是个三层嵌套：{"return-phrase": {"l": {"i": "hello"}}}，
        // 而且 `i` 有时是字符串、有时是数组 —— 所以用 flatStrings 兜住两种。
        final rp = asMap(asMap(w['return-phrase'])?['l']);
        final rpi = flatStrings(rp?['i']);
        title ??= (rpi.isNotEmpty ? rpi.first : null) ?? str(json['input']);
        final uk = str(w['ukphone']);
        final us = str(w['usphone']);
        if (uk != null) meta.add(('英音', '[$uk]'));
        if (us != null) meta.add(('美音', '[$us]'));
        if (uk != null || us != null) pinyin = '英 [${uk ?? '-'}]  美 [${us ?? '-'}]';
        // 发音：有道给的是**半个 URL** —— `hello&type=1`（type=1 英音 /
        // type=2 美音），前面补上 dictvoice 的地址就对了。
        // ⚠️ 早先按「value 是纯单词」处理、又拼了个 `&type=1`，
        // 拼出 `…audio=hello&type=1&type=1` —— 是校验脚本抓出来的，别再改回去。
        final sp = str(w['ukspeech']) ?? str(w['usspeech']);
        if (sp != null) {
          audio = sp.startsWith('http')
              ? sp
              : 'https://dict.youdao.com/dictvoice?audio=$sp';
        }
        final lines = <String>[];
        for (final t in asList(w['trs'])) {
          final tt = asMap(t);
          if (tt == null) continue;
          for (final tr in asList(tt['tr'])) {
            lines.addAll(flatStrings(asMap(tr)?['l']));
          }
        }
        if (lines.isNotEmpty) blocks.insert(0, DictBlock('释义', _dedup(lines)));
        // 词形变化
        final wfs = asList(w['wfs']);
        if (wfs.isNotEmpty) {
          final fl = <String>[];
          for (final f in wfs) {
            final ff = asMap(f);
            if (ff == null) continue;
            final n = str(ff['name']);
            final v = flatStrings(ff['value']).join('、');
            if (v.isNotEmpty) fl.add(n == null ? v : '$n：$v');
          }
          if (fl.isNotEmpty) blocks.add(DictBlock('词形变化', fl));
        }
      }
    }
  }

  if (blocks.isEmpty && meta.isEmpty) return null;
  return DictResult(
    source: DictSource.youdao.label,
    title: title ?? '',
    pinyin: pinyin,
    audio: audio,
    meta: meta,
    blocks: blocks,
  );
}

/// 把 HTML 实体还原成字符。
///
/// 汉典那边只用到几个（`&amp;` `&#39;` 之流），没必要引一个 HTML 包。
String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ');

// ===========================================================================
// 界面
// ===========================================================================

/// 在线字典 / 在线词典页面。用 [DictMode] 区分查字还是查词。
class DictLookupView extends StatefulWidget {
  const DictLookupView({super.key, required this.mode});

  final DictMode mode;

  @override
  State<DictLookupView> createState() => _DictLookupViewState();
}

class _DictLookupViewState extends State<DictLookupView> {
  final _input = TextEditingController();

  /// 自己建一个 Dio，不用 WebDAV 那个（域名完全不同，也不该带它的认证头）。
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    // 默认的 dart-http UA 太容易被这些站点拦，报一个普通浏览器的
    headers: const <String, String>{
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
    },
  ));

  /// 每个模式各记一份数据源选择 —— 用户在字典里挑「汉典」，
  /// 切到词典不该被一起改掉，那是两件独立的事。
  static final Map<DictMode, DictSource> _picked = <DictMode, DictSource>{
    DictMode.hanzi: DictSource.baidu,
    DictMode.ci: DictSource.baidu,
  };

  DictSource get _src => _picked[widget.mode]!;

  bool _busy = false;
  String? _error;
  DictResult? _r;
  String _query = '';
  Player? _player;

  @override
  void dispose() {
    _input.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final q = _input.text.trim();
    if (q.isEmpty) {
      setState(() => _error = '先输入要查的内容');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _r = null;
      _query = q;
    });
    try {
      final r = await _fetch(_src, q);
      if (!mounted) return;
      setState(() {
        _r = r;
        if (r == null || r.isEmpty) {
          _error = '${_src.label}没查到「$q」';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '请求失败：${shortErr(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<DictResult?> _fetch(DictSource s, String q) async {
    switch (s) {
      case DictSource.baidu:
        final r = await _dio.get<String>(
          'https://hanyu.baidu.com/hanyu/ajax/search_list'
          '?wd=${Uri.encodeComponent(q)}&pn=0',
          options: Options(responseType: ResponseType.plain),
        );
        final d = asMap(jsonDecode(_noBom(r.data ?? '')));
        return d == null ? null : parseBaidu(d);
      case DictSource.zdic:
        final r = await _dio.get<String>(
          'https://www.zdic.net/hans/${Uri.encodeComponent(q)}',
          options: Options(
            responseType: ResponseType.plain,
            headers: const <String, String>{'Referer': 'https://www.zdic.net/'},
          ),
        );
        final res = parseZdic(r.data ?? '');
        // 汉典的页面上拿得到词，但标题要自己填
        return res == null ? null : (res.title.isEmpty ? _withTitle(res, q) : res);
      case DictSource.youdao:
        final r = await _dio.get<String>(
          'https://dict.youdao.com/jsonapi?q=${Uri.encodeComponent(q)}',
          options: Options(responseType: ResponseType.plain),
        );
        final d = asMap(jsonDecode(_noBom(r.data ?? '')));
        return d == null ? null : parseYoudao(d);
    }
  }

  /// DictResult 的字段是 final 的，这里重建一个只为填标题 ——
  /// 比给 title 开一个 var 更容易看出「标题是补出来的」。
  DictResult _withTitle(DictResult r, String t) => DictResult(
        source: r.source,
        title: t,
        pinyin: r.pinyin,
        audio: r.audio,
        meta: r.meta,
        blocks: r.blocks,
      );

  /// 接口偶尔会带 BOM 或前后空白，统一处理掉再交给 jsonDecode
  static String _noBom(String s) {
    var t = s.trim();
    if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1);
    return t;
  }

  /// 发音。
  ///
  /// 汉典给的是 img.zdic.net 上的 mp3，**必须带 Referer** 才拿得到，
  /// 所以走「先下载到临时文件再播」这条路（media_kit 直接播 URL
  /// 加不了请求头，这是项目里已经验证过的做法，见 tool_pages_translate.dart）。
  /// 没有现成地址时退回有道的 dictvoice —— 它对中文单字和英文单词都认。
  Future<void> _speak(DictResult r) async {
    final url = r.audio ??
        'https://dict.youdao.com/dictvoice?type=${_isChinese(r.title) ? 0 : 1}'
            '&audio=${Uri.encodeComponent(r.title)}';
    try {
      final dir = await getTemporaryDirectory();
      final key = url.hashCode.toRadixString(16);
      final f = File(p.join(dir.path, 'dict_$key.mp3'));
      if (!await f.exists()) {
        final resp = await _dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: const <String, String>{'Referer': 'https://www.zdic.net/'},
          ),
        );
        final bytes = resp.data;
        if (bytes == null || bytes.isEmpty) throw Exception('没拿到音频');
        // 挡一下「接口鉴权失败返回 JSON」的情况：把 JSON 原样写成 .mp3
        // 会得到一个点开播不出来的文件，用户只会觉得「点了没反应」。
        // （百度那个老的 tts 接口就是这么返回 `Not verified user` 的。）
        if (!_looksLikeAudio(bytes)) throw Exception('这个源没有可用的发音');
        await f.writeAsBytes(bytes);
      }
      _player ??= Player();
      await _player!.setVolume(100);
      await _player!.open(Media('file://${f.path}'));
    } catch (e) {
      if (mounted) toast(context, '发音取不到：${shortErr(e)}');
    }
  }

  /// 粗略判断一段字节像不像音频文件。
  ///
  /// 只认文件头，不做完整解析 —— 目的是把「返回的是错误 JSON」
  /// 和「返回的是音频」分开，不需要更严格。
  /// 实测这三个源给的 mp3 都以 `ID3` 开头（`49 44 33`）。
  static bool _looksLikeAudio(List<int> b) {
    if (b.length < 4) return false;
    if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return true; // ID3v2
    if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return true; // MP3 裸帧同步
    if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) return true; // OggS
    if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) return true; // fLaC
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) return true; // RIFF
    return false;
  }

  static bool _isChinese(String s) =>
      s.isNotEmpty && s.codeUnitAt(0) > 0x2E80;

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: _input,
                  maxLines: 1,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _go(),
                  decoration: InputDecoration(
                    hintText: widget.mode == DictMode.hanzi
                        ? '输入一个汉字，例如：人'
                        : '输入一个词语，例如：学习',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: _input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() {
                              _input.clear();
                              _error = null;
                              _r = null;
                              _query = '';
                            }),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                // ---- 数据源选择：用户第 9/10 条明确要「多个接口供选择」----
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final s in DictSource.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: _src == s,
                        onSelected: (_) {
                          _picked[widget.mode] = s;
                          setState(() {
                            _error = null;
                            _r = null;
                          });
                          // 换了源就自动重查一次 —— 用户点源 Chip 的意图
                          // 显然是想「用这家再看看」，还要再点一次查询很别扭
                          if (_query.isNotEmpty) _go();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _go,
                        icon: _busy
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.search, size: 18),
                        label: Text(_busy ? '查询中…' : '查询'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null) _errBox(scheme, _error!),
        if (_r != null && !_r!.isEmpty) ..._result(scheme, _r!),
        const SizedBox(height: 14),
        _notes(scheme),
      ],
    );
  }

  List<Widget> _result(ColorScheme scheme, DictResult r) {
    return <Widget>[
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(r.title.isEmpty ? _query : r.title,
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w700)),
                        if (r.pinyin != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(r.pinyin!,
                              style: TextStyle(
                                  fontSize: 14,
                                  color: scheme.primary,
                                  letterSpacing: 0.5)),
                        ],
                      ],
                    ),
                  ),
                  if (r.title.isNotEmpty)
                    ActionChip(
                      avatar: const Icon(Icons.volume_up, size: 16),
                      label: const Text('发音'),
                      onPressed: () => _speak(r),
                    ),
                ],
              ),
              if (r.meta.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                // 字形信息用小胶囊排，比一行行「键：值」省地方也更好扫
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final kv in r.meta)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text('${kv.$1} ${kv.$2}',
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
              ],
              if (r.blocks.isNotEmpty) const SizedBox(height: 6),
              for (final b in r.blocks) ...<Widget>[
                const SizedBox(height: 12),
                Text(b.title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: 5),
                for (final line in b.lines) _line(line),
              ],
              const SizedBox(height: 12),
              Text('数据源：${r.source}',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _line(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(t, style: const TextStyle(fontSize: 13.5, height: 1.45)),
      );

  Widget _errBox(ColorScheme scheme, String msg) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
            ),
          ],
        ),
      );

  Widget _notes(ColorScheme scheme) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          widget.mode == DictMode.hanzi
              ? '三个数据源都是**免 key 的公开接口**，实测可用：\n'
                  '· 百度汉语 —— 内容最全，单字的部首/笔画/笔顺/组词都有（默认）\n'
                  '· 汉典 —— 字形信息最细，还带**真人发音**\n'
                  '· 有道 —— 现代汉语规范词典的义项和例句，最规范\n'
                  '没有「发声」按钮时说明这个源没给音频地址。'
              : '三个数据源都是**免 key 的公开接口**，实测可用：\n'
                  '· 百度汉语 —— 释义 + 出处 + 例句 + 近反义词 + 接龙（默认）\n'
                  '· 汉典 —— 偏字形和字源，词语的信息比百度少一些\n'
                  '· 有道 —— 现代汉语规范词典，义项分得最清楚\n'
                  '查英文单词请用「翻译」页的有道词典，那边有双语例句。',
          style: TextStyle(
              fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
        ),
      );
}
