import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../core/downloader.dart';
import '../../core/utils.dart';
import '../../data/dav/webdav_client.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';

/// 服务器文件操作集合（v1.9.0+31 新增）。
///
/// ## 为什么单独抽一个文件
///
/// 这套「新建文件夹 / 上传 / 重命名 / 编辑文本 / 下载 / 分享 / 复制直链 / 删除」
/// 原本只写在「服务器下载站」里。+31 用户要求**进入 StudyHub 根目录之后
/// 也要有同一套菜单**（根目录浏览页是另一个文件），两处各抄一遍必然走样，
/// 所以把操作逻辑抽到这里，页面只负责画列表。
///
/// ## 用法
///
/// ```dart
/// final ops = ServerFileOps(
///   context: context,
///   ref: ref,
///   dirPath: _curDir,          // 相对资料根的当前目录，'' = 根
///   onChanged: _load,          // 操作完刷新列表
/// );
/// await ops.showEntrySheet(entry);
/// ```
///
/// 各个方法内部已经处理了「context 已经不在树上」的情况（每个 await 之后
/// 都查 `context.mounted`），调用方不用自己兜。
class ServerFileOps {
  ServerFileOps({
    required this.context,
    required this.ref,
    required this.dirPath,
    required this.onChanged,
    this.onDownloaded,
  });

  /// 调用方页面的 context（用来弹对话框 / SnackBar）
  final BuildContext context;

  /// Riverpod 的 ref，用来取 WebDAV 客户端
  final WidgetRef ref;

  /// 当前所在目录（**相对资料根**，不带首尾斜杠；空串 = 根目录）
  final String dirPath;

  /// 任何写操作完成后调用，让页面重新拉一次列表
  final Future<void> Function() onChanged;

  /// 某个文件下载成功（下载站用它打「已下载」标记，别的页面不用传）
  final void Function(DavEntry e)? onDownloaded;

  /// 原生「选任意文件」通道（系统文件选择器 SAF，见 MainActivity.kt）
  static const MethodChannel _filesChannel = MethodChannel('studyhub/files');

  bool _progressOpen = false;

  WebDavClient? get _client => ref.read(davClientProvider);

  String _join(String name) => dirPath.isEmpty ? name : '$dirPath/$name';

  // ------------------------------------------------------------ 对外能力

