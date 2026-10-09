import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/repositories/note_repo.dart';
import 'utils.dart';

/// 待导出的一篇笔记
class ExportDoc {
  final String path; // 服务器路径，用来解析 md 里的相对图片
  final String title;
  final String markdown;

  const ExportDoc({required this.path, required this.title, required this.markdown});
}

/// 笔记导出器：把 Markdown 变成可以分享出去的 HTML / PDF。
///
/// 设计取舍：
/// * HTML 导出是「单文件自包含」——图片转成 base64 内嵌，发到微信、QQ、
///   丢到浏览器里都能直接看，不会因为相对路径失效而丢图。
/// * PDF 导出用纯 Dart 的 pdf 包 + 内置的中文字体（assets/fonts），
///   不需要任何原生依赖，中文不会变成方块。
class NoteExporter {
  final NoteRepo repo;
  NoteExporter(this.repo);

  /// 打包进 App 的中文字体
  static const String fontAsset = 'assets/fonts/NotoSansSC-Regular.ttf';
  static pw.Font? _cachedFont;

  static Future<pw.Font> _font() async {
    if (_cachedFont != null) return _cachedFont!;
    final data = await rootBundle.load(fontAsset);
    _cachedFont = pw.Font.ttf(data);
    return _cachedFont!;
  }

  // ------------------------------------------------------------ 图片

