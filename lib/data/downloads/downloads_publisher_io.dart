import 'dart:io';

import 'package:flutter/services.dart';

import 'downloads_publisher_types.dart';

/// Android 公共 Downloads 发布器：MethodChannel → MediaStore。
///
/// 通道实现见 `android/app/src/main/kotlin/top/stillmisty/molia/MainActivity.kt`
/// 的 `top.stillmisty.molia/downloads`（API 29+ `MediaStore.Downloads`
/// insert + openOutputStream，无需存储权限）。
///
/// 其余 IO 平台（桌面 / iOS）与通道缺失（测试 / 独立服务）一律按不支持处理：
/// 发布返回 null、删除返回 false，调用方只记日志，不崩。
class MethodChannelDownloadsPublisher implements DownloadsPublisher {
  MethodChannelDownloadsPublisher({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('top.stillmisty.molia/downloads');

  final MethodChannel _channel;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('publish', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': mimeType,
      });
    } catch (_) {
      // 通道异常 / 原生失败：按发布失败处理（best-effort）。
      return null;
    }
  }

  @override
  Future<bool> remove(String uri) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('remove', {'uri': uri}) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 工厂：`downloads_publisher.dart` 的条件导入入口。
DownloadsPublisher createDownloadsPublisher() =>
    MethodChannelDownloadsPublisher();
