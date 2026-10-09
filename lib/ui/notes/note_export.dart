import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/note_exporter.dart';
import '../../core/permissions.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/local/db.dart';
import '../../data/models/models.dart';
import '../../data/repositories/note_repo.dart';
import '../../providers/providers.dart';

/// 导出格式
enum ExportFormat { pdf, html, markdown }

extension ExportFormatX on ExportFormat {
  String get label => switch (this) {
        ExportFormat.pdf => 'PDF',
        ExportFormat.html => '网页 (HTML)',
        ExportFormat.markdown => 'Markdown 原文',
      };

  String get ext => switch (this) {
        ExportFormat.pdf => 'pdf',
        ExportFormat.html => 'html',
        ExportFormat.markdown => 'md',
      };

  String get hint => switch (this) {
        ExportFormat.pdf => '排版整齐，微信 / QQ 里直接能看，手机电脑都通用。推荐',
        ExportFormat.html => '单文件网页，图片会内嵌进去，双击用浏览器打开最清楚',
        ExportFormat.markdown => '原始文本，适合再拿去别的地方继续编辑',
      };

  IconData get icon => switch (this) {
        ExportFormat.pdf => Icons.picture_as_pdf_outlined,
        ExportFormat.html => Icons.language_outlined,
        ExportFormat.markdown => Icons.text_snippet_outlined,
      };
}

/// 一次导出的结果
class ExportResult {
  final List<File> files;
  final Directory dir;
  final int docCount;

  const ExportResult({required this.files, required this.dir, required this.docCount});
}

// --------------------------------------------------------------------- 服务

/// 笔记导出：把选中的笔记（可以是目录，会递归展开）导出成 PDF / HTML / Markdown。
///
/// 目录结构：
///   * 单篇 + 不合并  → 直接落到下载目录里一个文件
///   * 其它情况       → 建一个「笔记导出_时间戳」子目录，里面放多个文件
class NoteExportService {
  final NoteRepo repo;
  NoteExportService(this.repo);

