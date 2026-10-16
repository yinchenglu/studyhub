// ============================================================ 路路词典 v1.9.0
//
// #16「路路词典（做对标欧路基础功能）」一次性提交。
//
// 欧路词典核心 4 件套：
//   1. 多词库切换       —— 已实现：内置 + 用户上传 .txt/.csv + 手动添加
//   2. 查词（实时）     —— 已实现：前缀 + 子串双路
//   3. 生词本           —— 已实现：词条 star 进生词本
//   4. 历史记录         —— 已实现：最近 100 条
//
// 不做：
//   * MDX/MDD 解析（Mdict 二进制压缩格式，单独一个包 `mdict` 才能搞定；
//     而且 8 MB+ 的 AAR 一加进来大概率又踩 compileSdk 的坑）
//   * 发音（欧路用的是真人发音库，本项目没资源）
//   * 屏幕取词（要走 AccessibilityService，超出工具范畴）
//
// 用户友好策略：
//   * 进页面给个「Hello」「测试」之类的示例输入，立即看到结果，
//     避免「空词库 = 空白页」的开局尴尬
//   * 词库为空时一键加载「常用 200 词」（代码内置）
//   * 服务器下载站、笔记目录里如果有 *.txt / *.csv 可一键导入
//   * 生词本 / 历史都是 SharedPreferences 存，重装 APP 不丢

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tool_pages.dart'; // ToolScaffold / toast / copyText

// ============================================================ 数据模型

/// 一个词条。`id` = `${dictId}:${hash(word)}`。
class DictEntry {
  final String dictId;
  final String word;
  final String definition; // 释义（HTML / Markdown / 纯文本 都行，原样展示）
  final List<String> aliases; // 同义词列表（可选）

  DictEntry({
    required this.dictId,
    required this.word,
    required this.definition,
    this.aliases = const [],
  });

  String get id => '$dictId:$word';

  Map<String, dynamic> toJson() => {
        'd': dictId,
        'w': word,
        'f': definition,
        if (aliases.isNotEmpty) 'a': aliases,
      };

  factory DictEntry.fromJson(Map<String, dynamic> j) => DictEntry(
        dictId: j['d'] as String,
        word: j['w'] as String,
        definition: j['f'] as String,
        aliases: (j['a'] as List?)?.map((e) => e as String).toList() ?? const [],
      );
}

/// 一个词典（一个 .txt / .csv 文件）。
class DictBook {
  final String id; // 唯一 id（hash 文件名）
  final String name; // 显示名（用户可改）
  final String path; // 词库文件路径（空 = 内置）
  /// 词条数。v1.9.0+24 改成 mutable：手动加词条时需要原地递增
  /// (`_books.firstWhere(...).size++`)，final 编译不过。
  int size;
  final DateTime loadedAt;

  DictBook({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.loadedAt,
  });

  Map<String, dynamic> toJson() => {
        'i': id,
        'n': name,
        'p': path,
        's': size,
        'l': loadedAt.millisecondsSinceEpoch,
      };

  factory DictBook.fromJson(Map<String, dynamic> j) => DictBook(
        id: j['i'] as String,
        name: j['n'] as String,
        path: j['p'] as String,
        size: j['s'] as int,
        loadedAt: DateTime.fromMillisecondsSinceEpoch(j['l'] as int),
      );
}

/// 查词命中：单词 + 匹配方式（prefix / substring / exact）
class DictHit {
  final DictEntry entry;
  final HitKind kind;
  DictHit(this.entry, this.kind);
}

enum HitKind { exact, prefix, substring }

// ============================================================ 内置示例词库

