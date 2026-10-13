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

  /// 「显示答案」模式下答完自动跳下一题的秒数。0 = 不自动跳。
  /// 给 3 秒是折中：够看一眼解析，又不至于干等。
  static const int autoNextSec = 3;

  /// 「不带答案」模式下答错后停留几秒再跳（答对是立刻跳）
  static const int wrongStaySec = 6;

  /// 「刷题模式（只看不做）」下自动翻页的秒数。0 = 不自动跳。
  ///
  /// v1.6.0 按用户要求从 `autoNextSec` 里**独立出来**。
  /// 用户要的是三个各自独立的时间：
  ///   ① 普通模式答完跳的   → autoNextSec
  ///   ② 普通模式答错后跳的 → wrongStaySec
  ///   ③ 只看不做模式跳的   → browseNextSec
  /// 只看不做是「背题」，节奏本来就比做题慢，默认给 5 秒。
  static const int browseNextSec = 5;

  /// 「自动下一题」秒数可选项（0 表示关闭）
  ///
  /// v1.4.0 按用户要求调整：补上 1 秒和 2 秒（想快刷的人需要更短的间隔），
  /// 去掉 10 秒和 15 秒（真想要那么久，不如关掉自动跳、自己按下一题）。
  static const List<int> autoNextSecOptions = [0, 1, 2, 3, 5, 8];

  /// 答错停留秒数可选项。
  /// v1.4.0 去掉末尾两项 —— 15 / 30 秒等得太久，实际上没人会让它自己跳。
  static const List<int> wrongStaySecOptions = [2, 4, 6, 10];

  /// 「只看不做」模式翻页秒数可选项（0 表示关闭）。
  /// 比做题模式整体慢一档：背题时一页总要多看两眼。
  static const List<int> browseNextSecOptions = [0, 3, 5, 8, 12, 20];

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
  /// 录像给 0，但页面上会摆出几档 —— 录像是真占空间的
  /// （1080p 大约 1 分钟 60 MB），长时间没人看着录很容易把存储吃光，
  /// 所以选项里有 5 / 10 / 30 分钟这些常用档。
  static const int videoMaxMinutes = 0;

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
const String kAppVersion = '1.6.0';
