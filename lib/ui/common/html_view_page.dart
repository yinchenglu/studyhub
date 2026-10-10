import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 在 App 内用 WebView 打开一个 http(s) 页面。
///
/// 两个地方在用：
///   * 笔记里的 .html 文件预览
///   * 服务器 tools 目录下的 html 小工具
///
/// 为什么是 loadRequest(服务器 URL) 而不是 loadHtmlString(本地字符串)：
/// html 里常见的相对路径（`<img src="a.png">`、`<link href="x.css">`）
/// 在「按 URL 加载」时会自动相对于服务器去解析，图片和样式能正常显示；
/// 换成塞字符串就全断了。代价是子资源请求不一定带得上鉴权头
/// （Android 的 WebView 只给主文档加自定义 header），
/// 所以服务器若是无鉴权的 http 站点最省事。
class HtmlViewPage extends StatefulWidget {
  final String title;
  final String url;
  final Map<String, String> headers;

  /// 出错时给的额外提示（不同场景提示不同）
  final String? errorHint;

  const HtmlViewPage({
    super.key,
    required this.title,
    required this.url,
    this.headers = const {},
    this.errorHint,
  });

  @override
  State<HtmlViewPage> createState() => _HtmlViewPageState();
}

class _HtmlViewPageState extends State<HtmlViewPage> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _loading = true;
  String? _error;
  bool _canBack = false;

  /// 主文档是否已经渲染完成。
  /// 页面里常引用外链图片 / 字体，这些子资源加载失败时
  /// onWebResourceError 一样会回调；页面本身已经能看，不该再把整页顶掉。
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _loading = true;
              _error = null;
              _finished = false;
            });
          }
        },
        onPageFinished: (_) async {
          final back = await _controller.canGoBack();
          if (!mounted) return;
          setState(() {
            _loading = false;
            _finished = true;
            _canBack = back;
          });
        },
        onWebResourceError: (e) {
          if (!mounted) return;
          // 页面已经出来了，就不因为某个子资源（图片、字体、外链）失败而盖掉它
          if (_finished) return;
          setState(() {
            _loading = false;
            _error = e.description;
          });
        },
      ))
      ..loadRequest(Uri.parse(widget.url), headers: widget.headers);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: _canBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () async {
                  await _controller.goBack();
                  final back = await _controller.canGoBack();
                  if (mounted) setState(() => _canBack = back);
                },
              )
            : null,
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress / 100,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.language_outlined, size: 44, color: scheme.error),
                    const SizedBox(height: 14),
                    Text('页面加载失败：$_error',
                        textAlign: TextAlign.center, style: const TextStyle(height: 1.7)),
                    if (widget.errorHint != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        widget.errorHint!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, height: 1.7, color: scheme.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => _controller.reload(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : WebViewWidget(controller: _controller),
    );
  }
}
