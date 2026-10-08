# 学聚（StudyHub）—— 自用学习 App

一个「资料全放在自己 WebDAV 服务器上」的安卓学习 App。源码已全部写好，本文档是从零把它装进手机的完整操作指南。

---

## 〇、最省事的出包方式：云端编译（推荐先看这个）

**电脑上什么都不用装**。本项目已内置 GitHub Actions 工作流，
把代码推到 GitHub 后自动编译出 APK 并发布到 Release，直接下载安装即可。

- 工作流文件：`.github/workflows/build-apk.yml`
- 详细操作步骤：见工作区根目录的 `云端打包-操作指南.md`

**两个必须知道的实现细节**（否则会踩坑）：

1. **Flutter 版本锁定 3.24.5**。这个版本的 Android 模板使用 Groovy `build.gradle`，
   与 `android_custom/app_build.gradle` 匹配；3.29+ 改用 `build.gradle.kts`，覆盖会失败。
2. **`MainActivity` 由本仓库提供**（`android_custom/MainActivity.kt`）。
   因为 `app_build.gradle` 把 namespace 定为 `com.studyhub.app`，
   而模板生成的 `MainActivity` 在 `com.studyhub.studyhub` 下，
   清单里的 `.MainActivity` 会解析失败导致一启动就闪退。
   工作流会删掉模板生成的那份，换成包名正确的这一份。

如果你想走**本地编译**路线（改代码后出包更快），看下面第三节开始的内容。

---

## 一、这个 App 有什么

底部五个菜单，全部围绕你自己的 WebDAV 服务器：

| 菜单 | 功能 |
| --- | --- |
| **首页** | 未登录时显示「服务器目录规范」引导；登录后显示账号信息、笔记/视频/题库/工具数量、错题本、最近浏览、设置 |
| **笔记** | 读取服务器 notes 目录，Markdown 图文 + GIF/WebP 动图；可新建目录、新建笔记、上传图片、修改、重命名、删除 |
| **视频** | 自动扫描 media 目录，按目录分类；nplayer 风格播放器（双击快进退、滑动拖进度、倍速 0.5×~3×、长按 2 倍速、画面亮度/音量手势、进度记忆），图片左右滑动缩放、动图直接动 |
| **刷题** | 自动识别 quiz 下每套题库（选择题 + 单词库）；顺序练 / 随机练 / 只练错题 / 智能复习 / 模拟考试；答错自动进错题本，按题库与知识点分组 |
| **工具** | 12 个内嵌离线小工具 + 一个「服务器速查表」（读 tools 目录） |

所有内容**在线看、按需下载**，缓存一键清理后本地零占用；只有设置和错题本留在手机上。

---

## 二、代码结构

```
studyhub_app/
├─ pubspec.yaml                    依赖清单
├─ analysis_options.yaml           代码检查规则
├─ android_custom/                 ★ 需要覆盖到 Android 工程里的两个文件
│   ├─ AndroidManifest.xml         权限声明（网络、相册、相机等）
│   ├─ app_build.gradle            构建脚本（minSdk 23、签名回退、播放器兼容）
│   └─ key.properties.example      正式签名模板
├─ lib/
│   ├─ main.dart                   入口：初始化播放器内核 + 本地库
│   ├─ app.dart                    主框架 + 底部五个菜单
│   ├─ core/
│   │   ├─ constants.dart          服务器目录规范、文件类型判定
│   │   ├─ theme.dart              浅色/深色主题
│   │   └─ utils.dart              格式化工具函数
│   ├─ data/
│   │   ├─ models/models.dart      所有数据模型
│   │   ├─ dav/webdav_client.dart  ★ 手写 WebDAV 客户端（列目录/读/写/删/移动/断点下载/Range 检测）
│   │   ├─ local/db.dart           本地 SQLite（错题本、播放进度）+ 缓存管理
│   │   ├─ local/settings_store.dart 设置与账号（密码加密存储）
│   │   └─ repositories/           笔记、媒体、题库三个仓库
│   ├─ providers/providers.dart    全局状态
│   └─ ui/
│       ├─ home/                   首页、登录、设置、目录规范
│       ├─ notes/                  笔记列表、阅读、编辑
│       ├─ media/                  媒体库、播放器、图片查看
│       ├─ quiz/                   题库、答题、错题本
│       └─ tools/                  工具网格、12 个工具、服务器速查表
└─ 示例题库/                        （在工作区根目录）可直接上传服务器的示例题库
```

