import 'dart:io';

import 'package:flutter/services.dart';

import 'recorder.dart';

/// 后台录像的 Dart 侧封装（v1.6.0 新增）。
///
/// 通道名与 `MainActivity.kt` 的 `VIDEOREC_CHANNEL` 必须一致：`studyhub/videorec`。
///
/// ── 为什么要再写一个原生通道 ────────────────────────────
/// 原来的录像走 Flutter 的 `camera` 插件，只能在**前台**录：一退到后台，
/// Android 9 起会把相机会话掐掉，文件写不完。想「息屏 / 切后台继续录」，
/// 唯一的正路是把相机交给一个 `foregroundServiceType="camera"` 的前台服务
/// （Alibi 就是这么做的）。那段实现见 `MainActivity.kt` 的 `VideoRecorderService`。
///
/// 代价：相机同一时刻只能有一个持有者。交给服务之后，页面里就**没有实时画面**
/// 可看了。所以工具页保留了两种模式：
///   * 后台录像（走这里）—— 能息屏，没画面；
///   * 前台录像（走 camera 插件）—— 有画面，退到后台就停。
class VideoRecorder {
  VideoRecorder._();

  /// 与 `MainActivity.kt` 的 `VIDEOREC_CHANNEL` 必须逐字一致。
  static const MethodChannel _ch = MethodChannel('studyhub/videorec');

  /// 开始后台录像。
  ///
  /// [file] 必须是 [AudioRecorder.nextFile] 给的那个 —— 路径由原生直接交给
  /// `MediaRecorder`，所以必须是一段**真实路径**（不能用 content:// URI）。
  ///
  /// [lens] 是 `'back'` / `'front'`；[audio] 决定要不要录声音；
  /// [maxDurationMs] 是时长上限，0 = 不限。
  ///
  /// 同 [AudioRecorder.start]：这里会真的抛异常 —— 服务都拉不起来的话，
  /// 用户必须立刻知道，不能傻等一个不涨的计时器。
  static Future<void> start({
    required File file,
    String lens = 'back',
    bool audio = true,
    int maxDurationMs = 0,
  }) async {
    await _ch.invokeMethod<bool>('start', <String, Object?>{
      'path': file.path,
      'lens': lens,
      'audio': audio,
      'maxDurationMs': maxDurationMs,
    });
  }

  /// 停止录像并收尾（原生侧会 stop 会话、关相机、撤掉前台通知）。
  static Future<void> stop() async {
    await _ch.invokeMethod<bool>('stop');
  }

  /// 查一次状态。异常一律吞掉当成「没在录」——
  /// 这个方法每秒被调一次，出错刷屏没有意义。
  static Future<RecorderStatus> status() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('status');
      if (r == null) return const RecorderStatus();
      final ms = r['elapsedMs'];
      final err = r['error'];
      return RecorderStatus(
        running: r['running'] == true,
        elapsedMs: ms is num ? ms.toInt() : 0,
        error: err is String ? err : null,
      );
    } catch (_) {
      return const RecorderStatus();
    }
  }

  /// 清掉「还没来得及写就失败」的空壳文件。
  ///
  /// 什么时候会出现这种东西：`MediaRecorder.prepare()` 成功但相机开会话失败，
  /// 或者刚 `startForeground` 就被系统拒了 —— 文件已经建出来了，但一个字节都没有。
  /// 不删掉的话，用户的列表里会莫名其妙多出一条 0 字节、点了播不出来的录像。
  ///
  /// 只有**确认是 0 字节**才删，绝不碰任何有内容的文件。
  static Future<void> removeIfEmpty(File f) async {
    try {
      if (!await f.exists()) return;
      final len = await f.length();
      if (len == 0) await f.delete();
    } catch (_) {
      // 删除失败也无所谓，列表里会显示成 0 B，用户自己也能删
    }
  }
}
