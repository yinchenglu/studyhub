import 'dart:convert';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../dav/webdav_client.dart';
import '../models/models.dart';

/// 把一条错题记录还原成可作答的题目（错题本重做时用）
Question questionFromWrong(WrongRecord r) => Question(
      id: r.questionId,
      // 优先用记录里存的题型；v1.3.0 之前的老记录没有 qtype，
      // 才退回「按答案个数猜单选/多选」的老办法
      type: r.qtype.isNotEmpty ? r.qtype : (r.answer.length > 1 ? 'multi' : 'single'),
      stem: r.stem,
      options: r.options,
      answer: r.answer,
      analysis: r.analysis,
      tags: r.tags,
      bankDir: r.bankDir,
      bankName: r.bankName,
      textAccept: r.textAccept,
    );

/// 一条题库引用（就是服务器上的一个 .json 文件）
class QuizBankRef {
  final String path; // quiz/xxx/第一章.json
  final String name;
  final int count;
  final bool isWordBank;
  final int size;
  final DateTime? modified;

  const QuizBankRef({
    required this.path,
    required this.name,
    required this.count,
    this.isWordBank = false,
    this.size = 0,
    this.modified,
  });
}

/// 题库仓库：扫描 WebDAV 的 quiz 目录
///
/// v1.2.0 起的重要约定：**一个 .json 文件 = 一套题库**。
/// 以前是把整个目录里的 json 合并成一套，结果「一个目录里放了好几个题库」
/// 时既看不到题库列表，也没法只刷其中一套。
class QuizRepo {
  final WebDavClient dav;
  QuizRepo(this.dav);

  String get _root => AppDirs.quiz;

  /// 列出某个相对目录下的直接子项（子目录 + 文件）
  Future<List<DavEntry>> listChildren(String sub) => dav.list(joinPath(_root, sub), depth: 1);