---

## 三、准备开发环境（只需做一次）

1. **Flutter SDK**（3.22 或更高，含 Dart 3）
   下载 <https://flutter.dev/docs/get-started/install/windows>，解压到不含中文和空格的路径，例如 `C:\flutter`，然后把 `C:\flutter\bin` 加进系统 PATH。
   验证：
   ```bash
   flutter --version
   ```
2. **Android Studio**（提供 Android SDK 与命令行工具）
   安装后打开一次，在 `Settings → Languages & Frameworks → Android SDK` 里勾上：
   - Android SDK Platform 34
   - Android SDK Command-line Tools
   - Android SDK Build-Tools
   - Android SDK Platform-Tools
3. **JDK 17**（Android Studio 自带，一般不用单独装）
4. 检查环境：
   ```bash
   flutter doctor
   ```
   看到 `Android toolchain` 是绿勾就可以继续；`Android Studio` 黄字不影响。

---

## 四、生成工程（关键一步）

我提供的是 `lib/` 源码 + 关键配置文件，Android 平台的骨架（图标、Gradle Wrapper 等）由 Flutter 自动生成，这样最不容易出错。

```bash
# 1. 进入工作目录
cd /c/Users/YCL/WorkBuddy/2026-10-08-12-08-46

# 2. 生成安卓骨架（会创建 studyhub_app/android、图标等）
flutter create --org com.studyhub --platforms=android --project-name studyhub_app studyhub_app_tmp

# 3. 用我写好的工程目录覆盖过去
#    把 studyhub_app_tmp/android 整个复制到 studyhub_app/ 下
#    把 studyhub_app_tmp/.gitignore 等其它生成物也一并复制
cp -r studyhub_app_tmp/android studyhub_app/
cp studyhub_app_tmp/.metadata studyhub_app/ 2>/dev/null
cp studyhub_app_tmp/.gitignore studyhub_app/ 2>/dev/null

# 4. 用我的清单与构建脚本覆盖 Android 配置
cp studyhub_app/android_custom/AndroidManifest.xml studyhub_app/android/app/src/main/AndroidManifest.xml
cp studyhub_app/android_custom/app_build.gradle        studyhub_app/android/app/build.gradle

# 5. 清理临时工程
rm -rf studyhub_app_tmp
```

> **更简单的方式**：如果你想少几步，也可以直接 `cd studyhub_app && flutter create --org com.studyhub --platforms=android .`，
> 它会补齐缺失的平台文件（已存在的 `lib/` 和 `pubspec.yaml` 不会被破坏），然后再执行上面的第 4 步覆盖清单和构建脚本。

---

## 五、装依赖并跑到手机上

```bash
cd studyhub_app
flutter pub get          # 下载依赖，第一次大概 1~3 分钟
flutter devices          # 确认手机已识别（需要手机开 USB 调试）
flutter run              # 直接装到手机并启动，方便调试
```

首次运行会下载 media_kit 的解码库（约 50MB），耐心等一次，之后就快了。

---

## 六、打包成 APK（装到自己手机上）

### 方式 A：debug 包（最快，能用，适合自己用）

```bash
cd studyhub_app
flutter build apk --debug
# 产物：build/app/outputs/flutter-apk/app-debug.apk
```

### 方式 B：release 包（体积更小、更流畅，推荐）

先生成签名文件（只需一次）：

```bash
keytool -genkey -v -keystore C:/Users/YCL/studyhub-key.jks ^
  -keyalg RSA -keysize 2048 -validity 10000 -alias studyhub
# 会问你密码和姓名等信息，密码自己记住
```

然后创建 `studyhub_app/android/key.properties`（可照着 `android_custom/key.properties.example` 改）：

```properties
storePassword=你刚设的密码
keyPassword=你刚设的密码
keyAlias=studyhub
storeFile=C:/Users/YCL/studyhub-key.jks
```

最后打包：

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

**只想要 arm64 版（体积能小一半，自用手机基本都是 arm64）：**

```bash
flutter build apk --release --target-platform android-arm64
```

### 安装到手机

- 把 `app-release.apk` 传到手机（微信文件传输、数据线、网盘都行），点开安装；
- 手机需要允许「安装未知来源应用」；
- 或者直接在电脑上：`flutter install`（手机连着 USB 时）。

> 本 App 只做本地打包，不做应用商店上架。APK 直接装即可，不需要任何账号或资质。

