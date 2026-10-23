# 学聚（StudyHub）—— 自用学习 App

一个「资料全放在自己 WebDAV 服务器上」的安卓学习 App。源码已全部写好，本文档是从零把它装进手机的完整操作指南。

---

## 〇、最省事的出包方式：云端编译（推荐先看这个）

**电脑上什么都不用装**。本项目已内置 GitHub Actions 工作流，
把代码推到 GitHub 后自动编译出 APK 并发布到 Release，直接下载安装即可。

- 工作流文件：`.github/workflows/build-apk.yml`
- 详细操作步骤：见工作区根目录的 `云端打包-操作指南.md`

**核心设计：模板骨架 + 只覆盖清单 + 注入一行打包配置**

工作流先用 `flutter create` 在临时目录生成 Android 骨架，只把 `android/` 拷回来，
然后用本仓库的 `android_custom/AndroidManifest.xml` 覆盖清单文件。

`android/app/build.gradle(.kts)` **不覆盖**，只由脚本在 `android { }` 块开头
**注入**下面这一段（这是唯一一处必需的改动）：

```kotlin
android {
    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    // ……模板原有内容保持不变
}
```

| 为什么这么做 | 说明 |
| --- | --- |
| **① 必须注入 `useLegacyPackaging = true`** | media_kit 的 libmpv 要求 `.so` 解压到文件系统后才能加载（`media_kit_libs_android_video` 1.0.2 的 CHANGELOG 写着 "perf: enable extractNativeLibs"）。AGP 8 + minSdk≥23 默认**不**解压，libmpv 会加载失败。 |
| **② 不能写在清单里** | 新版 AGP 在 `packageRelease` 任务里会硬报错：`Avoid setting android:extractNativeLibs="true" explicitly in AndroidManifest.xml`。必须改由 Gradle 脚本设置。 |
| **③ 其余一律交给模板** | 模板在 Groovy `build.gradle` 与 Kotlin DSL `build.gradle.kts` 之间来回切；自己维护整套构建脚本必然失效。交给模板维护后，`compileSdk`、`ndkVersion`、`MainActivity` 包名、release 用 debug 签名全部自动正确。 |

> 踩过的坑：早期版本自己维护 `app_build.gradle` + 覆盖 `MainActivity`，
> 结果 Groovy/Kotlin DSL 切换导致覆盖失效、包名与 namespace 不一致导致 App 一启动就闪退。
> 现在这方案把这两类问题一起消除了。

**关于 Flutter 版本**：工作流**锁定 3.47.6**，不用 `latest`。两个理由：

1. `media_kit` 系媒体库要求 `compileSdk 36`，该值由 Flutter 版本决定；
   旧版（如 3.24.x 只给 34）会在 Gradle 阶段直接失败。
2. 3.27 起 `ThemeData.cardTheme` 的参数类型由 `CardTheme` 改为 `CardThemeData`。
   锁住版本可避免被上游变更再次打断。

**APK 产物**：用 `--split-per-abi` 一次产出按 CPU 架构分包的结果 ——
`app-arm64-v8a-release.apk`（近几年手机装这个）与 `app-armeabi-v7a-release.apk`（老机型）。
不要用「先 build 通用包、再 build `--target-platform android-arm64`」，
因为后者输出的文件名仍然是 `app-release.apk`，会把通用包覆盖掉。

如果想走**本地编译**路线（改代码后出包更快），看下面第三节开始的内容。

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
├─ android_custom/                 ★ 需要覆盖到 Android 工程里的文件
│   ├─ AndroidManifest.xml         权限声明（网络、相册、相机等）
│   └─ key.properties.example      正式签名模板（可选）
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

# 4. 用我的清单覆盖 Android 声明（权限、名称、明文流量）
cp studyhub_app/android_custom/AndroidManifest.xml studyhub_app/android/app/src/main/AndroidManifest.xml

# 5. 往 build.gradle.kts 注入 media_kit 必需的打包配置
#    只加这一段，模板原有内容不动（不能写在清单里，新版 AGP 会报错）
python3 - <<'PY'
import os
path = "studyhub_app/android/app/build.gradle.kts"
if not os.path.exists(path):
    path = "studyhub_app/android/app/build.gradle"
src = open(path, encoding="utf-8").read()
assert "useLegacyPackaging" not in src, "已存在，无需重复注入"
inject = ("android {\n"
          "    packagingOptions {\n"
          "        jniLibs {\n"
          "            useLegacyPackaging = true\n"
          "        }\n"
          "    }\n")
new = src.replace("android {", inject, 1)
assert new != src, "未找到 android { 块"
open(path, "w", encoding="utf-8").write(new)
print("已注入 ->", path)
PY

# 6. 清理临时工程
rm -rf studyhub_app_tmp
```

> **更简单的方式**：如果你想少几步，也可以直接 `cd studyhub_app && flutter create --org com.studyhub --platforms=android .`，
> 它会补齐缺失的平台文件（已存在的 `lib/` 和 `pubspec.yaml` 不会被破坏），然后再执行上面的第 4、5 步。

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

---

## 十一、v1.9.0 → v2.0.0 累积改动（最新）

> 本章按功能罗列，从 v1.9.0 一路累加到 v2.0.0。
> **v2.0.0 这一版的新东西**：视频封面自动抽帧（原生 `studyhub/thumb`）、
> 上传任意文件（原生 SAF 通道 `studyhub/files`）、下载站与根目录统一
> 「下载 / 修改 / 上传 / 删除」菜单、虚拟定位「选不到学聚」修复。

### 维护相关
- **版本号一键同步**：`tools/bump_version.py 1.10.0` 自动改 `pubspec.yaml` + `lib/core/constants.dart` 的 `kAppVersion`。
- **CI release 标题从 pubspec.yaml 动态提取**——发版忘改版本号也不会再显示错的。
- **「设置 → 关于」红字强提示**：两处版本号不一致时，App 启动时 assert + 设置页顶部红条。

### 笔记
- AppBar 菜单顺序：列表 / 阅读模式 / 更多（⋮）
- 单页 md（只有一个兄弟节点）也能左右滑切换
- 排序前缀：名称以「数字. 」开头的 md 自动排第一（如 `1.首页.md` 永远在第一位）
- 显示时去掉前缀：`1.首页.md` 列表里显示「首页」
- **md 链接点击跳转**（之前是空回调）：
  - `http(s)://` → 系统浏览器
  - 相对路径 → 拼到当前 md 目录
  - 跳转时取同目录兄弟作为新笔记的左右滑列表

### 服务器下载站
- 顶部 + 按钮：**上传文件** / 新建文件夹
  - v1.9.0+31 起「上传文件」能传**任意类型**（PDF / 压缩包 / apk / Office 文档…），
    而且是**多选**。底层走 Android 自带的文件选择器（SAF，原生通道 `studyhub/files`），
    不需要任何存储权限；原来的相册选图 / 选视频 / 拍照三条路仍然保留。
    （+30 之前只支持图片和视频，因为当时用的是 `image_picker`）
- 右上角文件夹图标：一键进 **StudyHub 根目录**（看全部笔记 / 视频 / 题库 / 速查表 / 备份）。
  +31 起列表里那条重复的大卡片删掉了，只留这个按钮。
- 长按（或进根目录后点右侧 `⋮`）菜单：**下载到手机 / 先下载再分享 / 重命名 /
  编辑文本 / 复制文件直链 / 删除**（文件夹是递归删）
- 操作实现的公用代码在 `lib/ui/tools/server_ops.dart`（[ServerFileOps]），
  下载站和根目录浏览页共用同一套，不会两处走样

### 视频
- 「已锁定」徽标 3 秒后自动隐藏，触屏再呼出

### PDF
- v1.8.0 翻页模式漏放 `SfPdfViewer` 的 bug 修了（之前翻页模式看不到内容）

### 设置
- 「笔记 → 隐藏的文件夹名」可编辑（CSV，默认 `image`，可加 `assets, pic, photos` 等）

### 录音录像（v1.9.0+17）
- **录像默认时长 0 → 60 分钟**：1080p 一分钟约 60 MB，忘了按停止就会吃光存储；
  默认 60 分钟既能录完一节课 / 一场小会，又能走神时及时封顶。
  用户仍可在页面上切到不限或别的档。
- **录像默认摄像头后置 → 前置**：这个工具最常见的场景是录自己的想法 / 口播，
  用前摄自然得多。第一次进入录像页默认就是前摄；用户在页面上「切换」即可换回后摄，
  新值会跟着存下来。

### 维护（v1.9.0+17）
- `bump_version.py` 现在同步改 `kPubspecVersion`，避免启动时 assert 失败。

### 工具（v1.9.0+18 / +22）
- **联网工具的标识从「右上角蓝点」改成「整张卡片描红边」**（+18）：
  原来那个 6×6 的小蓝点扫一眼容易漏掉，1.5 px 红边一眼可辨。
  颜色 `#B23A3A` 比纯红柔和，醒目不刺眼。
  同时清掉：给蓝点多留的 11 px 右边距、Stack 里 Positioned 的小蓝点、说明文案从「蓝色小点」改成「描红边」。
- **按用户截图重排 4 个分类**（+22）：见 `lib/ui/tools/tools_page.dart` 的 categories。
  原则是「最常用 → 较少用」，按日常使用频次排，每个分类只动相对位置，不动绝对成员。
  | 分类 | 重排 |
  |---|---|
  | 测量与设计 | 挂画助手提到第 3；简易画板 / 高级计算 / 单位换算前移到第 2 行；地图坐标 / 指南针 / 配色 / 颜色码后挪到末尾 4 |
  | 网络与编码 | CIDR 子网计算从第 5 提到第 3 |
  | 生活与娱乐 | SOS 手电筒提到第 1；后台录像次之 |
  | 公卫小工具 | Logistic / 实时再生 Rt 前移；食物中毒 / 营养配餐后挪 |

### 题库（v1.9.0+21）
- **简答题转 JSON**：`D:\WorkBuddy\题库转换\convert_essay.py`，把简答题 md → quiz 服务器 JSON
- **题库菜单默认「刷题模式」**：
  进题库的第一项从「顺序练」改成「刷题模式（只看不做）」。
  填空 / 简答题根本没法机判，用户更常把题库当「题书」翻看。
  只含填空 / 问答的题库本来就只有「刷题模式」一个选项（之前已有）。

### 数独 → 数独练习（v1.9.0+19 建，v1.9.0+28 按用户要求重做）
- **9 种主流异形**：标准 / 对角 X / 超 Hyper / 锯齿 / 杀手 / 不等式 / 奇偶 / 连续 / 箭头
- **4 难度**：简单 / 中等 / 困难 / 地狱（地狱额外验唯一解）
- **自动出题**：合法解（Latin Square 洗牌 + 回溯）→ 按难度挖洞
- **+28 改名与重排**（用户逐条点名）：
  - 工具名从「数独」改为「**数独练习**」
  - 删掉选页那一大段「说明」文字
  - 「新题」按钮挪到「题型 / 难度」同一区域（原来在最下面孤零零一个「开始」）
  - 底部按钮改成 5 个：**撤销 / 笔记 / 提示 / 校验 / 答案**
  - **笔记**按钮点一下变色进入笔记模式，再点褪色回普通填数模式
  - 棋盘 padding 压到 2px，格子尽可能大、贴屏幕边
  - 数字盘（宫格数字框）重做：去掉「擦除」按钮、9 个数字排**两排**（1-5 / 6-9）、
    每个数字右下角带**剩余个数角标**（放满变 ✓）、整体贴屏幕边、按钮随屏宽自适应
  - 想清一格：**再点一次同一个数字**，或**长按格子**
  - **校验**：跟出题解逐格比，错的格标红并统计处数
  - **答案**：确认后填入完整解（本局不再计分）
