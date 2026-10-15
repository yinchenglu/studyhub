import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/epub.dart';
import '../../core/utils.dart';
import '../../data/local/settings_store.dart';
import '../../providers/providers.dart';

/// 阅读模式：小说 / 电子书的沉浸式阅读页（v1.5.0 用户第 2 条）。
///
/// 支持的输入：
///   * .epub —— 自己解包（lib/core/epub.dart，零新依赖）
///   * .txt / .md —— 按「第X章 / Chapter N」切章，md 会先抹掉标记符号
///   * 其它纯文本 —— 整篇当一章（也能用，就是没目录）
///
/// 能调的东西：字号、行距、背景（纸白/米黄/护眼绿/夜间/灰）、
/// 字体（系统/宋体/黑体/等宽）、左右翻页还是上下滚动、自动翻页间隔。
///
/// 「读到哪了」按笔记路径存进 SharedPreferences（章|页|滚动位置），
/// 下次打开自动回到原位。
///
/// v1.7.0 大修（用户第 1 条的后半段）。原来这个页面**只认自己打开的那一个文件**：
/// 「上一篇 / 下一篇」是**章**级别，可一篇普通笔记往往只有一章 ——
/// 于是那两个按钮永远是灰的，目录里也只有孤零零一条，用户的原话是
/// 「没有匹配功能…不能切换到上一篇和下一篇，使用不了」。
/// 现在把「同目录的其它笔记」也接进来：
///   * 底栏首尾两个 skip 键改成**跨文件**的「上一篇 / 下一篇笔记」
///   * 目录弹窗分两段：上面「本目录的笔记」（跨文件）、下面「本篇章节」
///   * chevron 左右键仍然管文件内的翻页，职责分清
class ReadingPage extends ConsumerStatefulWidget {
  final String path;

  /// 同目录里所有能读的笔记（按列表页的排序）——「上一篇 / 下一篇笔记」用它
  final List<String> siblings;

  const ReadingPage({super.key, required this.path, this.siblings = const []});

  @override
  ConsumerState<ReadingPage> createState() => _ReadingPageState();
}

class _ReadTheme {
  final String name;
  final Color bg;
  final Color fg;
  final Color dim;

  const _ReadTheme(this.name, this.bg, this.fg, this.dim);
}

const List<_ReadTheme> _themes = [
  _ReadTheme('纸白', Color(0xFFFFFFFF), Color(0xFF1F2328), Color(0xFF9AA1AA)),
  _ReadTheme('米黄', Color(0xFFF6EFE0), Color(0xFF3B3226), Color(0xFFA08F76)),
  _ReadTheme('护眼绿', Color(0xFFCDE8D0), Color(0xFF1F3020), Color(0xFF687C6A)),
  _ReadTheme('夜间', Color(0xFF121212), Color(0xFFC4C4C4), Color(0xFF6E6E6E)),
  _ReadTheme('灰', Color(0xFFE4E6E9), Color(0xFF23262B), Color(0xFF8B9098)),
];

/// 字体：只能挑 Android 系统自带的几个通用名，加自装字体要动 pubspec 的 fonts 段
const List<String> _fontLabels = ['系统默认', '宋体', '黑体', '等宽'];
const List<String?> _fontFamilies = [null, 'serif', 'sans-serif', 'monospace'];

/// 单页最多排多少字才做分页。超了就直接切成「上下滚动」——
/// 分页靠 TextPainter 逐屏量，整章几百万字的 txt 会量到天荒地老。
const int _maxCharsToPaginate = 60000;

class _ReadingPageState extends ConsumerState<ReadingPage> {
  /// 当前正在读哪一篇。可以在本页里原地切到同目录的上一篇 / 下一篇。
  late String _path = widget.path;

  Book? _book;
  bool _loading = true;
  String? _error;

  int _chapter = 0;
  int _page = 0;
  List<String> _pages = const [];

  /// 分页结果对应的「章 + 视口 + 外观」指纹，变了就重排
  String _pageKey = '';

