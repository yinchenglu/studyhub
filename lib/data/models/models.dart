import 'dart:convert';

/// ---------------- WebDAV 账号 ----------------
class DavAccount {
  final String alias; // 显示名，例如「家里的群晖」
  final String baseUrl; // WebDAV 入口，例如 http://192.168.1.10:5005/ 或 https://nas/dav/
  final String username;
  final String password;
  final String root; // 资料根目录，默认 /StudyHub

  const DavAccount({
    required this.alias,
    required this.baseUrl,
    required this.username,
    required this.password,
    this.root = '/StudyHub',
  });

  DavAccount copyWith({String? alias, String? baseUrl, String? username, String? password, String? root}) => DavAccount(
        alias: alias ?? this.alias,
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        root: root ?? this.root,
      );

  /// 存本地设置时不写密码（密码单独加密存）
  Map<String, dynamic> toJson() => {
        'alias': alias,
        'baseUrl': baseUrl,
        'username': username,
        'root': root,
      };

  factory DavAccount.fromJson(Map<String, dynamic> j) => DavAccount(
        alias: j['alias'] as String? ?? '我的服务器',
        baseUrl: j['baseUrl'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        root: j['root'] as String? ?? '/StudyHub',
      );

  /// 密码存储的 key
  String get secretKey => 'dav_pwd_${base64Url.encode(utf8.encode('$baseUrl|$username'))}';
}

/// ---------------- 服务器上的一个条目 ----------------
class DavEntry {
  final String path; // 相对资料根目录的路径，例如 notes/中医/经络知识.md
  final bool isDir;
  final int size;
  final DateTime? modified;
  final String? contentType;

  const DavEntry({
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
    this.contentType,
  });

  String get name {
    final p = path.replaceAll(RegExp(r'/+$'), '');
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }
}

/// ---------------- 笔记 ----------------
class NoteMeta {
  final String path;
  final String title;
  final DateTime? modified;
  final int size;

  const NoteMeta({required this.path, required this.title, this.modified, this.size = 0});
}

/// ---------------- 媒体（视频 / 图片） ----------------
class MediaItem {
  final String path;
  final bool isVideo;
  final int size;
  final DateTime? modified;

  const MediaItem({required this.path, required this.isVideo, this.size = 0, this.modified});

  String get name {
    final p = path.replaceAll(RegExp(r'/+$'), '');
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }
}

/// ---------------- 题目 ----------------
class Question {
  final String id;
  final String type; // single / multi / judge
  final String stem;
  final List<String> options;
  final List<int> answer;
  final String analysis;
  final List<String> tags;
  final int difficulty;
  final String bankDir; // 所属题库目录，例如 quiz/python基础
  final String bankName;

  const Question({
    required this.id,
    required this.type,
    required this.stem,
    required this.options,
    required this.answer,
    this.analysis = '',
    this.tags = const [],
    this.difficulty = 2,
    this.bankDir = '',
    this.bankName = '',
  });

  bool get isMulti => type == 'multi';

  Question copyWith({String? bankDir, String? bankName}) => Question(
        id: id,
        type: type,
        stem: stem,
        options: options,
        answer: answer,
        analysis: analysis,
        tags: tags,
        difficulty: difficulty,
        bankDir: bankDir ?? this.bankDir,
        bankName: bankName ?? this.bankName,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'stem': stem,
        'options': options,
        'answer': answer,
        'analysis': analysis,
        'tags': tags,
        'difficulty': difficulty,
      };

  factory Question.fromJson(Map<String, dynamic> j) => Question(
        id: j['id']?.toString() ?? '',
        type: (j['type'] ?? 'single').toString(),
        stem: (j['stem'] ?? '').toString(),
        options: ((j['options'] ?? const []) as List).map((e) => e.toString()).toList(),
        answer: ((j['answer'] ?? const []) as List).map((e) => int.tryParse(e.toString()) ?? 0).toList(),
        analysis: (j['analysis'] ?? '').toString(),
        tags: ((j['tags'] ?? const []) as List).map((e) => e.toString()).toList(),
        difficulty: int.tryParse('${j['difficulty'] ?? 2}') ?? 2,
      );
}

/// 单词（单词库专用）
class WordItem {
  final String word;
  final String phonetic;
  final String meaning;
  final String example;
  final List<String> tags;

  const WordItem({
    required this.word,
    this.phonetic = '',
    required this.meaning,
    this.example = '',
    this.tags = const [],
  });

  factory WordItem.fromJson(Map<String, dynamic> j) => WordItem(
        word: (j['word'] ?? '').toString(),
        phonetic: (j['phonetic'] ?? '').toString(),
        meaning: (j['meaning'] ?? '').toString(),
        example: (j['example'] ?? '').toString(),
        tags: ((j['tags'] ?? const []) as List).map((e) => e.toString()).toList(),
      );
}

/// ---------------- 一套题库 ----------------
class QuestionBank {
  final String name;
  final String dir; // quiz/xxx
  final List<Question> questions;
  final List<WordItem> words;
  final bool isWordBank;

  const QuestionBank({
    required this.name,
    required this.dir,
    this.questions = const [],
    this.words = const [],
    this.isWordBank = false,
  });

  int get count => isWordBank ? words.length : questions.length;