- **+28 修的两个真 bug**：
  - 笔记模式下笔记与数字叠在一起 → 落子后端内笔记清空
  - **锯齿数独看不到锯齿**：`_JigsawPainter` 里每段宫界线都套了
    `if (!filledMask[r][c])`，只要那格有提示数字就整条边不画；开局 30~50 格是提示，
    于是锯齿宫几乎全被吃掉、看起来跟标准 9 宫一样。宫界线本来就在格**边**上、
    压不到居中的数字，改成直接全画。
- 文件 `lib/ui/tools/tool_pages_sudoku.dart`（~2100 行）

### 路路词典（v1.9.0+20 建 → v1.9.0+28 移出 App → v2.0.0+35 重写成真词典）
- **已从 App 内下架**，改为**网页版小工具**：`网页版小工具/路路词典.html`
  （同时登记在 `网页版小工具/index.html` 的「生活与娱乐」分类）
- **v2.0.0+35 整个重写**：不再内置小词库，改成查**自己导入的词典文件**，
  纯本地、不联网：
  - ✅ 支持 `.mdx`（MDX v1.2 / v2.0，zlib / lzo / 无压缩三种块压缩全支持）、
    `.mdd`（释义里的 css / 图片 / 发音音频按需解压）、
    `.tar.gz / .tgz / .gz`（自动解包取出里面的 mdx / mdd）
  - ❌ `.eudic` / `.ld2` / `.bgl` 是欧路等软件的**闭源格式、无公开文档**，
    浏览器解析不了（页面里也写明了）；同名词典几乎都有 mdx 版
  - 词典文件存浏览器 **IndexedDB**（几百 MB 也放得下），导入一次以后直接用；
    换浏览器 / 清数据需要重新导入
  - 功能：精确查词（同词多条全出）、输入联想（前缀二分）、生词本、查词历史
    （localStorage）、多词典同查、释义用 iframe 隔离渲染（词典 css 不污染页面）
  - 实现要点（改它之前先看）：
    * 全部整数字段是 **big-endian**；v2.0 用 8 字节整数、v1.2 用 4 字节；
      key index 在 v2.0 有 `"2000"` 魔数 + adler + zlib 包装，v1.2 不压缩
    * 块压缩类型：0=无 1=lzo 2=zlib；lzo 是裸 LZO1X 流（无 0xF0 文件头）
    * LZO 解压内嵌 **MIT 许可的 clean-room 纯 JS 实现**（npm `lzo1x@1.0.1`，
      只取解压部分）；zlib / gzip 用浏览器原生 `DecompressionStream`
      （`'deflate'` 就是 zlib 包装）
    * ⚠️ 内嵌解压器把原包 `extra > 262144` 的长度防护放宽到了 64MB ——
      原值太保守，大块连续重复数据（mdd 里的全零填充）会被误杀
    * key block 里的词条：`[u64 recordOffset][keyText][\0]`，UTF-16 词典按 2 字节对齐切
- App 侧删除文件：`lib/ui/tools/tool_pages_dict.dart`（约 990 行），
  并从 `tools_page.dart` 移除入口与分发分支
- 注意：`lib/ui/tools/dict_view.dart` **不是**这个词典，它是「翻译」工具的一部分，保留

### 虚拟定位（v1.9.0+28 新增，+32 修「选不到」）
- 归类：**生活与娱乐**；文件 `lib/ui/tools/tool_pages_mockloc.dart`
- 原生通道 `studyhub/mockloc`（`android_custom/MainActivity.kt`）：
  - `status` → 权限 / **是否已被选为模拟位置应用** / 是否运行中 / 当前模拟坐标
  - `requestPermission` → 申请 `ACCESS_FINE_LOCATION`（清单里本来就有，指南针在用）
  - `start` / `stop` → `LocationManager.addTestProvider` +
    `setTestProviderLocation`，**每秒刷新一次**（很多 App 会丢弃时间戳过期的定位）
  - `realLocation` → `getLastKnownLocation`（做「以我当前定位为起点」）
  - `openDevOptions` → 跳系统「开发者选项」
- **硬前提**：Android 只允许「被选为模拟位置信息应用」的 App 改定位，
  路径「设置 → 开发者选项 → 选择模拟位置信息应用 → 学聚」。
  没选就点开始 → 原生抛 `SecurityException`，页面把原因原文显示出来并提示怎么开。
- **+32 修「开发者选项的列表里根本没有『学聚』」**（用户实际遇到的）：
  那个列表筛的是「**清单里声明过 `ACCESS_MOCK_LOCATION` 的应用**」——
  AOSP 的 `MockLocationAppPreferenceController` 会遍历所有已安装应用的
  `requestedPermissions` 找这一条。清单里没写 → 用户永远选不到 → 虚拟定位永远启不起来。
  修法：`android_custom/AndroidManifest.xml` 里补
  ```xml
  <uses-permission android:name="android.permission.ACCESS_MOCK_LOCATION"
      tools:ignore="ProtectedPermissions" />
  ```
  这条权限本身**拿不到**（protectionLevel = signature），它纯粹是一张「报名表」，
  所以用 `tools:ignore` 关掉 lint 的「受保护权限」提示。装完**重开一次**开发者选项即可看到。
- **+32 页面直接显示选中状态**：原生读 `AppOpsManager.OPSTR_MOCK_LOCATION`
  （`unsafeCheckOpNoThrow`，API 29+；老版本用 `checkOpNoThrow`）判断「已选中 / 未选中」，
  绿色 / 橙色两条提示实时切换；页面还监听 `AppLifecycleState.resumed`，
  从开发者选项切回来会自动重读，不用手动刷新。
  未选中时点「开始模拟」会先弹对话框问「去设置吗？」，也留了「仍然尝试」（个别定制 ROM 的 AppOps 读不准）。
- 页面提供 10 个常用地点预设（天安门 / 人民广场 / 广州塔 / 市民中心 / 西湖 / 黄鹤楼 …）
- 说明：部分 App 用高德 / 腾讯定位 SDK 且做校验，可能不受影响（正常现象）；
  重启手机后模拟自动失效

### 通话记录生成（v2.0.0+37 新增）
- 归类：**生活与娱乐**；文件 `lib/ui/tools/tool_pages_calllog.dart`
- 原生通道 `studyhub/calllog`（`android_custom/MainActivity.kt`）：
  - `status` → 是否有 `WRITE_CALL_LOG` / `READ_CONTACTS` + 双卡信息
  - `requestPermissions` → 一次性申请上面两个 dangerous 权限
  - `contacts` → 读通讯录（姓名 + 号码，最多 3000 条，号码里非数字字符已剥掉）
  - `sims` → `SubscriptionManager.activeSubscriptionInfoList`（拿不到就返回空）
  - `insert` → 批量写 `CallLog.Calls`（子线程 + `Handler` 回主线程）
- 界面参数：
  - 呼出（默认）/ 呼入；接通（默认）/ 未接
  - **号码**：文本框一行一个（逗号/分号也认，自动去重）+ 「从通讯录导入」（带搜索的多选）
  - **通话时间**：第一条的时间，点日期按钮选（默认当前时间）
  - **通话间隔**：区间随机，默认 1~3 分钟
  - **通话时长**：区间随机，默认 30~60 秒（未接固定 0 秒）
  - **拨号卡**：检测到 ≥2 张卡才出现，可选卡1/卡2/默认卡
- 类型映射（Android 只有三种：1 呼入 / 2 呼出 / 3 未接）：
  - 呼出+接通 → 2，呼入+接通 → 1，呼入+未接 → 3
  - **呼出+未接 → 2 且时长 0**（Android 没有「呼出未接」这个类型，界面上写明了）
- 注意：`phone_account_id` / `simid` 不是公开 API，部分 ROM 会忽略 →
  记录能写进去，只是卡1/卡2 的标签可能不显示

### 水印相机（v2.0.0+37 新增）
- 归类：**生活与娱乐**；文件 `lib/ui/tools/tool_pages_watermark.dart`
- 原生通道 `studyhub/camera`：
  - `location` → 取一次定位（先 `getLastKnownLocation`，没有就注册更新，10 秒超时）
  - `geocode` → `Geocoder` 逆地理编码（子线程，失败返回空串）
  - `saveImage` → 存相册（Android 10+ 走 `MediaStore` + `RELATIVE_PATH=Pictures/学聚水印`，
    **不需要存储权限**；9 及以下用老的 external 目录）
- 模板（配色 / 标题条不同）：工作、生活、安全生产（白底红条）、培训、自定义
- 水印字段（可勾选）：时间（默认当前，可改）、地点（定位 / 手输）、经纬度、海拔、备注
- 地图小图：勾选后**右上角**出现 220×220 小图，底图用 OpenStreetMap 单张瓦片（z=15），
  中间叠定位针；没网自动降级成坐标网格（不会白块）
- 位置：左下（默认）/ 左上 / 右下 / 右上
- 入口：**拍照**（系统相机，拍完直接进编辑页）/ **选照片**（可多选，批量盖同一套水印）
- 合成方式：编辑页里 `FittedBox` 内放 **1080 逻辑宽**的固定画布，
  外面套 `RepaintBoundary`；保存时 `toImage(pixelRatio: 1.5)` → PNG → 原生存相册。
  这样预览和成片是同一套布局，所见即所得；输出约 1620px 宽
- 批量保存：逐张切图 → 等 `endOfFrame` + 120ms（让图片解码和地图瓦片就位）→ 截图保存，
  底部显示「正在处理 i / n」
- 编辑页底部六个 chip 可随时改：时间 / 地点 / 备注 / 位置 / 模板 / 字段开关

### 视频 / 图片浏览（v1.9.0+27 建，+28 / +30 扩展）
- **自动缓存缩略图**：列表 + 平铺缩略图都走 `CachedNetworkImage`
  （项目已有的 `cached_network_image`），内存 + 磁盘双层缓存，第二次进目录瞬间出
- **平铺模式（grid）**：AppBar 右上角切换按钮（grid_view ↔ view_list）
  - +28：视频目录也开放（原来只对有图片的目录显示按钮）
  - +30：**所有目录都给按钮**。原条件是 `_dirEntries.any((e) => !e.isDir)`
    ——「目录里必须有一个文件」才显示，纯子文件夹的目录就没按钮；
    现在只要目录里有内容就显示（纯文件夹目录铺开就是一格格文件夹）
- **双指捏合缩放**：范围 **50~200 px**，`SliverGridDelegateWithMaxCrossAxisExtent` 自动算列数；
  单指时 `d.scale` 恒为 1，不影响点击 / 长按
- 文件 `lib/ui/media/media_page.dart`

### 视频封面：自动抽帧（v1.9.0+30 新增）
以前视频在列表和平铺里只有个胶片图标，长得一模一样、完全分不出哪个是哪个。
现在**每个视频都自动抽一帧当封面**，不需要用户点任何东西。

