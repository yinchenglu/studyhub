import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/constants.dart';
import 'core/natural_sort.dart';
import 'core/sync_service.dart';
import 'data/local/db.dart';
import 'data/local/settings_store.dart';

/// 入口：
/// 1. 初始化播放器内核 media_kit（内部是 libmpv，负责全格式解码）
/// 2. 初始化本地设置与本地数据库（错题本、播放进度）
/// 3. 加载中文日期数据 —— intl 默认只带 en_US，
///    不调这一句的话，日期计算等工具里 DateFormat(..., 'zh_CN') 会直接抛异常
/// 4. v1.5.0：把「文件夹同步」服务的配置读回来。上次开着的话这里就会
///    把定时器接上 —— 它挂在单例上，跟任何页面都没关系，
///    这样用户切到别的页面、甚至退到后台都不会停。
/// 5. v1.8.0：把拼音表读进来，给「按名称排序要和电脑一致」用。
///    必须在这里读、不能等到用的时候再读 —— 排序是比较器，是**同步**调用的，
///    没有 await 的余地。表本身只在内存里查，46 KB，几百毫秒都不到。
/// 6. v1.9.0：版本号一致性校验。
///    升级流程见 tools/bump_version.py，App 启动时如果两个版本号不一致
///    会在控制台 + 设置页「关于」里给红字提醒（debug 模式 assert 直接抛错）。
///
/// 7. v2.0.0+39：启动诊断（修「装上就一片白屏」）。
///    release 版没有控制台，main() 里任何一个 await 卡死 / 抛异常，
///    用户看到的就是纯白一片，什么线索都没有。
///    现在：
///      * 每一步完成后记一笔进度；
///      * 出错就把「走到哪一步 + 错误 + 堆栈」画成一个错误页（可一键复制）；
///      * ErrorWidget.builder 换掉 release 默认的灰屏，build 异常也直接显示文字。
Future<void> main() async {
  final steps = <String>[];
  void mark(String s) => steps.add(s);

  // 单步初始化：完成记一笔；卡住超过 12 秒或抛错都转入诊断页。
  // 「卡住」和「抛错」在 release 下的表象一模一样（白屏），必须都兜住。
  Future<void> step(String name, Future<void> Function() f) async {
    try {
      await f().timeout(const Duration(seconds: 12));
      mark(name);
    } catch (e, st) {
      throw StateError('【卡在/出错于 $name】\n$e\n$st');
    }
  }

  try {
    WidgetsFlutterBinding.ensureInitialized();
    mark('Flutter binding');

    // release 下 build 抛异常默认是一块灰色 Screen，用户只会说「白屏/花屏」。
    // 换成把错误原文显示出来 —— 诊断期最有价值的就是这段文字。
    ErrorWidget.builder = (details) {
      final buf = StringBuffer();
      buf.writeln('页面渲染出错');
      buf.writeln(details.exception.toString());
      final st = details.stack?.toString() ?? '';
      final lines = st.split('\n').take(24);
      buf.write(lines.join('\n'));
      return _DiagPage(title: '渲染错误', body: buf.toString(), steps: steps);
    };

    MediaKit.ensureInitialized();
    mark('media_kit');

    await step('intl 日期', () => initializeDateFormatting('zh_CN'));
    await step('本地设置', () => SettingsStore.instance.init());
    await step('本地数据库', () => AppDb.instance.init());
    await step('同步服务', () => SyncService.instance.boot());
    await step('拼音表', () => PinyinTable.init());
  } catch (e, st) {
    runApp(_DiagPage(
      title: '启动失败',
      body: '卡在「${steps.isEmpty ? '最开始' : steps.last}」之后：\n\n$e\n\n$st',
      steps: steps,
    ));
    return;
  }

  // v1.9.0：kAppVersion 与 pubspec.yaml 的 version 去掉 +N 之后必须一致
  // 发布时两处一起改（用 tools/bump_version.py 一次同步）。
  assert(
    kAppVersion == kPubspecVersion.split('+').first,
    '\n\n'
    '❌ 版本号不一致！\n'
    '   lib/core/constants.dart 的 kAppVersion = "$kAppVersion"\n'
    '   pubspec.yaml 的 version            = "$kPubspecVersion"\n'
    '   跑 tools/bump_version.py 同步。\n',
  );
  runApp(const ProviderScope(child: StudyHubApp()));
}

/// 启动 / 渲染诊断页：黑底黄字，等宽显示错误原文。
/// 一键复制，用户截图发过来就能定位。
class _DiagPage extends StatelessWidget {
  _DiagPage({
    required this.title,
    required this.body,
    required this.steps,
  });

  final String title;
  final String body;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: [
                    Text('$title（$kAppVersion）',
                        style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(
                            text: '【$title】\n已完成步骤: ${steps.join(' → ')}\n\n$body'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制，去粘贴发给我')),
                        );
                      },
                      child: const Text('复制错误', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '已完成: ${steps.isEmpty ? '（无）' : steps.join(' → ')}',
                  style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 13),
                ),
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    body,
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
