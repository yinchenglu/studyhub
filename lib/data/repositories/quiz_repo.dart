import 'dart:convert';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../dav/webdav_client.dart';
import '../models/models.dart';

/// 把一条错题记录还原成可作答的题目（错题本重做时用）
Question questionFromWrong(WrongRecord r) => Question(
      id: r.questionId,
      type: r.answer.length > 1 ? 'multi' : 'single',
      stem: r.stem,
      options: r.options,
      answer: r.answer,
      analysis: r.analysis,
      tags: r.tags,
      bankDir: r.bankDir,
      bankName: r.bankName,
    );

/// 题库仓库：扫描 WebDAV 的 quiz 目录
class QuizRepo {
  final WebDavClient dav;
  QuizRepo(this.dav);

  String get _root => AppDirs.quiz;

  /// 列出某个相对目录下的直接子项（子目录 + 文件），刷题页的目录浏览用
  Future<List<DavEntry>> listChildren(String sub) => dav.list(joinPath(_root, sub), depth: 1);

  /// 题库概览：每个子目录 = 一套题库
  Future<List<QuestionBank>> listBanks() async {
    final List<DavEntry> dirs;
    try {
      dirs = await dav.list(_root, depth: 1);
    } catch (_) {
      return [];
    }
    final banks = <QuestionBank>[];
    for (final d in dirs.where((e) => e.isDir)) {
      try {
        final bank = await loadBank(d.path);
        if (bank.count > 0) banks.add(bank);
      } catch (_) {
        // 单个题库格式坏了不影响其他题库
        continue;
      }
    }
    // 如果用户直接把 json 丢在 quiz 根目录，也当成一套题库
    final looseJson = dirs.where((e) => !e.isDir && FileTypes.isJson(e.name)).toList();
    if (looseJson.isNotEmpty) {
      final merged = <Question>[];
      final words = <WordItem>[];
      var isWord = false;
      for (final f in looseJson) {
        try {
          final bank = await _parseOne(f.path);
          merged.addAll(bank.questions);
          words.addAll(bank.words);
          isWord = isWord || bank.isWordBank;
        } catch (_) {}
      }
      if (merged.isNotEmpty || words.isNotEmpty) {
        banks.add(QuestionBank(name: '根目录题库', dir: _root, questions: merged, words: words, isWordBank: isWord));
      }
    }
    return banks;
  }

  /// 载入一整套题库（合并该目录下所有 json）
  Future<QuestionBank> loadBank(String dirPath) async {
    final entries = await dav.list(dirPath, depth: 1);
    final files = entries.where((e) => !e.isDir && FileTypes.isJson(e.name)).toList();
    final questions = <Question>[];
    final words = <WordItem>[];
    var isWordBank = false;
    var name = baseName(dirPath);

    for (final f in files) {
      try {
        final bank = await _parseOne(f.path);
        if (bank.name.isNotEmpty) name = bank.name;
        questions.addAll(bank.questions);
        words.addAll(bank.words);
        isWordBank = isWordBank || bank.isWordBank;
      } catch (_) {
        continue;
      }
    }
    return QuestionBank(
      name: name,
      dir: dirPath,
      questions: questions.map((q) => q.copyWith(bankDir: dirPath, bankName: name)).toList(),
      words: words,
      isWordBank: isWordBank && questions.isEmpty,
    );
  }

  Future<QuestionBank> _parseOne(String filePath) async {
    final text = await dav.readText(filePath);
    final dynamic data = jsonDecode(text);
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

    final name = (map['bankName'] ?? titleFromFileName(filePath)).toString();
    final dir = parentOf(filePath);
    final isWord = (map['type'] ?? '').toString() == 'wordbank' || (map['words'] is List && map['questions'] == null);

    if (isWord) {
      final list = ((map['words'] ?? const []) as List).map((e) => WordItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      return QuestionBank(name: name, dir: dir, words: list, isWordBank: true);
    }

    final list = ((map['questions'] ?? const []) as List)
        .map((e) => Question.fromJson(Map<String, dynamic>.from(e as Map)).copyWith(bankDir: dir, bankName: name))
        .toList();
    return QuestionBank(name: name, dir: dir, questions: list);
  }

  /// 题库数量（首页统计）
  Future<int> bankCount() async {
    try {
      final dirs = await dav.list(_root, depth: 1);
      return dirs.where((e) => e.isDir).length;
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
            if (q['options'] is! List || (q['options'] as List).isEmpty) {
              errors.add('${f.name} 第 ${i + 1} 题：options 为空');
            }
            if (q['answer'] is! List || (q['answer'] as List).isEmpty) {
              errors.add('${f.name} 第 ${i + 1} 题：缺少 answer（答案下标数组）');
            } else {
              final optLen = (q['options'] is List) ? (q['options'] as List).length : 0;
              for (final a in q['answer'] as List) {
                final idx = int.tryParse(a.toString()) ?? -1;
                if (idx < 0 || idx >= optLen) {
                  errors.add('${f.name} 第 ${i + 1} 题：answer 下标 $idx 越界（共 $optLen 个选项）');
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