- **在哪儿抽**：原生。`android_custom/MainActivity.kt` 新增 `studyhub/thumb` 通道，
  用 Android 自带的 `MediaMetadataRetriever`。
  - 它支持**直接吃 `http(s)` 地址 + 请求头**，正好带上 WebDAV 的 Basic Auth，
  - 所以**不用先把整个视频下载到本地**，省流量也省等待。
  - 必须在**子线程**跑：主线程发网络请求会抛 `NetworkOnMainThreadException`，
    而且抽帧是同步阻塞的，放主线程会把列表卡死。
  - 取的是「时长的 **10%**」那一帧，不是第 0 帧 —— 视频开头往往是黑场 / 台标 /
    版权页，拿第 0 帧当封面基本全黑，等于白做。
  - API 27+ 走 `getScaledFrameAtTime` 直接拿缩放好的位图，
    省掉一次 `createScaledBitmap` 的大内存分配（4K 视频一帧就是 30 MB）。
- **在哪儿缓存**：`lib/data/local/video_thumb.dart` 的 `VideoThumbCache`。
  抽完落成 `<应用支持目录>/vidthumb/<md5(路径)>.jpg`，质量 75、宽 320px，
  一张 10~20 KB。第二次进同一个目录直接读文件，一行网络请求都不发。
  - 文件名用 **md5** 而不是原路径：路径里有 `/`、有中文、可能还有 `%` 转义，
    在 Android 上直接拿去当文件名会创建失败。
  - 先写 `.tmp` 再 `rename`：直接写目标文件的话，写到一半被打断
    （用户退出 / 进程被杀）会留下 0 字节坏文件，下次还得重抽。
- **三重去重**（`_inflight` / `_done` / `_failed`）：列表滚动时 `itemBuilder`
  会对同一格反复构造，没有去重就会对同一个视频发 N 次请求。
  `_failed` 也必须记 —— 否则每次 rebuild 都会对「抽不出来」的视频再试一次。
- **失败静默降级**：抽不到就继续显示原来的胶片图标，用户完全无感。
  抽帧失败的原因太多了（mkv / rmvb 老容器、服务器不支持 Range、网络抖动、
  编码不支持……），任何一个都不该让视频列表变慢或报错。
- **并发上限 2**：一屏十几个视频不限并发会把网络 + 解码同时拉满，
  反而拖慢列表滚动。
- **重试机会**：一次网络抖动会把某个视频永久打成「没封面」，
  所以挂在**用户主动刷新**（下拉刷新 / 点右上角刷新）上给一次重来的机会 ——
  既不会自己反复重试烧流量，又不至于只能靠重启 App 恢复。
- **清理缓存**：设置页「一键清理缓存」会连封面一起清（封面是纯缓存，
  删了下次进目录自动重抽，不影响任何数据）。
- **三处都在用**：视频浏览页的**列表**行、**平铺**格子，以及播放页的**选集**面板。
  平铺 / 列表的封面右下角都叠了一个小 ▶，一眼区分「这是视频」而不是「这是一张图」。

### 笔记（v1.9.0+28 追加修复）
- **索引 md 排序**：文件名以「数字.」开头的（`000.绳结总目录.md`、`1.首页.md`）
  排最前；`index` / `README` / `目录` / `总目录` / `索引` / `首页` / `大纲` 这类
  索引名次之；**两者都排在子文件夹前面**。见 `lib/core/sort_utils.dart` 的 `_pinRank()`。
- **v2.0.0+38：目录不再参与置顶**。原本「数字.」前缀对文件夹也生效，而笔记库里
  的子文件夹往往同样叫 `01.xxx` / `02.xxx`，于是两边同为「2 档」，接着又被
  「目录优先」规则顶回去，置顶 md 白排。现在 `_pinRank()` 只对**文件**计算，
  目录一律记 0 档，最终顺序固定为：
  **置顶 md（数字. 前缀） → 索引类 md（index/目录/首页…） → 子文件夹 → 其它文件**。
  文件夹之间、普通文件之间仍按名称（自然排序）/ 时间 / 大小排。
- **单屏短文档左右划不翻篇**（修的 bug）：原来用 `GestureDetector.onHorizontalDragEnd`，
  但正文里 `SelectableText` / `SelectionArea` 在手势竞技场里更深，横向拖动被它抢去当
  「拖动选字」，外层收不到回调；内容一屏放得下时必挂。
  改用 `Listener` 收**原始指针事件**（不进竞技场，谁来抢都能拿到），
  自己算位移 + 时长：600ms 内、横移 ≥ 80px 且横向占优 → 翻篇；长按 / 慢拖不算。
- **md 里的 `<br>` 不再显示成字面量**：knots3d 的表格用 `<br>` 换行，
  `flutter_markdown` 不渲染行内 HTML，会原样显示 `<br>`；读前统一替换成换行符。
- **knots3d 图片全挂（百分号二次编码）**：`flutter_markdown` 吐出的 uri 已经百分号编码过
  （`%E5%95%...`），再经 WebDAV `encodePath` 的 `Uri.encodeComponent`，`%` 又被编成 `%25`
  → 服务器 404，全部报「图片加载失败: %25E5%2595%...」。
  修法：`note_repo` 里先 `Uri.decodeComponent` 还原一次，再统一编码。

### 服务器下载站 + 根目录浏览（v1.9.0+29 / +31）
- 右上角文件夹图标：「**进入 StudyHub 根目录**」——点开能看到服务器上全部内容
  （`notes` / `media` / `quiz` / `tools` / `download` / `backup` 六个目录），
  再逐层点进去翻文件；左上角返回上一层。
  **+31 起列表顶上那条重复的大卡片删掉了** —— 顶栏已经有按钮，下面就不必再来一遍。
- 实现：把「服务器速查表」那套浏览页（`ServerFilesPage`）抽成可传起点，
  新增 `rootPath` / `titleOverride` 两个参数，传 `rootPath: ''` 就是从根目录开始。
  顺带修了它原来写死 `AppDirs.tools` 的前缀切片、并补了「返回上一层」按钮。
- **+31：根目录里每一条都有完整菜单**（用户要求「进去之后所有目录、文件都要有
  下载 / 修改 / 上传 / 删除」）：
  - 把下载站那套操作整体抽到 `lib/ui/tools/server_ops.dart`（`ServerFileOps`），
    两个页面共用 —— 不会再出现「一边改了另一边忘了改」；
  - 每个条目右侧 `⋮`（长按同效）→ 下载到手机 / 先下载再分享 / 重命名 /
    编辑文本 / 复制直链 / 删除；
  - 顶栏 `+` → 上传文件 / 新建文件夹，作用在**当前所在目录**；
  - 文件点击不再一律进纯文本页：按类型分派（文本 → 文本页、pdf → PDF 阅读器、
    图片 → 大图查看、音视频 → 播放器、其它 → 直接下载）。
- **+31：上传能选任意类型的文件了**。原来只有「相册图片 / 相册视频 / 拍照」三条路，
  PDF、压缩包、安装包根本传不上去。现在多一条「**选任意文件**」（置顶），
  走 Android 自带的系统文件选择器（SAF），**支持多选、且不需要任何存储权限**。
  实现是原生新通道 `studyhub/files`（见第十三章的原生能力清单）。

### 修编译（v1.9.0+29）
- **虚拟定位的原生 `addTestProvider` 少传了一个参数**，CI 报
  `MainActivity.kt:1449 None of the following candidates is applicable`：
  这个重载要 **10 个参数**
  （name + requiresNetwork / requiresSatellite / requiresCell / hasMonetaryCost /
  supportsAltitude / supportsSpeed / supportsBearing + powerRequirement + accuracy），
  上一版只传了 9 个（漏 `supportsBearing`），于是 `Int` 被当成 `Boolean` 用，编译失败。
- 教训：Kotlin 的重载报错信息会把**所有候选签名**列出来，
  数一下参数个数比读报错文字快得多。

### 设置（v1.9.0+28）
- 删掉「README · 项目自述」入口（首页已有）
- 删掉「v1.9.0 更新内容」整块卡片（改动清单见本 README 第十一章）

### 修编译（v1.9.0+23 / +24 / +25 / +26）
- **+19 数独一口气 1700+ 行没跑 dart analyze 就 push**，导致
  +19 / +20 / +21 / +22 / +23 5 个连续 commit 全在「编译 APK」步骤失败。
- **+23 修了 5 个数独编译错**
  (`SudokuBoard.cageId/cages/relationMark` 改 mutable；
  `EvenOddRules.evenOdd` 改 mutable；
  `ArrowRules.arrows` 从 `List<List<List<int>>>` 改成 `List<ArrowDef>`；
  overlay 函数签名收成基类 `SudokuRules` + 内部 `is Type` 收窄；
  `full.height` 改 `_type.height`)；
- **+24 修了 4 个 +20~+22 漏掉的编译错**
  (路路词典的 `_DictPageState` 写重了 `initState`，删一个；
  `DictBook.size` 改 mutable（手动加词条要 `size++`）；
  词库 chip 从 `ChoiceChip` 换成 `InputChip`（前者没 `onDeleted`）；
  工具红边 `Border.all(...)` 改成 `BorderSide`，给 `RoundedRectangleBorder.side` 喂类型；
  数独 `_SudokuGrid.build` 里 `(rules).arrows` 去掉括号让 Dart 类型 promote 生效)。
  但 Dart 4+ 把 `(rules).x` 拆开仍然不 promote（public final field + 短路求值的字段访问不收窄），
  编译报 `SudokuRules has no arrows getter`。
- **+25 把箭头那段改成嵌套 if**
  (`if (rules is ArrowRules) if (rules.arrows.isNotEmpty) _arrowOverlay(...)`，
  Dart 在内层能认出 `rules` 是 `ArrowRules`)，但 Dart 3.47.6 对 public final field
  + 嵌套 if **仍然不 promote**，仍然报 `SudokuRules has no arrows getter`。
- **+26 用 `(rules as ArrowRules).arrows` 强制 cast**
  ——不优雅但**确定能编译**，避免再 round-trip CI。CI 跑过出 release。

---

## 十二、数据来源（license & 怎么更新）

| 数据 | 来源仓库 | License | 怎么更新 |
|---|---|---|---|
| 区划码 `assets/data/id_region.json` | https://github.com/yescallop/areacodes | CC0 | 直接 `curl` 它的 `data/2025.txt` 覆盖 / 用 `tools/build_id_region.py` 重建 |
| 拼音排序表 `assets/data/pinyin_sort.txt` | https://github.com/mozillazg/python-pinyin | MIT | 用 `.workbuddy/gen_pinyin.py` 重新生成 |
| 翻页时钟字体 | 思源宋体/方正免费字体 | OFL | 替换 `assets/fonts/` 下的 `*.ttf` 即可 |

### 身份证区划码维护流程（小白友好版）

1. **yescallop/areacodes 还在更新**（最常见情况）
   - 进 https://github.com/yescallop/areacodes/blob/master/codes.json 看是否更新
   - 下载最新 codes.json，覆盖到 `studyhub_app/assets/data/id_region.json`（**格式完全一样**）
   - 同步覆盖到 `网页版小工具/id_region.json` 和 `id_region_data.js`（**这两个文件内容相同**）
   - 重新跑 `python tools/build_id_region.py` 生成带历史码的版本
   - Excel 版 `身份证户籍地批量匹配.xlsx`：从新 `id_region.json` 重新生成
