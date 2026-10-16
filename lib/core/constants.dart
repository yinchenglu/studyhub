/// 全局常量：服务器目录规范、文件类型判定等
class AppDirs {
  /// 服务器上的资料根目录（可在登录时修改，默认 /StudyHub）
  static const String defaultRoot = '/StudyHub';

  /// 五个固定子目录
  static const String notes = 'notes'; // 笔记
  static const String media = 'media'; // 视频与图片
  static const String quiz = 'quiz'; // 题库
  static const String tools = 'tools'; // 词库 / 速查表 / html 小工具
  static const String backup = 'backup'; // 错题本、设置备份

  /// 下载站：专门放「想直接在手机上下载下来」的文件。
  /// 工具页最上面那个按钮就是它，相当于一个迷你下载站。
  static const String download = 'download';

  static const List<String> all = [notes, media, quiz, tools, download, backup];

  /// 笔记配图统一放在「笔记所在目录」下的这个子目录里，方便集中管理
  static const String imageDirName = 'image';

  /// 列表里不显示的目录（配图目录属于附属资源，只让 .md 笔记可见）
  static const Set<String> hiddenDirNames = {imageDirName};

  /// html 小工具的入口文件名（优先级从高到低）
  static const List<String> htmlEntryNames = ['index.html', 'index.htm', 'main.html'];

  /// 目录用途说明（未登录首页的引导卡片直接用它渲染）
  static const Map<String, String> usage = {
    notes: '笔记：每篇一个 .md 文件，配图放同一目录；子目录就是分类。支持导出 PDF / HTML',
    media: '视频与图片：子目录会自动变成分类',
    quiz: '题库：一个 .json 就是一套题库，可以按套刷，也可以把整目录合并起来刷',
    tools: '工具资源：词库、速查表，以及可直接运行的 html 小工具（一个子文件夹 = 一个分类）',
    download: '下载站：专门放想在手机上下载的文件，工具页最上面的按钮直接进入',
    backup: 'App 回写：错题本、设置备份',
  };

  static const Map<String, String> sample = {
    notes: '中医/人体穴位图.png、中医/经络知识.md、绳结/平结演示.gif',
    media: '教学视频/xxx.mp4、图片/xxx.jpg',
    quiz: 'python基础/第一章.json、python基础/第二章.json',
    tools: '四级词汇.csv、公式速查.md、小工具/单位换算/index.html',
    download: '软件/apk、课件/讲义.pdf',
    backup: '错题本.json',
  };
}

/// 文件后缀 → 类型判定
class FileTypes {
  static const Set<String> video = {
    'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'rmvb', 'rm', 'ts', 'm2ts',
    'webm', 'm4v', '3gp', 'mpg', 'mpeg', 'vob', 'asf', 'f4v', 'ogv', 'divx',
  };

  static const Set<String> image = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'svg',
  };

  static const Set<String> audio = {'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus'};

  static const Set<String> doc = {'pdf', 'txt', 'md', 'json', 'csv', 'epub'};

  static String ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  static bool isVideo(String name) => video.contains(ext(name));
  static bool isImage(String name) => image.contains(ext(name));
  static bool isAudio(String name) => audio.contains(ext(name));
  static bool isMarkdown(String name) => ext(name) == 'md';
  static bool isJson(String name) => ext(name) == 'json';
  static bool isPdf(String name) => ext(name) == 'pdf';
  static bool isHtml(String name) {
    final e = ext(name);
    return e == 'html' || e == 'htm';
  }

  /// 能当纯文本直接读的类型（笔记导出、速查表预览都用它）
  static bool isReadableText(String name) {
    final e = ext(name);
    return e == 'md' || e == 'txt' || e == 'json' || e == 'csv' || e == 'log' || e == 'xml' || e == 'yaml' || e == 'yml';
  }

  /// 播放器可播的类型
  static bool isPlayable(String name) => isVideo(name) || isAudio(name);
}

/// 应用级偏好默认值
class Defaults {
  static const double playbackSpeed = 1.0;
  static const int quizCountPerRound = 20;
  static const int examCount = 30;
  static const int examMinutes = 40;
  static const int cacheLimitMb = 2048; // 缓存上限 2GB
  static const int scanMaxDepth = 4; // 媒体库最大扫描深度

  /// 「普通模式」答完自动跳下一题的秒数。0 = 不自动跳。
  ///
  /// v1.7.0：它**自己就是开关**了。用户要求删掉那个单独的
  /// 「答完自动下一题」总开关、连同菜单里的「不显示答案时也自动跳题」，
  /// 设置里只留三个时间，0 就代表不跳。选项按用户点名的来：
  /// 不自动跳 / 1 / 2 / 3 / 4 / 5 秒。
  static const int autoNextSec = 3;

  /// 「答错」**以及「点了显示答案之后」**停留几秒再跳。
  ///
  /// v1.7.0：从「只管答错」扩到「答错 + 看过答案」，所以改名叫
  /// 「答错和显示答案跳题秒数」；选项补上 8 秒和「不自动跳」（0）。
  static const int wrongStaySec = 6;