  /// 把笔记里引用的图片读成字节；失败返回 null
  Future<Uint8List?> _imageBytes(String notePath, String src) async {
    try {
      if (src.startsWith('http://') || src.startsWith('https://')) return null;
      final clean = src.replaceAll(RegExp(r'^\./'), '').split('#').first.split('?').first;
      final p = joinPath(parentOf(notePath), clean);
      return await repo.dav.readBytes(p);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ HTML

  /// 生成单文件 HTML（图片 base64 内嵌）
  Future<String> buildHtml(List<ExportDoc> docs, {bool cover = true}) async {
    final buf = StringBuffer();
    final title = docs.length == 1 ? docs.first.title : '${docs.length} 篇笔记合集';

    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html lang="zh-CN"><head><meta charset="utf-8">');
    buf.writeln('<meta name="viewport" content="width=device-width,initial-scale=1">');
    buf.writeln('<title>${_esc(title)}</title>');
    buf.writeln('''<style>
  :root { color-scheme: light dark; }
  body { margin:0; padding:24px 18px 60px; background:#f6f7f9; color:#1d1d1f;
         font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;
         font-size:16px; line-height:1.8; -webkit-text-size-adjust:100%; }
  .wrap { max-width:760px; margin:0 auto; }
  .doc { background:#fff; border-radius:14px; padding:26px 22px; margin-bottom:22px;
         box-shadow:0 1px 3px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.05); }
  h1,h2,h3,h4 { line-height:1.35; font-weight:700; margin:1.3em 0 .6em; }
  h1 { font-size:26px; border-bottom:2px solid #eee; padding-bottom:.3em; }
  h2 { font-size:22px; } h3 { font-size:19px; } h4 { font-size:17px; }
  h1:first-child,h2:first-child { margin-top:0; }
  p { margin:.7em 0; }
  img { max-width:100%; height:auto; border-radius:10px; display:block; margin:14px 0; }
  code { background:#f1f2f4; padding:2px 6px; border-radius:5px; font-size:.92em;
         font-family:ui-monospace,Menlo,Consolas,monospace; }
  pre { background:#f6f8fa; padding:14px 16px; border-radius:10px; overflow-x:auto; }
  pre code { background:none; padding:0; }
  blockquote { margin:1em 0; padding:.4em 1em; border-left:4px solid #8ab4f8;
               background:#f4f7ff; border-radius:0 8px 8px 0; color:#3c4043; }
  ul,ol { padding-left:1.6em; } li { margin:.3em 0; }
  hr { border:none; border-top:1px solid #e3e5e8; margin:1.8em 0; }
  table { border-collapse:collapse; width:100%; margin:1em 0; font-size:.95em; }
  th,td { border:1px solid #e3e5e8; padding:8px 10px; text-align:left; }
  th { background:#f6f7f9; }
  a { color:#1a73e8; }
  .cover { text-align:center; padding:40px 20px; }
  .cover h1 { border:none; font-size:28px; }
  .cover .meta { color:#5f6368; font-size:14px; margin-top:8px; }
  .cover ol { display:inline-block; text-align:left; margin-top:20px; color:#3c4043; }
  .foot { text-align:center; color:#9aa0a6; font-size:12px; margin-top:26px; }
  @media (prefers-color-scheme: dark) {
    body { background:#16181c; color:#e8eaed; }
    .doc { background:#202124; box-shadow:none; }
    code,pre,th { background:#2b2d31; }
    blockquote { background:#232a36; color:#cdd3da; }
    h1 { border-color:#3c4043; }
    th,td { border-color:#3c4043; }
    .cover .meta,.cover ol { color:#9aa0a6; }
  }
</style></head><body><div class="wrap">''');

    if (cover) {
      buf.writeln('<div class="doc cover">');
      if (docs.length == 1) {
        buf.writeln('<h1>${_esc(docs.first.title)}</h1>');
        buf.writeln('<div class="meta">导出自「学聚」学习 App</div>');
      } else {
        buf.writeln('<h1>${_esc(title)}</h1>');
        buf.writeln('<div class="meta">共 ${docs.length} 篇 · 导出自「学聚」学习 App</div>');
        buf.writeln('<ol>');
        for (final d in docs) {
          buf.writeln('<li>${_esc(d.title)}</li>');
        }
        buf.writeln('</ol>');
      }
      buf.writeln('</div>');
    }

    for (final doc in docs) {
      buf.writeln('<div class="doc">');
      if (docs.length > 1) buf.writeln('<h1>${_esc(doc.title)}</h1>');
      final blocks = _parse(doc.markdown);
      for (final b in blocks) {
        await _htmlBlock(buf, doc, b);
      }
      buf.writeln('</div>');
    }

    final now = DateTime.now();
    buf.writeln('<div class="foot">${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)} 导出</div>');
    buf.writeln('</div></body></html>');
    return buf.toString();
  }

  Future<void> _htmlBlock(StringBuffer buf, ExportDoc doc, _Block b) async {
    switch (b.kind) {
      case _BKind.h1:
      case _BKind.h2:
      case _BKind.h3:
      case _BKind.h4:
      case _BKind.h5:
      case _BKind.h6:
        final n = b.kind.index + 1;
        buf.writeln('<h$n>${_inline(b.text)}</h$n>');
        break;
      case _BKind.p:
        buf.writeln('<p>${_inline(b.text)}</p>');
        break;
      case _BKind.code:
        buf.writeln('<pre><code>${_esc(b.text)}</code></pre>');
        break;
      case _BKind.quote:
        buf.writeln('<blockquote>${_inline(b.text)}</blockquote>');
        break;
      case _BKind.ul:
        buf.writeln('<ul>');
        for (final it in b.items) {
          buf.writeln('<li>${_inline(it)}</li>');
        }
        buf.writeln('</ul>');
        break;
      case _BKind.ol:
        buf.writeln('<ol>');
        for (final it in b.items) {
          buf.writeln('<li>${_inline(it)}</li>');
        }
        buf.writeln('</ol>');
        break;
      case _BKind.hr:
        buf.writeln('<hr>');
        break;
      case _BKind.img:
        final bytes = await _imageBytes(doc.path, b.text);
        if (bytes != null) {
          final mime = _mimeOf(b.text);
          buf.writeln('<img alt="${_esc(b.alt ?? '')}" src="data:$mime;base64,${base64Encode(bytes)}">');
        } else {
          buf.writeln('<p><em>［图片加载失败：${_esc(b.text)}］</em></p>');
        }
        break;
      case _BKind.table:
        buf.writeln('<table>');
        for (var i = 0; i < b.rows.length; i++) {
          buf.writeln('<tr>');
          for (final c in b.rows[i]) {
            buf.writeln(i == 0 ? '<th>${_inline(c)}</th>' : '<td>${_inline(c)}</td>');
          }
          buf.writeln('</tr>');
        }
        buf.writeln('</table>');
        break;
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _mimeOf(String name) {
    final e = name.split('.').last.toLowerCase();
    switch (e) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'svg':
        return 'image/svg+xml';
      default:
        return 'image/jpeg';
    }
  }

  /// 极简行内 Markdown → HTML
  String _inline(String s) {
    var t = _esc(s);
    // 图片（行内出现的）
    t = t.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'), (m) => '<em>[图片: ${m.group(2)}]</em>');
    t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (m) => '<a href="${m.group(2)}">${m.group(1)}</a>');
    t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => '<strong>${m.group(1)}</strong>');
    t = t.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => '<strong>${m.group(1)}</strong>');
    t = t.replaceAllMapped(RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'), (m) => '<em>${m.group(1)}</em>');
    t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => '<code>${m.group(1)}</code>');
    t = t.replaceAllMapped(RegExp(r'~~([^~]+)~~'), (m) => '<del>${m.group(1)}</del>');
    return t;
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // ------------------------------------------------------------ PDF

  /// 生成 PDF
  Future<Uint8List> buildPdf(List<ExportDoc> docs, {bool cover = true}) async {
    final font = await _font();
    // 提前把图片读好（pdf 渲染是同步的）
    final images = <String, pw.MemoryImage>{};
    for (final doc in docs) {
      for (final b in _parse(doc.markdown)) {
        if (b.kind != _BKind.img) continue;
        final key = '${doc.path}|${b.text}';
        if (images.containsKey(key)) continue;
        final bytes = await _imageBytes(doc.path, b.text);
        if (bytes == null) continue;
        try {
          images[key] = pw.MemoryImage(bytes);
        } catch (_) {
          // gif / webp 等 pdf 包不支持的格式，跳过
        }
      }
    }

    final doc = pw.Document(title: docs.length == 1 ? docs.first.title : '${docs.length} 篇笔记合集');
    final base = pw.TextStyle(font: font, fontSize: 10.5, lineSpacing: 3, color: PdfColors.grey900);
    final h1 = pw.TextStyle(font: font, fontSize: 20, lineSpacing: 3, color: PdfColors.grey900);
    final h2 = pw.TextStyle(font: font, fontSize: 16, lineSpacing: 3, color: PdfColors.grey900);
    final h3 = pw.TextStyle(font: font, fontSize: 13.5, lineSpacing: 3, color: PdfColors.grey800);
    final small = pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey600);

    const margin = pw.EdgeInsets.fromLTRB(42, 46, 42, 46);

    final widgets = <pw.Widget>[];

    if (cover) {
      widgets.add(
        pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(vertical: 60),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(docs.length == 1 ? docs.first.title : '${docs.length} 篇笔记合集',
                  style: pw.TextStyle(font: font, fontSize: 26, color: PdfColors.grey900),
                  textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 14),
              pw.Text('导出自「学聚」学习 App · ${_dateText()}',
                  style: small.copyWith(fontSize: 10.5)),
              if (docs.length > 1) ...[
                pw.SizedBox(height: 30),
                pw.Divider(color: PdfColors.grey400),
                pw.SizedBox(height: 10),
                ...docs.asMap().entries.map((e) => pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: pw.Text('${e.key + 1}. ${e.value.title}', style: base.copyWith(fontSize: 11.5)),
                    )),
              ],
            ],
          ),
        ),
      );
      // 封面单独一页
      doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: margin, build: (c) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: widgets,
      )));
      widgets.clear();
    }

    for (var di = 0; di < docs.length; di++) {
      final note = docs[di];
      if (di > 0) widgets.add(pw.NewPage());
      if (docs.length > 1) {
        widgets.add(pw.Text(note.title, style: h1));
        widgets.add(pw.Divider(color: PdfColors.grey400));
        widgets.add(pw.SizedBox(height: 6));
      }
      for (final b in _parse(note.markdown)) {
        final w = _pdfBlock(b, note, images, base, h1, h2, h3, small);
        if (w != null) widgets.add(w);
      }
    }

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: margin,
      // 必须显式给 maxPages！MultiPage 的默认上限只有 20 页，
      // 超了会直接抛「This widget created more than 20 pages」。
      // 合并导出多篇笔记轻松就过 20 页，不写这一行等于「合并导出」必炸。
      maxPages: 2000,
      footer: (c) => pw.Align(
        alignment: pw.Alignment.center,
        child: pw.Text('${c.pageNumber} / ${c.pagesCount}', style: small),
      ),
      build: (c) => widgets,
    ));

    return doc.save();
  }

  String _dateText() {
    final n = DateTime.now();
    return '${n.year}-${_two(n.month)}-${_two(n.day)}';
  }

  pw.Widget? _pdfBlock(
    _Block b,
    ExportDoc doc,
    Map<String, pw.MemoryImage> images,
    pw.TextStyle base,
    pw.TextStyle h1,
    pw.TextStyle h2,
    pw.TextStyle h3,
    pw.TextStyle small,
  ) {
    switch (b.kind) {
      case _BKind.h1:
        return _pdfHeading(b.text, h1, 14);
      case _BKind.h2:
        return _pdfHeading(b.text, h2, 11);
      case _BKind.h3:
      case _BKind.h4:
      case _BKind.h5:
      case _BKind.h6:
        return _pdfHeading(b.text, h3, 8);
      case _BKind.p:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Text(_plain(b.text), style: base),
        );
      case _BKind.code:
        return pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(color: PdfColors.grey100, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Text(b.text, style: base.copyWith(fontSize: 9.5, lineSpacing: 2)),
        );
      case _BKind.quote:
        return pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: const pw.EdgeInsets.fromLTRB(10, 6, 8, 6),
          decoration: const pw.BoxDecoration(
            color: PdfColors.grey100,
            border: pw.Border(left: pw.BorderSide(color: PdfColors.blue300, width: 3)),
          ),
          child: pw.Text(_plain(b.text), style: base.copyWith(color: PdfColors.grey700)),
        );
      case _BKind.ul:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: b.items
                .map((it) => pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.SizedBox(width: 12, child: pw.Text('•', style: base)),
                        pw.Expanded(child: pw.Text(_plain(it), style: base)),
                      ],
                    ))
                .toList(),
          ),
        );
      case _BKind.ol:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: b.items.asMap().entries.map((e) => pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(width: 16, child: pw.Text('${e.key + 1}.', style: base)),
                    pw.Expanded(child: pw.Text(_plain(e.value), style: base)),
                  ],
                )).toList(),
          ),
        );
      case _BKind.hr:
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 8),
          child: pw.Divider(color: PdfColors.grey400),
        );
      case _BKind.img:
        final img = images['${doc.path}|${b.text}'];
        if (img == null) {
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6),
            child: pw.Text('［图片：${b.text}］', style: small),
          );
        }
        final iw = (img.width ?? 1).toDouble();
        final ih = (img.height ?? 1).toDouble();
        const maxW = 470.0;
        var w = maxW;
        var h = maxW * ih / iw;
        if (h > 600) {
          h = 600;
          w = 600 * iw / ih;
        }
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          child: pw.Image(img, width: w, height: h, fit: pw.BoxFit.contain),
        );
      case _BKind.table:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.TableHelper.fromTextArray(
            headers: b.rows.isEmpty ? null : b.rows.first.map(_plain).toList(),
            data: b.rows.length <= 1
                ? const <List<String>>[]
                : b.rows.sublist(1).map((r) => r.map(_plain).toList()).toList(),
            border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
            headerStyle: base.copyWith(fontSize: 10),
            cellStyle: base.copyWith(fontSize: 10),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          ),
        );
    }
  }

  pw.Widget _pdfHeading(String text, pw.TextStyle style, double bottom) => pw.Padding(
        padding: pw.EdgeInsets.only(top: 4, bottom: bottom),
        child: pw.Text(_plain(text), style: style),
      );

  /// PDF 里不做行内富文本（没有粗体字重），把标记去掉即可
  String _plain(String s) => s
      .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'), (m) => '［图片：${m.group(2)}］')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
      .replaceAllMapped(RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'), (m) => m.group(1)!);

  // ------------------------------------------------------------ Markdown 解析

  List<_Block> _parse(String md) {
    final lines = md.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <_Block>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final t = line.trim();

      if (t.isEmpty) {
        i++;
        continue;
      }

      // 代码块
      if (t.startsWith('```') || t.startsWith('~~~')) {
        final fence = t.substring(0, 3);
        final buf = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence)) {
          buf.add(lines[i]);
          i++;
        }
        i++; // 跳过结束标记
        out.add(_Block(_BKind.code, text: buf.join('\n')));
        continue;
      }

      // 分隔线
      if (RegExp(r'^([-*_])\1{2,}$').hasMatch(t.replaceAll(' ', ''))) {
        out.add(const _Block(_BKind.hr));
        i++;
        continue;
      }

      // 标题
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(t);
      if (h != null) {
        final lvl = h.group(1)!.length;
        out.add(_Block(_BKind.values[lvl - 1], text: h.group(2)!.trim()));
        i++;
        continue;
      }

      // 表格
      if (t.startsWith('|') && i + 1 < lines.length && RegExp(r'^\|[\s:\-|]+\|$').hasMatch(lines[i + 1].trim())) {
        final rows = <List<String>>[];
        rows.add(_cells(lines[i]));
        i += 2;
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          rows.add(_cells(lines[i]));
          i++;
        }
        out.add(_Block(_BKind.table, rows: rows));
        continue;
      }

      // 引用
      if (t.startsWith('>')) {
        final buf = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          buf.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        out.add(_Block(_BKind.quote, text: buf.join(' ')));
        continue;
      }

      // 有序列表
      if (RegExp(r'^\d+[.)]\s+').hasMatch(t)) {
        final items = <String>[];
        while (i < lines.length && RegExp(r'^\d+[.)]\s+').hasMatch(lines[i].trim())) {
          items.add(lines[i].trim().replaceFirst(RegExp(r'^\d+[.)]\s+'), ''));
          i++;
        }
        out.add(_Block(_BKind.ol, items: items));
        continue;
      }

      // 无序列表
      if (RegExp(r'^[-*+]\s+').hasMatch(t)) {
        final items = <String>[];
        while (i < lines.length && RegExp(r'^[-*+]\s+').hasMatch(lines[i].trim())) {
          items.add(lines[i].trim().replaceFirst(RegExp(r'^[-*+]\s+'), ''));
          i++;
        }
        out.add(_Block(_BKind.ul, items: items));
        continue;
      }

      // 独占一行的图片
      final img = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$').firstMatch(t);
      if (img != null) {
        out.add(_Block(_BKind.img, text: img.group(2)!, alt: img.group(1)));
        i++;
        continue;
      }

      // 普通段落
      final buf = <String>[];
      while (i < lines.length) {
        final cur = lines[i].trim();
        if (cur.isEmpty ||
            cur.startsWith('```') ||
            cur.startsWith('~~~') ||
            cur.startsWith('>') ||
            cur.startsWith('|') ||
            cur.startsWith('#') ||
            RegExp(r'^[-*+]\s+').hasMatch(cur) ||
            RegExp(r'^\d+[.)]\s+').hasMatch(cur) ||
            RegExp(r'^([-*_])\1{2,}$').hasMatch(cur.replaceAll(' ', ''))) {
          break;
        }
        buf.add(cur);
        i++;
      }
      if (buf.isEmpty) {
        i++;
        continue;
      }
      out.add(_Block(_BKind.p, text: buf.join(' ')));
    }
    return out;
  }

  List<String> _cells(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s.split('|').map((e) => e.trim()).toList();
  }
}

enum _BKind { h1, h2, h3, h4, h5, h6, p, code, quote, ul, ol, hr, img, table }

class _Block {
  final _BKind kind;
  final String text;
  final List<String> items;
  final List<List<String>> rows;
  final String? alt;

  const _Block(this.kind, {this.text = '', this.items = const [], this.rows = const [], this.alt});
}