2. **yescallop 不更新了**（备用）
   - 进国家统计局 http://www.stats.gov.cn/sj/tjbz/qhdm/ 看最新县及县以上的区划码
   - 把统计局的码表改成 `code  name` 格式（每行空格分隔），放到 `studyhub_app/assets/data/id_region.json`
   - 跑 `tools/build_id_region.py` 加历史码

---

## 十三、内置工具 / 资料放在哪（小白友好版）

```
studyhub_app/
├── lib/
│   ├── core/                  通用工具（自然排序、设置常量、版本号）
│   │   ├── constants.dart     全局常量 + AppDirs（服务器目录结构） + kAppVersion
│   │   ├── sort_utils.dart    排序逻辑（带「数字. 前缀置顶」）
│   │   └── utils.dart         baseName / joinPath / stripLeadingNumber 等
│   ├── data/
│   │   ├── dav/               WebDAV 客户端（增删查、上传、移动）
│   │   ├── local/             本地数据库 + 设置存储
│   │   ├── models/            题目、笔记、收藏等数据模型
│   │   └── repositories/      笔记/题库/视频仓库
│   ├── ui/
│   │   ├── home/              首页 + 设置页
│   │   ├── notes/             笔记阅读 / 编辑 / 导出
│   │   ├── quiz/              题库 + 答题
│   │   ├── tools/             工具页 + 服务器小工具入口
│   │   ├── media/             视频 / 图片播放
│   │   └── common/            通用组件（PDF 预览、文件选择等）
│   └── main.dart              入口：初始化媒体/数据库/拼音
├── assets/
│   ├── data/                  数据文件（区划码 json、拼音表）
│   ├── fonts/                 字体
│   ├── icons/                 图标
│   └── sounds/                提示音
├── tools/
│   ├── bump_version.py        改版本号脚本（v1.9.0 新增，同步 pubspec + kPubspecVersion）
│   └── build_id_region.py     构建区划码数据
├── android_custom/            Android 清单 + MainActivity.kt（原生能力都在这）+ 图标覆盖层（CI 用）
├── pubspec.yaml               依赖 + 版本号（version: 1.9.0+30）
└── .github/workflows/
    └── build-apk.yml          CI 编译流程
```

**原生能力清单**（都写在 `android_custom/MainActivity.kt`，CI 会覆盖到 `android/`）：
| 通道 | 用途 |
|---|---|
| `studyhub/display` | 真实物理 DPI、锁横屏 / 竖屏 / 跟随系统 |
| `studyhub/location` | 定位持续推送（指南针） |
| `studyhub/recorder` | 后台录音（前台服务） |
| `studyhub/videorec` | 后台录像（Camera2 + MediaRecorder，前台服务） |
| `studyhub/audio` | 音量 / 音频相关 |
| `studyhub/mockloc` | **v1.9.0+28 新增**：定位权限、模拟位置注入、真实定位、打开开发者选项 |
| `studyhub/thumb` | **v1.9.0+30 新增**：视频封面抽帧（`MediaMetadataRetriever`，支持 http(s) + 请求头，子线程） |
| `studyhub/files` | **v1.9.0+31 新增**：系统文件选择器（SAF，`ACTION_OPEN_DOCUMENT`）选任意类型文件、可多选；把 `content://` 内容复制到 App 缓存后返回真实路径给 Dart |
| `studyhub/calllog` | **v2.0.0+37 新增**：通话记录（权限 / 通讯录 / 双卡 / 批量写 `CallLog.Calls`） |
| `studyhub/camera` | **v2.0.0+37 新增**：水印相机辅助（存相册 / 取一次定位 / 逆地理编码） |

**修改内置工具的位置**（按你的图重排时改这里）：
- 工具分类 + 顺序 + 名称：见 `lib/ui/tools/tools_page.dart`（`_Category` 列表）
- 每个工具的入口：见 `lib/ui/tools/tools_page.dart` 底部的 `switch (tool)` 分发
- **服务器下载站**（不是内置，是动态从 WebDAV 拉的）：`lib/ui/tools/download_site_page.dart`
- **服务器文件的增删改（下载 / 上传 / 重命名 / 编辑 / 删除）**：`lib/ui/tools/server_ops.dart`
  —— 下载站和「StudyHub 根目录」浏览页共用这一套，两处不会再走样
- 👉 **更详细的分行号速查表见第十六章**

**修改服务器小工具**：
- 服务器路径：`/StudyHub/tools/<子目录>/<工具名>.html`
- 显示顺序：按名称前缀数字排（如 `1.字典.html`、`2.数独.html`），显示时自动剥掉前缀

**网页版小工具（仓库外，电脑 / 手机浏览器直接用）**：
- 目录：`D:\WorkBuddy\StudyHub\网页版小工具\`（41+ 个 `.html`，不在 git 里）
- 新增一个工具要做两件事：写 `工具名.html`（照抄 `_模板.html` 的 CSS 变量）+ 在 `index.html` 的对应分类里加一条 `<a class="tool">`
- v1.9.0+28 新增 **`路路词典.html`**（原 App 内嵌词典移到这里，功能对齐 + 词库/生词本/历史存 `localStorage`）
- **坑**：这个目录里的 `*.html` 用 Python 脚本**写不进去**（PermissionError），要用编辑器 / 本助手直接写文件
- 详见 `lib/core/utils.dart` 的 `stripLeadingNumber` 和 `lib/core/sort_utils.dart` 的 `_isPinnedName`

---

## 十四、服务器目录规范（小白友好版）

**WebDAV 根目录** = App 登录时填的服务器根；通常就是 `/`。

**App 预期目录**（都建在登录根目录下）：

```
<根目录>/
  ├─ StudyHub/                 ← 资料主目录
  │  ├─ notes/                 笔记
  │  │  ├─ Python-100-Days/   ← 一套笔记
  │  │  │  ├─ 1.首页.md        ← 索引类 md 名称前缀加「数字. 」，自动排第一位
  │  │  │  ├─ 01.基础/         ← 子目录就是分类
  │  │  │  │  └─ *.md
  │  │  │  └─ image/           ← 配图目录（默认隐藏，App 不显示）
  │  │  └─ knots3d/
  │  ├─ media/                 视频 / 图片
  │  ├─ quiz/                  题库（每个子目录 = 一套）
  │  ├─ tools/                 服务器小工具（HTML）
  │  │  ├─ 1.数独.html
  │  │  ├─ 2.单位换算.html
  │  │  └─ 3.某分类/
  │  │     └─ 1.某工具.html   ← 嵌套也支持
  │  ├─ backup/                App 自动写错题本和笔记备份
  │  └─ download/              服务器下载站
```

**隐藏目录**：在「设置 → 笔记 → 隐藏的文件夹名」里输入逗号分隔的文件夹名（默认 `image`，可加 `assets, pic, photos`）。

**排序规则**：
- 目录/工具名称以「数字. 」（如 `1.`, `2.`, `01. `）开头 → 自动排第一
- 显示时**自动去掉前缀**（用户看到的是「数独」而不是「1.数独」）
- 不加前缀就按电脑的「自然排序」（数字按大小、中文按拼音）

### 目录适配（v2.3.4）：notes 还能叫别的名字

老版本只认 `notes / media / quiz / tools / download / backup` 这 6 个英文名，
服务器上叫「文档笔记」就整个读不到。v2.3.4 起 App 登录时会先列一遍根目录，
自己认出每个逻辑目录对应哪个真实文件夹，**你按自己的习惯命名就行**：

| 逻辑目录 | 认得的真实名（英文不分大小写，前面的序号自动忽略） |
|---|---|
| `notes` 笔记 | notes / note / document / documents / doc / docs / 笔记 / 文档 / 文档笔记 / 记事 / 记事本 |
| `media` 视频图片 | media / video / videos / movie / movies / 视频 / 图片 / 视频图片 / 音视频 / 影音 / 媒体 |
| `quiz` 题库 | quiz / quizzes / exam / 题库 / 刷题 / 题库刷题 / 题目 / 试题 |
| `tools` 小工具 | tools / tool / 工具 / 软件工具 / html工具 / 小工具 / 资源 |
| `download` 下载 | download / downloads / 下载 / 文件下载 / 下载站 |
| `backup` 备份 | backup / backups / 备份 |

所以 `1 文档笔记`、`2 视频图片`、`3 题库刷题`、`4 软件工具`、`5 文件下载`
这类带序号的文件夹名也直接能用。

**匹配顺序**（先命中先得，一个文件夹只归一类）：
1. 和逻辑名完全一致（`notes`）→ 优先用标准的
2. 去掉序号前缀（`1 `、`(2)`、`01-`、全角数字、全角空格）后与某个别名**完全一致**
3. 还不行就退一步：去掉前缀后**包含**某个别名，长别名优先
   （这样「文档笔记」不会被「文档」抢走）

**实现位置**：`lib/core/constants.dart` 的 `AppDirs.aliases` / `resolveFolders()` /
`normalizeFolder()`，以及 `lib/data/dav/webdav_client.dart` 的 `_ensureFolders()`。

**为什么不用改四十多处拼路径的代码**：App 内部（包含记在手机数据库里的路径）
一律用逻辑名 `notes/xxx.md`，只有真发请求时 `_absolute()` 才换成服务器上的
`1 文档笔记/xxx.md`；列目录回读时 `_hrefToRel()` 又换回逻辑名。
所以**服务器改目录名不会让本机的笔记记录、阅读进度失效**，也不用重新登录。

> 认不出来时按默认名走（不会让 App 打不开）；换了服务器 / 退出登录会清掉映射重认。

---

## 十五、维护时容易踩的坑（小白必看）

1. **改版本号必须两处同步**
   - `pubspec.yaml` 的 `version: X.Y.Z+N`
   - `lib/core/constants.dart` 的 `kAppVersion = 'X.Y.Z'`
   - 或者跑 `python tools/bump_version.py 1.10.0` 一次同步

2. **不要用 `TextStyle(12)` 这种位置参数**
   - Flutter 几乎所有组件都是**命名参数构造器**
   - 错：`TextStyle(12)` → 对：`TextStyle(fontSize: 12)`
   - lint 不抓，只有编译抓

3. **不要用 file_picker（任何版本）**
   - 8.x → AAR 内部用 android-34 编译，外部怎么改 compileSdk 都救不了
   - 6.x → 用已删除的 v1 Android Plugin API
   - 图片 / 视频上传用 `image_picker`；
     **任意类型文件**用系统文件选择器 SAF（自己写原生，通道 `studyhub/files`）。
     SAF 还给两个额外好处：不需要存储权限、天然支持多选。
     注意 SAF 交出来的是 `content://` URI，Dart 的 `dart:io` 读不了 ——
     必须先在原生侧把内容复制到 App 缓存目录，再把真实路径递给 Dart。

4. **`setState(() { ... })` 内部不能 `await`**
   - setState 回调是 VoidCallback 不是 async
   - 先 `final x = await ...;` 拿到值再放进 setState

