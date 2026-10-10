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

  /// 「自动下一题」秒数可选项（0 表示关闭）
  static const List<int> autoNextSecOptions = [0, 3, 5, 8, 10, 15];

  /// 答错停留秒数可选项
  static const List<int> wrongStaySecOptions = [2, 4, 6, 10, 15, 30];

  /// 默认下载目录（Android）：系统「下载」目录下的 StudyHub 文件夹
  static const String androidDownloadFolder = 'StudyHub';
}
