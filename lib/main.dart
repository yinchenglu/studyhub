import 'package:flutter/material.dart';
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
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await SettingsStore.instance.init();
  await AppDb.instance.init();
  await SyncService.instance.boot();
  await PinyinTable.init();
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