5. **新加的依赖要测试编译**
   - Flutter 3.47.6 默认 compileSdk 35，**很多新插件要求 36**
   - 改 SDK 版本要改 Flutter SDK 而不是 build.gradle

6. **CI 已经做的自动注入**
   - `minSdk` 自动抬到 ≥ 24（写在 `.github/workflows/build-apk.yml`）
   - `useLegacyPackaging = true`（libmpv 加载需要）
   - **不要**自己改 `android/app/build.gradle` 之外的事

7. **CI 触发条件**：`main` 分支 push 自动编译 + Release。**别在 release tag 上 push**，会让 Release 重复。

8. **Dart 的类型 promote 在字段访问上不生效**（v1.9.0+23~+26 连踩 4 轮）
   - `if (rules is ArrowRules && rules.arrows.isNotEmpty)` → 报 `SudokuRules has no arrows getter`
   - `(rules).arrows` 去掉括号、嵌套 `if` —— **都不 promote**
   - 唯一稳的写法：`(rules as ArrowRules).arrows` 强制 cast
   - 结论：**派生类独有字段不要写在 `is` 判断的同一表达式里**

9. **`SelectableText` / `SelectionArea` 会抢横向拖动**（v1.9.0+28）
   - 需要在可选中文字上做「左右滑翻页」时，别用 `GestureDetector.onHorizontalDragEnd`
   - 用 `Listener.onPointerDown / onPointerUp` 自己算位移 + 时长（列表：`note_read_page.dart`）

10. **WebDAV URL 不要二次编码**（v1.9.0+28）
    - `flutter_markdown` 给的 uri 已是百分号编码；再经 `Uri.encodeComponent` 会变成 `%25`
    - 处理相对图片路径前，先 `Uri.decodeComponent` 还原一次（`note_repo._normalizeSrc`）

11. **CustomPainter 的 `filledMask` 截断陷阱**（v1.9.0+28）
    - 锯齿数独的宫界线原来「格子有数字就不画」，结果开局提示一多，**整个锯齿宫消失**
    - 边界线画在**格子边**上，不会压到居中数字；除非真会遮挡，否则别做截断

12. **前置摄像头录像不要额外 `+180°`**（v1.9.0+28）
    - `MediaRecorder.setOrientationHint` 用 `SENSOR_ORIENTATION` 原值即可（后摄 90 / 前摄 270）
    - 自己再加 180 会让前摄录出来是倒的（镜像由显示层处理）

13. **模拟位置需要用户在开发者选项里授权**（v1.9.0+28 虚拟定位）
    - `LocationManager.addTestProvider` 在未被选为「模拟位置信息应用」时抛 `SecurityException`
    - 代码必须把这条原因展示给用户，并给一个「打开开发者选项」的按钮
    - **+32 补充：还得先在清单里声明 `ACCESS_MOCK_LOCATION`**，
      否则开发者选项那个列表里**根本不会出现本应用**（用户报的就是这个）。
      这条权限拿不到（signature 级），纯「报名」，配 `tools:ignore="ProtectedPermissions"`。
      判断「选没选中」读 `AppOpsManager.OPSTR_MOCK_LOCATION`。
      参考：[AOSP `MockLocationAppPreferenceController`] 遍历已安装应用的
      `requestedPermissions` 来筛候选应用

14. **改完大文件先自检再 push**
    - 数独一次 1700 行没跑 analyze，导致 5 个 commit 连续编译失败
    - 本地没有 Flutter SDK 时，至少 `grep` 复核：重复的 `initState`、final 字段被赋值、
      `Border.all` 喂给 `side`、`List<int>.fill(0)` 这类不存在的 API

15. **写公共目录（下载等）必须主动带用户走权限**（v2.0.0+35）
    - `permission_handler` 的 `Permission.manageExternalStorage.request()` 在很多
      ROM 上**只返回 denied、不跳任何页面** —— 用户根本没机会授权，
      表现就是「下载目录改不了 / 下载失败」
    - 修法：原生 Intent 直达本 App 的开关页
      （`ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` + `package:` uri，
      见 `MainActivity.kt` 的 `studyhub/files` 通道 `openAllFilesAccess`），
      跳完弹「我已开启」确认框再复查权限
    - 授权时机放在**用户主动保存下载目录**时（探针失败 → 申请 → 复查 → 再探针），
      不要放进下载热路径（突然跳系统页太打断）

16. **改内置工具名必须同步改 `case`**（v2.0.0+35 修）
    - `tools_page.dart` 里 `_ToolDef('名字', …)` 和底部 `switch (name)` 的
      `case '名字':` 是**两处独立的名字**，只改一处 → 落进 default，
      点开提示「还没做好」
    - 现在 default 会直接显示对不上的名字，一眼定位漏配了哪个
    - 验证方法：`grep -oE "_ToolDef\\('([^']+)'" tools_page.dart` 和
      `grep -oE "case '([^']+)'"` 的名单 diff 一下必须为空

17. **发版自动同步到 Gitee**（v2.0.0+40 新增；+45/+46 换过一次上传方式；
    **v2.3.3+58 彻底改成「发行版附件」**）
    - 位置：`.github/workflows/build-apk.yml` 里**独立的 `gitee` job**
      （不在 `build` 里 —— 跨境传 21 MB 要十几到几十分钟，放 build 里会把
      这个包的上线时间一起拖住）
    - 流程：`build` 先出包、建 GitHub Release（约 8 分钟，你马上能下），
      `gitee` job 再去取 Artifact、慢慢同步，同步多久都不影响 GitHub
    - 目标仓库写死在 workflow 的 `GITEE_REPO`（当前 `yin-cheng-lu/StudyHub`），
      改仓库要改这一处
    - 令牌放 Actions secret **`GITEE_TOKEN`**（Gitee → 设置 → 私人令牌，
      权限勾 `projects`）。**没配不会让构建失败**，只会打一条 warning 跳过
    - 做三件事：① 把源码强推到 Gitee 默认分支（分支名用 `git ls-remote` 现查）
      ② 打 `v<run_number>` tag 推过去 ③ 建发行版，**把 arm64 的 APK 作为
      发行版附件上传**
    - **下载地址（免登录，直接点）**：
      * `https://gitee.com/yin-cheng-lu/StudyHub/releases/tag/v<run_number>`
      * 直链：`https://gitee.com/yin-cheng-lu/StudyHub/releases/download/v<run_number>/app-arm64-v8a-release.apk`
    - **为什么不再把 APK 塞进 git 分支（老办法已废弃，别改回去）**：
      Gitee 免费版配额是**单仓库 500 MB / 单文件 50 MB / 附件 3 GB**。
      老办法每版 `force push` 一条装两个 21 MB 安装包的 `apk` 分支，
      而 force push 只移动分支指针、**旧对象不会被回收** —— 四十多版下来
      仓库早超过 500 MB。超限后 Gitee 会把这些大文件分支**静默丢弃**：
      客户端日志里明明有 `* [new branch] HEAD -> apk`，服务端却没留下这个分支，
      于是 `raw/apk/xxx.apk` 永远 404，浏览器显示
      **`[session-xxxxxxxx] Repository or file not found`**。
      发行版附件走的是「附件容量」（3 GB，和仓库体积分开算），直链还免登录。
    - 同步逻辑在 **`tools/sync_gitee.py`**（从 StudyHub-TV 仓库移植的同款脚本），
      两个包都传、已传过的自动跳过；GitHub 网页「Run workflow」时填
      `release_tag`（例：`v88`）可以给历史版本补建发行版
    - **速度**：实测 14 MB 附件要 ~15 分钟、21 MB 要 ~20 分钟（跨境就是慢，
      不是卡死），两个包约 40 分钟
    - 排查通道：`gitee` job 的全量输出会推到 **`ci-logs` 分支的 `gitee.log`**，
      匿名可读（`raw.githubusercontent.com/<repo>/ci-logs/gitee.log`），
      不用登 GitHub 翻 Actions
    - 易踩的坑：
      * **checkout 必须 `fetch-depth: 0`** —— 浅克隆往另一个远端 push 会被
        `shallow update not allowed` 拒绝
      * **上传必须走 curl 且关掉 100-continue**：`--http1.1 -H "Expect:"`，
        再配 `--speed-limit 4096 --speed-time 90`（低于 4 KB/s 持续 90 秒
        就放弃重来）+ 外层重试。urllib 直传会在 sendall 上卡死
        （StudyHub-TV v1.4.0 实测）；StudyHub 仓库 v72~v75 把「传得慢」
        误判成「接口无响应」而弃用附件，一半原因就是没关 100-continue
      * **Gitee 的匿名 API 限流很凶**（构建机 IP 直接 `403 Rate Limit Exceeded`），
        能不用 API 的地方都别用；建发行版/传附件失败只打 warning，不影响 GitHub
      * **Gitee 的 raw 有内容审核**：`README.md` 命中文违禁词会回
        `451 The content may contain violation information`（本仓库就中招过），
        `pubspec.yaml` / APK 不受影响
      * **仓库体积要留意**：现在每版只推源码（几 MB），体积增长很慢；
        若哪天源码也推不上，说明仓库彻底超限，去 Gitee 设置里看「仓库体积」，
        必要时删库重建（CI 下一次构建会自动把源码补回去）

18. **`shared_preferences` 插件已从项目移除，不要再加回来**（v2.0.0+49 修）
    - 症状：装完打开**纯白屏**（release 版看不到任何报错）。装诊断版后能看到：
      ```
      Bad state: 【卡在/出错于 本地设置】
      PlatformException(NoSuchMethodError: no non-static method
        Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;
        .getAll(Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;)
      ```
    - 原因：这个插件是「Dart 侧 pigeon 绑定 + Android 侧 Kotlin 实现」两半，
      **两半方法签名必须严格一致**。本仓库 `pubspec.lock` **不入库**，
      CI 每次 `flutter pub get` 都重新解析 `^2.3.2`；一旦解析成
      「Dart 是新版、原生侧还是旧版」的组合，运行期调用就对不上号。
      而 `SettingsStore.init()` 是启动第三步，所以表现是**启动即白屏**。
      这类问题本地 `flutter analyze` 完全查不出来（能编译、不能跑）。
    - 现状：改用自家实现 **`lib/data/local/pref_store.dart`**
      - 对外**类名和 API 与插件完全一样**（`SharedPreferences.getInstance()`、
        `getString/setString/getInt/...`），所以业务代码一行没改，只换了 import
      - 底层走原生通道 **`studyhub/prefs`**（`android_custom/MainActivity.kt`），
        直接读写系统 `SharedPreferences` 文件 `FlutterSharedPreferences`，
        键名沿用 **`flutter.` 前缀** → **老用户数据原样还在，不需要迁移**
      - getter 同步（读内存缓存），setter 异步落盘；通道不可用时降级为内存存储，
        绝不抛异常中断启动
    - 以后要存新的本地偏好：直接 `import 'pref_store.dart'`，别引第三方插件

---

## 十六、想自己改 App 里的东西？位置速查

> 这一章是**留给你自己动手时查的**。格式统一成「你要改的东西 → 去哪个文件的哪一段」。
>
> ⚠️ **行号按 v1.9.0+30 的代码写的**，你增删几行之后就会漂移。
> 更稳的办法是**搜关键字符串**（比如搜 `服务器目录规范`、搜 `static const categories`），
> 比死记行号可靠得多。

