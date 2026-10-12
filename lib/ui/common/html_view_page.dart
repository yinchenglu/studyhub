import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 在 App 内用 WebView 打开 html。
///
/// 支持两种加载方式，用哪种取决于内容从哪来：
///
/// **1. html 内容模式（笔记里的 .html 走这条）**
///    先把文件内容从 WebDAV 读下来，再交给 WebView 渲染，
///    同时用 [baseUrl] 告诉它相对路径该去哪儿解析。
///
///    为什么不用 loadRequest 直接指服务器地址（v1.3.0 的做法）：
///    那样整页的成败完全押在「这一次 HTTP 请求能不能成」上，
///    服务器一要鉴权、或者只是慢半拍，就直接 `onWebResourceError`，
///    用户看到的是「页面加载失败」—— 而他明明能从别的地方打开这个文件。
///    改成先取内容再渲染，**主文档一定能显示**。
///
///    代价：页面里 `<img>` / `<link>` 这些子资源仍然由 WebView 自己去拿，
///    拿不到我们加的自定义 header（Android 只给主文档加），
///    所以服务器需要允许免鉴权访问那些静态文件 —— 拿不到也只是图裂，
///    正文照样能看，这比整页白屏好得多。
///
/// **2. url 模式（服务器 tools 目录里的 html 小工具走这条）**
///    直接 loadRequest，header 能带上，适合整站式的小工具。
///
/// 另外一个老 bug 也在这里修掉了：以前只要 `onWebResourceError` 一回调
/// 就把整页换成错误页，而**子资源失败是极其常见的**（外链字体、CDN 图片、
/// 没有的 favicon），结果好好的页面被顶掉。
/// 现在靠 `isForMainFrame` 判断，只有主文档失败才算真失败。
class HtmlViewPage extends StatefulWidget {
  final String title;

  /// 页面内容（与 [url] 二选一）
  final String? html;

  /// 页面地址（与 [html] 二选一）
  final String? url;

  /// html 模式下，相对路径的基准地址。
  /// 一般传「该文件所在目录」的服务器 URL，并且以 `/` 结尾。
  final String? baseUrl;

  /// url 模式下随主文档一起发的请求头（一般是 WebDAV 的 Authorization）
  final Map<String, String> headers;

  /// 出错时给的额外提示（不同场景提示不同）
  final String? errorHint;

  const HtmlViewPage({
    super.key,
    required this.title,
    this.html,
    this.url,
    this.baseUrl,
    this.headers = const {},
    this.errorHint,
  }) : assert(html != null || url != null, 'html 和 url 至少要给一个');

  @override
  State<HtmlViewPage> createState() => _HtmlViewPageState();
}

class _HtmlViewPageState extends State<HtmlViewPage> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _loading = true;
  String? _error;
  bool _canBack = false;

  /// 主文档是否已经渲染完成（用来给刷新按钮和返回键定状态）
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

          // 只认「主文档加载失败」。
          //   * isForMainFrame == false → 明确是子资源（图片 / 字体 / CSS），忽略
          //   * isForMainFrame == null  → 平台没给这个信息（iOS），
          //     再用 url 兜一次底：不是主文档地址就当子资源忽略
          // 这两条一起，才算把「子资源失败把整页顶掉」彻底堵住。
          if (e.isForMainFrame == false) return;
          if (e.isForMainFrame == null && e.url != null && widget.url != null && e.url != widget.url) {
            return;
          }
          // 页面已经渲染出来了就别再翻脸
          if (_finished) return;

          setState(() {
            _loading = false;
            _error = _error ?? e.description;
          });
        },
      ));
    _load();
  }

  void _load() {
    final html = widget.html;
    if (html != null) {
      // 内容在我们手里，主文档必然能渲染。
      // baseUrl 传 null 也能显示，只是相对路径会以 about:blank 为基准而全部失效，
      // 所以调用方最好把目录地址传进来。
      _controller.loadHtmlString(html, baseUrl: widget.baseUrl);
    } else {
      _controller.loadRequest(Uri.parse(widget.url!), headers: widget.headers);
    }
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
            onPressed: () {
              // html 模式的「刷新」是把内容重新塞一遍；
              // url 模式才是真的重新请求服务器。
              if (widget.html != null) {
                setState(() {
                  _error = null;
                  _loading = true;
                  _finished = false;
                });
                _load();
              } else {
                _controller.reload();
              }
            },
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
                    const Text('页面加载失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, height: 1.6)),
                    if (widget.errorHint != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        widget.errorHint!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, height: 1.7, color: scheme.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _loading = true;
                          _finished = false;
                        });
                        _load();
                      },
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
