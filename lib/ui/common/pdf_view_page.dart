import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// 通用 PDF 预览页。
///
/// 三处入口都用它：
///   * 笔记目录里点 .pdf（远程地址 + WebDAV 鉴权头）
///   * 下载站里点 .pdf（先下到本地缓存再看，省流量）
///   * 已经下载到手机上的 .pdf（本地文件）
///
/// 用 Syncfusion 的纯 Flutter 渲染器，不依赖系统 WebView / 第三方 App，
/// 断网也能看，翻页、双指缩放、文本选择都支持。
class PdfViewPage extends StatefulWidget {
  /// 远程地址（与 [file] / [bytes] 三选一）
  final String? url;

  /// 本地文件
  final File? file;

  /// 直接给字节
  final Uint8List? bytes;

  final String title;

  /// 访问远程地址时要带的请求头（WebDAV 的 Authorization）
  final Map<String, String> headers;

  const PdfViewPage.network({
    super.key,
    required String this.url,
    required this.title,
    this.headers = const {},
  })  : file = null,
        bytes = null;

  const PdfViewPage.local({
    super.key,
    required File this.file,
    required this.title,
  })  : url = null,
        bytes = null,
        headers = const {};

  const PdfViewPage.memory({
    super.key,
    required Uint8List this.bytes,
    required this.title,
  })  : url = null,
        file = null,
        headers = const {};

  @override
  State<PdfViewPage> createState() => _PdfViewPageState();
}

class _PdfViewPageState extends State<PdfViewPage> {
  final _controller = PdfViewerController();
  final _key = GlobalKey<SfPdfViewerState>();

  String? _error;
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '回到第 1 页',
            onPressed: _ready ? () => _controller.jumpToPage(1) : null,
            icon: const Icon(Icons.vertical_align_top),
          ),
          IconButton(
            tooltip: '适应宽度',
            onPressed: _ready ? () => _controller.zoomLevel = 1 : null,
            icon: const Icon(Icons.fit_screen_outlined),
          ),
        ],
      ),
      body: _error != null ? _errorView() : _viewer(),
    );
  }

  Widget _viewer() {
    // 本地文件直接读，最稳
    final f = widget.file;
    if (f != null) {
      return SfPdfViewer.file(
        f,
        key: _key,
        controller: _controller,
        canShowScrollHead: false,
        onDocumentLoaded: (_) => _setReady(),
        onDocumentLoadFailed: (d) => _onFail(d.description),
      );
    }

    final b = widget.bytes;
    if (b != null) {
      return SfPdfViewer.memory(
        b,
        key: _key,
        controller: _controller,
        canShowScrollHead: false,
        onDocumentLoaded: (_) => _setReady(),
        onDocumentLoadFailed: (d) => _onFail(d.description),
      );
    }

    return SfPdfViewer.network(
      widget.url ?? '',
      key: _key,
      headers: widget.headers.isEmpty ? null : widget.headers,
      controller: _controller,
      canShowScrollHead: false,
      onDocumentLoaded: (_) => _setReady(),
      onDocumentLoadFailed: (d) => _onFail(d.description),
    );
  }

  void _setReady() {
    if (!mounted) return;
    setState(() => _ready = true);
  }

  void _onFail(String desc) {
    if (!mounted) return;
    setState(() => _error = desc.isEmpty ? 'PDF 打不开' : desc);
  }

  Widget _errorView() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf_outlined, size: 46, color: scheme.error),
            const SizedBox(height: 14),
            const Text('这个 PDF 没能打开', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, height: 1.6),
            ),
            const SizedBox(height: 6),
            Text(
              '如果文件在服务器上，先确认服务器支持 Range 分段读取；\n也可以先「下载到本地」再看。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
