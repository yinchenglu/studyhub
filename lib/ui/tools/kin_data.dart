/// 亲戚称呼查表（v1.8.0 需求12）
///
/// 这张表**不是**运行时算出来的，而是构建前用公认实现
/// （mumuy/relationship，MIT）离线跑出全表存成 `assets/data/kin.json`，
/// App 里只做查表。理由见 `.workbuddy/gen_kin_part.js` 的头部注释：
/// 关系链化简和「堂/表/从」的前缀分支规则太绕，自己重写必错；
/// 而且手机上只要「点按钮拼关系链」，用不上中文分词那一整套。
///
/// 表的结构（见 `.workbuddy/gen_kin.py`）：
///   n  称谓数组
///   f  我 → 他（自己是男）；值可能是 int（一个称谓）或 List<int>
///   r  他 → 我（自己是男）
///   f0 同上但自己是女，**只存跟 f 不同的条目**（大部分一样，省 2/3 体积）
///   r0 同上
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 参与拼链的 10 个基本关系，**顺序即编码**，跟生成脚本里的 RELS 必须一致。
const List<String> kKinRels = [
  '爸爸', '妈妈', '哥哥', '弟弟', '姐姐', '妹妹', '儿子', '女儿', '丈夫', '妻子',
];

class KinTable {
  final List<String> names;
  final Map<String, dynamic> _f;
  final Map<String, dynamic> _r;
  final Map<String, dynamic> _f0;
  final Map<String, dynamic> _r0;

  KinTable._(this.names, this._f, this._r, this._f0, this._r0);

  static KinTable? _inst;
  static Future<KinTable>? _loading;

  /// 懒加载：只有真的点进「亲戚称呼」才读这个 300 KB 的表。
  /// 别放 main() 里 —— 那是每次冷启动都要付的代价，而绝大多数人
  /// 用不到这个工具。
  static Future<KinTable> load() async {
    final cached = _inst;
    if (cached != null) return cached;
    return _loading ??= _doLoad();
  }

  static Future<KinTable> _doLoad() async {
    final raw = await rootBundle.loadString('assets/data/kin.json');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final t = KinTable._(
      (m['n'] as List).cast<String>(),
      (m['f'] as Map).cast<String, dynamic>(),
      (m['r'] as Map).cast<String, dynamic>(),
      (m['f0'] as Map).cast<String, dynamic>(),
      (m['r0'] as Map).cast<String, dynamic>(),
    );
    _inst = t;
    return t;
  }

  /// 一个键的值可能是 int（单个称谓）也可能是 List<int>（多个），两种都认。
  ///
  /// 生成脚本对长度为 1 的列表做了「退化成裸整数」的压缩，这里必须兼容，
  /// 否则一多半条目会被当成解析失败。
  List<String> _ids(dynamic v) {
    if (v == null) return const [];
    if (v is int) return [names[v]];
    if (v is List) {
      return [for (final e in v) names[e as int]];
    }
    return const [];
  }

  /// 「我怎么称呼他」。`chain` 是下标拼成的数字串（`'02'` = 爸爸的哥哥）。
  List<String> forward(String chain, {required bool male}) {
    if (chain.isEmpty) return const [];
    if (!male) {
      final d = _f0[chain];
      if (d != null) return _ids(d);
    }
    return _ids(_f[chain]);
  }

  /// 「他怎么称呼我」。
  List<String> reverse(String chain, {required bool male}) {
    if (chain.isEmpty) return const [];
    if (!male) {
      final d = _r0[chain];
      if (d != null) return _ids(d);
    }
    return _ids(_r[chain]);
  }

  /// 把数字串翻成人话：「02」→「爸爸的哥哥」。用于结果区展示。
  static String describe(String chain) {
    if (chain.isEmpty) return '我';
    final parts = <String>[];
    for (var i = 0; i < chain.length; i++) {
      final idx = int.tryParse(chain[i]);
      if (idx == null || idx < 0 || idx >= kKinRels.length) return chain;
      parts.add(kKinRels[idx]);
    }
    return parts.join('的');
  }

  int get chainCount => _f.length;
}