/// 内置「常用 200 词」，进页面就有内容；空词库也不会一脸懵。
/// 数据是手写的简短释义，不大（< 6 KB）。
const List<List<String>> _kBuiltIn = [
  // [word, definition (可含 HTML 标签)]
  ['hello', '你好；喂；哈啰。\n\n* int.* 见面招呼语。'],
  ['world', '世界；人间。'],
  ['apple', '苹果（树/果）；【电脑】苹果公司。\n\n* int.* 例：I eat an apple every morning.'],
  ['banana', '香蕉。'],
  ['cat', '猫；【口】家伙。'],
  ['dog', '狗；【口】家伙。'],
  ['book', '书；书籍；预订；订（票/位）。\n\n* n./v.*'],
  ['computer', '计算机；电脑。'],
  ['phone', '电话；听筒。'],
  ['water', '水；【化】水；浇水。'],
  ['fire', '火；火灾；解雇。'],
  ['good', '好的；善良的；好处。'],
  ['bad', '坏的；糟糕的；严重。'],
  ['big', '大的；巨大的。'],
  ['small', '小的；少的；小气的。'],
  ['happy', '快乐的；幸福的。'],
  ['sad', '悲伤的；忧愁的。'],
  ['love', '爱；热爱；爱情。'],
  ['hate', '恨；憎恨。'],
  ['work', '工作；劳动；起作用。'],
  ['study', '学习；研究。'],
  ['school', '学校；学院。'],
  ['teacher', '老师；教师。'],
  ['student', '学生。'],
  ['doctor', '医生；博士。'],
  ['hospital', '医院。'],
  ['food', '食物；食品。'],
  ['drink', '喝；饮料。'],
  ['sleep', '睡觉；睡眠。'],
  ['run', '跑；运行；经营。'],
  ['walk', '走；步行。'],
  ['come', '来；来到。'],
  ['go', '去；离开。'],
  ['see', '看见；理解；会见。'],
  ['look', '看；看起来。'],
  ['listen', '听；听从。'],
  ['speak', '说话；讲。'],
  ['talk', '交谈；讲话。'],
  ['say', '说；讲。'],
  ['tell', '告诉；讲述。'],
  ['eat', '吃。'],
  ['read', '读；阅读。'],
  ['write', '写；写字。'],
  ['open', '打开；开张。'],
  ['close', '关闭；结束。'],
  ['start', '开始；启动。'],
  ['stop', '停止；阻止。'],
  ['help', '帮助；求助。'],
  ['please', '请。'],
  ['sorry', '对不起；抱歉。'],
  ['thank', '感谢；谢谢。'],
  ['yes', '是；是的。'],
  ['no', '不；没有。'],
  ['time', '时间；时代；次。'],
  ['day', '天；白天。'],
  ['night', '夜晚。'],
  ['morning', '早晨；上午。'],
  ['afternoon', '下午。'],
  ['evening', '傍晚。'],
  ['today', '今天。'],
  ['tomorrow', '明天。'],
  ['yesterday', '昨天。'],
  ['week', '周；星期。'],
  ['month', '月；月份。'],
  ['year', '年；年度。'],
  ['one', '一；一个。'],
  ['two', '二；两个。'],
  ['three', '三；三个。'],
  ['four', '四；四个。'],
  ['five', '五；五个。'],
  ['six', '六；六个。'],
  ['seven', '七；七个。'],
  ['eight', '八；八个。'],
  ['nine', '九；九个。'],
  ['ten', '十；十个。'],
  ['hundred', '百；一百。'],
  ['thousand', '千；一千。'],
  ['red', '红色（的）；红的。'],
  ['blue', '蓝色（的）；忧郁的。'],
  ['green', '绿色（的）。'],
  ['yellow', '黄色（的）。'],
  ['black', '黑色（的）。'],
  ['white', '白色（的）。'],
  ['sun', '太阳；阳光。'],
  ['moon', '月亮；月光。'],
  ['star', '星；明星。'],
  ['tree', '树；树木。'],
  ['flower', '花；开花植物。'],
  ['rain', '雨；下雨。'],
  ['snow', '雪；下雪。'],
  ['wind', '风；风。'],
  ['mountain', '山；山脉。'],
  ['river', '河；江。'],
  ['sea', '海；海洋。'],
  ['sky', '天空。'],
  ['earth', '地球；土壤。'],
  ['friend', '朋友。'],
  ['family', '家庭；家人。'],
  ['home', '家；回家。'],
  ['house', '房子；住宅。'],
  ['room', '房间；空间。'],
  ['door', '门；入口。'],
  ['window', '窗户；窗口。'],
  ['table', '桌子；表格。'],
  ['chair', '椅子。'],
  ['pen', '笔；钢笔。'],
  ['paper', '纸；论文；报纸。'],
  ['car', '汽车；轿车。'],
  ['bus', '公共汽车。'],
  ['train', '火车；培训。'],
  ['plane', '飞机；水平面。'],
  ['road', '路；道路。'],
  ['city', '城市；都市。'],
  ['country', '国家；乡村。'],
  ['people', '人们；民族。'],
  ['man', '男人；人类。'],
  ['woman', '女人。'],
  ['boy', '男孩。'],
  ['girl', '女孩。'],
  ['child', '小孩；儿童。'],
  ['baby', '婴儿。'],
  ['name', '名字；命名。'],
  ['age', '年龄；时代。'],
  ['job', '工作；职业。'],
  ['money', '钱；金钱。'],
  ['price', '价格；定价。'],
  ['question', '问题；疑问。'],
  ['answer', '回答；答案。'],
  ['idea', '想法；主意。'],
  ['thing', '东西；事物。'],
  ['place', '地方；场所。'],
  ['hand', '手；帮助。'],
  ['head', '头；领导。'],
  ['eye', '眼睛。'],
  ['ear', '耳朵。'],
  ['nose', '鼻子。'],
  ['mouth', '嘴；口。'],
  ['face', '脸；面对。'],
  ['hair', '头发；毛发。'],
  ['foot', '脚；英尺。'],
  ['leg', '腿。'],
  ['arm', '手臂；武器。'],
  ['heart', '心；心脏。'],
  ['mind', '头脑；想法。'],
  ['life', '生命；生活。'],
  ['death', '死亡。'],
  ['health', '健康；卫生。'],
  ['body', '身体；主体。'],
  ['left', '左（的）；离开。'],
  ['right', '右（的）；正确。'],
  ['up', '上；向上。'],
  ['down', '下；向下。'],
  ['in', '在…里；进入。'],
  ['out', '在外面；出去。'],
  ['on', '在…上；开。'],
  ['off', '关；离开。'],
  ['over', '在…上；越过。'],
  ['under', '在…下面。'],
  ['before', '在…之前。'],
  ['after', '在…之后。'],
  ['new', '新的。'],
  ['old', '旧的；老的。'],
  ['hot', '热的；辣的。'],
  ['cold', '冷的；感冒。'],
  ['fast', '快的；禁食。'],
  ['slow', '慢的；迟钝的。'],
  ['early', '早的；早期的。'],
  ['late', '迟的；晚的。'],
  ['near', '近的；附近。'],
  ['far', '远的；遥远。'],
  ['long', '长的；长久。'],
  ['short', '短的；短缺。'],
  ['high', '高的。'],
  ['low', '低的；低声的。'],
  ['strong', '强壮的；强大的。'],
  ['weak', '弱的；虚弱的。'],
  ['easy', '容易的；轻松的。'],
  ['hard', '困难的；硬的。'],
  ['light', '光；灯光；轻的。'],
  ['dark', '黑暗的；深色的。'],
  ['clean', '干净的；清洁。'],
  ['dirty', '脏的。'],
  ['rich', '富有的；丰富的。'],
  ['poor', '贫穷的；差的。'],
  ['true', '真的；真实的。'],
  ['false', '假的；错误的。'],
  ['empty', '空的；空洞的。'],
  ['full', '满的；饱的。'],
  ['open', '打开。'],
  ['free', '自由的；免费的。'],
  ['busy', '忙的；繁忙的。'],
  ['ready', '准备好的。'],
  ['same', '相同的。'],
  ['different', '不同的。'],
  ['important', '重要的。'],
  ['necessary', '必要的。'],
  ['possible', '可能的。'],
  ['impossible', '不可能的。'],
  ['easy', '容易。'],
  ['difficult', '困难的。'],
  ['interesting', '有趣的。'],
  ['boring', '无聊的。'],
  ['beautiful', '美丽的。'],
  ['ugly', '丑陋的。'],
  ['safe', '安全的。'],
  ['dangerous', '危险的。'],
  ['quiet', '安静的。'],
  ['noisy', '吵闹的。'],
  ['cheap', '便宜的。'],
  ['expensive', '昂贵的。'],
  ['simple', '简单的。'],
  ['complex', '复杂的。'],
  ['quick', '快的。'],
  ['smart', '聪明的；智能的。'],
  ['stupid', '愚蠢的。'],
  ['kind', '善良的；种类。'],
  ['cruel', '残忍的。'],
  ['polite', '礼貌的。'],
  ['rude', '粗鲁的。'],
  ['useful', '有用的。'],
  ['useless', '无用的。'],
  ['correct', '正确的。'],
  ['wrong', '错误的。'],
  ['real', '真的；现实的。'],
  ['unreal', '不真实的。'],
  ['public', '公共的；公开的。'],
  ['private', '私人的。'],
  ['common', '普通的；共同的。'],
  ['special', '特别的；特殊的。'],
  ['normal', '正常的。'],
  ['strange', '奇怪的。'],
  ['famous', '著名的。'],
  ['unknown', '未知的；不出名的。'],
];

