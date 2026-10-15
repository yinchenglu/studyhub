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

  /// v1.8.0：翻页阅读模式（一页一页翻，而不是连续滚动）
  bool _pageMode = false;
  int _currentPage = 1; // 1-based，和 SfPdfViewer.jumpToPage 一致
  int _totalPages = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_ready && !_pageMode)
            IconButton(
              tooltip: '回到第 1 页',
              onPressed: () => _controller.jumpToPage(1),
              icon: const Icon(Icons.vertical_align_top),
            ),
          if (_ready)
            IconButton(
              tooltip: _pageMode ? '切换到滚动模式' : '切换到翻页模式',
              onPressed: () => setState(() {
                _pageMode = !_pageMode;
                if (_pageMode) _syncPageNumber();
              }),
              icon: Icon(_pageMode ? Icons.view_stream_outlined : Icons.menu_book_outlined),
            ),
          if (!_pageMode) ...[
            IconButton(
              tooltip: '适应宽度',
              onPressed: () => _controller.zoomLevel = 1,
              icon: const Icon(Icons.fit_screen_outlined),
            ),
          ],
        ],
      ),
      body: _error != null ? _errorView() : _viewer(),
    );
  }

  Widget _viewer() {
    // 翻页模式：SfPdfViewer 仍然在底层渲染，但外层用 Column 包住，
    // 底部加一个固定的翻页工具栏；并捕获 SfPdfViewer 的 scrollView
    // 监听翻页（通过 pageNumber 变化）。
    final viewer = _buildViewer();
    if (!_pageMode) return viewer;

    // 翻页模式下的布局
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              // 底部指示器提示
              if (_ready) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '第 $_currentPage / $_totalPages 页',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        _pageNavBar(),
      ],
    );
  }

  Widget _buildViewer() {
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

  /// 翻页模式下的底部工具栏
  Widget _pageNavBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: '第一页',
              onPressed: _currentPage > 1 ? () => _goPage(-_currentPage + 1) : null,
              icon: const Icon(Icons.first_page),
            ),
            IconButton(
              tooltip: '上一页',
              onPressed: _currentPage > 1 ? () => _goPage(-1) : null,
              icon: const Icon(Icons.chevron_left, size: 28),
            ),
            const Spacer(),
            Text('第 $_currentPage / $_totalPages 页', style: const TextStyle(fontSize: 14)),
            const Spacer(),
            IconButton(
              tooltip: '下一页',
              onPressed: _currentPage < _totalPages ? () => _goPage(1) : null,
              icon: const Icon(Icons.chevron_right, size: 28),
            ),
            IconButton(
              tooltip: '最后一页',
              onPressed: _currentPage < _totalPages
                  ? () => _goPage(_totalPages - _currentPage)
                  : null,
              icon: const Icon(Icons.last_page),
            ),
          ],
        ),
      ),
    );
  }

  void _setReady() {
    if (!mounted) return;
    // 获取总页数（SfPdfViewer 加载完成后才能读到）
    _totalPages = _controller.pageCount;
    setState(() {
      _ready = true;
      if (_pageMode) _syncPageNumber();
    });
  }

  /// 同步当前页码（翻页模式下使用）
  void _syncPageNumber() {
    try {
      setState(() => _currentPage = _controller.pageNumber);
    } catch (_) {}
  }

  /// 翻页：上一页 / 下一页
  void _goPage(int delta) {
    final target = _currentPage + delta;
    if (target < 1 || target > _totalPages) return;
    _controller.jumpToPage(target);
    setState(() => _currentPage = target);
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
