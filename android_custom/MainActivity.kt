package com.studyhub.app

import io.flutter.embedding.android.FlutterActivity

/**
 * 学聚 App 的入口 Activity。
 *
 * 为什么要把这个文件也放进 android_custom/：
 * 云端工作流用 `flutter create --project-name studyhub` 生成骨架时，
 * 模板会把 MainActivity 放在 `com.studyhub.studyhub` 包下，
 * 但 app_build.gradle 里把 namespace 定成了 `com.studyhub.app`，
 * AndroidManifest 中的 `.MainActivity` 是相对 namespace 解析的，
 * 两者对不上 → 一启动就 ClassNotFoundException 闪退。
 *
 * 所以这里显式提供一份包名正确的 MainActivity，工作流会删掉模板生成的、
 * 用这一份覆盖过去，确保包名与 namespace 完全一致。
 */
class MainActivity : FlutterActivity()
