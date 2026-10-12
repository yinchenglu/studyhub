import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'zip_reader.dart';

/// 电子书 / 小说阅读模式用的统一书本模型。
///
/// 三种来源都归到这里：
///   * EPUB（zip + XHTML）→ 自己解包、自己抽正文
///   * txt / md 小说 → 按「第X章 / Chapter N」这类标题切章
///   * 其它纯文本 → 整篇当一章
///
/// 为什么不用现成的 epub 包：和 zip 一样的理由，pubspec 里一个字节都不动。
class Book {
  final String title;
  final String author;
  final List<BookChapter> chapters;

  const Book({required this.title, required this.author, required this.chapters});

  int get charCount {
    var n = 0;
    for (final c in chapters) {
      n += c.text.length;
    }
    return n;
  }
}

class BookChapter {
  final String title;
  final String text;

  const BookChapter({required this.title, required this.text});
}

/// 章节标题的识别规则。刻意宽松：网络小说标题花样太多。
final RegExp _chapterHead = RegExp(
  r'^[ \t\u3000]*('
  r'第\s*[0-9０-９零一二三四五六七八九十百千万两]+\s*[章节節回卷篇话話集部]'
  r'|卷[0-9０-９零一二三四五六七八九十百千]+'
  r'|[Cc][Hh][Aa][Pp][Tt][Ee][Rr]\s+[0-9IVXLCivxlc]+'
  r'|序章|序言|序|前言|引子|楔子|尾声|尾聲|终章|終章|后记|後記|番外'
  r')',
  multiLine: true,
);

/// EPUB 解析器：container.xml → .opf → spine → 每章 XHTML
class EpubParser {
  static Book parse(Uint8List bytes, {String fallbackTitle = '未命名'}) {
    final zip = ZipReader.parse(bytes);

    // ---------- 1) container.xml 里找 .opf 的路径 ----------
    var opfPath = '';
    final container = zip.tryReadText('META-INF/container.xml');
    if (container != null && container.isNotEmpty) {
      try {
        final doc = XmlDocument.parse(container);
        for (final e in doc.descendants.whereType<XmlElement>()) {
          if (e.name.local == 'rootfile') {
            final p = e.getAttribute('full-path');
            if (p != null && p.trim().isNotEmpty) {
              opfPath = p.trim();
              break;
            }
          }
        }
      } catch (_) {
        // 容器的 xml 坏了不要紧，下面还有兜底
      }
    }
    if (opfPath.isEmpty) {
      for (final n in zip.names) {
        if (n.toLowerCase().endsWith('.opf')) {
          opfPath = n;
          break;
        }
      }
    }
    if (opfPath.isEmpty) throw const FormatException('这个 epub 里找不到 .opf 清单文件');

    final opfText = zip.tryReadText(opfPath);
    if (opfText == null) throw FormatException('读不出 epub 清单：$opfPath');

    final baseDir = _dirOf(opfPath);

    // ---------- 2) 解析 opf ----------
    var title = fallbackTitle;
    var author = '';
    final hrefOfId = <String, String>{}; // manifest: id -> 展开后的路径
    final spine = <String>[]; // spine 里的 idref 顺序
    var ncxPath = '';
    var navPath = '';

    final opf = XmlDocument.parse(opfText);
    for (final e in opf.descendants.whereType<XmlElement>()) {
      final local = e.name.local;
      if (local == 'title') {
        final t = e.innerText.trim();
        if (t.isNotEmpty && title == fallbackTitle) title = t;
      } else if (local == 'creator') {
        final a = e.innerText.trim();
        if (a.isNotEmpty && author.isEmpty) author = a;
      } else if (local == 'item') {
        final id = e.getAttribute('id') ?? '';
        final href = e.getAttribute('href') ?? '';
        final type = (e.getAttribute('media-type') ?? '').toLowerCase();
        final props = (e.getAttribute('properties') ?? '').toLowerCase();
        if (id.isEmpty || href.isEmpty) continue;
        final path = _joinPath(baseDir, href);
        hrefOfId[id] = path;
        if (type.contains('dtbncx')) ncxPath = path;
        if (props.contains('nav')) navPath = path;
      } else if (local == 'itemref') {
        final ref = e.getAttribute('idref') ?? '';
        if (ref.isNotEmpty) spine.add(ref);
      }
    }
    if (spine.isEmpty) throw const FormatException('这个 epub 的 spine 是空的，读不出章节顺序');

    // ---------- 3) 章节目录：先 NCX（epub2），再 nav（epub3）----------
    final tocTitle = <String, String>{};
    if (ncxPath.isNotEmpty) {
      final ncx = zip.tryReadText(ncxPath);
      if (ncx != null) _readNcx(ncx, _dirOf(ncxPath), tocTitle);
    }
    if (tocTitle.isEmpty && navPath.isNotEmpty) {
      final nav = zip.tryReadText(navPath);
      if (nav != null) _readNav(nav, _dirOf(navPath), tocTitle);
    }

    // ---------- 4) 逐章抽正文 ----------
    final chapters = <BookChapter>[];
    for (final id in spine) {
      final path = hrefOfId[id];
      if (path == null) continue;
      final raw = zip.tryReadText(path);
      if (raw == null) continue;
      final text = htmlToText(raw);
      if (text.trim().isEmpty) continue;
      chapters.add(BookChapter(
        title: _titleFor(path, tocTitle, text, chapters.length + 1),
        text: text,
      ));
    }
    if (chapters.isEmpty) {
      throw const FormatException('这个 epub 的正文是空的（可能是纯图片漫画版）');
    }
    return Book(title: title, author: author, chapters: chapters);
  }

