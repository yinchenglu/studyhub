import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dict_view.dart';
import 'tool_pages.dart';

/// 在线翻译 / 词典
///
/// v1.4.0 新增。要求是「调用常用的网络字典、网络翻译接口，多提供一些可以切换；
/// 英语单词要有音标和语音、例句」。
///
/// **接口可用性是实测过的**，不是照文档猜的：
///   * 有道 `dict.youdao.com/jsonapi` —— 通。英汉 + 汉英，词和句子都认。
///     返回里有音标（ukphone/usphone）、释义、词形变化、短语、同近义词、
///     网络释义、双语例句 —— 一个词该有的它都有，所以设为默认源。
///   * 百度 `fanyi.baidu.com/sug`（POST kw=）—— 通。返回若干条 k→v，
///     中英双向都能用，胜在快、结果短。
///   * MyMemory `api.mymemory.translated.net/get` —— 通。纯翻译，长句子表现最好。
///
/// v1.6.0 又实测了一轮、新加两个**免 key**的整句翻译源：
///   * 腾讯交互翻译 `transmart.qq.com/api/imt`（POST JSON）—— 通，质量最好。
///     `header.fn = auto_translation`、`source.lang = auto` 能自动判别语种
///     （返回里的 `src_lang` 就是判出来的），译文在 `auto_translation[0]`。
///     实测 zh/en/ja/ko/fr/de/es/ru 互译都行，200 字的句子也没截断。
///     必须带 `Referer: https://transmart.qq.com/` 和 `Content-Type: application/json`，
///     少一个就 4xx。
///   * 有道 `aidemo.youdao.com/trans`（POST q=/from=/to=）—— 通。判定语种的老
///     公开接口，`errorCode == "0"` 才算成功（102 = 不支持这对语种，113 = 没译出）。
///     实测 zh-CHS→en、en→zh-CHS、auto→zh-CHS 都好使。
///
/// **这一轮试过但不可用的**（别再往回加）：
///   * 谷歌 `translate.googleapis.com` —— 实测超时，国内本来就访问不了。
///   * 金山词霸 `fy.iciba.com/ajax.php` —— 老接口已下线，现在返回整页 HTML。
///   * 搜狗 `fanyi.sogou.com/reventondc/translateV2` —— 同样返回 HTML 了。
///   * 有道 `fanyi.youdao.com/translate` —— 返回 HTML，说明老 GET 接口也下线了。
///   * 必应 `cn.bing.com/ttranslatev3` —— 能抓到 IG/IID，但 body 里还要一个
///     从页面脚本里算出来的 token，拿不到 → `statusCode: 205`。
///   * 彩云小译 `api.interpreter.caiyunai.com` —— 401 Invalid token，要 key。
///   * LibreTranslate 系（libretranslate.com / .de / argosopentech / terraprint /
///     lt.vern.cc）、Lingva（Google 代理）系、simplytranslate、Yandex —— 全部
///     连不通（Cloudflare 拦截 / 部署暂停 / 502），不可靠，不做。
///   * 百度 `fanyi.baidu.com/transapi` —— 返回 errno 1022（要 token），不做。
///   * vvhan / oioweb 那两个「免费 API」—— 一个 DNS 解析不了、一个 404，不做。
///
/// **语音不走任何 TTS 包**：新的原生插件在这个项目里风险太高（历次构建失败
/// 全是依赖）。直接用有道的发音接口 `dictvoice?audio=单词&type=1|2` 拿到 mp3
/// 字节，存到缓存目录后交给已有的 media_kit 播放 —— 第一次联网取，之后就本地读。
class TranslatePage extends StatefulWidget {
  const TranslatePage({super.key});

  @override
  State<TranslatePage> createState() => _TranslatePageState();
}

/// 数据源（整句翻译 / 英汉词典那一边）。顺序就是内部枚举顺序。
enum _Src { youdao, youdaoTx, transmart, baidu, mymemory }

