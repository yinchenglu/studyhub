import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 极简 ZIP 读取器（**只读**，不做写）。
///
/// 为什么自己写而不是用 archive 包：
///   EPUB 就是个 zip。但这个项目对 pubspec 极度保守 —— archive 一旦声明成直接依赖，
///   就会和 xml / syncfusion 那几条链打架（pubspec 里已经写满了这类血泪注释）。
///   而「解 raw deflate」这件事 dart:io 自带：ZLibDecoder(raw: true)。
///   于是整个 zip 只需要「读懂中央目录」这一步，一百多行就够，
///   pubspec 一个字节都不用改。
///
/// 支持：stored(0) / deflate(8)、zip64 的尺寸与偏移、UTF-8 名字标志位。
/// 不支持：加密 zip、zstd 等新压缩法、多卷 —— 电子书不会用到。
class ZipReader {
  static const int _sigEocd = 0x06054b50;
  static const int _sigZip64Eocd = 0x06064b50;
  static const int _sigZip64Loc = 0x07064b50;
  static const int _sigCentral = 0x02014b50;
  static const int _sigLocal = 0x04034b50;

  static const int _u32max = 0xFFFFFFFF;

  final Uint8List _d;
  final Map<String, _ZipEntry> _byName;
  final Map<String, String> _byLower;

  ZipReader._(this._d, this._byName, this._byLower);

  /// 包里的全部条目名
  List<String> get names => _byName.keys.toList();

  bool has(String name) => _find(name) != null;

  /// 读某个条目；不存在直接抛错
  Uint8List read(String name) {
    final e = _find(name);
    if (e == null) throw ArgumentError('zip 里没有「$name」');
    return _extract(e);
  }

  /// 读某个条目；不存在或解压失败都返回 null
  Uint8List? tryRead(String name) {
    final e = _find(name);
    if (e == null) return null;
    try {
      return _extract(e);
    } catch (_) {
      return null;
    }
  }

  /// 按名字读一段文本；失败返回 null
  String? tryReadText(String name) {
    final b = tryRead(name);
    if (b == null) return null;
    return utf8.decode(b, allowMalformed: true);
  }

  _ZipEntry? _find(String n) {
    final hit = _byName[n];
    if (hit != null) return hit;
    // zip 规范要求名字比较时不区分大小写（EPUB 也这么规定）
    final real = _byLower[n.toLowerCase()];
    return real == null ? null : _byName[real];
  }

  // ---------------------------------------------------------------- 解析

  static ZipReader parse(Uint8List data) {
    if (data.length < 22) throw const FormatException('不是 zip：文件太短');

    // 1) 从尾巴往前找「中央目录结束记录」。注释最长 65535，所以最多回溯这么多。
    var eocd = -1;
    final lowest = data.length - 22 - 65535;
    for (var i = data.length - 22; i >= 0 && i >= lowest; i--) {
      if (_u32(data, i) == _sigEocd) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('不是 zip：找不到中央目录');

    var count = _u16(data, eocd + 10);
    var cdOff = _u32(data, eocd + 16);

    // 2) zip64 兜底：EOCD 里写不下时那几个字段全是 0xFFFFFFFF
    if (count == 0xFFFF || cdOff == _u32max) {
      final loc = eocd - 20;
      if (loc >= 0 && _u32(data, loc) == _sigZip64Loc) {
        final z64 = _u64(data, loc + 8);
        if (z64 >= 0 && z64 + 56 <= data.length && _u32(data, z64) == _sigZip64Eocd) {
          count = _u64(data, z64 + 32);
          cdOff = _u64(data, z64 + 48);
        }
      }
    }
    if (cdOff < 0 || cdOff >= data.length) throw const FormatException('zip 中央目录位置越界');

    // 3) 逐条读中央目录
    final byName = <String, _ZipEntry>{};
    final byLower = <String, String>{};
    var p = cdOff;
    for (var i = 0; i < count; i++) {
      if (p + 46 > data.length || _u32(data, p) != _sigCentral) break;
      final method = _u16(data, p + 10);
      var compSize = _u32(data, p + 20);
      var rawSize = _u32(data, p + 24);
      final nameLen = _u16(data, p + 28);
      final extraLen = _u16(data, p + 30);
      final cmtLen = _u16(data, p + 32);
      var localOff = _u32(data, p + 42);

      final nameStart = p + 46;
      if (nameStart + nameLen > data.length) break;
      final name = utf8.decode(
        Uint8List.sublistView(data, nameStart, nameStart + nameLen),
        allowMalformed: true,
      );

      // zip64 扩展字段：只在本条的那几个值被写成 0xFFFFFFFF 时才有内容
      if (compSize == _u32max || rawSize == _u32max || localOff == _u32max) {
        final ex = nameStart + nameLen;
        var q = ex;
        final exEnd = ex + extraLen;
        while (q + 4 <= exEnd && q + 4 <= data.length) {
          final id = _u16(data, q);
          final size = _u16(data, q + 2);
          if (id == 0x0001) {
            var r = q + 4;
            if (rawSize == _u32max && r + 8 <= data.length) {
              rawSize = _u64(data, r);
              r += 8;
            }
            if (compSize == _u32max && r + 8 <= data.length) {
              compSize = _u64(data, r);
              r += 8;
            }
            if (localOff == _u32max && r + 8 <= data.length) {
              localOff = _u64(data, r);
              r += 8;
            }
            break;
          }
          q += 4 + size;
        }
      }

      final key = name.trim();
      if (key.isNotEmpty && !key.endsWith('/')) {
        byName[key] = _ZipEntry(key, method, compSize, rawSize, localOff);
        byLower.putIfAbsent(key.toLowerCase(), () => key);
      }
      p = nameStart + nameLen + extraLen + cmtLen;
    }

    if (byName.isEmpty) throw const FormatException('zip 里一个文件都没有');
    return ZipReader._(data, byName, byLower);
  }

  Uint8List _extract(_ZipEntry e) {
    if (e.method != 0 && e.method != 8) {
      throw FormatException('压缩方式 ${e.method} 不支持');
    }
    if (e.offset < 0 || e.offset + 30 > _d.length || _u32(_d, e.offset) != _sigLocal) {
      throw const FormatException('zip 条目头损坏');
    }
    final nameLen = _u16(_d, e.offset + 26);
    final extraLen = _u16(_d, e.offset + 28);
    final start = e.offset + 30 + nameLen + extraLen;
    final end = start + e.compSize;
    if (start < 0 || end > _d.length) throw const FormatException('zip 条目数据越界');
    final raw = Uint8List.sublistView(_d, start, end);
    if (e.method == 0) return Uint8List.fromList(raw);
    return Uint8List.fromList(const ZLibDecoder(raw: true).convert(raw));
  }

  // ---------------------------------------------------------------- 小工具

  static int _u16(Uint8List d, int i) => d[i] | (d[i + 1] << 8);

  static int _u32(Uint8List d, int i) =>
      d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24);

  static int _u64(Uint8List d, int i) => _u32(d, i) + _u32(d, i + 4) * 0x100000000;
}

class _ZipEntry {
  final String name;
  final int method;
  final int compSize;
  final int rawSize;
  final int offset;

  const _ZipEntry(this.name, this.method, this.compSize, this.rawSize, this.offset);
}