  static String _titleFor(
      String path, Map<String, String> toc, String text, int ordinal) {
    final hit = toc[path] ?? toc[path.split('/').last];
    if (hit != null && hit.trim().isNotEmpty) return hit.trim();
    for (final line in text.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      if (s.length <= 30 && _chapterHead.hasMatch(s)) return s;
      break; // 只看第一行有内容的
    }
    return '第 $ordinal 章';
  }

  static void _readNcx(String xmlText, String baseDir, Map<String, String> out) {
    try {
      final doc = XmlDocument.parse(xmlText);
      var label = '';
      for (final e in doc.descendants.whereType<XmlElement>()) {
        if (e.name.local == 'text') {
          final t = e.innerText.trim();
          if (t.isNotEmpty) label = t;
        } else if (e.name.local == 'content') {
          final src = e.getAttribute('src') ?? '';
          if (src.isNotEmpty) {
            final p = _joinPath(baseDir, src);
            if (label.isNotEmpty) out.putIfAbsent(p, () => label);
            out.putIfAbsent(p.split('/').last, () => label);
          }
        }
      }
    } catch (_) {
      // NCX 坏了不影响读，只是目录标题退化成默认
    }
  }

  /// epub3 的 nav.xhtml：只粗糙地抓 `<a href="...">标题</a>`
  static void _readNav(String html, String baseDir, Map<String, String> out) {
    final re = RegExp(r'<a\s[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>',
        caseSensitive: false, dotAll: true);
    for (final m in re.allMatches(html)) {
      final href = m.group(1) ?? '';
      final label = htmlToText(m.group(2) ?? '').replaceAll('\n', ' ').trim();
      if (href.isEmpty || label.isEmpty) continue;
      final p = _joinPath(baseDir, href);
      out.putIfAbsent(p, () => label);
      out.putIfAbsent(p.split('/').last, () => label);
    }
  }
}