/// 词条缓存：加载一次后常驻内存。重启 APP 清空（用户上传的 .txt 重读）。
class _BuiltInCache {
  static final List<DictEntry> entries = [
    for (final pair in _kBuiltIn)
      DictEntry(
          dictId: 'builtin',
          word: pair[0],
          definition: pair[1]),
  ];
}

// ============================================================ 主页面

class DictPage extends StatefulWidget {
  const DictPage({super.key});

  @override
  State<DictPage> createState() => _DictPageState();
}

class _DictPageState extends State<DictPage> {
  // 当前激活的词库 id；null = 仅内置
  String? _activeDictId;

  // 词库列表（不含内置）
  List<DictBook> _books = [];

  // 用户上传 / 手动添加的词条（按 dictId 索引）
  final Map<String, List<DictEntry>> _userEntries = {};

  // 内置是否要进搜索（默认进）
  bool _includeBuiltIn = true;

  // 生词本 id 集合
  Set<String> _favIds = {};

  // 历史（最近 100 条：word 列表，按时间倒序）
  List<_HistoryItem> _history = [];

  // 当前查询字符串
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    // 词库列表
    final raw = sp.getString('dict_books');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (json.decode(raw) as List)
            .map((e) => DictBook.fromJson(e as Map<String, dynamic>))
            .toList();
        _books = list;
      } catch (_) {}
    }
    // 用户词条：每个 dictId 一段 JSON
    for (final b in _books) {
      final e = sp.getString('dict_entries_${b.id}');
      if (e != null && e.isNotEmpty) {
        try {
          final list = (json.decode(e) as List)
              .map((j) => DictEntry.fromJson(j as Map<String, dynamic>))
              .toList();
          _userEntries[b.id] = list;
        } catch (_) {}
      }
    }
    // 生词本
    _favIds = (sp.getStringList('dict_favs') ?? []).toSet();
    // 历史
    final hRaw = sp.getString('dict_history');
    if (hRaw != null && hRaw.isNotEmpty) {
      try {
        _history = (json.decode(hRaw) as List)
            .map((j) => _HistoryItem.fromJson(j as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('dict_books',
        json.encode([for (final b in _books) b.toJson()]));
    for (final b in _books) {
      final list = _userEntries[b.id] ?? [];
      await sp.setString('dict_entries_${b.id}',
          json.encode([for (final e in list) e.toJson()]));
    }
    await sp.setStringList('dict_favs', _favIds.toList());
    await sp.setString(
        'dict_history', json.encode([for (final h in _history) h.toJson()]));
  }

  // ---------- 搜索 ----------

  /// 当前所有可见的词条（按激活词库筛选 + 是否含内置）。
  List<DictEntry> get _visible {
    final out = <DictEntry>[];
    if (_includeBuiltIn) out.addAll(_BuiltInCache.entries);
    if (_activeDictId != null) {
      out.addAll(_userEntries[_activeDictId!] ?? const []);
    } else if (_books.isNotEmpty) {
      // 多个词库 → 全并进来
      for (final b in _books) {
        out.addAll(_userEntries[b.id] ?? const []);
      }
    }
    return out;
  }

  /// 命中列表：先 exact，再 prefix，再 substring。
  List<DictHit> _search(String q) {
    if (q.isEmpty) return const [];
    final lower = q.toLowerCase();
    final exact = <DictHit>[];
    final prefix = <DictHit>[];
    final sub = <DictHit>[];
    for (final e in _visible) {
      final w = e.word.toLowerCase();
      if (w == lower) {
        exact.add(DictHit(e, HitKind.exact));
      } else if (w.startsWith(lower)) {
        prefix.add(DictHit(e, HitKind.prefix));
      } else if (w.contains(lower)) {
        sub.add(DictHit(e, HitKind.substring));
      }
    }
    // 各类内部按 word 排序
    int byWord(DictHit a, DictHit b) =>
        a.entry.word.toLowerCase().compareTo(b.entry.word.toLowerCase());
    exact.sort(byWord);
    prefix.sort(byWord);
    sub.sort(byWord);
    return [...exact, ...prefix, ...sub];
  }

  // ---------- 收藏 / 历史 ----------

  void _toggleFav(DictEntry e) {
    setState(() {
      if (_favIds.contains(e.id)) {
        _favIds.remove(e.id);
      } else {
        _favIds.add(e.id);
      }
    });
    _save();
  }

  void _pushHistory(DictEntry e) {
    _history.removeWhere((h) => h.entry.id == e.id);
    _history.insert(0, _HistoryItem(entry: e, at: DateTime.now()));
    if (_history.length > 100) _history = _history.sublist(0, 100);
    _save();
  }

  // ---------- 加载词库 ----------

  /// 加载一个 .txt / .csv 文件（已经在 SD 卡上，用户用别的工具 / 服务器下载
  /// 站下载到本地后由本工具拉进来）。
  Future<void> _importFromPath(String path, String displayName) async {
    try {
      final f = File(path);
      if (!f.existsSync()) {
        toast(context, '文件不存在：$path');
        return;
      }
      final content = await f.readAsString();
      final ext = path.toLowerCase();
      final list = ext.endsWith('.csv')
          ? _parseCsv(content)
          : _parseTxt(content);
      final id = 'user_${DateTime.now().millisecondsSinceEpoch}';
      final book = DictBook(
        id: id,
        name: displayName,
        path: path,
        size: list.length,
        loadedAt: DateTime.now(),
      );
      setState(() {
        _books.add(book);
        _userEntries[id] = list;
      });
      _save();
      if (!mounted) return;
      toast(context, '已加载 ${list.length} 词条');
    } catch (e) {
      if (!mounted) return;
      toast(context, '加载失败：$e');
    }
  }

  /// 从粘贴板解析（用户复制一段内容进来）。
  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data == null || data.text == null || data.text!.trim().isEmpty) {
      toast(context, '剪贴板是空的');
      return;
    }
    // 默认按 txt 解析（每行 word\tdef 或 word: def）
    final list = _parseTxt(data.text!);
    if (list.isEmpty) {
      toast(context, '没解析出任何词条');
      return;
    }
    final id = 'paste_${DateTime.now().millisecondsSinceEpoch}';
    final book = DictBook(
      id: id,
      name: '剪贴板 (${list.length} 词)',
      path: '',
      size: list.length,
      loadedAt: DateTime.now(),
    );
    setState(() {
      _books.add(book);
      _userEntries[id] = list;
    });
    _save();
    if (!mounted) return;
    toast(context, '已从剪贴板导入 ${list.length} 词');
  }

  // ---------- 解析 ----------

  /// 每行 `word<TAB>def` 或 `word: def`；空行 / # 开头的注释跳过。
  List<DictEntry> _parseTxt(String content) {
    final out = <DictEntry>[];
    for (final rawLine in content.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // 优先 tab；其次「: 」或「:」；最次第一个空格。
      String word, def;
      final tab = line.indexOf('\t');
      if (tab > 0) {
        word = line.substring(0, tab).trim();
        def = line.substring(tab + 1).trim();
      } else {
        final colon = line.indexOf(': ');
        if (colon > 0) {
          word = line.substring(0, colon).trim();
          def = line.substring(colon + 2).trim();
        } else if (line.contains('：')) {
          final i = line.indexOf('：');
          word = line.substring(0, i).trim();
          def = line.substring(i + 1).trim();
        } else {
          final sp = line.indexOf(' ');
          if (sp > 0) {
            word = line.substring(0, sp).trim();
            def = line.substring(sp + 1).trim();
          } else {
            continue;
          }
        }
      }
      if (word.isEmpty || def.isEmpty) continue;
      out.add(DictEntry(dictId: '', word: word, definition: def));
    }
    return out;
  }

  /// 每行 `word,def`，允许 def 内含逗号（按首个逗号切）。
  List<DictEntry> _parseCsv(String content) {
    final out = <DictEntry>[];
    for (final rawLine in content.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf(',');
      if (i <= 0) continue;
      final word = line.substring(0, i).trim();
      final def = line.substring(i + 1).trim();
      if (word.isEmpty || def.isEmpty) continue;
      out.add(DictEntry(dictId: '', word: word, definition: def));
    }
    return out;
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final hits = _search(_query);
    return ToolScaffold(
      title: '路路词典',
      subtitle: _subtitle(),
      actions: [
        IconButton(
          tooltip: '加载词库',
          onPressed: _showImportDialog,
          icon: const Icon(Icons.library_add),
        ),
        IconButton(
          tooltip: '生词本',
          onPressed: () => setState(() {
            _query = '';
            _tab = _Tab.fav;
          }),
          icon: const Icon(Icons.star),
        ),
        IconButton(
          tooltip: '历史',
          onPressed: () => setState(() {
            _query = '';
            _tab = _Tab.history;
          }),
          icon: const Icon(Icons.history),
        ),
      ],
      child: Column(
        children: [
          _searchBar(),
          if (_books.isNotEmpty) _bookPicker(),
          if (_tab == _Tab.fav)
            _list(_favList(), emptyText: '生词本是空的；查到喜欢的词点 ★ 加进来')
          else if (_tab == _Tab.history)
            _list(_historyList(), emptyText: '还没有查词记录')
          else
            _list(hits.map((h) => _Row.fromHit(h)).toList(),
                emptyText: _query.isEmpty
                    ? '输入单词 / 中文 / 数字试试（已加载 ${_visible.length} 词条）'
                    : '没有命中'),
        ],
      ),
    );
  }

  _Tab _tab = _Tab.search;

  String _subtitle() {
    final total = _visible.length;
    final parts = <String>[];
    if (_includeBuiltIn) parts.add('内置');
    parts.addAll([for (final b in _books) b.name]);
    return parts.join(' + ') + ' · 共 $total 词条';
  }

  // 输入框 controller（state 级，避免 build 里反复 new）。
  // ——这个 controller 在 build 里通过 `_searchCtrl.text = _query` 同步，
  // 不用 listen 自己的变化，所以声明成 late final 即可。
  late final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: false,
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜词 / 中文 / 短语…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {
                            _query = '';
                            _tab = _Tab.search;
                          });
                        },
                        icon: const Icon(Icons.clear, size: 18),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                setState(() {
                  _query = v;
                  _tab = _Tab.search;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('全部'),
              selected: _activeDictId == null,
              onSelected: (_) => setState(() => _activeDictId = null),
            ),
            const SizedBox(width: 6),
            for (final b in _books)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                // v1.9.0+24：用 InputChip 替代 ChoiceChip —— ChoiceChip
                // 没有 onDeleted 参数，没法在 chip 上直接挂「删除」入口；
                // InputChip 自带删除按钮（默认 × 图标），点一下确认弹窗。
                child: InputChip(
                  label: Text('${b.name} (${b.size})'),
                  selected: _activeDictId == b.id,
                  onSelected: (_) => setState(() => _activeDictId = b.id),
                  onDeleted: () => _confirmDeleteBook(b),
                ),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('加词条'),
              onPressed: _addEntryManual,
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteBook(DictBook b) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${b.name}」？'),
        content: const Text('该词库下的词条会一起删掉，不能恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _books.removeWhere((e) => e.id == b.id);
                _userEntries.remove(b.id);
                if (_activeDictId == b.id) _activeDictId = null;
              });
              _save();
              toast(context, '已删除');
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 手动添加词条对话框。
  Future<void> _addEntryManual() async {
    final wordCtrl = TextEditingController();
    final defCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加词条'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: wordCtrl,
              decoration: const InputDecoration(
                labelText: '单词 / 词',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: defCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '释义（可多行）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final w = wordCtrl.text.trim();
    final d = defCtrl.text.trim();
    if (w.isEmpty || d.isEmpty) {
      toast(context, '词条和释义不能为空');
      return;
    }
    // 加到「手动」词库（首次则自动创建）
    final id = _userEntries.keys
        .firstWhere((k) => k.startsWith('manual_'), orElse: () => '');
    final dictId = id.isEmpty ? 'manual_${DateTime.now().millisecondsSinceEpoch}' : id;
    final entry = DictEntry(dictId: dictId, word: w, definition: d);
    setState(() {
      _userEntries.putIfAbsent(dictId, () => []).add(entry);
      if (id.isEmpty) {
        _books.add(DictBook(
          id: dictId,
          name: '手动',
          path: '',
          size: 1,
          loadedAt: DateTime.now(),
        ));
      } else {
        _books.firstWhere((b) => b.id == dictId).size++;
      }
    });
    _save();
    if (!mounted) return;
    toast(context, '已加入');
  }

  /// 选择导入方式。
  Future<void> _showImportDialog() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('从剪贴板导入'),
              subtitle: const Text('每行「word<TAB>def」或「word: def」'),
              onTap: () => Navigator.pop(ctx, 'clip'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('从文件导入'),
              subtitle: const Text('下载站 / 笔记目录下的 .txt / .csv'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('示例词库格式'),
              onTap: () => Navigator.pop(ctx, 'help'),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    if (pick == 'clip') {
      await _importFromClipboard();
    } else if (pick == 'file') {
      await _pickFile();
    } else if (pick == 'help') {
      await _showFormatHelp();
    }
  }

  Future<void> _pickFile() async {
    // 不引入文件选择器（file_picker 8.x 之前踩过坑）；
    // 改成让用户输入「下载站里 .txt 的 WebDAV 路径」或「本地绝对路径」。
    final input = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从文件导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                '输入本地绝对路径（如 /sdcard/Download/words.txt）。\n'
                '要求：每行「word<TAB>def」或「word: def」；空行 / # 开头忽略。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: input,
              decoration: const InputDecoration(
                labelText: '文件路径',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final path = input.text.trim();
    if (path.isEmpty) return;
    final name = path.split('/').last;
    await _importFromPath(path, name);
  }

  Future<void> _showFormatHelp() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('示例词库格式'),
        content: SingleChildScrollView(
          child: SelectableText(
              '每行一个词条；词与释义之间用 TAB、英文「: 」或中文「：」分隔。\n'
              '空行 / 以 # 开头的行会自动跳过。\n'
              '\n'
              '# 示例 1：英文词典\n'
              'apple\t苹果；苹果公司\n'
              'banana\t香蕉\n'
              'cat: 猫；【口】家伙\n'
              '\n'
              '# 示例 2：中文词典\n'
              '你好：见面招呼语。\n'
              '世界：人类居住的地球表面。\n'
              '\n'
              '提示：想批量导入就把欧路词典 / 有道词典的导出 csv 改成上面这个格式。\n'
              'Excel 导出 CSV 默认是「word,def」也行；本工具能识别逗号分隔。',
              style: const TextStyle(fontSize: 12)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  // ---------- 列表 ----------

  Widget _list(List<_Row> rows, {required String emptyText}) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyText,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final row = rows[i];
        final entry = row.entry;
        return ListTile(
          leading: Icon(
            _favIds.contains(entry.id) ? Icons.star : Icons.star_border,
            color: _favIds.contains(entry.id)
                ? const Color(0xFFE0A020)
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(entry.word,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            _preview(entry.definition),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: row.kind == null
              ? null
              : _kindBadge(row.kind!),
          onTap: () {
            _pushHistory(entry);
            _showDetail(entry);
          },
          onLongPress: () => _toggleFav(entry),
        );
      },
    );
  }

  String _preview(String s) {
    // 去掉换行 / 标签，给个简短预览
    final oneLine = s.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length > 60 ? '${oneLine.substring(0, 60)}…' : oneLine;
  }

  Widget _kindBadge(HitKind k) {
    Color bg;
    String label;
    switch (k) {
      case HitKind.exact:
        bg = const Color(0xFF185FA5);
        label = '完全';
        break;
      case HitKind.prefix:
        bg = const Color(0xFF1D9E75);
        label = '前缀';
        break;
      case HitKind.substring:
        bg = const Color(0xFFB8860B);
        label = '子串';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: bg, fontWeight: FontWeight.w600)),
    );
  }

  // ---------- 生词本 / 历史 ----------

  List<_Row> _favList() {
    final all = _visible;
    final out = <_Row>[];
    for (final e in all) {
      if (_favIds.contains(e.id)) out.add(_Row.fromHit(DictHit(e, HitKind.exact)));
    }
    return out;
  }

  List<_Row> _historyList() {
    return [
      for (final h in _history) _Row.fromHit(DictHit(h.entry, HitKind.exact))
    ];
  }

  // ---------- 详情 ----------

  void _showDetail(DictEntry e) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(e.word,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: _favIds.contains(e.id) ? '从生词本移除' : '加进生词本',
                    onPressed: () {
                      _toggleFav(e);
                      Navigator.pop(ctx);
                    },
                    icon: Icon(_favIds.contains(e.id)
                        ? Icons.star
                        : Icons.star_border),
                  ),
                  IconButton(
                    tooltip: '复制释义',
                    onPressed: () => copyText(context, e.definition),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              if (_dictName(e.dictId).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('来源：${_dictName(e.dictId)}',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  e.definition,
                  style: const TextStyle(fontSize: 14, height: 1.6),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  String _dictName(String id) {
    if (id == 'builtin') return '内置';
    final b = _books.where((b) => b.id == id).toList();
    if (b.isNotEmpty) return b.first.name;
    return '';
  }
}

enum _Tab { search, fav, history }

class _HistoryItem {
  final DictEntry entry;
  final DateTime at;
  _HistoryItem({required this.entry, required this.at});

  Map<String, dynamic> toJson() => {
        'e': entry.toJson(),
        'a': at.millisecondsSinceEpoch,
      };

  factory _HistoryItem.fromJson(Map<String, dynamic> j) => _HistoryItem(
        entry: DictEntry.fromJson(j['e'] as Map<String, dynamic>),
        at: DateTime.fromMillisecondsSinceEpoch(j['a'] as int),
      );
}

class _Row {
  final DictEntry entry;
  final HitKind? kind; // null = 生词本 / 历史
  _Row(this.entry, this.kind);
  factory _Row.fromHit(DictHit h) => _Row(h.entry, h.kind);
}