/// v2.3.1：**所有可切换的接口**都摆在一个列表里，不再先分「翻译 / 在线字典 /
/// 在线词典」三页（用户：去掉上面那三个分类，直接一个查询框，下面把能查的
/// 接口都列出来，点哪个就用哪个查）。
///
/// 每一行 = 一个接口。前五个是原来的「翻译」，后三个是原来的「字典 / 词典」
/// （这三个源本身字词通吃，查「人」和查「学习」都是同一个接口）。
enum _Api {
  youdaoDict('有道词典', '英汉 · 音标 / 例句', _ApiKind.translate, _Src.youdao),
  baiduDict('百度词典', '英汉 · 简明对照', _ApiKind.translate, _Src.baidu),
  youdaoTx('有道翻译', '整句 · 中英互译', _ApiKind.translate, _Src.youdaoTx),
  transmart('腾讯翻译', '整句 · 长句最顺', _ApiKind.translate, _Src.transmart),
  mymemory('MyMemory', '整句 · 多语种', _ApiKind.translate, _Src.mymemory),
  baiduHanyu('百度汉语', '汉字 / 词语 / 成语', _ApiKind.dict, null, DictSource.baidu),
  zdic('汉典', '汉字 · 字形字源', _ApiKind.dict, null, DictSource.zdic),
  youdaoZh('有道汉语', '汉字 / 词语 · 规范释义', _ApiKind.dict, null, DictSource.youdao);

  const _Api(this.label, this.hint, this.kind, this.src, [this.dictSource]);

  final String label;
  final String hint;
  final _ApiKind kind;
  final _Src? src;
  final DictSource? dictSource;

  bool get isDict => kind == _ApiKind.dict;
}

enum _ApiKind { translate, dict }

class _TranslatePageState extends State<TranslatePage> {
  final _input = TextEditingController();

