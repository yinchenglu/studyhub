/// 全局常量：服务器目录规范、文件类型判定等
class AppDirs {
  /// 服务器上的资料根目录（可在登录时修改，默认 /StudyHub）
  static const String defaultRoot = '/StudyHub';

  /// 五个固定子目录
  static const String notes = 'notes'; // 笔记
  static const String media = 'media'; // 视频与图片
  static const String quiz = 'quiz'; // 题库
  static const String tools = 'tools'; // 词库 / 速查表
  static const String backup = 'backup'; // 错题本、设置备份

  static const List<String> all = [notes, media, quiz, tools, backup];

  /// 目录用途说明（未登录首页的引导卡片直接用它渲染）
  static const Map<String, String> usage = {
    notes: '笔记：每篇一个 .md 文件，配图放同一目录；子目录就是分类',
    media: '视频与图片：子目录会自动变成分类',
    quiz: '题库：每个子目录 = 一套题库，里面放 .json',
    tools: '工具资源：词库、速查表、模板',
    backup: 'App 回写：错题本、设置备份',
  };

  static const Map<String, String> sample = {
    notes: '中医/人体穴位图.png、中医/经络知识.md、绳结/平结演示.gif',
    media: '教学视频/xxx.mp4、图片/xxx.jpg',
    quiz: 'python基础/python基础.json',
    tools: '四级词汇.csv、公式速查.md',
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
}