  /// 长按 / 点「⋮」弹出的条目菜单。
  Future<void> showEntrySheet(DavEntry e) async {
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // 通用：重命名（文件和文件夹都有）
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('重命名'),
                subtitle: const Text('在同一目录下改名'),
                onTap: () {
                  Navigator.pop(ctx);
                  rename(e);
                },
              ),
              // 只在文件上出现：下载 / 分享 / 编辑 / 直链
              if (!e.isDir) ...[
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('下载到手机'),
                  subtitle: Text('${formatBytes(e.size)} · 存到下载目录'),
                  onTap: () {
                    Navigator.pop(ctx);
                    downloadOne(e);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('先下载再分享'),
                  onTap: () {
                    Navigator.pop(ctx);
                    downloadOne(e, share: true);
                  },
                ),
                if (FileTypes.isReadableText(e.name))
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('编辑文本'),
                    subtitle: const Text('直接改完保存到服务器'),
                    onTap: () {
                      Navigator.pop(ctx);
                      editText(e);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('复制文件的直链'),
                  subtitle: const Text('可以在浏览器里打开（需要能连通你的服务器）'),
                  onTap: () {
                    Navigator.pop(ctx);
                    copyLink(e);
                  },
                ),
              ],
              const Divider(),
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text('删除', style: TextStyle(color: scheme.error)),
                subtitle: Text(e.isDir ? '文件夹及其内容会一起被删掉' : '无法恢复，请确认'),
                onTap: () {
                  Navigator.pop(ctx);
                  remove(e);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「新建文件夹」
  Future<void> createFolder() async {
    final client = _client;
    if (client == null) return;
    final name = await askName(
      context: context,
      title: '新建文件夹',
      hint: '文件夹名',
      initial: '新文件夹',
    );
    if (name == null) return;
    final clean = _cleanName(name);
    if (clean.isEmpty) return;
    try {
      await client.ensureDir(_join(clean));
      _toast('已建「$clean」');
    } catch (e) {
      _toast('建文件夹失败：$e');
    }
    await onChanged();
  }

  /// 「上传文件」——先让用户挑来源，再传。
  ///
  /// v1.9.0+31 起多了「选任意文件」这一条（系统文件选择器 SAF），
  /// 之前只有相册和拍照，PDF / 压缩包 / 安装包根本传不上去。
  Future<void> upload() async {
    final client = _client;
    if (client == null) return;

    final source = await _askUploadSource();
    if (source == null) return;

    if (source == 'any') {
      await uploadAnyFiles();
      return;
    }

    final picker = ImagePicker();
    XFile? picked;
    try {
      if (source == 'image') {
        picked = await picker.pickImage(source: ImageSource.gallery);
      } else if (source == 'video') {
        picked = await picker.pickVideo(source: ImageSource.gallery);
      } else {
        picked = await picker.pickImage(source: ImageSource.camera);
      }
    } catch (e) {
      _toast('选择失败：$e');
      return;
    }
    if (picked == null) return;
    final path = picked.path;
    if (path.isEmpty) {
      _toast('文件路径不可用');
      return;
    }
    final name = picked.name.isNotEmpty ? picked.name : p.basename(path);
    await _uploadFiles(client, [_LocalPick(name: name, path: path)]);
  }

  /// 系统文件选择器（任意类型、可多选）。
  Future<void> uploadAnyFiles() async {
    final client = _client;
    if (client == null) return;

    List<dynamic>? raw;
    try {
      raw = await _filesChannel.invokeMethod<List<dynamic>>('pickFiles');
    } on PlatformException catch (e) {
      _toast('打不开文件选择器：${e.message ?? e.code}');
      return;
    } catch (e) {
      _toast('选文件失败：$e');
      return;
    }
    if (raw == null || raw.isEmpty) return; // 用户取消

    final picks = <_LocalPick>[];
    for (final it in raw) {
      if (it is! Map) continue;
      final path = it['path']?.toString() ?? '';
      if (path.isEmpty) continue;
      final pickedName = it['name']?.toString() ?? '';
      picks.add(_LocalPick(
        name: pickedName.isNotEmpty ? pickedName : p.basename(path),
        path: path,
      ));
    }
    if (picks.isEmpty) {
      _toast('没能读到所选文件');
      return;
    }
    await _uploadFiles(client, picks, dropPickCache: true);
  }

  /// 重命名（保持在同一个目录里）
  Future<void> rename(DavEntry e) async {
    final client = _client;
    if (client == null) return;
    // 注意：列表上显示的名字可能被剥掉了「1.」这类排序前缀，
    // 这里一定要用真实文件名当初始值，否则用户改个字就把前缀弄丢了。
    final stem = baseName(e.path);
    final newName = await askName(
      context: context,
      title: '重命名',
      hint: '新名字',
      initial: stem,
    );
    if (newName == null) return;
    final clean = _cleanName(newName);
    if (clean.isEmpty || clean == stem) return;
    try {
      await client.move(e.path, joinPath(parentOf(e.path), clean));
      _toast('已改名：$clean');
    } catch (err) {
      _toast('改名失败：$err');
    }
    await onChanged();
  }

  /// 编辑文本文件（.md / .txt / .json / .csv …）
  Future<void> editText(DavEntry e) async {
    final client = _client;
    if (client == null) return;
    String content;
    try {
      content = await client.readText(e.path);
    } catch (err) {
      _toast('读不回来：$err');
      return;
    }
    if (!context.mounted) return;
    final newContent = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => ServerTextEditorPage(title: e.name, initial: content),
    ));
    if (newContent == null || newContent == content) return;
    try {
      await client.writeText(e.path, newContent);
      _toast('已保存：${e.name}');
    } catch (err) {
      _toast('保存失败：$err');
    }
    await onChanged();
  }

  /// 删除（文件夹走递归删：WebDAV 服务端一般不会替你级联）
  Future<void> remove(DavEntry e) async {
    final client = _client;
    if (client == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除${e.isDir ? '文件夹' : '文件'}？'),
        content: Text(
          e.isDir
              ? '「${e.name}」及其内部所有内容会从服务器上删除，无法恢复。'
              : '「${e.name}」会从服务器上删除，无法恢复。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (e.isDir) {
        await _deleteRecursive(client, e.path);
      } else {
        await client.delete(e.path);
      }
      _toast('已删：${e.name}');
    } catch (err) {
      _toast('删除失败：$err');
    }
    await onChanged();
  }

  /// 下载单个文件（可选：下完直接调系统分享）
  Future<void> downloadOne(DavEntry e, {bool share = false}) async {
    final client = _client;
    if (client == null) return;
    final f = await Downloader.withUi(
      context,
      client.urlFor(e.path),
      baseName(e.path),
      headers: client.headers,
      title: e.name,
    );
    if (f == null) return;
    onDownloaded?.call(e);
    if (!share) return;
    if (!context.mounted) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
    } catch (err) {
      _toast('分享失败：$err');
    }
  }

  /// 复制直链到剪贴板
  void copyLink(DavEntry e) {
    final client = _client;
    if (client == null) return;
    Clipboard.setData(ClipboardData(text: client.urlFor(e.path)));
    _toast('链接已复制');
  }

  /// 批量下载当前目录下的所有文件
  Future<void> downloadAll(List<DavEntry> files) async {
    if (files.isEmpty) return;
    final client = _client;
    if (client == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载这个目录里的 ${files.length} 个文件？'),
        content: Text('总大小约 ${formatBytes(files.fold<int>(0, (a, b) => a + b.size))}，'
            '会依次下载到手机的下载目录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;

    final note = ValueNotifier<String>('准备中…');
    _openProgress(note);
    var done = 0;
    final total = files.length;
    try {
      for (var i = 0; i < total; i++) {
        final e = files[i];
        note.value = '正在下载 ${i + 1}/$total：${e.name}';
        try {
          final dir = await downloadTargetDir();
          if (dir == null) break;
          final target = File(p.join(dir.path, Downloader.safeName(baseName(e.path))));
          await client.download(e.path, target.path);
          done++;
          onDownloaded?.call(e);
        } catch (_) {
          // 单个失败跳过，继续下一个
        }
      }
    } finally {
      _closeProgress();
    }
    _toast('下载完成：$done / $total 个文件');
  }

  // ------------------------------------------------------------ 内部

  /// 上传一批本地文件到当前目录。
  ///
  /// [dropPickCache] = true 时，上传完把源文件删掉 —— 那是系统文件选择器
  /// 复制到 App 缓存的副本，不删就白占空间（用户手机上可删不掉它）。
  Future<void> _uploadFiles(
    WebDavClient client,
    List<_LocalPick> picks, {
    bool dropPickCache = false,
  }) async {
    if (picks.isEmpty) return;
    final note = ValueNotifier<String>('');
    final total = picks.length;
    note.value = total == 1 ? '正在上传 ${picks.first.name}…' : '正在上传 1/$total：${picks.first.name}';
    _openProgress(note);

    var ok = 0;
    final fails = <String>[];
    try {
      for (var i = 0; i < total; i++) {
        final f = picks[i];
        if (total > 1) {
          note.value = '正在上传 ${i + 1}/$total：${f.name}';
        }
        try {
          await client.writeFileStream(joinPath(dirPath, f.name), File(f.path));
          ok++;
        } catch (e) {
          fails.add('${f.name}：$e');
        }
      }
    } finally {
      _closeProgress();
    }

    if (dropPickCache) {
      // 删掉整个「这次选择」的临时目录（原生那边一个批次一个子目录）
      for (final f in picks) {
        try {
          final dir = File(f.path).parent;
          if (dir.path.contains('${Platform.pathSeparator}uploads${Platform.pathSeparator}')) {
            await dir.delete(recursive: true);
          }
        } catch (_) {
          // 删不掉就算了，缓存目录系统迟早会收
        }
      }
    }

    if (ok == total) {
      _toast(total == 1 ? '已上传：${picks.first.name}' : '已上传 $ok 个文件');
    } else if (ok == 0) {
      _toast('上传失败：${fails.isEmpty ? '未知原因' : fails.first}');
    } else {
      _toast('上传完成 $ok/$total，失败的：${fails.first}');
    }
    await onChanged();
  }

  /// 上传来源选择：任意文件 / 相册图片 / 相册视频 / 拍照
  Future<String?> _askUploadSource() {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 置顶：「任意文件」才是用户要的那条 —— PDF、压缩包、
            // 安装包、Office 文档都能传
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('选任意文件'),
              subtitle: const Text('PDF、压缩包、安装包、文档…可以从文件管理器里挑，支持多选'),
              onTap: () => Navigator.pop(ctx, 'any'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选图片'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('从相册选视频'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张照片'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteRecursive(WebDavClient client, String path) async {
    final entries = await client.list(path, depth: 1);
    for (final e in entries) {
      if (e.isDir) {
        await _deleteRecursive(client, e.path);
      } else {
        await client.delete(e.path);
      }
    }
    await client.delete(path);
  }

  /// 弹一个不可取消的进度框。
  ///
  /// 进度文字用 ValueNotifier 驱动，而不是 StatefulBuilder —— 万一对话框
  /// 已经被系统收掉（用户按了返回键），StatefulBuilder 的 setState 会直接抛
  /// 「setState called after dispose」；ValueListenableBuilder 在卸载后
  /// 不再 rebuild，改值只是没人听而已。
  void _openProgress(ValueNotifier<String> note) {
    if (!context.mounted) return;
    _progressOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: note,
                builder: (_, v, __) => Text(v, style: const TextStyle(fontSize: 13.5, height: 1.5)),
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      _progressOpen = false;
    });
  }

  void _closeProgress() {
    if (!_progressOpen) return;
    _progressOpen = false;
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
  }

  void _toast(String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _cleanName(String raw) =>
      raw.replaceAll('/', '_').replaceAll('\\', '_').trim();
}

/// 本地待上传文件
class _LocalPick {
  const _LocalPick({required this.name, required this.path});
  final String name;
  final String path;
}

/// 让用户输入一个名字（新建文件夹 / 重命名都用它）
Future<String?> askName({
  required BuildContext context,
  required String title,
  required String hint,
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('确定')),
      ],
    ),
  );
}

/// 简易文本编辑器（服务器上的 .md / .txt / .json / .csv 直接改）
class ServerTextEditorPage extends StatefulWidget {
  final String title;
  final String initial;
  const ServerTextEditorPage({super.key, required this.title, required this.initial});

  @override
  State<ServerTextEditorPage> createState() => _ServerTextEditorPageState();
}

class _ServerTextEditorPageState extends State<ServerTextEditorPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed = _ctrl.text != widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: changed ? () => Navigator.of(context).pop(_ctrl.text) : null,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _ctrl,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5),
          decoration: const InputDecoration(border: InputBorder.none, hintText: '（空文件）'),
          onChanged: (_) => setState(() {}), // 让保存按钮 enable / disable
        ),
      ),
    );
  }
}