  /// 把「选中的条目」展开成待导出的笔记列表
  Future<List<ExportDoc>> collect(List<DavEntry> picked) async {
    final out = <ExportDoc>[];
    final seen = <String>{};

    for (final e in picked) {
      if (e.isDir) {
        // 目录：递归把里面的 md 全拿出来
        final sub = _relOf(e.path);
        final notes = await repo.listNotes(sub, recursive: true);
        for (final n in notes) {
          if (!seen.add(n.path)) continue;
          out.add(ExportDoc(path: n.path, title: n.title, markdown: await repo.readNote(n.path)));
        }
      } else {
        if (!FileTypes.isReadableText(e.name)) continue;
        if (!seen.add(e.path)) continue;
        out.add(ExportDoc(
          path: e.path,
          title: titleFromFileName(e.name),
          markdown: await repo.readNote(e.path),
        ));
      }
    }
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  /// picked 路径 → 相对 notes 的子路径
  String _relOf(String path) =>
      path.startsWith('${AppDirs.notes}/') ? path.substring(AppDirs.notes.length + 1) : '';

  /// 执行导出。返回落盘的文件列表。
  Future<ExportResult> run({
    required List<DavEntry> picked,
    required ExportFormat format,
    required bool merge,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在读取笔记…');
    final docs = await collect(picked);
    if (docs.isEmpty) {
      throw StateError('选中的内容里没有可以导出的笔记（只支持 .md / .txt 文本）');
    }

    final exporter = NoteExporter(repo);
    final outDir = await _resolveOutDir(docs.length == 1 && !merge);
    final files = <File>[];

    if (format == ExportFormat.markdown) {
      onProgress?.call('正在写出 Markdown…');
      if (merge) {
        final buf = StringBuffer();
        for (var i = 0; i < docs.length; i++) {
          if (i > 0) buf.write('\n\n---\n\n');
          buf.write('# ${docs[i].title}\n\n');
          buf.write(docs[i].markdown.trim());
          buf.write('\n');
        }
        files.add(await _write(outDir, _fileName(docs, merge: true, ext: 'md'), buf.toString()));
      } else {
        for (final d in docs) {
          files.add(await _write(outDir, '${Downloader.safeName(d.title)}.md', d.markdown));
        }
      }
      return ExportResult(files: files, dir: outDir, docCount: docs.length);
    }

    if (format == ExportFormat.html) {
      if (merge) {
        onProgress?.call('正在生成网页（图片内嵌，稍等）…');
        final html = await exporter.buildHtml(docs);
        files.add(await _write(outDir, _fileName(docs, merge: true, ext: 'html'), html));
      } else {
        for (var i = 0; i < docs.length; i++) {
          onProgress?.call('正在生成网页 ${i + 1}/${docs.length}…');
          final html = await exporter.buildHtml([docs[i]]);
          files.add(await _write(outDir, '${Downloader.safeName(docs[i].title)}.html', html));
        }
      }
      return ExportResult(files: files, dir: outDir, docCount: docs.length);
    }

    // PDF
    if (merge) {
      onProgress?.call('正在生成 PDF（共 ${docs.length} 篇）…');
      final bytes = await exporter.buildPdf(docs);
      files.add(await _writeBytes(outDir, _fileName(docs, merge: true, ext: 'pdf'), bytes));
    } else {
      for (var i = 0; i < docs.length; i++) {
        onProgress?.call('正在生成 PDF ${i + 1}/${docs.length}…');
        final bytes = await exporter.buildPdf([docs[i]]);
        files.add(await _writeBytes(outDir, '${Downloader.safeName(docs[i].title)}.pdf', bytes));
      }
    }
    return ExportResult(files: files, dir: outDir, docCount: docs.length);
  }

  /// 合并导出时的文件名：单篇用标题，多篇用「首篇等 N 篇合集」
  String _fileName(List<ExportDoc> docs, {required bool merge, required String ext}) {
    if (docs.length == 1) return '${Downloader.safeName(docs.first.title)}.$ext';
    final head = Downloader.safeName(docs.first.title);
    return '$head 等 ${docs.length} 篇合集.$ext';
  }

  /// 决定输出目录。单篇且不合并就直接放下载目录；否则建子目录。
  /// 拿不到公共目录权限时自动退回应用专属目录，保证一定能导出成功。
  Future<Directory> _resolveOutDir(bool flat) async {
    Directory base;
    try {
      if (Platform.isAndroid) {
        final granted = await ensureStoragePermission();
        if (!granted) {
          base = Directory(await CacheManager.appPrivateDownloadPath());
        } else {
          base = await CacheManager.instance.downloadDir;
        }
      } else {
        base = await CacheManager.instance.downloadDir;
      }
    } catch (_) {
      base = Directory(await CacheManager.appPrivateDownloadPath());
    }
    if (!await base.exists()) await base.create(recursive: true);
    if (flat) return base;

    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = '笔记导出_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dir = Directory(p.join(base.path, name));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _write(Directory dir, String name, String content) async {
    final f = File(p.join(dir.path, name));
    await f.writeAsString(content);
    return f;
  }

  Future<File> _writeBytes(Directory dir, String name, List<int> bytes) async {
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    return f;
  }
}

// --------------------------------------------------------------------- UI

/// 打开「导出笔记」面板。picked 是当前长按多选选中的条目。
///
/// 流程：面板里选格式 → 导出 → 面板把结果「返回」给这里 → 这里用**宿主页面的
/// context** 弹结果框。这样做是为了避免面板关闭后还拿它的 context 弹窗（会崩）。
Future<void> showNoteExportSheet(BuildContext context, List<DavEntry> picked) async {
  final result = await showModalBottomSheet<ExportResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _NoteExportSheet(picked: picked),
  );
  if (result == null) return;
  if (!context.mounted) return;
  await _showExportResultDialog(context, result);
}

/// 导出结果：列一下文件、给个分享按钮
Future<void> _showExportResultDialog(BuildContext context, ExportResult r) async {
  final scheme = Theme.of(context).colorScheme;
  final total = r.files.fold<int>(0, (a, f) => a + (f.existsSync() ? f.lengthSync() : 0));

  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导出完成'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('共 ${r.docCount} 篇笔记 → ${r.files.length} 个文件（${formatBytes(total)}）'),
              const SizedBox(height: 12),
              if (r.files.length <= 8)
                ...r.files.map((f) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.insert_drive_file_outlined,
                              size: 15, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(baseName(f.path),
                                style: const TextStyle(fontSize: 12.5)),
                          ),
                        ],
                      ),
                    ))
              else
                Text('（共 ${r.files.length} 个文件）', style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(r.dir.path, style: const TextStyle(fontSize: 11, height: 1.4)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, 'share'),
          icon: const Icon(Icons.share_outlined, size: 18),
          label: const Text('分享出去'),
        ),
      ],
    ),
  );

  if (action != 'share') return;
  await _shareExport(context, r);
}