### 一、App 内嵌的「服务器目录规范」

| 你要改的东西 | 文件位置 | 说明 |
|---|---|---|
| **规范页正文内容** | `studyhub_app/lib/ui/home/server_guide_page.dart`（全文 319 行） | 「设置 / 首页 → 服务器目录规范」点进去看到的**整页**：`_TreeCard()` 里的目录树、每个目录放什么、常见问题 —— 全是这个文件里的写死文本 |
| **首页那个入口卡片** | `studyhub_app/lib/ui/home/home_page.dart` 第 320–328 行 | 卡片标题「服务器目录规范」+ 副标题「每个目录放什么、怎么建」+ 点击跳转 |
| **目录名常量**（决定 App 认哪 6 个目录） | `studyhub_app/lib/core/constants.dart` 里的 `AppDirs` | **只有懂代码才改这里**；改名会导致 App 找不到资料 |
| **目录别名**（`notes` 还能叫什么） | 同文件 `AppDirs.aliases` + `resolveFolders()` | v2.3.4 起 App 会自动认 `Documents`、`笔记`、`1 文档笔记`、`视频图片`、`题库刷题`… 想加新叫法就在这里往对应那行加词；匹配规则见下面「目录适配」一节 |
| **README 全文**（内置兜底版） | `studyhub_app/lib/ui/home/settings_page.dart` 第 1011 行起（`ReadmePage` 的 `_fallback`，到约第 1057 行的 `''';`） | 优先读服务器 / 资料里的 `README.md`，**读不到才用这一段兜底** |

> 首页还有第二个入口：`home_page.dart` 第 330–343 行「README · 项目自述」卡片。
> （设置页里那个入口按你要求删了，首页这个保留。）

### 二、小工具的位置 + 分类排序

小工具分**三种**，改法完全不同 —— 先分清你要改哪一种：

#### 1）内置工具（在 App 里，改完**需要重新编译**）

| 你要改的东西 | 文件位置 | 说明 |
|---|---|---|
| **分类、顺序、名称、颜色** | `studyhub_app/lib/ui/tools/tools_page.dart` | 第 69–168 行 `static const categories`，就是那 6 个分类（时间与效率 / 测量与设计 / 网络与编码 / 生活与娱乐 / 公卫小工具） |
| **每个分类里有哪些工具** | 同上 | 一行一个 `_ToolDef('工具名', 图标, 颜色, online: true/false)`，**行的先后就是显示顺序** |
| **工具名 → 具体页面** | 同上，`toolPageOf()` 里的 `switch (name)` | 把工具名对到具体页面。**这里的名字必须和 `_ToolDef` 里的完全一致** |
| **具体页面实现** | `studyhub_app/lib/ui/tools/tool_pages_*.dart` | 如 `tool_pages_sudoku.dart`（数独练习）、`tool_pages_mockloc.dart`（虚拟定位） |

#### 自己动手改内置工具：三条规矩

> v2.3.0 起工具页里的「拖动排序 / 改名」已经**整套删掉**了（点了就是打开工具）。
> 要调整顺序或名字，只能改代码，然后重新编译。
> 原因和上次「改了名字之后小工具打不开」一样：**工具名是两份定义绑在一起的** ——
> 一处是 `categories` 里的 `_ToolDef('名字', ...)`，另一处是 `toolPageOf()` 里的
> `case '名字'`。只改一处，点进去就会落到 `default` 那个「「某某」还没有绑定页面」。

**① 只改顺序**

把 `_ToolDef(...)` **整行**剪到目标位置（同一分类内），行尾逗号别丢。
跨分类就剪进另一个 `_Category([...])` 里。**名字一个字都别动**（连空格也别动）。

**② 要改名字**

两处一起改，缺一处就打不开：

```dart
// 第 ① 处：lib/ui/tools/tools_page.dart 顶部的 categories
_ToolDef('新名字', Icons.grid_3x3, Color(0xFF534AB7)),

// 第 ② 处：同一个文件末尾 toolPageOf()
case '新名字':
  return const SudokuPage();
```

**③ 加一个新工具**

① 在对应分类里加一行 `_ToolDef('新工具', 图标, 颜色)`，
② 在 `toolPageOf()` 里加一个 `case '新工具': return const 你的页面();`，
③ 页面本身写在 `lib/ui/tools/tool_pages_*.dart` 里。

**④ 删一个工具**：同样两处一起删（`_ToolDef` 那行 + `case` 那个分支）。

#### 2）网页版小工具（**不在 App 里**，浏览器直接用，改完**不用编译**）

- **文件夹**：`D:\WorkBuddy\StudyHub\网页版小工具\`（41+ 个 `.html`，**不在 git 里**）
- **分类排序**：`index.html`。搜 `<h2>` 就能找到那 5 个分类
  （时间与效率 / 测量与设计 / 网络与编码 / 生活与娱乐 / 公卫小工具），
  每个分类里 `<a class="tool">` 的先后就是显示顺序
- **新加一个**：照抄 `_模板.html` 写一个 `工具名.html`，
  再到 `index.html` 对应分类里加一条 `<a class="tool" href="工具名.html">`
- 本次新增：`路路词典.html`（已登记进「生活与娱乐」）
- **附属文件一律放同名文件夹**（v2.3.4 整理，免得根目录被一堆 js/json 淹没）：
  | 工具 | 它自己的文件夹 | 里面放什么 |
  |---|---|---|
  | `二维码生成.html` | `qrcode/` | `qrcode.min.js` |
  | `身份证查户籍.html` | `id_region/` | `id_region.json`（+ `id_region_data.js`，内容相同，给 `file://` 用） |
  | `路路词典.html` | `dictionary/` | 词典 `.mdx` / `.mdd`，文件名前面加序号 + 括号里写名称，如 `1（牛津高阶英汉词典）.mdx` |
  以后加新工具也照这个来：`工具名.html` + `工具名/` 文件夹，别往根目录扔散文件
- **坑**：这个目录里的 `*.html` 用 Python 脚本**写不进去**（PermissionError），
  要用编辑器直接写（`.js` / `.json` 和建目录、删文件不受限）

#### 3）服务器上的小工具（App 动态加载，改完**不用编译**）

- **服务器路径**：`/StudyHub/tools/<子目录>/<工具名>.html`
- **排序**：文件名前加数字前缀（`1.字典.html`、`2.数独.html`），
  App 显示时会**自动剥掉前缀**（所以用户看到的是「字典」而不是「1.字典」）

---

## 十七、一句话总结（v1.9.0 版）

1. 数据都放自己的 WebDAV 服务器
2. 服务器上建 `StudyHub/{notes,media,quiz,tools,backup,download}` 6 个目录
3. App 首页登录，扫一遍服务器，资料就出现在对应模块
4. 想改什么：看上面 11-16 章（**16 章是「改哪个文件」的速查表**）

---

## 十八、更新记录（新版本在最上面）

> Release 页面的正文已经精简成几行（不然 APK 下载按钮被顶到很下面），
> 每次改了什么统一记在这里。

### v2.3.9（2.3.9+64）—— 数独：锯齿出不来真凶落网（digitMap 卷进 0）、线条全蓝、数字加大、杀手选中笼高亮

- **锯齿数独「还是没有锯齿」的根因终于找到**：`_buildJigsaw` 的数字重映射把 0 也卷进洗牌——0 是空格，约 88% 的随机种子里总有某个数字被映成 0，导致「答案自检」必失败，出题逻辑随即**静默退回标准 3×3 宫**。玩家看到的就是普通九宫格，只有 digitMap 恰好没把 0 用上的那 ~12% 局才能见到锯齿——「刷好多次才出一次」完全吻合。修复：0 号位固定不用，只洗 1~9（模拟 2000 局零失败）。
- **线条全蓝**（对齐参考截图）：细网格浅蓝（主色 32%）、宫界/外框蓝（70%），全题型统一。
- **数字加大、不加粗**：字号 0.58 → 0.66 倍格宽，字重统一常规；选中/同数继续靠实底反白区分。
- **杀手数独选中笼高亮**：点某格后它所在的笼垫淡蓝填充 + 轮廓描 2.4px 加粗蓝线，其它笼保持细虚线。

### v2.3.8（2.3.8+63）—— 数独：配色/虚线对齐参考截图、锯齿宫界双保险、新增窗口数独

**一、整体配色与笼虚线按用户给的参考截图重做**

- 笼虚线：1.6px 深黑长虚线 → **1.2px 浅蓝短虚线**（虚线周期改成一格的 1/7，短划密排）；
- 笼和数字：深色加粗 → **灰色小字**（`onSurfaceVariant`），位置仍在笼左上角；
- 锯齿宫界线：2.4px 深黑 → **1.8px 浅蓝**；
- 选中格 / 同数字：参考图里都是**实蓝底 + 白字** —— 照搬。选中格叠一圈更深的
  描边做区分；同行同列同宫只铺 0.10 的浅蓝淡底；
- 锯齿宫底色从九彩色改回**浅蓝 / 白交替**（参考图就是这种马赛克）。

**二、锯齿数独：宫界线加双保险**

v2.3.7 的宫界只靠覆盖层 `_JigsawPainter` 一层画，真机上只要这层出任何意外，
锯齿就一根线都没有。现在宫界线**同时画进每个格子的 BorderSide**（上邻/左邻
不同宫 → 上/左边框用 1.6px 浅蓝宫界色，右/下同理），覆盖层再叠加画粗一遍。
任何一层失效都还有另一层，格子边框拼起来就是完整的锯齿。

**三、新增「窗口数独」（Windoku）**

标准行/列/3×3 宫之外再加 **4 个 3×3 窗口**（位置在行 1~3 / 5~7 与列 1~3 / 5~7
的交叉处，正好嵌在四个角宫之间）：每个窗口里的 1~9 也不能重复，窗口与普通宫
部分重叠、约束叠加。

- `WindokuRules`：`isLegal` 加窗口检查；快速求解器走 `extraOk` 钩子；
- 绘制：4 个浅蓝圆角粗框（`_WindowPainter`）+ 窗口内极淡蓝底色；
- 出题有合法性兜底重试 —— 拉丁方兜底公式不保证满足窗口约束，不能让玩家
  拿到「按答案填也判错」的盘。

---

### v2.3.7（2.3.7+62）—— 数独：杀手虚线各画各的、锯齿重做模板 + 九宫九色、同数高亮更醒目

**一、杀手数独：相邻虚线框不再共用一条线**

用户要求「相邻虚线框不能共用虚线，要各是各，所有虚线框的框线都独立存在，连续且不超出」。

v2.3.6 的写法按**网格边**去重：两个笼共享的那条边只画一遍，两个框在那一段完全重合，
看着就是一根共用的线；每条边还各自外伸一截补拐角，棋盘边缘会探出框外。

现在改成**每个笼只画它自己的轮廓**（`_CagePainter` 重写）：

1. 把笼子所有朝外的边按逆时针串成闭环（每条边带内法线）；
2. 整条闭环朝**笼内**平移 inset，顶点取相邻两条偏移线的交点 —— 拐角严丝合缝，
   也不会探出笼外；
3. 沿闭环**一圈连续**画虚线：相位按周长推进，一圈正好整数个周期，收口处是 gap，
   不断也不多画。