  /// 把单词组装成「看词选义」的选择题：干扰项从同库其他单词里抽
  List<Question> buildWordQuestions() {
    final out = <Question>[];
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final wrong = <String>[];
      var k = i + 1;
      while (wrong.length < 3 && words.length > 1) {
        final cand = words[k % words.length];
        if (cand.meaning != w.meaning && !wrong.contains(cand.meaning)) wrong.add(cand.meaning);
        k++;
        if (k > i + 1 + words.length) break;
      }
      final opts = <String>[w.meaning, ...wrong];
      // 打乱顺序并记录正确答案下标
      final seed = w.word.hashCode;
      opts.sort((a, b) => ((a.hashCode ^ seed) % 1000).compareTo((b.hashCode ^ seed) % 1000));
      out.add(Question(
        id: 'word-${w.word}',
        type: 'single',
        stem: '${w.word}\n${w.phonetic}\n\n选出正确的词义',
        options: opts,
        answer: [opts.indexOf(w.meaning)],
        analysis: w.example.isEmpty ? w.meaning : '${w.meaning}\n例句：${w.example}',
        tags: w.tags.isEmpty ? ['单词'] : w.tags,
        difficulty: 2,
        bankDir: dir,
        bankName: name,
      ));
    }
    return out;
  }

  /// 全套题目（单词库自动生成选择题）
  List<Question> allQuestions() => isWordBank ? buildWordQuestions() : questions;
}

/// ---------------- 错题记录 ----------------
class WrongRecord {
  final int? id;
  final String bankDir;
  final String bankName;
  final String questionId;
  final String stem;
  final List<String> options;
  final List<int> answer;
  final String analysis;
  final List<String> tags;
  final List<int> lastChoice;
  final int wrongCount;
  final bool mastered;
  final DateTime lastWrongAt;
  final String myNote;

  const WrongRecord({
    this.id,
    required this.bankDir,
    required this.bankName,
    required this.questionId,
    required this.stem,
    required this.options,
    required this.answer,
    this.analysis = '',
    this.tags = const [],
    this.lastChoice = const [],
    this.wrongCount = 1,
    this.mastered = false,
    required this.lastWrongAt,
    this.myNote = '',
  });

  WrongRecord copyWith({int? id, int? wrongCount, bool? mastered, List<int>? lastChoice, DateTime? lastWrongAt, String? myNote}) =>
      WrongRecord(
        id: id ?? this.id,
        bankDir: bankDir,
        bankName: bankName,
        questionId: questionId,
        stem: stem,
        options: options,
        answer: answer,
        analysis: analysis,
        tags: tags,
        lastChoice: lastChoice ?? this.lastChoice,
        wrongCount: wrongCount ?? this.wrongCount,
        mastered: mastered ?? this.mastered,
        lastWrongAt: lastWrongAt ?? this.lastWrongAt,
        myNote: myNote ?? this.myNote,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'bank_dir': bankDir,
        'bank_name': bankName,
        'question_id': questionId,
        'stem': stem,
        'options': jsonEncode(options),
        'answer': jsonEncode(answer),
        'analysis': analysis,
        'tags': jsonEncode(tags),
        'last_choice': jsonEncode(lastChoice),
        'wrong_count': wrongCount,
        'mastered': mastered ? 1 : 0,
        'last_wrong_at': lastWrongAt.millisecondsSinceEpoch,
        'my_note': myNote,
      };

  factory WrongRecord.fromMap(Map<String, dynamic> m) => WrongRecord(
        id: m['id'] as int?,
        bankDir: (m['bank_dir'] ?? '').toString(),
        bankName: (m['bank_name'] ?? '').toString(),
        questionId: (m['question_id'] ?? '').toString(),
        stem: (m['stem'] ?? '').toString(),
        options: _list(m['options']),
        answer: _ints(m['answer']),
        analysis: (m['analysis'] ?? '').toString(),
        tags: _list(m['tags']),
        lastChoice: _ints(m['last_choice']),
        wrongCount: (m['wrong_count'] as int?) ?? 1,
        mastered: ((m['mastered'] as int?) ?? 0) == 1,
        lastWrongAt: DateTime.fromMillisecondsSinceEpoch((m['last_wrong_at'] as int?) ?? 0),
        myNote: (m['my_note'] ?? '').toString(),
      );

  static List<String> _list(dynamic v) {
    if (v == null) return const [];
    try {
      return (jsonDecode(v.toString()) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  static List<int> _ints(dynamic v) {
    if (v == null) return const [];
    try {
      return (jsonDecode(v.toString()) as List).map((e) => int.tryParse(e.toString()) ?? 0).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// ---------------- 播放进度 ----------------
class PlayProgress {
  final String path;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  const PlayProgress({required this.path, required this.positionMs, required this.durationMs, required this.updatedAt});
}

/// ---------------- 首页统计 ----------------
class StatsSummary {
  final int noteCount;
  final int videoCount;
  final int imageCount;
  final int bankCount;
  final int toolCount;
  final int wrongCount;
  final int todayReviewCount;

  const StatsSummary({
    this.noteCount = 0,
    this.videoCount = 0,
    this.imageCount = 0,
    this.bankCount = 0,
    this.toolCount = 0,
    this.wrongCount = 0,
    this.todayReviewCount = 0,
  });
}

/// ---------------- 连接检测结果 ----------------
class ConnectionCheck {
  final bool ok;
  final bool canWrite;
  final bool supportsRange;
  final int fileCount;
  final String message;
  final List<String> missingDirs;

  const ConnectionCheck({
    required this.ok,
    this.canWrite = false,
    this.supportsRange = false,
    this.fileCount = 0,
    this.message = '',
    this.missingDirs = const [],
  });
}