Future<void> _shareExport(BuildContext context, ExportResult r) async {
  final files = r.files.where((f) => f.existsSync()).toList();
  if (files.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件不在了，可能被清理了')));
    return;
  }
  try {
    await SharePlus.instance.share(ShareParams(
      files: files.map((f) => XFile(f.path)).toList(),
      subject: files.length == 1 ? baseName(files.first.path) : '学聚笔记导出',
      text: r.docCount == 1 ? baseName(files.first.path) : '共 ${r.docCount} 篇笔记',
    ));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享失败：$e')));
  }
}

class _NoteExportSheet extends ConsumerStatefulWidget {
  final List<DavEntry> picked;
  const _NoteExportSheet({required this.picked});

  @override
  ConsumerState<_NoteExportSheet> createState() => _NoteExportSheetState();
}

class _NoteExportSheetState extends ConsumerState<_NoteExportSheet> {
  ExportFormat _format = ExportFormat.pdf;
  bool _merge = true;
  bool _busy = false;
  String _step = '';
  double? _ratio;

  /// 选中的目录会递归展开，这里先算个大概数量给用户看
  int get _fileCount =>
      widget.picked.where((e) => !e.isDir && FileTypes.isReadableText(e.name)).length;
  bool get _hasDir => widget.picked.any((e) => e.isDir);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final multi = widget.picked.length > 1 || _hasDir;

    if (_busy) return _busyView(scheme);

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('导出 ${widget.picked.length} 项', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                _hasDir
                    ? '目录会自动展开，把里面的笔记一起导出'
                    : (_fileCount > 1 ? '已选中 $_fileCount 篇笔记' : ''),
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),

              _label('导出格式'),
              for (final f in ExportFormat.values)
                _ChoiceTile(
                  selected: _format == f,
                  leading: Icon(f.icon, size: 19),
                  title: f.label,
                  subtitle: f.hint,
                  onTap: () => setState(() => _format = f),
                ),

              if (multi) ...[
                const SizedBox(height: 6),
                _label('导出方式'),
                _ChoiceTile(
                  selected: _merge,
                  title: '合并成一个文件',
                  subtitle: '所有笔记合成一份，带封面和目录，方便整体分享',
                  onTap: () => setState(() => _merge = true),
                ),
                _ChoiceTile(
                  selected: !_merge,
                  title: '每篇笔记一个文件',
                  subtitle: '各导出各的，放在同一个文件夹里',
                  onTap: () => setState(() => _merge = false),
                ),
              ],

              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 17, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '导出到手机「下载」目录下的 StudyHub 文件夹（可在设置里改）。'
                        '导出完可以直接分享到微信 / QQ。',
                        style: TextStyle(fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _startExport,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('开始导出'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _busyView(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(_step.isEmpty ? '正在导出…' : _step, textAlign: TextAlign.center),
            if (_ratio != null) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _ratio, minHeight: 5, borderRadius: BorderRadius.circular(3)),
            ],
            const SizedBox(height: 10),
            Text('图片要一张张读回来内嵌，篇数多的时候会慢一点',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 2, top: 4),
        child: Text(s,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            )),
      );

  Future<void> _startExport() async {
    final repo = ref.read(noteRepoProvider);
    if (repo == null) {
      _toast('还没有连接服务器');
      return;
    }
    setState(() {
      _busy = true;
      _step = '正在读取笔记…';
    });

    try {
      final result = await NoteExportService(repo).run(
        picked: widget.picked,
        format: _format,
        merge: _merge && (widget.picked.length > 1 || _hasDir),
        onProgress: (m) {
          if (mounted) setState(() => _step = m);
        },
      );
      if (!mounted) return;
      // 把结果「返回」给打开的宿主页面去弹框 —— 不要在这里用本面板的 context
      // 弹窗，因为下一行面板就被销毁了。
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = '';
      });
      _toast('导出失败：$e');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
}

/// 单选条目：不用 RadioListTile，避免各版本 Flutter 的 API 差异
class _ChoiceTile extends StatelessWidget {
  final bool selected;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.selected,
    required this.title,
    required this.onTap,
    this.leading,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 19,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: TextStyle(
                            fontSize: 11.5, height: 1.45, color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