  /// 自己建一个 Dio，不用 WebDAV 那个 —— 目标域名完全不同，
  /// 也不该带上 WebDAV 的 Basic Auth 头。
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    // 默认的 dart-http UA 太容易被这些接口拦，报一个普通浏览器的
    headers: const {'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36'},
  ));

  _Api _api = _Api.youdaoDict;
  bool _busy = false;
  String? _error;
  String _query = '';

  /// 每查一次 +1。字典那半边（[DictLookupView]）靠它判断「再查一次」。
  int _runId = 0;

  /// 当前接口如果是整句 / 英汉类，对应的内部数据源
  _Src? get _src => _api.src;

  _Youdao? _youdao;
  List<(String, String)> _baidu = const [];
  String? _mymemory;

  /// 有道 `aidemo` 的整句译文
  String? _youdaoTx;

  /// 腾讯交互翻译的整句译文 + 它自己判出来的原文语种
  String? _tmart;
  String _tmartFrom = '';

  Player? _player;

  @override
  void initState() {
    super.initState();
    // 输入框有内容时右边才显示「清空」小叉，所以要跟着输入重画
    _input.addListener(_onInput);
  }

  void _onInput() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _input.removeListener(_onInput);
    _input.dispose();
    _player?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 查询

  bool get _hasCjk => RegExp(r'[\u4e00-\u9fff]').hasMatch(_query);

  /// 点「查询」，或者点下面任意一个接口。
  void _run({String? q}) {
    final text = (q ?? _input.text).trim();
    if (text.isEmpty) {
      setState(() {
        _error = '先输入要查的内容';
        _youdao = null;
        _baidu = const [];
        _mymemory = null;
        _youdaoTx = null;
        _tmart = null;
        _tmartFrom = '';
        _query = '';
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _query = text;
      _runId++;
      // 换接口 / 重查时把上一家的结果全清掉，免得「看到的是上一家的」
      _youdao = null;
      _baidu = const [];
      _mymemory = null;
      _youdaoTx = null;
      _tmart = null;
      _tmartFrom = '';
      _busy = !_api.isDict;
    });
    if (!_api.isDict) _translate(text);
  }

  /// 切换接口：点哪个就用哪个查；已经查过内容就立刻重查一次。
  void _pickApi(_Api a) {
    if (a == _api) return;
    setState(() => _api = a);
    // 输入框里已经有字、或之前查过，就立刻用新接口重查；
    // 什么都没有就只是换个接口，不弹「先输入」那种没意义的提示。
    final typed = _input.text.trim();
    final text = typed.isNotEmpty ? typed : _query;
    if (text.isNotEmpty) _run(q: text);
  }

  Future<void> _translate(String q) async {
    try {
      switch (_src!) {
        case _Src.youdao:
          final r = await _dio.get<String>(
            'https://dict.youdao.com/jsonapi?q=${Uri.encodeComponent(q)}',
            options: Options(responseType: ResponseType.plain),
          );
          if (!mounted) return;
          setState(() => _youdao = _parseYoudao(_decode(r.data)));
          if (_youdao!.isEmpty) setState(() => _error = '有道没有查出结果');
        case _Src.baidu:
          final r = await _dio.post<String>(
            'https://fanyi.baidu.com/sug',
            data: {'kw': q},
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              responseType: ResponseType.plain,
            ),
          );
          final j = _decode(r.data);
          if (!mounted) return;
          final data = (j['data'] as List?) ?? const [];
          setState(() => _baidu = [
                for (final e in data)
                  if (e is Map) ('${e['k'] ?? ''}', '${e['v'] ?? ''}'),
              ]);
          if (_baidu.isEmpty) setState(() => _error = '百度没有查出结果');
        case _Src.mymemory:
          final pair = _hasCjk ? 'zh-CN|en' : 'en|zh-CN';
          final r = await _dio.get<String>(
            'https://api.mymemory.translated.net/get'
            '?q=${Uri.encodeComponent(q)}&langpair=${Uri.encodeComponent(pair)}',
            options: Options(responseType: ResponseType.plain),
          );
          final j = _decode(r.data);
          if (!mounted) return;
          final rd = j['responseData'];
          final text = rd is Map ? '${rd['translatedText'] ?? ''}' : '';
          final status = j['responseStatus'];
          if (status != null && '$status' != '200') {
            setState(() => _error = 'MyMemory 返回 $status：${j['responseDetails'] ?? ''}');
          } else if (text.trim().isEmpty) {
            setState(() => _error = 'MyMemory 没有查出结果');
          } else {
            setState(() => _mymemory = text);
          }
        case _Src.youdaoTx:
          // 这个接口的 from 不接受 auto 配英/日当目标（实测 102），
          // 所以自己按「有没有汉字」判方向，判法跟 MyMemory 那条一致。
          final r = await _dio.post<String>(
            'https://aidemo.youdao.com/trans',
            data: {
              'q': q,
              'from': _hasCjk ? 'zh-CHS' : 'en',
              'to': _hasCjk ? 'en' : 'zh-CHS',
            },
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              responseType: ResponseType.plain,
            ),
          );
          final j = _decode(r.data);
          if (!mounted) return;
          final ec = '${j['errorCode'] ?? ''}';
          final list = (j['translation'] as List?) ?? const [];
          final text = list.isEmpty ? '' : '${list.first}';
          if (ec != '0') {
            setState(() => _error = _youdaoTxErr(ec));
          } else if (text.trim().isEmpty) {
            setState(() => _error = '有道翻译没有译出结果');
          } else {
            setState(() => _youdaoTx = text);
          }
        case _Src.transmart:
          // 腾讯交互翻译：一个 POST 打天下，source.lang=auto 让它自己判。
          // Referer / Content-Type 少一个就 4xx，别删。
          final payload = jsonEncode({
            'header': {'fn': 'auto_translation', 'client_key': _tmClientKey},
            'type': 'plain',
            'model_category': 'normal',
            'source': {
              'lang': 'auto',
              'text_list': [q],
            },
            'target': {'lang': _hasCjk ? 'en' : 'zh'},
          });
          final r = await _dio.post<String>(
            'https://transmart.qq.com/api/imt',
            data: payload,
            options: Options(
              contentType: Headers.jsonContentType,
              responseType: ResponseType.plain,
              headers: const {'Referer': 'https://transmart.qq.com/zh-CN/index'},
            ),
          );
          final j = _decode(r.data);
          if (!mounted) return;
          final code = '${_m(j['header'])['ret_code'] ?? ''}';
          final list = (j['auto_translation'] as List?) ?? const [];
          final text = list.isEmpty ? '' : '${list.first}';
          if (code != 'succ') {
            setState(() => _error = '腾讯翻译返回 ${code.isEmpty ? '未知状态' : code}');
          } else if (text.trim().isEmpty) {
            setState(() => _error = '腾讯翻译没有译出结果');
          } else {
            setState(() {
              _tmart = text;
              _tmartFrom = '${j['src_lang'] ?? ''}';
            });
          }
        }
    } catch (e) {
      if (mounted) setState(() => _error = '网络请求失败：${_short(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 腾讯交互翻译认的一个固定的浏览器指纹，官方网页版就发这个。
  /// 它只是用来区分调用方，不带任何账号信息。
  static const _tmClientKey =
      'browser-chrome-110.0.0-Mac OS-df4bd4c5-a65d-44b2-a40f-42f34f3535f2-1677486696487';

  /// 有道 aidemo 的错误码 → 人话（实测过的三个，其余兜底）
  static String _youdaoTxErr(String code) => switch (code) {
        '102' => '有道翻译不支持这对语种',
        '113' => '有道翻译没拿到可译的内容',
        '108' => '有道翻译暂时不可用（服务器侧限流）',
        _ => '有道翻译返回错误码 $code',
      };

  /// transmart 回来的 `src_lang` 是短码，翻成中文给人看
  static String _langName(String code) => switch (code) {
        '' || 'auto' => '自动识别',
        'zh' || 'zh-CHS' || 'zh-Hans' => '中文',
        'en' => '英语',
        'ja' => '日语',
        'ko' => '韩语',
        'fr' => '法语',
        'de' => '德语',
        'es' => '西班牙语',
        'pt' => '葡萄牙语',
        'it' => '意大利语',
        'ru' => '俄语',
        'th' => '泰语',
        'vi' => '越南语',
        'id' => '印尼语',
        'ar' => '阿拉伯语',
        'nl' => '荷兰语',
        _ => code,
      };

  /// v1.8.0：实现搬到 `tool_pages.dart` 的 [shortErr] 了（字典/词典页也要用），
  /// 这里保留这个名字只是为了不动文件里十几处调用点。
  static String _short(Object e) => shortErr(e);

  /// 解 JSON；接口偶尔会带 BOM 或前后空白，这里统一处理
  Map<String, dynamic> _decode(String? body) {
    final s = (body ?? '').replaceFirst('\uFEFF', '').trim();
    if (s.isEmpty) return const {};
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : const {};
    } catch (_) {
      return const {};
    }
  }

  // ---------------------------------------------------------------- 解析

  static Map<String, dynamic> _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};
  static List _l(dynamic v) => v is List ? v : const [];

  /// 从有道那种套娃结构里抠纯文本。
  ///
  /// 形状有好几种，都实测过：
  ///   `{l: {i: ["int. 喂，你好"]}}`          —— 英汉释义
  ///   `{l: {i: ["", {#text: "hello"}], #tran: "喂，你好"}}` —— 汉英释义（译文在 #tran）
  ///   `{l: {i: "打招呼；问好"}}`              —— 短语
  /// 所以优先级是 #tran → #text → i → l，字符串列表按分号拼起来。
  static String _t(dynamic node) {
    if (node == null) return '';
    if (node is String) return node.trim();
    if (node is num || node is bool) return '$node';
    if (node is List) {
      return node.map(_t).where((e) => e.isNotEmpty).join('；');
    }
    if (node is Map) {
      for (final k in const ['#tran', '#text', 'i', 'l', 'value', 'text']) {
        if (node.containsKey(k)) {
          final s = _t(node[k]);
          if (s.isNotEmpty) return s;
        }
      }
    }
    return '';
  }

  /// `trs` 是个数组，每项 `{tr: [{l: {...}}]}`；一项就是一行释义
  static List<String> _trs(dynamic trs) => [
        for (final e in _l(trs)) _t(_m(e)['tr']),
      ].where((e) => e.isNotEmpty).toList();

  _Youdao _parseYoudao(Map<String, dynamic> j) {
    final ec = _m(j['ec']);
    final ce = _m(j['ce']);

    // 英文词：ec 里有音标和释义。中文词：只有 ce。
    final word = _m(_l(ec['word']).isNotEmpty ? _l(ec['word']).first : null);

    final trs = <String>[
      ..._trs(word['trs']),
      ..._trs(_l(ce['word']).isNotEmpty ? _m(_l(ce['word']).first)['trs'] : null),
    ];

    // 词形变化：复数 / 过去式之类
    final wfs = <String>[];
    for (final e in _l(word['wfs'])) {
      final wf = _m(_m(e)['wf']);
      final n = _t(wf['name']);
      final v = _t(wf['value']);
      if (n.isNotEmpty && v.isNotEmpty) wfs.add('$n $v');
    }

    // 短语
    final phrs = <(String, String)>[];
    for (final e in _l(_m(j['phrs'])['phrs'])) {
      final phr = _m(_m(e)['phr']);
      final head = _t(phr['headword']);
      final tr = _t(phr['trs']);
      if (head.isNotEmpty) phrs.add((head, tr));
    }

    // 同近义词
    final synos = <String>[];
    for (final e in _l(_m(j['syno'])['synos'])) {
      final s = _m(_m(e)['syno']);
      final pos = _t(s['pos']);
      final tran = _t(s['tran']);
      final words = _l(s['ws'])
          .map((w) => _t(_m(w)['w']))
          .where((w) => w.isNotEmpty)
          .join('、');
      final line = [if (pos.isNotEmpty) pos, if (tran.isNotEmpty) tran, if (words.isNotEmpty) words].join(' ');
      if (line.trim().isNotEmpty) synos.add(line.trim());
    }

    // 网络释义
    final web = <(String, String)>[];
    for (final e in _l(_m(j['web_trans'])['web-translation'])) {
      final item = _m(e);
      final key = _t(item['key']);
      final vals = _l(item['trans'])
          .map((t) => _t(_m(t)['value']))
          .where((v) => v.isNotEmpty)
          .take(4)
          .join('、');
      if (key.isNotEmpty && vals.isNotEmpty) web.add((key, vals));
    }

    // 双语例句
    final sents = <(String, String)>[];
    final bp = _m(j['blng_sents_part']);
    for (final e in _l(bp['sentence-pair'])) {
      final item = _m(e);
      final en = _t(item['sentence']);
      final zh = _t(item['sentence-translation']);
      if (en.isNotEmpty) sents.add((en, zh));
    }

    return _Youdao(
      phrase: _t(word['return-phrase']).isNotEmpty ? _t(word['return-phrase']) : _query,
      ukPhone: _t(word['ukphone']),
      usPhone: _t(word['usphone']),
      trs: trs,
      wfs: wfs,
      phrs: phrs,
      synos: synos,
      web: web,
      sents: sents,
    );
  }

  // ---------------------------------------------------------------- 发音

  /// 播放发音。type：1 = 英音，2 = 美音。
  ///
  /// 先把 mp3 拉到本地缓存再播 —— 直接让播放器去流这个地址，
  /// 网络一抖就没声音；而且同一个词反复点应该秒出。
  Future<void> _speak(String text, int type) async {
    final t = text.trim();
    if (t.isEmpty) return;
    try {
      final dir = await getTemporaryDirectory();
      final safe = t.hashCode.toRadixString(16);
      final f = File(p.join(dir.path, 'tts_${safe}_$type.mp3'));
      if (!await f.exists()) {
        final r = await _dio.get<List<int>>(
          'https://dict.youdao.com/dictvoice?type=$type&audio=${Uri.encodeComponent(t)}',
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = r.data;
        if (bytes == null || bytes.isEmpty) throw Exception('没有拿到音频');
        await f.writeAsBytes(bytes);
      }
      _player ??= Player();
      await _player!.setVolume(100);
      await _player!.open(Media('file://${f.path}'));
    } catch (e) {
      if (mounted) toast(context, '发音取不到：${_short(e)}');
    }
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ToolScaffold(
      title: '翻译查词',
      subtitle: '${_api.label} · ${_api.hint}',
      // v2.3.1：一个输入框 + 下面一排接口，点哪个用哪个查。
      // 原来的「翻译 / 在线字典 / 在线词典」三分页去掉了。
      child: Column(
        children: <Widget>[
          _searchCard(scheme),
          Expanded(
            child: _api.isDict
                ? DictLookupView(
                    // 不给 key：换接口时复用同一个 State，靠 source / runId 触发重查。
                    // 给 key 会重建 State，initState 和 didUpdateWidget 会各查一次。
                    mode: DictMode.ci,
                    embedded: true,
                    query: _query,
                    source: _api.dictSource,
                    runId: _runId,
                  )
                : _translateBody(scheme),
          ),
        ],
      ),
    );
  }

  /// 顶部的统一查询区：输入框 + 查询按钮 + 所有接口。
  Widget _searchCard(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _run(),
                  decoration: InputDecoration(
                    hintText: '输入英文单词、句子，或汉字 / 词语 / 成语',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: _input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() {
                              _input.clear();
                              _error = null;
                              _youdao = null;
                              _baidu = const [];
                              _mymemory = null;
                              _youdaoTx = null;
                              _tmart = null;
                              _tmartFrom = '';
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 46,
                child: FilledButton.icon(
                  onPressed: _busy && !_api.isDict ? null : _run,
                  icon: _busy && !_api.isDict
                      ? const SizedBox(
                          height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: const Text('查询'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('用哪个接口查（点一下就切过去）',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final a in _Api.values)
                ChoiceChip(
                  label: Text(a.label, style: const TextStyle(fontSize: 12.5)),
                  selected: _api == a,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _pickApi(a),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 结果区（整句翻译 / 英汉词典那一半）。
  ///
  /// v2.3.1：输入框和接口选择已经统一挪到上面的 [_searchCard]，
  /// 这里只剩「查出来的东西」，不再自带一套输入控件。
  Widget _translateBody(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        if (_error != null) _errBox(scheme, _error!),
        if (_query.isNotEmpty) ..._resultArea(scheme),
        const SizedBox(height: 14),
        _notes(scheme),
      ],
    );
  }

  List<Widget> _resultArea(ColorScheme scheme) {
    switch (_src!) {
      case _Src.youdao:
        final y = _youdao;
        if (y == null) return const [];
        return [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---- 词头 + 发音 ----
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(y.phrase.isEmpty ? _query : y.phrase,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      _speakBtn('英', () => _speak(y.phrase.isEmpty ? _query : y.phrase, 1)),
                      _speakBtn('美', () => _speak(y.phrase.isEmpty ? _query : y.phrase, 2)),
                    ],
                  ),
                  if (y.ukPhone.isNotEmpty || y.usPhone.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        if (y.ukPhone.isNotEmpty) _phone('英', y.ukPhone, scheme),
                        if (y.usPhone.isNotEmpty) _phone('美', y.usPhone, scheme),
                      ],
                    ),
                  ],
                  if (y.trs.isNotEmpty) _block('释义', [for (final t in y.trs) _line(t)], scheme),
                  if (y.wfs.isNotEmpty) _block('词形变化', [for (final t in y.wfs) _line(t)], scheme),
                  if (y.phrs.isNotEmpty)
                    _block('短语', [
                      for (final e in y.phrs)
                        _kv(e.$1, e.$2, scheme),
                    ], scheme),
                  if (y.synos.isNotEmpty) _block('同近义词', [for (final t in y.synos) _line(t)], scheme),
                  if (y.web.isNotEmpty)
                    _block('网络释义', [
                      for (final e in y.web) _kv(e.$1, e.$2, scheme),
                    ], scheme),
                  if (y.sents.isNotEmpty)
                    _block('双语例句', [
                      for (var i = 0; i < y.sents.length; i++) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${i + 1}. ${y.sents[i].$1}',
                                      style: const TextStyle(fontSize: 13.5, height: 1.5)),
                                  if (y.sents[i].$2.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                                      child: Text(y.sents[i].$2,
                                          style: TextStyle(
                                              fontSize: 13, height: 1.5, color: scheme.onSurfaceVariant)),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '读这句',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.volume_up_outlined, size: 18),
                              onPressed: () => _speak(y.sents[i].$1, 2),
                            ),
                          ],
                        ),
                        if (i < y.sents.length - 1) const SizedBox(height: 8),
                      ],
                    ], scheme),
                  if (y.isEmpty)
                    Text('没有查到内容', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ];

      case _Src.baidu:
        if (_baidu.isEmpty) return const [];
        return [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(_query,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      ),
                      _speakBtn('读一下', () => _speak(_query, 2)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final e in _baidu) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (e.$1 != _query) ...[
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(e.$1, style: TextStyle(fontSize: 11.5, color: scheme.onSecondaryContainer)),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(child: Text(e.$2, style: const TextStyle(fontSize: 13.5, height: 1.6))),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text('百度词典给的是简明对照，要音标和例句请切到有道词典',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ];

      case _Src.mymemory:
        final text = _mymemory;
        if (text == null) return const [];
        return [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_query, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  SelectableText(text, style: const TextStyle(fontSize: 17, height: 1.6)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => copyText(context, text),
                        icon: const Icon(Icons.copy, size: 17),
                        label: const Text('复制'),
                      ),
                      if (!_hasCjk) ...[
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () => _speak(_query, 2),
                          icon: const Icon(Icons.volume_up_outlined, size: 17),
                          label: const Text('读原文'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ];

      case _Src.youdaoTx:
        final tx = _youdaoTx;
        if (tx == null) return const [];
        return [
          _sentenceCard(
            scheme,
            text: tx,
            tip: '有道翻译 · ${_hasCjk ? '中 → 英' : '英 → 中'}',
          ),
        ];

      case _Src.transmart:
        final tm = _tmart;
        if (tm == null) return const [];
        return [
          _sentenceCard(
            scheme,
            text: tm,
            tip: '腾讯交互翻译 · 识别为 ${_langName(_tmartFrom)} → '
                '${_hasCjk ? '英语' : '中文'}',
          ),
        ];
    }
  }

  /// 整句翻译的通用结果卡（有道翻译 / 腾讯翻译共用一套版式）
  Widget _sentenceCard(ColorScheme scheme,
          {required String text, required String tip}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_query, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SelectableText(text, style: const TextStyle(fontSize: 17, height: 1.6)),
              const SizedBox(height: 6),
              Text(tip, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => copyText(context, text),
                    icon: const Icon(Icons.copy, size: 17),
                    label: const Text('复制'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _speak(_query, 2),
                    icon: const Icon(Icons.volume_up_outlined, size: 17),
                    label: const Text('读原文'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _speakBtn(String label, VoidCallback onTap) => ActionChip(
        avatar: const Icon(Icons.volume_up_outlined, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );

  Widget _phone(String tag, String value, ColorScheme scheme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(tag, style: TextStyle(fontSize: 10.5, color: scheme.onTertiaryContainer)),
          ),
          const SizedBox(width: 5),
          Text('/$value/', style: const TextStyle(fontSize: 13.5)),
        ],
      );

  Widget _block(String title, List<Widget> lines, ColorScheme scheme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Row(
            children: [
              Container(width: 3, height: 13, color: scheme.primary.withValues(alpha: 0.7)),
              const SizedBox(width: 7),
              Text(title,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          ...lines,
        ],
      );

  Widget _line(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(t, style: const TextStyle(fontSize: 13.5, height: 1.6)),
      );

  Widget _kv(String k, String v, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(v, style: TextStyle(fontSize: 13, height: 1.5, color: scheme.onSurfaceVariant)),
            ),
          ],
        ),
      );

  Widget _errBox(ColorScheme scheme, String msg) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(msg, style: const TextStyle(fontSize: 13, height: 1.5))),
          ],
        ),
      );

  Widget _notes(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 17, color: scheme.onSurfaceVariant),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                '八个接口都是公开的免 key 接口，用的同一个网络，'
                '哪个不通就换一个再试；换了会自动用新接口重查一次。\n'
                '· 有道词典：英汉最全，有音标 / 词形变化 / 短语 / 同近义词 / 双语例句\n'
                '· 百度词典：英汉简明对照，最快\n'
                '· 有道翻译：整句翻译，自动判中英方向，短句快\n'
                '· 腾讯翻译：整句翻译，长句最顺，能自动认语种（日 / 韩 / 法 / 德…）\n'
                '· MyMemory：长句也顺，词条信息少\n'
                '· 百度汉语 / 汉典 / 有道汉语：汉字、词语、成语，'
                '字形和释义分别侧重「最全 / 字源 / 最规范」\n'
                '发音来自有道，一个词读一次就会存到本地，之后点了马上响。',
                style: TextStyle(fontSize: 11.5, height: 1.75, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
}

/// 有道词典的解析结果
class _Youdao {
  final String phrase;
  final String ukPhone;
  final String usPhone;
  final List<String> trs;
  final List<String> wfs;
  final List<(String, String)> phrs;
  final List<String> synos;
  final List<(String, String)> web;
  final List<(String, String)> sents;

  const _Youdao({
    required this.phrase,
    required this.ukPhone,
    required this.usPhone,
    required this.trs,
    required this.wfs,
    required this.phrs,
    required this.synos,
    required this.web,
    required this.sents,
  });

  bool get isEmpty =>
      trs.isEmpty && phrs.isEmpty && synos.isEmpty && web.isEmpty && sents.isEmpty && wfs.isEmpty;
}
