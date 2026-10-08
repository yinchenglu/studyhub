import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'data/local/db.dart';
import 'data/local/settings_store.dart';

/// 入口：
/// 1. 初始化播放器内核 media_kit（内部是 libmpv，负责全格式解码）
/// 2. 初始化本地设置与本地数据库（错题本、播放进度）
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SettingsStore.instance.init();
  await AppDb.instance.init();
  runApp(const ProviderScope(child: StudyHubApp()));
}