相邻两笼各自缩到自己那一侧，共享边处天然变成**两条平行虚线、中间留空** —— 各是各的。
（Python 复刻渲染目检通过：闭合、无断点、无越界、双层边清晰分离。）

**二、锯齿数独：模板重新生成 + 九宫九色**

- v2.3.6 的 12 套模板是「随机长出来再挑能解的」，形状偏胖，多数看上去仍像九宫格；
  而且宫底色只有 4 种（`宫号 % 4`），9 个宫必然撞色，相邻两宫同色时糊成一整片，
  只有少数几次刷出来的编号组合恰好两两不同色，才「看着是对的」。
- 现在**离线先造一个合法解，再反复做「边界格互换」**（每次都保证两宫仍连通、
  宫内 1..9 不重复），生成 40 套新模板：每宫 9 格四连通、**没有任何一个宫是
  规矩的 3×3 矩形**、平均周长 ≥ 14.5（3×3 是 12），全部附带合法解；
- 宫底色改为**按宫号给 9 个不同色相**（主色色相 + 40° 步长绕一圈），
  任意两宫颜色都不同，边界一眼可辨；
- 宫界线维持 2.4px 深色，压过细网格。

**三、点数字之后的同数高亮重做**

老配色三档都在「主色 + 低透明度」里打转（0.22 / 0.20 / 0.07），深浅差一两个百分点，
屏幕上分不开。现在按**三层色阶**重排：

- **选中格**：主色实底 + 数字反白 + 2px 描边（对比最强）；
- **相同数字**：主色 0.34 底 + 1.6px 主色描边 + 数字加粗（w900）；
- 同行 / 同列 / 同宫：主色 0.06 淡底（只是提示）。

---

### v2.3.6（2.3.6+61）—— 数独：锯齿真的锯齿了、杀手虚线闭合成框

**一、锯齿数独终于真的是锯齿**

根因（用 Python 复刻算法跑出来的）：v2.3.5 的「从标准宫出发，把相邻两格互换归属」
在 3×3 标准宫上**永远成功不了**。互换后每边新得的那一格只跟被换走的那一格相邻，
两边立刻断成两截，连通性检查必然失败 → 有效交换次数恒为 0 → 原样返回标准宫。
所以玩家看到的只是「按宫涂了色的普通九宫格」。

现在改成**内置模板 + 随机变换**：

- 12 套 9×9 锯齿布局写死进代码（`_kJigsawTemplates`），每套都离线验证过：
  每宫 9 格、四连通、没有一个是规矩的 3×3、**附带一个合法解**；
- 出题时随机取一套，做「转置 / 上下翻 / 左右翻」+ 宫号重排 + 数字重排，
  形状组合远多于 12 种，也不需要运行期再求解（出题更快、不会卡）；
- 同时删掉了 `makeRandomRegions` / `_regionConnected` / `_transformTemplate`。

**二、杀手数独虚线框闭合成环、笼和不被压住**

- 老写法**按格**画虚线：每格各画自己那几条边，每条边单独起虚线相位、还各自内缩，
  拐角处必然断开；内部边又只让「下/右那格」画，碰到同笼格子整段漏掉 —— 就是
  「框连不起来、有的边没有」；
- 现在每条宫界边**只画一次**（无向去重，否则半透明色叠两遍会发黑），
  虚线周期取成「格宽的整数分之一」（相邻边首尾对齐），每条边两端各多画一截，
  拐角处两条虚线必定叠上 → 每个笼都是一圈闭合的虚线；
- 整条线朝**格内**挪 1~2px，不再压在格子实线边框上；
- 笼和数字往格内多让一点，并垫一层底色，不再和虚线重合。

---

### v2.3.5（2.3.5+60）—— 六处细节修复：阅读遮挡 / 三个记录开关 / 视频 / 题库序号 / 下载站 / 数独

**一、md 正文最后几行不再被底部虚拟键压住**
- Android 15 起系统强制 edge-to-edge，`Scaffold` 的 body 会画到屏幕最底部，
  系统导航栏（三个虚拟键）是**浮在上面**的，正文最后一屏被盖住
- 阅读页外面套一层 `SafeArea(top: false)`（顶部 AppBar 已经自己避让了）

**二、设置里「保存浏览记录」拆成三个开关**（默认全开）
| 开关 | 管什么 |
|---|---|
| 保存文档记录 | 打开过哪篇笔记、每个目录上次看到哪篇 |
| 保存视频记录 | 播放进度（下次接着看）、「最近浏览」里的视频条目 |
| 保存题库记录 | 哪些题刷过了、每套题库刷了多少（**错题本不受影响**） |
- 判断下沉到 `AppDb.saveProgress` / `markDone`：按路径前缀区分笔记和媒体，
  关掉就不再写库，已经在库里的老记录不删（首页「清空」可清）
- 旧的总开关键 `save_view_history` 保留做迁移，老用户关过的三个都继承关闭

**三、视频**
- 平铺模式的格子 `childAspectRatio` 0.85 → 0.75，文件夹 / 文件名改成**最多两行**，
  窄格子也能看全「第 3 章 细胞膜的物质运输」这种长名字
- 进播放页**直接进沉浸式**（`SystemUiMode.immersiveSticky`），状态栏不再压在画面上方；
  点右上角「退出全屏」可以换回带状态栏的样子，退出页面时恢复 `edgeToEdge`

**四、题库名称隐藏序号**
- 文件和目录按 `1.xxx` `2.xxx` 编号只为排序，列表里显示时会去掉序号前缀
- 序号还在 `path` 里，排序、进度记录、错题本匹配都不受影响
- 错题本里的老记录（bankName 带序号）显示时也一起剥掉，同一套题库不会被拆成两组

**五、服务器下载站 / 根目录浏览**
- 「StudyHub 根目录」（以及服务器速查表）补了 `PopScope`：进到子目录后按系统返回键
  **先回上一级**，不会一步退回工具菜单（之前只有下载站这一页做了）
- 根目录浏览时显示**服务器上的真实名字**（新增 `DavEntry.realName`）——
  目录适配之后 `e.name` 是逻辑名（notes / media），照它显示会让人以为服务器上真叫这个
- 根目录按真实名自然排序，`1 文档笔记` 这类序号前缀才有意义

**六、数独练习**
- **提示**真的会填数字了（以前只是把空格染个淡色）：选中某格点提示 → 填这一格；
  没选格 → 在所有还没填对的格里随机挑一个。可撤销，另记提示次数
- **锯齿数独**：宫形状生成改成「从标准宫出发、反复交换相邻异格」（每宫格数不变 +
  交换后检查四连通），可解率大幅提高；兜底模板删掉了那张「6 个宫还是标准 3×3」的，
  只留锯齿明显的一张并随机转置 / 翻转（8 种朝向）
- **杀手数独**：笼子虚线整条**往笼内缩 2~3 px**，不再压在格子的实线边框上；
  同一段边界只画一次（否则两侧各缩一次会变成两条平行虚线）
- 顺手修了五个 painter 的 `shouldRepaint` 恒 `false` —— 换题后画布不重绘，
  宫界 / 笼子 / 不等号还停在上一题的位置
- **点数字高亮**：选中一个带数字的格子，盘面上**所有相同的数字一起点亮**（比同行同列更醒目）

### v2.3.4（2.3.4+59）—— 目录适配 + 路路词典 v3 + 小工具附属文件归位

**一、目录适配：notes 不用非得叫 notes**
- 登录时先列一遍根目录，自动认出每个逻辑目录对应哪个真实文件夹。
  现在 `Documents`、`笔记`、`文档笔记`、`1 文档笔记`、`视频图片`、`2 视频图片`、
  `题库刷题`、`软件工具`、`文件下载` 这些名字全都认（英文不分大小写，
  前面的序号 `1 ` / `(2)` / `01-` / 全角数字自动忽略）
- 匹配三级：① 等于逻辑名 → ② 去序号后等于某个别名 → ③ 去序号后包含某个别名
  （长别名优先，「文档笔记」不会被「文档」抢走）；一个文件夹只归一类
- App 内部全用逻辑名，**只有发请求那一刻才换成服务器上的真实名字**，
  列表读回来又换回逻辑名 —— 所以服务器改目录名不会让本机笔记记录 / 阅读进度失效
- 认不出来就按默认名走；退出登录会清掉映射重认。规范页也补了这条说明
- 别名清单在 `lib/core/constants.dart` 的 `AppDirs.aliases`，想加词往对应那行加

**二、路路词典.html 重写（v3）：能读 dictionary 里所有 mdx / mdd**
- **原来的 bug**：v2 只扫「页面所在目录」，词典放在 `dictionary/` 子目录里
  压根没扫到；就算扫到也要求先「导入」进 IndexedDB，658 MB 的资源包根本存不进去
- 现在打开页面就扫 `dictionary/`：① 让静态服务器列目录 → ② 读
  `dictionary/index.json` 清单（不给列目录的托管用它）→ ③ 本机选文件兜底
- **列表排在搜索框下面**，按文件名前面的**数字排序**，名字显示**括号里**那一段
  （`1（牛津高阶英汉词典）英汉双解第7版….mdx` → ①「牛津高阶英汉词典」）
- **手风琴**：查完默认展开第一部命中的词典，点别的标题才展开它、其余自动合上，
  再点当前这个就收起自己
- **mdd 真的能用了**：读音/图片直接从 mdd 里按偏移现取现解压，
  `entry://`、`sound://`、`src`/`href` 相对路径都会改成 blob URL；
  超过 48 MB 的资源包不自动加载（只影响图片发音，正文照常查），列表里标注「未加载」
- 现读现解析，不再往 IndexedDB 里塞整本词典；生词本 / 查词历史仍然存 `localStorage`
- 更名 `路路词典 v3`，说明卡片重写（`dictionary/` 约定、序号规则、48 MB 策略、
  双击打开（file://）时浏览器不让读同目录文件，要起 `python -m http.server`）

**三、网页版小工具的附属文件归位**（根目录不再堆散文件）
- `二维码生成.html` 的 `lib/qrcode.min.js` → **`qrcode/qrcode.min.js`**
- `身份证查户籍.html` 的 `id_region.json` / `id_region_data.js` → **`id_region/`**
- `路路词典.html` 的词典 → **`dictionary/`**（另附 `index.json` 清单）
- 以后新工具统一 `工具名.html` + `工具名/` 文件夹

### v2.3.3（2.3.3+58）—— 只改发布链路，App 功能跟 v2.3.2 一样

**修「Gitee 下载一直报 `Repository or file not found`」**
- 原因：Gitee 免费版**单仓库 500 MB** 上限。老做法每版往仓库里 force push
  一条装两个 21 MB 安装包的 `apk` 分支，而 force push 不回收旧对象，
  四十多版下来仓库早超了。超限后 Gitee 会把这些大分支**静默丢弃**：
  日志里明明有 `* [new branch] HEAD -> apk`，服务端却没留下分支，于是
  所有 `raw/apk/*.apk` 链接一律 404（浏览器就显示那句
  `[session-xxxxxxxx] Repository or file not found`）。
- 另外 raw 下载本身还要求登录（`403 large file require login`），
  就算分支在，手机浏览器直接点也下不了。