  /// 「带答案刷题（只看不做）」模式翻页的秒数。0 = 不自动跳。
  ///
  /// v1.6.0 按用户要求从 `autoNextSec` 里**独立出来**。
  /// 三个时间各管各的：
  ///   ① 普通模式答完跳的    → autoNextSec
  ///   ② 答错 / 看过答案跳的 → wrongStaySec
  ///   ③ 带答案刷题模式跳的  → browseNextSec
  static const int browseNextSec = 4;

  /// 普通模式答完自动跳的秒数可选项（0 表示不自动跳）
  /// v1.7.0 按用户点名的档位重排。
  static const List<int> autoNextSecOptions = [0, 1, 2, 3, 4, 5];

  /// 答错 / 看过答案后停留的可选项（0 = 不自动跳）
  /// v1.7.0 按用户点名的档位重排（原来是 [2, 4, 6, 10]，没有「不自动跳」）。
  static const List<int> wrongStaySecOptions = [0, 2, 4, 6, 8];

  /// 「带答案刷题 / 只看不做」模式翻页秒数可选项（0 = 不自动跳）
  /// v1.7.0 按用户点名的档位重排。
  static const List<int> browseNextSecOptions = [0, 2, 4, 6, 8];

  /// 把从磁盘读回来的旧值归一到当前选项列表里的合法值。
  ///
  /// 为什么必须有：用户升级前可能存着 10 / 12 / 20 这些**已经不在选项里**
  /// 的秒数，而 DropdownButton 的 value 一旦不等于任何 item 就直接断言崩。
  /// 归一到「最接近的合法档位」，体验上也比悄悄跳回默认值合理。
  static int normalizeSec(int v, List<int> options) {
    if (options.contains(v)) return v;
    var best = options.first;
    for (final o in options) {
      if ((o - v).abs() < (best - v).abs()) best = o;
    }
    return best;
  }

  /// 默认下载目录（Android）：系统「下载」目录下的 StudyHub 文件夹
  static const String androidDownloadFolder = 'StudyHub';

  // ---------------------------------------------------------- 阅读模式（v1.5.0）

  /// 正文默认字号。17 比 app 正文（15 左右）大一点，
  /// 因为看小说是长时间盯屏，略大更省眼。
  static const double readFontSize = 17;

  /// 默认行距
  static const double readLineHeight = 1.75;

  /// 自动翻页间隔可选项（0 = 关闭）
  static const List<int> readAutoSecOptions = [0, 5, 10, 15, 20, 30, 60];

  // ---------------------------------------------------------- 文件夹同步（v1.5.0）

  /// 默认每 5 分钟对一次（用户原话是「每几分钟识别一次，直至同步完成」）
  static const int syncIntervalMin = 5;

  /// 可选的同步间隔（分钟）
  static const List<int> syncIntervalOptions = [1, 2, 5, 10, 15, 30, 60];

  // ---------------------------------------------------------- 后台录音录像（v1.6.0）

  /// 录音最长时长默认值（分钟）。0 = 不限。
  static const int audioMaxMinutes = 0;

  /// 录像最长时长默认值（分钟）。0 = 不限。
  ///
  /// 录像给 60：1080p 一分钟约 60 MB，如果用户忘了按停止就会把存储吃光，
  /// 给个 60 分钟默认值既能录完一节课、一场小会，又能在用户走神时及时封顶。
  /// 用户仍可在页面上切成其他档（含不限）。
  static const int videoMaxMinutes = 60;

  /// 录音最长时长可选项（分钟，0 = 不限）
  static const List<int> audioMaxOptions = [0, 5, 10, 20, 30, 60, 120];

  /// 录像最长时长可选项（分钟，0 = 不限）
  static const List<int> videoMaxOptions = [0, 1, 3, 5, 10, 20, 30, 60];
}

/// App 版本（设置页「关于」里显示）。
///
/// 为什么写死在这里而不是读 pubspec / package_info_plus：
///   * 读 pubspec 要引 yaml 解析，读 package_info_plus 要再加一个原生插件。
///     这个项目历次构建翻车全是因为依赖，为一个版本号不值得。
///   * 反正发版时 pubspec 里的 version 也是手改的，两处一起改就行。
/// 改这里的时候记得同步 pubspec.yaml 的 version。
///
/// v1.9.0 改进：引入 `_kPubspecVersion`（与 pubspec.yaml 一致性校验），
///             在 App 启动时如果两个不一致，会在控制台 + 调试页打印告警。
///             升级只需：① 改这里的字符串 ② 改 pubspec.yaml。
///             也可跑 `python tools/bump_version.py 1.10.0` 一次同步。
const String kAppVersion = '1.9.0';

/// pubspec.yaml 的 version（去掉 +N 之后必须等于 kAppVersion）。
/// 启动时会在 main() 里 assert，保证两个一致。
/// ——用工具：python tools/bump_version.py 1.10.0
///
/// v1.9.0+17 修：bump_version.py 之前**只改 kAppVersion 不改 kPubspecVersion**，
/// 会让启动 assert 失败。这里把 bump_version.py 一起修了（见 bump_version.py）。
const String kPubspecVersion = '1.9.0+18';