---

## 七、服务器这边怎么准备

在 WebDAV 根目录下建一个 `StudyHub` 文件夹，里面建 5 个子文件夹：

```
StudyHub/
  ├─ notes/    笔记：每篇一个 .md，配图放同一目录
  ├─ media/    视频与图片：子目录自动成为分类
  ├─ quiz/     题库：每个子目录 = 一套题库，放 .json
  ├─ tools/    词库、速查表（.md/.txt/.csv/.json）
  └─ backup/   App 回写的错题本与笔记备份
```

快速验证：把工作区里 `示例题库/` 的三个 JSON 按目录传上去——

```
quiz/python基础/python基础.json
quiz/医学中级/医学中级.json
quiz/单词/英语四级核心词.json
```

打开 App → 刷题，就能看到三套题库了。

**服务器类型提示**

- **群晖（WebDAV Server 套件）**：读写、建目录、Range 分段都完整，体验最好。地址一般形如 `http://群晖IP:5005/`。
- **chfs**：WebDAV 是它的附加能力，部分版本目录遍历不全。App 已做降级处理（Depth:1 失败自动改 infinity、再失败改为逐层请求），如果仍然看不到子目录，直接在 chfs 网页端把目录建好即可。
- HTTPS 自签证书报错时，先用 http 连（App 已允许明文流量）。

---

## 八、常见报错怎么解决

| 报错 | 原因与处理 |
| --- | --- |
| `cmdline-tools not found` | Android Studio 里没装 Command-line Tools，去 SDK Manager 勾上 |
| `CocoaPods not installed` | 只在打 iOS 包时出现，你不需要 |
| `Gradle build failed` / `Execution failed for task ':app:...'` | 先 `flutter clean` 再 `flutter pub get` 重新 `flutter build apk` |
| `Could not resolve all files` / 依赖下载慢 | 换国内镜像：在 `android/build.gradle` 的 repositories 里加 `maven { url 'https://maven.aliyun.com/repository/public' }` |
| `Keystore was tampered with, or password was incorrect` | `key.properties` 里的密码和生成时不一致 |
| 装上去闪退 | 用 `flutter run --release` 看日志，多数是 minSdk 太低（本项目设为 23） |
| 视频播放黑屏 / 只有声音 | 该文件编码较特殊，试试长按加速或先下载到本地再播 |
| 在线播放拖不动进度条 | 服务器不支持 HTTP Range（首页会显示「不支持拖进度」），先下载到本地看 |
| 笔记能看不能改 | 服务器是只读账号，首页会显示「只读」；换一个可写账号即可 |
| 中文文件名乱码 / 找不到 | 确认服务器是 UTF-8（群晖默认没问题；chfs 需开启 UTF-8 支持） |

---

## 九、已知限制与后续可加的功能

**当前版本的限制（说清楚，避免期待落空）**

1. 只做了 Android。代码保持了跨平台结构，将来要 iOS 只需补平台配置与开发者证书。
2. 画面亮度手势做的是「App 内调暗」，不改手机系统亮度（改系统亮度需要额外插件，且部分机型受限）。
3. 视频缩略图目前用类型图标占位，没做逐帧截图（需要 ffmpeg，会让 APK 再大几十兆）。
4. 笔记编辑器是纯文本 Markdown，没有所见即所得预览开关（当前预览按钮显示的是原文）。
5. 错题本保存本地；导出 Markdown 到服务器的功能已做（设置 → 数据）。
6. 未做多账号同时在线（设置里可以切换账号）。

**下一版可以加**（V2）

- 笔记全文搜索、收藏夹
- 播放器外挂字幕、音轨切换、A-B 循环
- 错题艾宾浩斯复习曲线、填空题/简答题
- 视频缩略图（引入 ffmpeg 截图）
- 批量下载整个课程目录、离线课程包
- 应用锁（指纹 / 密码）

---

## 十、一句话总结操作顺序

1. 装 Flutter + Android Studio → `flutter doctor` 全绿
2. `flutter create` 生成骨架 → 覆盖本项目的 `lib/`、`pubspec.yaml` 和 `android_custom/` 两个文件
3. `flutter pub get` → `flutter run` 试跑
4. `flutter build apk --release` → 得到 APK → 装进手机
5. 服务器上建好 `StudyHub/{notes,media,quiz,tools,backup}` → 在 App 首页登录 WebDAV