- 改法：**APK 改走 Gitee 发行版附件**。附件容量和仓库体积分开算（免费版 3 GB），
  直链 `releases/download/<tag>/<file>` 免登录可下。
  CI 改为调用 `tools/sync_gitee.py`（StudyHub-TV 同款脚本）：
  只推源码 + tag，APK 全部作为发行版附件上传，不再产生任何大文件分支。
- 上传细节按 StudyHub-TV 的踩坑记录修正：curl `--http1.1` + 关 `Expect:` +
  低速 90 秒中断 + 3 次重试。（v72~v75 那几版把「传得慢」误判成
  「接口无响应」，其实 14 MB 就要 ~15 分钟。）
- 下载页变成：`https://gitee.com/yin-cheng-lu/StudyHub/releases/tag/v<构建号>`，
  附件免登录直下。

### v2.3.2（2.3.2+57）

**水印相机**
- **旋转手机不再弹系统提示**：那个「转横屏」小按钮是 Android 的旋转建议
  （应用允许跟随系统旋转时才会弹）。水印相机本来就一步不转屏，
  现在进页面直接**锁死竖屏**、退出时恢复跟随系统 —— 系统从此不再弹
- **横屏拍照后水印位置跟随**：编辑页新增 `landscape` 参数，取景页横屏
  模式拍出来（或选的照片）在成片里也把水印旋转 90° 贴左上角，
  和取景预览完全一致（之前编辑页不知道横屏状态，拍完水印又回竖屏位）

**数独练习**
- 「标准数独」改名**九宫格**；「对角数独 X」改名**对角线数独**，
  盘面上直接画出两条对角线（半透明主色实线）
- 「不等式数独」改名**六宫格比比数独**，排到题型第三位
- **删掉三个题型**：超数独、连续数独、箭头数独（连代码带绘制一起删）
- 每种题型在棋盘下面**显示玩法说明**（`SudokuType.rule`，两行封顶）
- **杀手数独画虚线笼 + 总和角标**：旧绘制按「已填格截断」画线，
  开局提示数字多，线几乎全被跳过 —— 所以看不到笼。现在跟锯齿宫界一样
  逐格检查四邻全画（虚线 dash 3.2 / gap 2.4），角标画在笼内最左上格角落
- **锯齿数独保证有锯齿**：随机切法 6 次全失败时，旧兜底是「退回标准 3×3 宫」，
  看起来就是普通九宫格。现在改成退到**内置模板**（两张离线生成、
  验证过连通 + 可解 + 30 种随机顺序都能解出的锯齿宫布局写死在代码里，
  宫编号随机重映射）；兜底求解节点上限放大到 10 万
- **地狱难度加难**：挖洞比例 0.72 → 0.78，且挖洞算法从「一口气挖 + 补回」
  换成**逐格验证法**（每挖一格就用求解器数解数，解不唯一就放回），
  能一路挖到该算法的极限（九宫格实测平均剩 24 个提示，全部唯一解）
- 验证：8 种题型各 15 次「生成 → 地狱挖洞 → 解数=1」全部通过；
  随机锯齿切法 100 次全部连通且各 9 格

**高级计算（整页重做）**
- 按卡西欧 fx 系列截图重做：显示区 + 模式行 + 9 排 6 列科学计算键盘
- 新增：**正常 / 数学 / 小数**三种显示（数学模式把 0.5 显示成 1/2 这类分数，
  连分数逼近）；**SOLVE**（解方程，牛顿法自动换初值）、**d/dx**（数值导数）、
  **∫dx**（定积分，Simpson 1000 段）、**Σ**（整数求和）四个弹窗式求解器；
  **hyp** 键把 sin/cos/tan 切成 sinh/cosh/tanh；
  nPr / nCr / GCD / LCM / FACT / Abs / mod / x² / x³ / xʸ / ³√ / x⁻¹ /
  10ˣ / eˣ / EXP / Ans / Ran# / RanInt / 复制 / 历史
- 截图里没做的（MATRIX / VECTOR / 复数 / 统计 / 进制）：进制转换
  已在「单位换算」有独立入口；矩阵 / 向量 / 复数 / 统计需要整套模式切换，
  以后需要再单独加页；SHIFT / ALPHA 不需要 —— App 屏幕够大，
  第二功能全部平铺

**README**
- 新增「数独是怎么出题的」一节（见第十九章）

## 十九、数独是怎么出题的（原理说明）

**所有题目都是打开页面那一刻、在手机本地现场计算生成的**，不是预置题库，
也不联网。整个流程四步：

1. **先生成一张完整答案**。用「位掩码 + MRV」求解器从空盘随机填：
   每一步都挑「可选项最少」的格子先填，候选数字用二进制位一次算出来，
   候选顺序随机 —— 所以每局答案都不一样。锯齿数独先随机切宫
   （9 个种子轮流往外长，每宫恰好 9 格且连成一片），切完直接试解，
   试不出就换一种切法（最多 6 次），再不行退到内置的验证过可解的模板。
2. **异形规则「按答案生成」**。杀手的笼是叠在答案上圈出来的（笼和自然等于
   答案里那几个数的和，笼内强制不重复）；比比数独的 `>` `<` 是按答案里
   相邻两数的真实大小标的；奇偶数独的 O/E 标记按答案里数字的奇偶标。
   这样「照正确答案填」永远不会被误报。
3. **挖洞 = 出题**。从完整答案里按随机顺序把格子挖空：
   * 简单 / 中等 / 困难：按比例一口气挖（0.37 / 0.50 / 0.63）；
   * **地狱**：逐格验证 —— 每试着挖一格就用求解器数一遍解的数量，
     挖了之后解不唯一就放回去，所以每一局都保证**唯一解**，
     并一路挖到挖不动为止（九宫格平均剩 24 个提示）。
4. **求解器有节点上限**（默认 6 万）。真碰到极难的盘，超限就放弃重来，
   宁可换一题也不卡界面；出题过程中还会主动让出帧，让「正在生成」的
   提示先画出来。

校验方式：本机没有 Dart 环境，改动时用 Python 把同一套算法重写一遍
当「本地编译器」，跑「每种题型 15 次生成 + 地狱唯一解验证」全过再推云端编译。

### v2.3.1（2.3.1+56）

**水印相机**
- 五个按钮（关闭 / 闪光灯 / 横屏 / 定位 / 前后镜头）从顶部横排搬到**屏幕右侧边、
  竖直居中**；「关闭」单独留在最上面、与下面四个空开一段，避免手滑退出
- 「横屏」不再转屏幕：**只把水印整块旋转 90° 并换到画面左侧**，
  取景画面、本地照片 / 快门 / 水印三个按钮、右侧工具条全都不动
  （`_landscape` 只驱动 `_watermarkOverlay`，不调 `SystemChrome`）

**翻译查词**
- 去掉顶部「翻译 / 在线字典 / 在线词典」三个分类，改成**一个查询框 + 下面一排接口**
- 接口共 8 个，点哪个用哪个查（已有内容会自动重查）：
  有道词典 / 百度词典 / 有道翻译 / 腾讯翻译 / MyMemory / 百度汉语 / 汉典 / 有道汉语
- `DictLookupView` 新增 `embedded / query / source / runId` 参数，只出结果不出输入框

**数独练习**
- 新增 **四宫格（4×4）** 和 **六宫格（6×6）**，排在题型最前面；
  宫大小按尺寸自动算（4→2×2、6→2×3、9→3×3）
- 难度改成按格子总数的**比例**挖洞（原来写死 56 格，4×4 一共才 16 格会挖穿）
- **锯齿数独卡死**根因有两个，都修了：
  * 宫界生成的边界池只清理尾部，中间的「已被别区占用」格子会被再次抢占 →
    区域大小不均、不连通、无解；改成整池过滤（`removeWhere`）
  * 出题用无上限的顺序回溯；换成**位掩码 + MRV** 求解器（`_FastSolver`），
    带节点上限，切法无解就换一种，最多试 12 次
- 顺带修掉一批「照正确答案填反而报错」的规则 bug：
  * 不等式数独：原来随机撒 `<` `>`，与解无关；现在按解的真实大小关系生成。
    盘面也从 9×6 改成 **6×6**（棋盘是 N×N，9×6 会填 9 行只显示 6 行）
  * 连续数独：标记只表示「本格与右邻」，但旧代码对上下左右四个方向都用它判断
  * 奇偶数独：原来随机标奇偶，现在按解的值标
  * 箭头数独：原来随便画箭头，现在只生成「路径和 = 球值」的形状
  * 杀手数独：笼内可能包含相同数字，现在叠笼时强制笼内不重复
- 地狱难度的唯一解验证改用本题型自己的规则（原来写死 3×3 宫）

**README**
- 第十六章新增「自己动手改内置工具：三条规矩」——改顺序 / 改名字 / 加工具
  各要动哪两处，以及「只改一处就打不开」的原因

### v2.1.0（2.1.0+50）

**发版说明**
- GitHub Release 正文缩短到 8 行，APK 下载链接回到页面最上方

**工具**
- **地图坐标转换**：新增「十进制度 ⇄ 度分秒」互转。切换输入格式时会自动把
  框里的值换算成对应写法；`39°54′31.3″N`、`N39°54'31.3"`、`39 54 31.3`、
  `39:54:31.3` 都认，带 S / W 按负数处理
- **身份证查户籍**：底部「单个查询 / 批量查询」两个标签被系统导航栏压住点不到 ——
  `ToolScaffold` 的 `bottom` 现在包了 `SafeArea`（Scaffold 不会自动避让
  `bottomNavigationBar`，只避让 body）
- **通话记录生成**：通话时间原来只能改日期（`_pickStartTime` 写了但没接到界面上）。
  现在点时间框会**先选日期再选时刻**，右边另给一个「只改时刻」的按钮
- **水印相机**：改成「今日水印相机」那种用法
  * 打开就是**取景画面**，当前水印实时叠在上面（右下/左下等位置跟设置一致）
  * 顶部「水印」→ 换模板、改时间地点；底部左「照片」→ 本地照片加同一套水印
  * 中间大圆键 = 快门，**拍完自动合成并保存**（`WatermarkEditorPage(autoSave: true)`）
  * 底部右「定位」一键取经纬度 / 海拔 / 中文地址，水印立刻更新
  * 水印**去掉底板，背景透明**，只留左侧色条 + 文字，文字带投影
  * 新增 `WatermarkCameraPage`，`WatermarkPage` 降级为「水印样式」设置页

**数独练习**
- **笔记模式**：按钮改成整块变色（原来只染图标那一小块，看不出开没开）；
  修掉「这一格已经有数字时，加的候选看不见」—— 记笔记前先清掉数字
- **锯齿数独**：宫格生成算法重写（旧的经常失败后退回标准 3×3 宫，
  所以根本没有锯齿）。新算法：9 个种子均布 + 轮流往外吃，保证每区 9 格且连通
- **宫格**：左右内边距 0，格子贴着屏幕边、尽可能大；
  `LayoutBuilder` 挪进 `Container` 内部，覆盖层（锯齿/笼/箭头）不再错位
- **数字盘**：按键更大（上限 78 → 96），仍是 9 个分两排；右下角有剩余个数角标；
  没有擦除按钮（再点一次同一个数字 = 清除）
- 笔记在 6×6 盘面只画 1~6（原来固定画 1~9）