/// 把 txt / md 小说按章节标题切开；切不出来就整篇一章。
List<BookChapter> splitChapters(String text, String fallbackTitle) {
  final heads = <int>[];
  for (final m in _chapterHead.allMatches(text)) {
    final lineEnd = text.indexOf('\n', m.start);
    final end = lineEnd < 0 ? text.length : lineEnd;
    // 标题行不能太长，否则正文里提一句「第一章」也会被当成新章
    if (end - m.start <= 40) heads.add(m.start);
  }
  if (heads.isEmpty) {
    return [BookChapter(title: fallbackTitle, text: text)];
  }
  final out = <BookChapter>[];
  // 第一个标题之前如果有正文，单独做成「前言」
  if (heads.first > 0) {
    final pre = text.substring(0, heads.first).trim();
    if (pre.length > 40) out.add(BookChapter(title: '前言', text: pre));
  }
  for (var i = 0; i < heads.length; i++) {
    final start = heads[i];
    final stop = i + 1 < heads.length ? heads[i + 1] : text.length;
    final body = text.substring(start, stop).trim();
    if (body.isEmpty) continue;
    final nl = body.indexOf('\n');
    final head = (nl < 0 ? body : body.substring(0, nl)).trim();
    out.add(BookChapter(title: head.isEmpty ? '第 ${i + 1} 章' : head, text: body));
  }
  return out.isEmpty ? [BookChapter(title: fallbackTitle, text: text)] : out;
}

// ------------------------------------------------------------------ 文本处理

/// 把 XHTML / HTML 抽成纯文本：块级标签变段落，行内标签直接抹掉。
String htmlToText(String html) {
  var s = html;
  // 注释、脚本、样式整段丢掉
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  s = s.replaceAll(RegExp(r'<(script|style|head)\b.*?</\1\s*>',
      caseSensitive: false, dotAll: true), '');
  // 块级收尾标签 → 换行
  s = s.replaceAll(
      RegExp(r'</\s*(p|div|h[1-6]|li|tr|section|article|blockquote|pre|dd|dt)\s*>',
          caseSensitive: false),
      '\n');
  // <br> 与 <hr> → 换行
  s = s.replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*hr\s*/?\s*>', caseSensitive: false), '\n');
  // 剩下的标签全抹掉
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');
  s = decodeEntities(s);

  final lines = <String>[];
  for (final raw in s.split('\n')) {
    final t = raw.replaceAll(RegExp(r'[ \t\u3000]+'), ' ').trim();
    if (t.isEmpty) {
      // 连续空行压成一个段落分隔
      if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
      continue;
    }
    lines.add(t);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

const Map<String, String> _named = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00a0',
  'ensp': ' ',
  'emsp': '\u3000',
  'thinsp': ' ',
  'middot': '·',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'laquo': '«',
  'raquo': '»',
  'bull': '•',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
  'times': '×',
  'divide': '÷',
  'prime': '′',
  'Prime': '″',
  'shy': '',
};

final RegExp _entityRe = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);');

String decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entityRe, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final v = int.tryParse(body.substring(2), radix: 16);
      return (v == null || v <= 0 || v > 0x10FFFF) ? m.group(0)! : String.fromCharCode(v);
    }
    if (body.startsWith('#')) {
      final v = int.tryParse(body.substring(1));
      return (v == null || v <= 0 || v > 0x10FFFF) ? m.group(0)! : String.fromCharCode(v);
    }
    return _named[body] ?? m.group(0)!;
  });
}

// ------------------------------------------------------------------ 路径

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// 把 opf / ncx 里的相对 href 展开成 zip 内的绝对路径。
/// 会处理 `./`、`../`、`#锚点` 和 `%20` 这类百分号转义。
String _joinPath(String baseDir, String href) {
  var h = href.split('#').first.trim();
  if (h.isEmpty) return '';
  h = _pctDecode(h);
  final parts = <String>[];
  if (!baseDir.isEmpty) parts.addAll(baseDir.split('/'));
  for (final seg in h.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

String _pctDecode(String s) {
  if (!s.contains('%')) return s;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '%' && i + 2 < s.length) {
      final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        out.writeCharCode(v);
        i += 2;
        continue;
      }
    }
    out.write(s[i]);
  }
  return out.toString();
}
