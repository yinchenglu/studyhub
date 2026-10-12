// 农历 / 节气 / 干支 —— 纯 Dart，零依赖。
//
// 给「翻页时钟」用：大屏上显示公历的同时带农历日期、星期、干支、节气。
//
// 算法用的是流传很广的那套「1900—2100 农历码表」：
//   * 每个年份压缩成一个 20 bit 的整数
//       bit 16      闰月是大月(30天)还是小月(29天)，1 = 大月
//       bit 15..4   十二个常规月的大小月，1 = 30 天，0 = 29 天
//       bit 3..0    闰月是第几个月，0 表示这一年没有闰月
//   * 以 1900-01-31（农历 1900 年正月初一）为基准日，按天数往后推
//
// ⚠️ 码表**不能凭记忆改**。本文件落地前，先用等价的 Python 版本对过答案：
//      春节（正月初一）31 个年份 31/31 全对，
//      中秋（八月十五）7 个年份 7/7 全对。
//    以后要动这张表，务必重跑一遍对照，不要直接改数字。

/// 农历日期
class LunarDate {
  final int year;       // 农历年（如 2026）
  final int month;      // 农历月 1~12
  final int day;        // 农历日 1~30
  final bool isLeap;    // 是否闰月

  const LunarDate({
    required this.year,
    required this.month,
    required this.day,
    required this.isLeap,
  });

  static const List<String> _monthNames = <String>[
    '正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊',
  ];

  static const List<String> _dayNames = <String>[
    '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
    '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
  ];

  static const List<String> _gan = <String>[
    '甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸',
  ];
  static const List<String> _zhi = <String>[
    '子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥',
  ];
  static const List<String> _zodiac = <String>[
    '鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪',
  ];

  /// 「正月」「闰四月」这种
  String get monthName =>
      '${isLeap ? '闰' : ''}${_monthNames[(month - 1).clamp(0, 11)]}月';

  /// 「初一」「廿三」这种
  String get dayName => _dayNames[(day - 1).clamp(0, 29)];

  /// 「甲辰」这种
  String get ganZhi => '${_gan[(year - 4) % 10]}${_zhi[(year - 4) % 12]}';

  /// 「龙」这种
  String get zodiac => _zodiac[(year - 4) % 12];

  /// 完整写法：二〇二六年正月初一
  String get full => '$year年$monthName$dayName';

  @override
  String toString() => '$monthName$dayName';
}

/// 农历码表，1900—2100 共 201 项
const List<int> _kLunarInfo = <int>[
  0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2, // 1900-1909
  0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977, // 1910-1919
  0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970, // 1920-1929
  0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950, // 1930-1939
  0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557, // 1940-1949
  0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0, // 1950-1959
  0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0, // 1960-1969
  0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6, // 1970-1979
  0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570, // 1980-1989
  0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x055c0, 0x0ab60, 0x096d5, 0x092e0, // 1990-1999
  0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5, // 2000-2009
  0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930, // 2010-2019
  0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530, // 2020-2029
  0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45, // 2030-2039
  0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0, // 2040-2049
  0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0, // 2050-2059
  0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4, // 2060-2069
  0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0, // 2070-2079
  0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160, // 2080-2089
  0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252, // 2090-2099
  0x0d520,                                                                                  // 2100
];

int _leapMonth(int y) => _kLunarInfo[y - 1900] & 0xf;

int _leapDays(int y) {
  if (_leapMonth(y) == 0) return 0;
  return (_kLunarInfo[y - 1900] & 0x10000) != 0 ? 30 : 29;
}

int _monthDays(int y, int m) {
  if (m < 1 || m > 12) return -1;
  return (_kLunarInfo[y - 1900] & (0x10000 >> m)) != 0 ? 30 : 29;
}

/// 这一农历年共多少天
int _yearDays(int y) {
  var sum = 348;                       // 12 个月先按 29 天算
  for (var i = 0x8000; i > 0x8; i >>= 1) {
    if ((_kLunarInfo[y - 1900] & i) != 0) sum += 1;
  }
  return sum + _leapDays(y);
}

/// 公历 → 农历。超出 1900~2100 会夹到边界（不会崩）。
LunarDate solarToLunar(DateTime date) {
  final clampY = date.year.clamp(1900, 2100);
  final d = DateTime(clampY, date.month, date.day);

  // 基准：公历 1900-01-31 = 农历 1900 年正月初一
  var offset = d.difference(DateTime(1900, 1, 31)).inDays;

  var i = 1900;
  var temp = 0;
  while (i < 2101 && offset > 0) {
    temp = _yearDays(i);
    offset -= temp;
    i++;
  }
  if (offset < 0) {
    offset += temp;
    i--;
  }
  final year = i;

  final leap = _leapMonth(year);
  var isLeap = false;
  i = 1;
  temp = 0;
  while (i < 13 && offset > 0) {
    if (leap > 0 && i == leap + 1 && !isLeap) {
      i--;
      isLeap = true;
      temp = _leapDays(year);
    } else {
      temp = _monthDays(year, i);
    }
    if (isLeap && i == leap + 1) isLeap = false;
    offset -= temp;
    i++;
  }
  if (offset == 0 && leap > 0 && i == leap + 1) {
    if (isLeap) {
      isLeap = false;
    } else {
      isLeap = true;
      i--;
    }
  }
  if (offset < 0) {
    i--;
    offset += temp;
  }

  return LunarDate(year: year, month: i, day: offset + 1, isLeap: isLeap);
}

// ===========================================================================
// 二十四节气
// ===========================================================================

/// 节气名，按公历月份从 1 月开始两两排列
const List<String> kTermNames = <String>[
  '小寒', '大寒', '立春', '雨水', '惊蛰', '春分',
  '清明', '谷雨', '立夏', '小满', '芒种', '夏至',
  '小暑', '大暑', '立秋', '处暑', '白露', '秋分',
  '寒露', '霜降', '立冬', '小雪', '大雪', '冬至',
];

/// 节气时刻表（单位：分钟，相对每年一个固定基准）
const List<int> _kTermInfo = <int>[
  0, 21208, 42467, 63836, 85337, 107014, 128867, 150921,
  173149, 195551, 218072, 240693, 263343, 285989, 308563, 331033,
  353350, 375494, 397447, 419210, 440795, 462224, 483532, 504758,
];

final int _kTermEpochMs =
    DateTime.utc(1900, 1, 6, 2, 5).millisecondsSinceEpoch;

/// 第 n 个节气（n 从 0 起，0 = 小寒）在 `y` 年的哪一天。
///
/// ⚠️ 这是**线性近似**公式（回归年长度取 31556925974.7 毫秒），
/// 绝大多数年份准，个别年份会差一天（已知 2023 夏至会算成 22 日）。
/// 作为时钟上的装饰足够，但**不要拿它当历法数据用**。
int _termDay(int y, int n) {
  final ms = (31556925974.7 * (y - 1900) +
          _kTermInfo[n] * 60000.0 +
          _kTermEpochMs)
      .round();
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).day;
}

/// 这一天是不是节气日；是就返回节气名，不是返回 null。
String? solarTermOf(DateTime date) {
  final y = date.year;
  if (y < 1900 || y > 2100) return null;
  for (final n in <int>[(date.month - 1) * 2, (date.month - 1) * 2 + 1]) {
    if (_termDay(y, n) == date.day) return kTermNames[n];
  }
  return null;
}

/// 星期几的中文写法
String weekdayCn(DateTime d) =>
    const <String>['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];
