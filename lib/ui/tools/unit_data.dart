/// 「单位换算」集中工具的数据与纯函数（v1.8.0 需求12）
///
/// 设计取舍
/// --------
/// 所有换算都归结成「先换成基准单位、再从基准单位换出来」两步：
///
/// ```
/// toBase(v)   = v * k + b
/// fromBase(x) = (x - b) / k
/// ```
///
/// 线性单位（长度、质量…）的 `b = 0`；温度是唯一需要 `b` 的族
/// （℃→℉ 不是等比放大，是「先乘 9/5 再加 32」，写成上面这个形式就是
/// `k = 5/9, b = -160/9`）。这样一张表就能覆盖全部 20 个类别，
/// 加新单位只要往数组里塞一行，不用改任何逻辑。
///
/// 为什么不做成「两两换算矩阵」：那要 `n²` 条数据，而且每加一个单位
/// 就要跟所有旧单位配一遍。基准单位法只有 `n` 条。
library;

/// 一个单位。
class Unit {
  /// 显示名（如「米」）
  final String name;

  /// 符号（如「m」），列表里跟在名字后面显示
  final String symbol;

  /// 换算到基准单位的比例系数
  final double k;

  /// 换算到基准单位的偏移量，只有温度用得到
  final double b;

  const Unit(this.name, this.symbol, this.k, [this.b = 0]);

  double toBase(double v) => v * k + b;

  double fromBase(double x) => (x - b) / k;
}

/// 一个换算类别（长度 / 面积 / …）
class UnitCategory {
  final String name;

  /// 该类的全部单位，**第一个是基准单位**
  final List<Unit> units;

  /// 配速类要额外显示「折合时速」——它是**倒数**关系，
  /// 硬塞进线性表会算错，所以单独标记一下。
  final bool pace;

  const UnitCategory(this.name, this.units, {this.pace = false});
}

