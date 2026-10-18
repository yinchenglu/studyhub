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

17. **发版自动同步到 Gitee**（v2.0.0+40 新增，v2.0.0+45 改掉上传方式）
    - 位置：`.github/workflows/build-apk.yml` 第 12 步「同步到 Gitee 镜像」
    - 目标仓库写死在 workflow 的 `GITEE_REPO`（当前 `yin-cheng-lu/StudyHub`），
      改仓库要改这一处
    - 令牌放 Actions secret **`GITEE_TOKEN`**（Gitee → 设置 → 私人令牌，
      权限勾 `projects`）。**没配不会让构建失败**，只会打一条 warning 跳过
    - 做四件事：① 把源码强推到 Gitee 的默认分支（分支名用 `git ls-remote`
      现查，**不调 API**）② 打 `v<run_number>` tag 推过去
      ③ **把两个 APK 当普通文件强推到一条叫 `apk` 的孤儿分支**
      ④ （可选）调 v5 API 建发行版，正文里放下载链接
    - **APK 的下载地址是固定的**（`apk` 分支每次被整体覆盖，只留最新一版）：
      * 64 位：`https://gitee.com/yin-cheng-lu/StudyHub/raw/apk/app-arm64-v8a-release.apk`
      * 32 位：`https://gitee.com/yin-cheng-lu/StudyHub/raw/apk/app-armeabi-v7a-release.apk`
      * 版本信息：同分支下的 `latest.json`
    - 三个易踩的坑：
      * **checkout 必须 `fetch-depth: 0`** —— 浅克隆往另一个远端 push 会被
        `shallow update not allowed` 拒绝（本仓库历史才 3 MB，全量拉没负担）
      * **不要用发行的「附件上传」接口**（`POST /releases/{id}/attach_files`）：
        GitHub 的海外 runner 上去连 Gitee，这个接口**长期无响应**，
        连接建起来就不回、一直挂到超时（v71~v75 连试五版，发行版都建出来了、
        附件表永远是空的）。所以 APK 改走 git push，同一个令牌、稳得多
      * **Gitee 的匿名 API 限流很凶**（构建机 IP 直接 `403 Rate Limit Exceeded`），
        凡是能不用 API 的地方都别用 —— 分支名用 `ls-remote`，
        建发行版只是锦上添花，失败只打 warning
    - 仓库体积：每次构建会往 Gitee 推约 43 MB 对象（旧版本变成不可达对象），
      免费仓库 1 GB 上限，大约能撑 20 次左右；攒够了可以让我清一次

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
| **工具名 → 具体页面** | 同上，第 632 行起 `toolPageOf()` 里的 `switch (name)` | 把工具名对到具体页面 |
| **具体页面实现** | `studyhub_app/lib/ui/tools/tool_pages_*.dart` | 如 `tool_pages_sudoku.dart`（数独练习）、`tool_pages_mockloc.dart`（虚拟定位） |
| **不想改代码的排序办法** | 工具页右上角进「**自定义**」模式 | 可拖动排序、重命名 —— 结果存在 `lib/data/local/settings_store.dart` 的 `_kToolOrder` / `_kToolAlias` 两个键里（按分类存，拖动只在分类内部生效） |

#### 2）网页版小工具（**不在 App 里**，浏览器直接用，改完**不用编译**）

- **文件夹**：`D:\WorkBuddy\StudyHub\网页版小工具\`（41+ 个 `.html`，**不在 git 里**）
- **分类排序**：`index.html`。搜 `<h2>` 就能找到那 5 个分类
  （时间与效率 / 测量与设计 / 网络与编码 / 生活与娱乐 / 公卫小工具），
  每个分类里 `<a class="tool">` 的先后就是显示顺序
- **新加一个**：照抄 `_模板.html` 写一个 `工具名.html`，
  再到 `index.html` 对应分类里加一条 `<a class="tool" href="工具名.html">`
- 本次新增：`路路词典.html`（已登记进「生活与娱乐」）
- **坑**：这个目录里的 `*.html` 用 Python 脚本**写不进去**（PermissionError），
  要用编辑器直接写

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