  /// 目录里所有 json = 这个目录下的所有题库
  Future<List<QuizBankRef>> banksInDir(String dirPath) async {
    final entries = await dav.list(dirPath, depth: 1);
    final files = entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).toList();
    // 并发读，目录里几十个 json 也不会太慢
    return Future.wait(files.map((f) async {
      try {
        final bank = await _parseOne(f.path);
        return QuizBankRef(
          path: f.path,
          name: bank.name.trim().isEmpty ? titleFromFileName(f.name) : bank.name.trim(),
          count: bank.count,
          isWordBank: bank.isWordBank,
          size: f.size,
          modified: f.modified,
        );
      } catch (_) {
        return QuizBankRef(
          path: f.path,
          name: titleFromFileName(f.name),
          count: 0,
          size: f.size,
          modified: f.modified,
        );
      }
    }));
  }

  /// 统计目录里有多少个 .json（子目录卡片显示「N 套题库」用）
  Future<int> jsonCountInDir(String dirPath) async {
    try {
      final entries = await dav.list(dirPath, depth: 1);
      return entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).length;
    } catch (_) {
      return 0;
    }
  }

  /// 读取单独一套题库（按 json 文件路径）
  Future<QuestionBank> loadBankFile(String filePath) async {
    final bank = await _parseOne(filePath);
    final name = bank.name.trim().isEmpty ? titleFromFileName(filePath) : bank.name.trim();
    return QuestionBank(
      name: name,
      dir: filePath,
      questions: bank.questions.map((q) => q.copyWith(bankDir: filePath, bankName: name)).toList(),
      words: bank.words,
      isWordBank: bank.isWordBank,
    );
  }

  /// 把一个目录下所有 json 合并成一套题库（「合并刷题」用）
  ///
  /// 关键点：合并后每道题仍然带着它自己所属 json 的路径作为 bankDir，
  /// 所以合并刷的时候，进度照样能落回原来的单套题库上。
  Future<QuestionBank> mergeDir(String dirPath) async {
    final entries = await dav.list(dirPath, depth: 1);
    final files = entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).toList();
    final questions = <Question>[];
    final words = <WordItem>[];
    var isWordBank = false;
    for (final f in files) {
      try {
        final bank = await _parseOne(f.path);
        final name = bank.name.trim().isEmpty ? titleFromFileName(f.name) : bank.name.trim();
        questions.addAll(bank.questions.map((q) => q.copyWith(bankDir: f.path, bankName: name)));
        words.addAll(bank.words);
        isWordBank = isWordBank || bank.isWordBank;
      } catch (_) {
        continue;
      }
    }
    final name = dirPath == _root ? '根目录题库' : baseName(dirPath);
    return QuestionBank(
      name: files.isEmpty ? name : '$name（合并 ${files.length} 套）',
      dir: dirPath,
      questions: questions,
      words: words,
      isWordBank: isWordBank && questions.isEmpty,
    );
  }

  /// 兼容旧调用（速查表里的「题库体检」等）：合并整个目录
  Future<QuestionBank> loadBank(String dirPath) => mergeDir(dirPath);

  /// 题库概览
  Future<List<QuestionBank>> listBanks() async {
    final List<DavEntry> dirs;
    try {
      dirs = await dav.list(_root, depth: 1);
    } catch (_) {
      return [];
    }
    final banks = <QuestionBank>[];
    Future<void> addAllOf(String dir) async {
      for (final ref in await banksInDir(dir)) {
        try {
          banks.add(await loadBankFile(ref.path));
        } catch (_) {
          continue;
        }
      }
    }

    await addAllOf(_root);
    for (final d in dirs.where((e) => e.isDir)) {
      await addAllOf(d.path);
    }
    return banks;
  }

  Future<QuestionBank> _parseOne(String filePath) async {
    final text = await dav.readText(filePath);
    final dynamic data = jsonDecode(text);
    final map = data is Map ? Map<String, dynamic>.from(data as Map) : <String, dynamic>{};

    final name = (map['bankName'] ?? titleFromFileName(filePath)).toString();
    final dir = parentOf(filePath);
    final isWord = (map['type'] ?? '').toString() == 'wordbank' || (map['words'] is List && map['questions'] == null);

    if (isWord) {
      final list = ((map['words'] ?? const []) as List).map((e) => WordItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      return QuestionBank(name: name, dir: dir, words: list, isWordBank: true);
    }

    final raw = ((map['questions'] ?? const []) as List)
        .map((e) => Question.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    // 题库里没写 id 的题按顺序补一个稳定 id —— 进度条和错题本都需要唯一键
    final list = <Question>[];
    for (var i = 0; i < raw.length; i++) {
      final q = raw[i];
      list.add(q.copyWith(
        id: q.id.trim().isEmpty ? 'q${i + 1}' : q.id,
        bankDir: filePath,
        bankName: name,
      ));
    }
    return QuestionBank(name: name, dir: filePath, questions: list);
  }

  /// 题库数量（首页统计）：数一数 quiz 树里的 json 文件
  Future<int> bankCount() async {
    try {
      final entries = await dav.list(_root, depth: 1);
      var n = entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).length;
      for (final d in entries.where((e) => e.isDir)) {
        n += await jsonCountInDir(d.path);
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 文件是否是可用的题库（校验 JSON 结构，给「题库体检」工具用）
  Future<List<String>> validate(String dirPath) async {
    final errors = <String>[];
    List<DavEntry> files;
    try {
      files = await dav.list(dirPath, depth: 1);
    } catch (e) {
      return ['无法访问目录：$e'];
    }
    for (final f in files.where((e) => !e.isDir && FileTypes.isJson(e.name))) {
      try {
        final text = await dav.readText(f.path);
        final data = jsonDecode(text);
        if (data is! Map) {
          errors.add('${f.name}：顶层不是 JSON 对象');
          continue;
        }
        if (data['questions'] == null && data['words'] == null) {
          errors.add('${f.name}：缺少 questions 或 words 字段');
          continue;
        }
        if (data['questions'] is List) {
          final qs = data['questions'] as List;
          for (var i = 0; i < qs.length; i++) {
            final q = qs[i];
            if (q is! Map) {
              errors.add('${f.name} 第 ${i + 1} 题：不是对象');
              continue;
            }
            if (q['stem'] == null) errors.add('${f.name} 第 ${i + 1} 题：缺少 stem');

            final qtype = Question.normalizeType((q['type'] ?? 'single').toString());
            final isText = qtype == 'fill' || qtype == 'essay';
            // 文本答案可能写在 answer / answerText / textAnswer 任何一个里
            final rawAns = q['answer'] ?? q['answerText'] ?? q['textAnswer'];

            if (isText) {
              // 填空题 / 问答题：不打选项，答案是字符串（或字符串数组）
              final empty = rawAns == null ||
                  (rawAns is List && rawAns.isEmpty) ||
                  (!(rawAns is List) && rawAns.toString().trim().isEmpty);
              if (empty) {
                errors.add('${f.name} 第 ${i + 1} 题：缺少答案文本'
                    '（${qtype == 'fill' ? '填空' : '问答'}题的 answer 直接写文字即可，不用写下标）');
              }
            } else {
              if (q['options'] is! List || (q['options'] as List).isEmpty) {
                errors.add('${f.name} 第 ${i + 1} 题：options 为空');
              }
              if (rawAns is! List || rawAns.isEmpty) {
                errors.add('${f.name} 第 ${i + 1} 题：缺少 answer（答案下标数组）');
              } else {
                final optLen = (q['options'] is List) ? (q['options'] as List).length : 0;
                for (final a in rawAns) {
                  final idx = int.tryParse(a.toString()) ?? -1;
                  if (idx < 0 || idx >= optLen) {
                    errors.add('${f.name} 第 ${i + 1} 题：answer 下标 $idx 越界（共 $optLen 个选项）');
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        errors.add('${f.name}：JSON 解析失败（$e）');
      }
    }
    return errors;
  }
}