  /// 这一章是否真的按页排（超长章节会降级成滚动）
  bool _pagedNow = false;

  /// 切到上一章时要停在最后一页，但那时还没分页，先用旗标记着
  bool _wantLastPage = false;

  PageController _pCtrl = PageController(keepPage: false);
  final ScrollController _sCtrl = ScrollController();

  bool _chrome = true;
  bool _auto = false;
  Timer? _timer;

  String _pendingPos = '';
  bool _posApplied = false;
  String _lastSaved = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pCtrl.dispose();
    _sCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 载入

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ext = FileTypes.ext(_path);
      final name = titleFromFileName(_path);
      Book book;
      if (ext == 'epub') {
        final dav = ref.read(davClientProvider);
        if (dav == null) throw StateError('未登录');
        final bytes = await dav.readBytes(_path);
        book = EpubParser.parse(bytes, fallbackTitle: name);
      } else {
        final repo = ref.read(noteRepoProvider);
        if (repo == null) throw StateError('未登录');
        var text = await repo.readNote(_path);
        if (ext == 'md') text = markdownToPlain(text);
        book = Book(title: name, author: '', chapters: splitChapters(text, name));
      }
      final raw = await SettingsStore.instance.readPos(_path);
      if (!mounted) return;
      setState(() {
        _book = book;
        _chapter = 0;
        _page = 0;
        _pages = const [];
        _pageKey = '';
        _posApplied = false;
        _pendingPos = raw ?? '';
        _lastSaved = '';
        _wantLastPage = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendly(e);
        _loading = false;
      });
    }
  }

  // ------------------------------------------------- 同目录的上一篇 / 下一篇

  bool get _hasSibs => widget.siblings.length > 1;

  int get _sibIndex => widget.siblings.indexOf(_path);

  /// 切到同目录的另一篇。
  ///
  /// 切之前先把当前这篇的进度写盘 —— 不写的话，用户看一眼再回来
  /// 会发现自己「读到哪儿」丢了。
  Future<void> _openSibling(String path) async {
    if (path == _path) return;
    _savePos();
    _timer?.cancel();
    _timer = null;
    setState(() {
      _path = path;
      _auto = false;
      _book = null;
      _loading = true;
      _error = null;
      _pages = const [];
      _pageKey = '';
      _chapter = 0;
      _page = 0;
      _posApplied = false;
      _pendingPos = '';
      _lastSaved = '';
    });
    await _load();
    // 换了一篇之后滚动位置要回顶（_load 里只重置了页码）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_sCtrl.hasClients) _sCtrl.jumpTo(0);
    });
  }

  /// dir = -1 上一篇，+1 下一篇
  void _siblingStep(int dir) {
    final i = _sibIndex;
    if (i < 0) return;
    final j = i + dir;
    if (j < 0) {
      _snack('已经是第一篇笔记了');
      return;
    }
    if (j >= widget.siblings.length) {
      _snack('已经是最后一篇笔记了');
      return;
    }
    _openSibling(widget.siblings[j]);
  }

  String _friendly(Object e) {
    var s = e.toString();
    if (s.startsWith('Exception: ')) s = s.substring(11);
    if (s.startsWith('Bad state: ')) s = s.substring(11);
    return s;
  }

  // ---------------------------------------------------------------- 分页

  _ReadTheme get _theme => _themeOf(ref.read(readPrefsProvider).themeIndex);

  _ReadTheme _themeOf(int i) {
    if (i <= 0) return _themes[0];
    if (i >= _themes.length) return _themes[_themes.length - 1];
    return _themes[i];
  }

  TextStyle _bodyStyle(ReadPrefs p, Color fg) {
    final fi = (p.fontIndex < 0 || p.fontIndex >= _fontFamilies.length) ? 0 : p.fontIndex;
    return TextStyle(
      fontSize: p.fontSize,
      height: p.lineHeight,
      color: fg,
      fontFamily: _fontFamilies[fi],
      letterSpacing: 0.2,
    );
  }

  /// 每帧都会走这里；只有指纹变了才真去重排。
  /// 之所以敢在 build 里改字段：这里不触发重建，只是「顺手把缓存刷新了」。
  void _ensurePages(double w, double h, ReadPrefs p) {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    if (_chapter < 0) _chapter = 0;
    if (_chapter >= book.chapters.length) _chapter = book.chapters.length - 1;
    if (w <= 8 || h <= 8) return;

    final text = book.chapters[_chapter].text;
    final canPage = p.paged && text.length <= _maxCharsToPaginate;
    final key = '$_chapter|${w.round()}|${h.round()}|${p.fontSize.toStringAsFixed(1)}'
        '|${p.lineHeight.toStringAsFixed(2)}|${p.fontIndex}|$canPage';
    if (key == _pageKey) return;
    _pageKey = key;
    _pagedNow = canPage;

    final style = _bodyStyle(p, _theme.fg);
    if (!canPage) {
      _pages = [text];
      _page = 0;
      return;
    }
    var pages = _paginate(text, style, w, h);
    if (pages.isEmpty) pages = ['（这一章没有正文）'];
    _pages = pages;
    if (_wantLastPage) {
      _wantLastPage = false;
      _page = pages.length - 1;
    }
    if (_page < 0) _page = 0;
    if (_page >= pages.length) _page = pages.length - 1;
    _resetPagedController();
  }

  /// 把一章正文按「一屏」切开。
  ///
  /// 关键点是**只在窗口内排版**：如果拿整章去 TextPainter.layout，
  /// 每切一页都要排一遍剩下的全部文字，复杂度 O(n²)，几十万字的章节直接卡死。
  /// 这里先按一屏字数估个窗口，不够再翻倍。
  List<String> _paginate(String text, TextStyle style, double w, double h) {
    final out = <String>[];
    final total = text.length;
    final fs = style.fontSize ?? 17;
    final lh = fs * (style.height ?? 1.6);
    var win = ((h / lh) * (w / fs)).ceil();
    if (win < 200) win = 200;
    var start = 0;
    while (start < total) {
      var end = start + win;
      if (end > total) end = total;
      TextPainter tp;
      while (true) {
        tp = TextPainter(
          text: TextSpan(text: text.substring(start, end), style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: w);
        if (tp.height > h || end >= total) break;
        win *= 2;
        end = start + win;
        if (end > total) end = total;
      }
      if (tp.height <= h) {
        out.add(text.substring(start));
        break;
      }
      var acc = 0.0;
      for (final m in tp.computeLineMetrics()) {
        if (acc + m.height > h) break;
        acc += m.height;
      }
      var cut = tp.getPositionForOffset(Offset(w, acc > 1 ? acc - 1 : 0)).offset;
      if (cut <= 0) cut = (end - start) ~/ 2;
      var abs = start + cut;
      if (abs <= start) abs = start + 1;
      if (abs > total) abs = total;
      out.add(text.substring(start, abs));
      start = abs;
    }
    return out;
  }

  /// 换一次分页就换一次 controller：PageView 的 itemCount 和 controller
  /// 必须始终一致，否则页码越界会直接断言崩掉。
  void _resetPagedController() {
    final old = _pCtrl;
    _pCtrl = PageController(initialPage: _page, keepPage: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        old.dispose();
      } catch (_) {}
    });
  }

  // ---------------------------------------------------------------- 进度

  String _posString() {
    final page = _pagedNow ? _page : 0;
    final scroll = _pagedNow ? 0.0 : _sCtrl.positions.isEmpty ? 0.0 : _sCtrl.offset;
    return '$_chapter|$page|${scroll.toStringAsFixed(0)}';
  }

  void _savePos() {
    final s = _posString();
    if (s == _lastSaved) return;
    _lastSaved = s;
    SettingsStore.instance.setReadPos(_path, s);
  }

  void _applyPosIfNeeded() {
    if (_posApplied) return;
    final book = _book;
    if (book == null || _pages.isEmpty) return;
    _posApplied = true;
    final raw = _pendingPos;
    if (raw.isEmpty) return;

    final parts = raw.split('|');
    final ch = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final pg = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    final sc = double.tryParse(parts.length > 2 ? parts[2] : '') ?? 0;
    final target = ch < 0 ? 0 : (ch >= book.chapters.length ? book.chapters.length - 1 : ch);
    if (target == 0 && pg <= 0 && sc <= 0) return;

    setState(() {
      _chapter = target;
      _page = pg < 0 ? 0 : pg;
      _pageKey = '';
      _pages = const [];
    });
    // 布局完成后再把滚动条挪过去
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pagedNow) {
        if (_pCtrl.hasClients) {
          final p = _page >= _pages.length ? _pages.length - 1 : _page;
          _pCtrl.jumpToPage(p < 0 ? 0 : p);
        }
      } else if (_sCtrl.hasClients && sc > 0) {
        _sCtrl.jumpTo(sc.clamp(0.0, _sCtrl.position.maxScrollExtent).toDouble());
      }
      _savePos();
      // v1.7.0：用户要求删掉「已回到上次读到的地方 · 第 N 章／从头看」这条提示。
      // 每次打开都弹一下确实烦 —— 位置已经自动回去了，用户自己能看出来。
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  /// 「回到文章开头」。
  ///
  /// 先退到第 1 章（`_goChapter(0)` 会把页码和滚动都归零），
  /// 已经在本篇开头时再把滚动条拉回顶部 —— 不然点一下什么都不会发生，
  /// 用户会以为按钮坏了。
  void _backToTop() {
    if (_chapter != 0 || _page != 0) {
      _goChapter(0);
    } else if (_sCtrl.hasClients) {
      _sCtrl.animateTo(0,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
    _savePos();
  }

  // ---------------------------------------------------------------- 翻页

  int get _chapterCount => _book?.chapters.length ?? 0;

  void _goChapter(int index, {bool toEnd = false}) {
    if (index < 0 || index >= _chapterCount) return;
    _wantLastPage = toEnd;
    setState(() {
      _chapter = index;
      _page = 0;
      _pageKey = '';
      _pages = const [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pagedNow && _pCtrl.hasClients) _pCtrl.jumpToPage(_page);
      if (!_pagedNow && _sCtrl.hasClients) _sCtrl.jumpTo(0);
      _savePos();
    });
  }

  void _setPage(int p) {
    if (p < 0 || p >= _pages.length) return;
    setState(() => _page = p);
    _savePos();
  }

  void _turn(int dir, {bool auto = false}) {
    final book = _book;
    if (book == null) return;
    if (_pagedNow) {
      if (dir > 0) {
        if (_page + 1 < _pages.length) {
          if (_pCtrl.hasClients) {
            _pCtrl.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          } else {
            _setPage(_page + 1);
          }
        } else if (_chapter + 1 < _chapterCount) {
          _goChapter(_chapter + 1);
        } else if (auto) {
          _setAuto(false);
          _snack('已经读到最后一页了，自动翻页已停');
        }
      } else {
        if (_page > 0) {
          if (_pCtrl.hasClients) {
            _pCtrl.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          } else {
            _setPage(_page - 1);
          }
        } else if (_chapter > 0) {
          _goChapter(_chapter - 1, toEnd: true);
        }
      }
      return;
    }

    // 上下滚动模式：按屏滚
    if (!_sCtrl.hasClients) return;
    final pos = _sCtrl.position;
    final step = pos.viewportDimension * 0.9;
    if (dir > 0 && pos.pixels >= pos.maxScrollExtent - 2) {
      if (_chapter + 1 < _chapterCount) {
        _goChapter(_chapter + 1);
      } else if (auto) {
        _setAuto(false);
        _snack('已经读到最后一页了，自动翻页已停');
      }
      return;
    }
    final target = (pos.pixels + dir * step).clamp(0.0, pos.maxScrollExtent).toDouble();
    _sCtrl.animateTo(target,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    if (auto) _savePos();
  }

  void _setAuto(bool on) {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    setState(() => _auto = on);
    if (!on) return;
    final sec = ref.read(readPrefsProvider).autoSec;
    if (sec <= 0) {
      _snack('先在阅读设置里选一个自动翻页间隔（现在是「关闭」）');
      setState(() => _auto = false);
      return;
    }
    _timer = Timer.periodic(Duration(seconds: sec), (_) => _turn(1, auto: true));
  }

  Future<void> _close() async {
    _savePos();
    if (mounted) Navigator.of(context).maybePop();
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(readPrefsProvider);
    final t = _themeOf(prefs.themeIndex);
    final book = _book;
    final title = book == null || book.title.isEmpty ? titleFromFileName(_path) : book.title;

    if (_loading) {
      return Scaffold(backgroundColor: t.bg, body: const Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(height: 1.7)),
          ),
        ),
      );
    }
    if (book == null || book.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
        body: const Center(child: Text('这本书里没有正文')),
      );
    }

    // 自动翻页开着但秒数被改成 0 了 → 停掉
    if (_auto && prefs.autoSec <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _auto) _setAuto(false);
      });
    }

    return Scaffold(
      backgroundColor: t.bg,
      appBar: _chrome
          ? AppBar(
              backgroundColor: t.bg,
              foregroundColor: t.fg,
              elevation: 0,
              title: Text(
                '${_chapter + 1}/${_chapterCount} ${book.chapters[_chapter].title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              actions: [
                IconButton(
                  tooltip: '目录',
                  icon: const Icon(Icons.list_alt),
                  onPressed: _showToc,
                ),
                IconButton(
                  tooltip: '阅读设置',
                  icon: const Icon(Icons.text_fields),
                  onPressed: _showSettings,
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: _close,
                ),
              ],
            )
          : null,
      bottomNavigationBar: _chrome ? _bottomBar(t, prefs) : null,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          const pad = 18.0;
          const footerH = 24.0;
          final w = box.maxWidth - pad * 2;
          final h = box.maxHeight - 12 - footerH;
          _ensurePages(w, h, prefs);
          WidgetsBinding.instance.addPostFrameCallback((_) => _applyPosIfNeeded());
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTapZone(d.localPosition.dx, box.maxWidth),
            child: Column(
              children: [
                Expanded(
                  child: _pagedNow ? _pagedView(t, prefs, w, h, pad) : _scrollView(t, prefs, pad),
                ),
                _footer(t),
              ],
            ),
          );
        }),
      ),
    );
  }

  void _onTapZone(double x, double width) {
    if (x < width * 0.32) {
      _turn(-1);
    } else if (x > width * 0.68) {
      _turn(1);
    } else {
      setState(() => _chrome = !_chrome);
    }
  }

  Widget _pagedView(_ReadTheme t, ReadPrefs p, double w, double h, double pad) {
    if (_pages.isEmpty) return const SizedBox.shrink();
    return PageView.builder(
      controller: _pCtrl,
      itemCount: _pages.length,
      onPageChanged: (i) {
        if (i != _page) setState(() => _page = i);
        _savePos();
      },
      itemBuilder: (context, i) {
        final body = i < _pages.length ? _pages[i] : '';
        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 0),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              body,
              style: _bodyStyle(p, t.fg),
              // 分页时就是按这个宽度量的，这里必须一模一样
              textAlign: TextAlign.left,
            ),
          ),
        );
      },
    );
  }

  Widget _scrollView(_ReadTheme t, ReadPrefs p, double pad) {
    final text = (_chapter < _chapterCount) ? _book!.chapters[_chapter].text : '';
    return NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        _savePos();
        return false;
      },
      child: SingleChildScrollView(
        controller: _sCtrl,
        padding: EdgeInsets.fromLTRB(pad, 6, pad, 24),
        child: Text(text, style: _bodyStyle(p, t.fg)),
      ),
    );
  }

  Widget _footer(_ReadTheme t) {
    final total = _chapterCount;
    final pct = total == 0
        ? 0.0
        : (_chapter + (_pages.isEmpty ? 0 : (_page + 1) / _pages.length)) * 100 / total;
    return SizedBox(
      height: 24,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Text(
              _pagedNow ? '第 ${_page + 1} / ${_pages.length} 页' : '上下滚动',
              style: TextStyle(fontSize: 11.5, color: t.dim),
            ),
            const Spacer(),
            Text(
              '全书 ${pct.toStringAsFixed(1)}%　${_chapter + 1}/${total} 章',
              style: TextStyle(fontSize: 11.5, color: t.dim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(_ReadTheme t, ReadPrefs p) {
    final si = _sibIndex;
    final hasPrev = si > 0;
    final hasNext = si >= 0 && si + 1 < widget.siblings.length;
    return Material(
      color: t.bg,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              // v1.7.0：首尾两个 skip 键改成**跨文件**的「上一篇 / 下一篇笔记」。
              // 原来它们是「上一章 / 下一章」，可一篇普通笔记往往只有一章，
              // 于是永远是灰的、点不动 —— 用户反馈的「使用不了」就是这个。
              _barBtn(
                Icons.skip_previous,
                hasPrev ? '上一篇笔记' : '已经是第一篇了',
                hasPrev ? () => _siblingStep(-1) : null,
              ),
              _barBtn(Icons.chevron_left, '上一页', () => _turn(-1)),
              // ★ v1.8.0 按用户明确要求再翻回来：图标表示**当前是哪种模式**。
              //   上下滚动 → 上下箭头（swap_vert）
              //   左右翻页 → 书本（menu_book）
              //
              // v1.7.0 那版是按「点一下会切成什么」做的（翻页时显示 swap_vert），
              // 用户这次直接说「搞反了」—— 所以以**当前模式**为准。
              // tooltip 里两种信息都写上，既不歧义也不用猜。
              _barBtn(
                p.paged ? Icons.menu_book : Icons.swap_vert,
                p.paged
                    ? '当前是左右翻页，点一下切成上下滚动'
                    : '当前是上下滚动，点一下切成左右翻页',
                () => ref.read(readPrefsProvider.notifier).setPaged(!p.paged),
              ),
              _barBtn(
                _auto ? Icons.pause_circle_filled : Icons.play_circle_fill,
                _auto ? '停止自动翻页' : '自动翻页${p.autoSec > 0 ? '（${p.autoSec} 秒）' : ''}',
                () => _setAuto(!_auto),
              ),
              // v1.7.0：新增「回到文章开头」，位置按用户要求紧跟在自动翻页按钮之后
              _barBtn(Icons.vertical_align_top, '回到文章开头', _backToTop),
              _barBtn(Icons.chevron_right, '下一页', () => _turn(1)),
              _barBtn(
                Icons.skip_next,
                hasNext ? '下一篇笔记' : '已经是最后一篇了',
                hasNext ? () => _siblingStep(1) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 自写的底栏按钮：IconButton 自带 48×48 的最小点击区，七连排会直接顶出屏幕。
  Widget _barBtn(IconData icon, String tip, VoidCallback? onTap) {
    final off = onTap == null;
    final color = _theme.fg.withValues(alpha: off ? 0.28 : 0.9);
    return Expanded(
      child: Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Icon(icon, size: 24, color: color),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 目录 / 设置

  /// 目录弹窗。v1.7.0 起分两段：
  ///   ① 本目录的笔记（**跨文件**）—— 顶栏那个「目录」按钮终于有内容可看了
  ///   ② 本篇的章节（原来的行为，保留）
  ///
  /// 返回值用字符串编码：`s:<下标>` 表示选了第几篇笔记，`c:<下标>` 表示选章节。
  /// 之所以不用 int：一个 int 表达不了两种来源。
  Future<void> _showToc() async {
    final book = _book;
    if (book == null) return;
    final t = _theme;
    final sibs = widget.siblings;
    final curSib = _sibIndex;

    final pick = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bg,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          builder: (ctx2, ctrl) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('目录',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600, color: t.fg)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('收起'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: ctrl,
                  children: [
                    if (sibs.length > 1) ...[
                      _tocSection(t, '本目录的笔记 · 共 ${sibs.length} 篇'),
                      for (var i = 0; i < sibs.length; i++)
                        _tocTile(
                          t,
                          index: '${i + 1}',
                          title: titleFromFileName(sibs[i]),
                          cur: i == curSib,
                          onTap: () => Navigator.pop(ctx, 's:$i'),
                        ),
                      const Divider(height: 20),
                    ],
                    _tocSection(
                      t,
                      sibs.length > 1
                          ? '本篇章节 · 共 ${book.chapters.length} 章'
                          : '共 ${book.chapters.length} 章',
                    ),
                    for (var i = 0; i < book.chapters.length; i++)
                      _tocTile(
                        t,
                        index: null,
                        title: book.chapters[i].title,
                        sub: '${book.chapters[i].text.length} 字',
                        cur: i == _chapter,
                        onTap: () => Navigator.pop(ctx, 'c:$i'),
                      ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (pick == null) return;
    if (pick.startsWith('s:')) {
      final i = int.tryParse(pick.substring(2));
      if (i != null && i >= 0 && i < sibs.length) await _openSibling(sibs[i]);
    } else if (pick.startsWith('c:')) {
      final i = int.tryParse(pick.substring(2));
      if (i != null && i != _chapter) _goChapter(i);
    }
  }

  Widget _tocSection(_ReadTheme t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
        child: Text(text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.dim)),
      );

  Widget _tocTile(
    _ReadTheme t, {
    required String? index,
    required String title,
    String? sub,
    required bool cur,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      selected: cur,
      selectedTileColor: t.fg.withValues(alpha: 0.08),
      leading: index == null
          ? null
          : SizedBox(
              width: 26,
              child: Text(index, style: TextStyle(fontSize: 12.5, color: t.dim)),
            ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14.5,
          color: cur ? t.fg : t.fg.withValues(alpha: 0.82),
          fontWeight: cur ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: sub == null ? null : Text(sub, style: TextStyle(fontSize: 11.5, color: t.dim)),
      trailing: cur ? Icon(Icons.push_pin, size: 16, color: t.dim) : null,
      onTap: onTap,
    );
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _theme.bg,
      builder: (ctx) => Consumer(builder: (ctx2, ref2, _) {
        final p = ref2.watch(readPrefsProvider);
        final n = ref2.read(readPrefsProvider.notifier);
        final t = _themeOf(p.themeIndex);
        final tooLong = (_book != null &&
            _chapter < _chapterCount &&
            _book!.chapters[_chapter].text.length > _maxCharsToPaginate);
        return Padding(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 16,
            bottom: 16 + MediaQuery.of(ctx2).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('阅读设置',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.fg)),
                const SizedBox(height: 14),

                // 字号
                Row(
                  children: [
                    Text('字号', style: TextStyle(fontSize: 13.5, color: t.fg)),
                    const Spacer(),
                    Text('${p.fontSize.toStringAsFixed(0)}',
                        style: TextStyle(fontSize: 13.5, color: t.dim)),
                  ],
                ),
                Slider(
                  value: p.fontSize.clamp(12, 30).toDouble(),
                  min: 12,
                  max: 30,
                  divisions: 18,
                  label: '${p.fontSize.toStringAsFixed(0)}',
                  onChanged: (v) => n.setFontSize(v),
                ),

                // 行距
                Row(
                  children: [
                    Text('行距', style: TextStyle(fontSize: 13.5, color: t.fg)),
                    const Spacer(),
                    Text(p.lineHeight.toStringAsFixed(2),
                        style: TextStyle(fontSize: 13.5, color: t.dim)),
                  ],
                ),
                Slider(
                  value: p.lineHeight.clamp(1.2, 2.6).toDouble(),
                  min: 1.2,
                  max: 2.6,
                  divisions: 14,
                  label: p.lineHeight.toStringAsFixed(2),
                  onChanged: (v) => n.setLineHeight(v),
                ),

                const SizedBox(height: 6),
                Text('背景', style: TextStyle(fontSize: 13.5, color: t.fg)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _themes.length; i++)
                      GestureDetector(
                        onTap: () => n.setThemeIndex(i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: _themes[i].bg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: p.themeIndex == i ? t.fg : t.dim.withValues(alpha: 0.5),
                              width: p.themeIndex == i ? 2 : 1,
                            ),
                          ),
                          child: Text(_themes[i].name,
                              style: TextStyle(fontSize: 12.5, color: _themes[i].fg)),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 16),
                Text('字体', style: TextStyle(fontSize: 13.5, color: t.fg)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _fontLabels.length; i++)
                      ChoiceChip(
                        label: Text(_fontLabels[i], style: const TextStyle(fontSize: 12.5)),
                        selected: p.fontIndex == i,
                        onSelected: (_) => n.setFontIndex(i),
                      ),
                  ],
                ),

                const SizedBox(height: 16),
                Text('翻页方式', style: TextStyle(fontSize: 13.5, color: t.fg)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('左右翻页', style: TextStyle(fontSize: 12.5)),
                      selected: p.paged,
                      onSelected: (_) => n.setPaged(true),
                    ),
                    ChoiceChip(
                      label: const Text('上下滚动', style: TextStyle(fontSize: 12.5)),
                      selected: !p.paged,
                      onSelected: (_) => n.setPaged(false),
                    ),
                  ],
                ),
                if (tooLong)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('这一章太长（超过 $_maxCharsToPaginate 字），已自动改用上下滚动',
                        style: TextStyle(fontSize: 11.5, color: t.dim)),
                  ),

                const SizedBox(height: 16),
                Text('自动翻页间隔', style: TextStyle(fontSize: 13.5, color: t.fg)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in Defaults.readAutoSecOptions)
                      ChoiceChip(
                        label: Text(s == 0 ? '关闭' : '$s 秒',
                            style: const TextStyle(fontSize: 12.5)),
                        selected: p.autoSec == s,
                        onSelected: (_) {
                          n.setAutoSec(s);
                          if (_auto) _setAuto(false);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('选好间隔后，点底栏中间的播放按钮开始／停止自动翻页',
                    style: TextStyle(fontSize: 11.5, color: t.dim)),
                // v1.7.0：这里原来还有「目录」和「回到开头」两个按钮，
                // 用户反馈它们贴着底部导航条、被挡着点不到；而且这两个功能
                // 顶栏（目录）和底栏（回到开头）都已经有了，属于重复。
                // 删掉之后面板内容变短，整块自然往上提了一截。
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// 把 Markdown 抹成能当小说看的纯文本（阅读模式用）。
///
/// 只做「不破坏正文」的轻处理：去标题井号、去加粗斜体星号、去行内代码反引号、
/// 去引用尖括号、链接留文字、图片整段丢掉。表格分隔线这类也一并清掉。
String markdownToPlain(String md) {
  final out = <String>[];
  for (var line in md.split('\n')) {
    final t = line.trimRight();
    if (RegExp(r'^\s*\|?[\s:\-|]+\|?\s*$').hasMatch(t) && t.contains('-')) {
      continue; // 表格的分隔行
    }
    var s = t;
    s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*'), '');
    s = s.replaceAll(RegExp(r'^\s{0,3}>\s?'), '');
    s = s.replaceAllMapped(RegExp(r'!\[[^\]]*\]\([^)]*\)'), (m) => '');
    s = s.replaceAllMapped(
        RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
    s = s.replaceAll(RegExp(r'`{1,3}'), '');
    s = s.replaceAll(RegExp(r'\*\*|__'), '');
    s = s.replaceAll(RegExp(r'(?<!\*)\*(?!\*)'), '');
    s = s.replaceAll(RegExp(r'^\s*([-*+]|\d+\.)\s+'), '');
    s = s.replaceAll(RegExp(r'^\s*(-{3,}|={3,})\s*$'), '');
    out.add(s);
  }
  return out.join('\n');
}