/// 把 double 显示成人看得懂的样子。
///
/// 规则：整数就不带小数点；否则保留到 8 位有效数字再抹掉尾部的 0。
/// 不用 `toStringAsFixed` 是因为它会把 `1e-9` 这类小值显示成 `0.00000000`。
String fmtUnit(double v) {
  if (v.isNaN) return '—';
  if (v.isInfinite) return v > 0 ? '∞' : '-∞';
  if (v == 0) return '0';
  final a = v.abs();
  // 特别大 / 特别小的走科学计数法，否则一行放不下
  if (a >= 1e15 || a < 1e-6) {
    var s = v.toStringAsExponential(6);
    // 抹掉指数前面多余的 0：1.230000e+15 → 1.23e+15
    s = s.replaceFirst(RegExp(r'0+e'), 'e').replaceFirst(RegExp(r'\.e'), 'e');
    return s;
  }
  var s = v.toStringAsPrecision(10);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

// ============================================================ 各分类数据

const List<UnitCategory> kUnitCategories = [
  UnitCategory('长度', [
    Unit('千米', 'km', 1000),
    Unit('米', 'm', 1),
    Unit('分米', 'dm', 0.1),
    Unit('厘米', 'cm', 0.01),
    Unit('毫米', 'mm', 0.001),
    Unit('微米', 'μm', 0.000001),
    Unit('纳米', 'nm', 1e-9),
    Unit('英里', 'mi', 1609.344),
    Unit('码', 'yd', 0.9144),
    Unit('英尺', 'ft', 0.3048),
    Unit('英寸', 'in', 0.0254),
    Unit('海里', 'nmi', 1852),
    Unit('市里', '里', 500),
    Unit('丈', '丈', 10.0 / 3),
    Unit('市尺', '尺', 1.0 / 3),
    Unit('市寸', '寸', 1.0 / 30),
    Unit('光年', 'ly', 9.4607304725808e15),
    Unit('天文单位', 'AU', 1.495978707e11),
    Unit('秒差距', 'pc', 3.0856775814913673e16),
  ]),
  UnitCategory('面积', [
    Unit('平方米', 'm²', 1),
    Unit('平方千米', 'km²', 1000000),
    Unit('公顷', 'ha', 10000),
    Unit('公亩', 'a', 100),
    Unit('平方分米', 'dm²', 0.01),
    Unit('平方厘米', 'cm²', 0.0001),
    Unit('平方毫米', 'mm²', 1e-6),
    Unit('亩', '亩', 2000.0 / 3),
    Unit('平方市里', '里²', 250000),
    Unit('平方英尺', 'ft²', 0.09290304),
    Unit('平方英寸', 'in²', 0.00064516),
    Unit('平方码', 'yd²', 0.83612736),
    Unit('英亩', 'ac', 4046.8564224),
    Unit('平方英里', 'mi²', 2589988.110336),
  ]),
  UnitCategory('体积 / 容积', [
    Unit('立方米', 'm³', 1),
    Unit('升', 'L', 0.001),
    Unit('立方分米', 'dm³', 0.001),
    Unit('分升', 'dL', 0.0001),
    Unit('厘升', 'cL', 0.00001),
    Unit('毫升', 'mL', 0.000001),
    Unit('立方厘米', 'cm³', 0.000001),
    Unit('立方毫米', 'mm³', 1e-9),
    Unit('美制加仑', 'gal', 0.003785411784),
    Unit('英制加仑', 'gal(UK)', 0.00454609),
    Unit('美制夸脱', 'qt', 0.000946352946),
    Unit('美制品脱', 'pt', 0.000473176473),
    Unit('美制液盎司', 'fl oz', 2.95735295625e-5),
    Unit('立方英尺', 'ft³', 0.028316846592),
    Unit('立方英寸', 'in³', 1.6387064e-5),
    Unit('石油桶', 'bbl', 0.158987294928),
  ]),
  UnitCategory('质量', [
    Unit('千克', 'kg', 1),
    Unit('吨', 't', 1000),
    Unit('克', 'g', 0.001),
    Unit('毫克', 'mg', 1e-6),
    Unit('微克', 'μg', 1e-9),
    Unit('市斤', '斤', 0.5),
    Unit('两', '两', 0.05),
    Unit('钱', '钱', 0.005),
    Unit('磅', 'lb', 0.45359237),
    Unit('盎司', 'oz', 0.028349523125),
    Unit('英石', 'st', 6.35029318),
    Unit('克拉', 'ct', 0.0002),
    Unit('美制短吨', 'ton', 907.18474),
    Unit('英制长吨', 'LT', 1016.0469088),
  ]),
  UnitCategory('温度', [
    Unit('摄氏度', '℃', 1, 0),
    // ℉ = ℃ × 9/5 + 32  →  以 ℃ 为基准：k = 5/9，b = -160/9（即 -32×5/9）
    Unit('华氏度', '℉', 5.0 / 9, -160.0 / 9),
    Unit('开尔文', 'K', 1, -273.15),
    Unit('兰氏度', '°R', 5.0 / 9, -273.15),
    // 列氏度：80 °Ré = 100 ℃  →  ℃ = °Ré × 1.25
    Unit('列氏度', '°Ré', 1.25, 0),
  ]),
  UnitCategory('速度', [
    Unit('米/秒', 'm/s', 1),
    Unit('千米/小时', 'km/h', 1.0 / 3.6),
    Unit('英里/小时', 'mph', 0.44704),
    Unit('节', 'kn', 0.5144444444444444),
    Unit('英尺/秒', 'ft/s', 0.3048),
    Unit('马赫', 'Ma', 340.3),
    Unit('光速', 'c', 299792458),
  ]),
  UnitCategory('时间', [
    Unit('秒', 's', 1),
    Unit('纳秒', 'ns', 1e-9),
    Unit('微秒', 'μs', 1e-6),
    Unit('毫秒', 'ms', 0.001),
    Unit('分钟', 'min', 60),
    Unit('刻钟', '刻', 900),
    Unit('小时', 'h', 3600),
    Unit('天', 'd', 86400),
    Unit('周', 'w', 604800),
    Unit('月(30天)', 'mo', 2592000),
    Unit('年(365天)', 'y', 31536000),
    Unit('回归年', 'a', 31556925.216),
  ]),
  UnitCategory('数据存储', [
    Unit('字节', 'B', 1),
    Unit('比特', 'bit', 0.125),
    Unit('千字节', 'KB', 1024),
    Unit('兆字节', 'MB', 1048576),
    Unit('吉字节', 'GB', 1073741824),
    Unit('太字节', 'TB', 1099511627776),
    Unit('拍字节', 'PB', 1125899906842624),
    Unit('艾字节', 'EB', 1.152921504606847e18),
    Unit('千字节(10³)', 'kB', 1000),
    Unit('兆字节(10⁶)', 'MB₁₀', 1e6),
    Unit('吉字节(10⁹)', 'GB₁₀', 1e9),
    Unit('太字节(10¹²)', 'TB₁₀', 1e12),
  ]),
  UnitCategory('角度', [
    Unit('度', '°', 1),
    Unit('弧度', 'rad', 57.29577951308232),
    Unit('百分度', 'grad', 0.9),
    Unit('角分', '′', 1.0 / 60),
    Unit('角秒', '″', 1.0 / 3600),
    Unit('转', 'turn', 360),
    Unit('毫弧度', 'mrad', 0.05729577951308232),
  ]),
  UnitCategory('压力', [
    Unit('帕斯卡', 'Pa', 1),
    Unit('千帕', 'kPa', 1000),
    Unit('兆帕', 'MPa', 1000000),
    Unit('巴', 'bar', 100000),
    Unit('毫巴', 'mbar', 100),
    Unit('标准大气压', 'atm', 101325),
    Unit('毫米汞柱', 'mmHg', 133.322387415),
    Unit('磅力/平方英寸', 'psi', 6894.757293168),
    Unit('千克力/平方厘米', 'kgf/cm²', 98066.5),
  ]),
  UnitCategory('能量 / 功', [
    Unit('焦耳', 'J', 1),
    Unit('千焦', 'kJ', 1000),
    Unit('卡', 'cal', 4.184),
    Unit('千卡 / 大卡', 'kcal', 4184),
    Unit('瓦时', 'Wh', 3600),
    Unit('千瓦时 / 度', 'kWh', 3600000),
    Unit('英热单位', 'BTU', 1055.05585262),
    Unit('英尺磅', 'ft·lb', 1.3558179483314004),
    Unit('尔格', 'erg', 1e-7),
    Unit('电子伏', 'eV', 1.602176634e-19),
  ]),
  UnitCategory('功率', [
    Unit('瓦特', 'W', 1),
    Unit('千瓦', 'kW', 1000),
    Unit('兆瓦', 'MW', 1000000),
    Unit('毫瓦', 'mW', 0.001),
    Unit('公制马力', 'PS', 735.49875),
    Unit('英制马力', 'hp', 745.6998715822702),
    Unit('千卡/小时', 'kcal/h', 1.163),
    Unit('英热单位/小时', 'BTU/h', 0.29307107017222),
  ]),
  UnitCategory('力', [
    Unit('牛顿', 'N', 1),
    Unit('千牛', 'kN', 1000),
    Unit('达因', 'dyn', 1e-5),
    Unit('千克力', 'kgf', 9.80665),
    Unit('磅力', 'lbf', 4.4482216152605),
    Unit('盎司力', 'ozf', 0.27801385095378125),
  ]),
  UnitCategory('频率', [
    Unit('赫兹', 'Hz', 1),
    Unit('千赫', 'kHz', 1000),
    Unit('兆赫', 'MHz', 1000000),
    Unit('吉赫', 'GHz', 1000000000),
    Unit('转/分', 'rpm', 1.0 / 60),
  ]),
  UnitCategory('密度', [
    Unit('千克/立方米', 'kg/m³', 1),
    Unit('克/立方厘米', 'g/cm³', 1000),
    Unit('克/毫升', 'g/mL', 1000),
    Unit('克/升', 'g/L', 1),
    Unit('千克/升', 'kg/L', 1000),
    Unit('磅/立方英尺', 'lb/ft³', 16.01846337396014),
    Unit('磅/美制加仑', 'lb/gal', 119.82642731689663),
  ]),
  UnitCategory('流量', [
    Unit('立方米/秒', 'm³/s', 1),
    Unit('立方米/小时', 'm³/h', 1.0 / 3600),
    Unit('升/秒', 'L/s', 0.001),
    Unit('升/分', 'L/min', 1.0 / 60000),
    Unit('美制加仑/分', 'gpm', 6.30901964e-5),
    Unit('立方英尺/分', 'cfm', 4.719474432e-4),
  ]),
  UnitCategory('光照度', [
    Unit('勒克斯', 'lx', 1),
    Unit('英尺烛光', 'fc', 10.763910416709722),
    Unit('福透', 'phot', 10000),
    Unit('诺克斯', 'nox', 0.001),
  ]),
  // 配速：单位是「时间 / 距离」，彼此之间是线性的；但跟「时速」是**倒数**关系，
  // 所以单独标记 pace，由页面额外算一行「折合时速」。
  UnitCategory(
    '配速',
    [
      Unit('分/千米', 'min/km', 1),
      Unit('分/英里', 'min/mi', 1 / 1.609344),
      Unit('秒/千米', 's/km', 1.0 / 60),
      Unit('秒/英里', 's/mi', 1 / 1.609344 / 60),
      Unit('分/100米', 'min/100m', 10),
    ],
    pace: true,
  ),
];

// ============================================================ 人民币大写

/// 数字 0~9 的汉字
const List<String> _cnDigit = ['零', '壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖'];

/// 节内单位：个、拾、佰、仟
const List<String> _cnUnit = ['', '拾', '佰', '仟'];

/// 节名：个、万、亿、万亿、亿亿（每 4 位一节）
const List<String> _cnSection = ['', '万', '亿', '万亿', '亿亿'];

/// 整数部分 → 汉字大写（不带「元」）。
///
/// 难点全在「零」的补法上，规则是：
///   * 连续多个 0 只写一个「零」；
///   * 一节全是 0 → 这一节不写数字，也不写节名（如 100000001 中间的「万」不写）；
///   * 末尾的 0 不写「零」（1230 → 壹仟贰佰叁拾，不是…叁拾零）。
///
/// 另外一位数前面不加「壹」，比如 12 → 拾贰 还是 壹拾贰？
/// 银行票据口径是 **壹拾贰**，所以这里统一带上「壹」。
String rmbUpperInt(String digits) {
  // 去掉前导 0；全 0 直接回「零」
  var s = digits.replaceFirst(RegExp(r'^0+'), '');
  if (s.isEmpty) return '零';

  final n = s.length;
  final sb = StringBuffer();
  var pendingZero = false; // 攒着一个「零」还没写出去

  for (var i = 0; i < n; i++) {
    final posFromRight = n - 1 - i; // 这一位从右数是第几位（0 起）
    final sec = posFromRight ~/ 4; // 第几节（4 位一节）
    final inSec = posFromRight % 4; // 节内位置：0=个 1=拾 2=佰 3=仟
    final d = s.codeUnitAt(i) - 0x30;

    if (d == 0) {
      pendingZero = true;
    } else {
      if (pendingZero && sb.isNotEmpty) sb.write('零');
      pendingZero = false;
      sb.write(_cnDigit[d]);
      sb.write(_cnUnit[inSec]);
    }

    // 一节处理完（走到了这一节的个位）→ 补这一节的节名
    if (inSec == 0) {
      // 这一节里有没有非 0 数字
      final segStart = i - 3 < 0 ? 0 : i - 3;
      var segHasDigit = false;
      for (var j = segStart; j <= i; j++) {
        if (s.codeUnitAt(j) != 0x30) {
          segHasDigit = true;
          break;
        }
      }
      if (segHasDigit) {
        sb.write(_cnSection[sec]);
      } else {
        // 整节全 0：不写节名，但要把「零」攒着，
        // 让后面那一节开头补一个（100010000 → 壹亿零壹万）
        if (sec > 0) pendingZero = sb.isNotEmpty;
      }
    }
  }

  // 收尾：如果最后攒了一个「零」说明末位是 0，按规则不写
  return sb.toString();
}

/// 金额 → 汉字大写（含「元 / 角 / 分」）。
///
/// 几个约定（照银行票据来）：
///   * 角分都为 0 → 末尾加「整」
///   * 只有角 → 「…元伍角整」；只有分 → 「…元零伍分」
///   * 不足 1 元：0.50 → 「伍角整」（**不写「零元」**）；0.05 → 「伍分」
///   * 0.00 → 「零元整」
String rmbUpperAmount(double v) {
  final neg = v < 0;
  var cents = (v.abs() * 100 + 0.5).floor(); // 四舍五入到分
  final yuan = cents ~/ 100;
  final jiao = (cents % 100) ~/ 10;
  final fen = cents % 10;

  final sb = StringBuffer();
  if (neg) sb.write('负');

  if (yuan > 0) {
    sb.write(rmbUpperInt(yuan.toString()));
    sb.write('元');
  }

  if (jiao == 0 && fen == 0) {
    // 整数金额
    if (yuan == 0) return '零元整';
    sb.write('整');
    return sb.toString();
  }

  if (jiao > 0) {
    sb.write(_cnDigit[jiao]);
    sb.write('角');
  } else if (yuan > 0) {
    // 有元、无角、有分 → 中间补「零」
    sb.write('零');
  }

  if (fen > 0) {
    sb.write(_cnDigit[fen]);
    sb.write('分');
  } else {
    // 只有角（fen == 0）→ 收「整」
    sb.write('整');
  }

  return sb.toString();
}

/// 汉字大写的单个数字 → 数值
int? _cnDigitValue(String c) {
  const map = {
    '零': 0, '〇': 0, '○': 0,
    '壹': 1, '一': 1, '幺': 1,
    '贰': 2, '貳': 2, '二': 2, '两': 2, '弍': 2,
    '叁': 3, '參': 3, '三': 3,
    '肆': 4, '四': 4,
    '伍': 5, '五': 5,
    '陆': 6, '陸': 6, '六': 6,
    '柒': 7, '七': 7,
    '捌': 8, '八': 8,
    '玖': 9, '九': 9,
  };
  return map[c];
}

/// 汉字大写的「单位」→ 倍率
int? _cnUnitValue(String c) {
  const map = {
    '拾': 10, '十': 10,
    '佰': 100, '百': 100,
    '仟': 1000, '千': 1000,
    '万': 10000, '萬': 10000,
    '亿': 100000000, '億': 100000000,
  };
  return map[c];
}

/// 汉字大写整数 → 数值。
///
/// 按「亿 / 万」把串切成大段，段内按「数×单位」累加；
/// `拾贰` 这种「单位在前、没有数字」的，把前导数字当作 1。
///
/// 解析失败返回 null（调用方据此提示「认不出」）。
int? rmbParseInt(String s) {
  if (s.isEmpty) return null;
  var total = 0; // 已结算的大段之和
  var section = 0; // 当前段内累加值
  var cur = 0; // 当前待用的数字
  var hasAny = false;

  for (final ch in s.split('')) {
    final d = _cnDigitValue(ch);
    if (d != null) {
      cur = d;
      hasAny = true;
      continue;
    }
    final u = _cnUnitValue(ch);
    if (u == null) return null; // 出现不认识的字
    hasAny = true;

    if (u >= 10000) {
      // 大段结束：把当前段（含游离的 cur）并进去，再乘段倍率
      section += cur;
      cur = 0;
      if (section == 0) section = 1; // 「万」单独出现当作 1 万
      total += section * u;
      section = 0;
    } else {
      // 段内小单位：拾贰 = 1×10 + 2
      if (cur == 0) cur = 1;
      section += cur * u;
      cur = 0;
    }
  }
  section += cur;
  final r = total + section;
  if (!hasAny) return null;
  return r;
}

/// 汉字大写**金额** → 数值（元）。
///
/// 只认「…元…角…分」「…角…分」「…分」这几种收尾；
/// 中间的「零」直接忽略（它只是占位）。
double? rmbParseAmount(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  var neg = false;
  if (t.startsWith('负') || t.startsWith('-')) {
    neg = true;
    t = t.substring(1);
  }

  var yuanPart = '';
  var jiaoPart = '';
  var fenPart = '';

  // 「整」只是收尾语，去掉
  t = t.replaceAll('整', '').replaceAll('正', '');

  final iYuan = t.indexOf('元');
  final iJiao = t.indexOf('角');
  final iFen = t.indexOf('分');

  if (iYuan >= 0) {
    yuanPart = t.substring(0, iYuan);
  }
  if (iJiao >= 0) {
    // 角前面的那个字才是数字（「零伍角」里的「伍」）
    final start = iYuan >= 0 ? iYuan + 1 : 0;
    final seg = t.substring(start, iJiao);
    jiaoPart = seg.isEmpty ? '' : seg.substring(seg.length - 1);
  }
  if (iFen >= 0) {
    final start = iJiao >= 0 ? iJiao + 1 : (iYuan >= 0 ? iYuan + 1 : 0);
    final seg = t.substring(start, iFen);
    fenPart = seg.isEmpty ? '' : seg.substring(seg.length - 1);
  }

  double yuan = 0;
  if (yuanPart.isNotEmpty) {
    // 「元」前面可能还拖着「零」，去掉再解析
    final cleaned = yuanPart.replaceAll(RegExp(r'^零+'), '');
    if (cleaned.isNotEmpty) {
      final n = rmbParseInt(cleaned);
      if (n == null) return null;
      yuan = n.toDouble();
    }
  }

  var jiao = 0;
  if (jiaoPart.isNotEmpty) {
    final n = _cnDigitValue(jiaoPart);
    if (n == null) return null;
    jiao = n;
  }
  var fen = 0;
  if (fenPart.isNotEmpty) {
    final n = _cnDigitValue(fenPart);
    if (n == null) return null;
    fen = n;
  }

  if (yuanPart.isEmpty && jiaoPart.isEmpty && fenPart.isEmpty) {
    // 一个「元/角/分」都没写（比如只写了「壹拾贰」）→ 整串当整数元看。
    // 不兜这一步的话，用户少写一个「元」字就整条报「认不出来」，太苛刻。
    if (iYuan < 0 && iJiao < 0 && iFen < 0) {
      final n = rmbParseInt(t);
      if (n == null) return null;
      return neg ? -n.toDouble() : n.toDouble();
    }
    return null;
  }

  final v = yuan + jiao / 10 + fen / 100;
  return neg ? -v : v;
}

/// 判断一段输入是「数字金额」还是「汉字大写」，并给出规范化结果。
///
/// 返回 `(是否数字输入, 数字值, 汉字, 出错信息)` 四元组不方便，
/// 所以直接返回一个结果类。
class RmbResult {
  /// 解析成功时的金额（元）
  final double? value;

  /// 规范化后的汉字大写
  final String upper;

  /// 出错信息，null 表示成功
  final String? error;

  const RmbResult({this.value, required this.upper, this.error});
}

/// 智能识别输入方向：像数字就当金额、否则按汉字大写解析，再互相补齐。
RmbResult rmbConvert(String input) {
  final t = input.trim();
  if (t.isEmpty) return const RmbResult(value: null, upper: '');

  // 1) 数字形态（允许千分位逗号、允许全角）
  final numish = t.replaceAll(',', '').replaceAll('，', '').replaceAll('．', '.');
  final asNum = double.tryParse(numish);
  if (asNum != null) {
    if (asNum.abs() >= 1e16) {
      return RmbResult(value: asNum, upper: '—', error: '金额太大，超出支持范围');
    }
    return RmbResult(value: asNum, upper: rmbUpperAmount(asNum));
  }

  // 2) 纯汉字形态
  final v = rmbParseAmount(t);
  if (v == null) {
    return const RmbResult(value: null, upper: '', error: '认不出来，请输入数字（如 1234.56）或汉字大写（如 壹仟贰佰叁拾肆元伍角陆分）');
  }
  return RmbResult(value: v, upper: rmbUpperAmount(v));
}
