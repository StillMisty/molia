import 'dart:io';

import 'package:flutter/services.dart';

import '../../platform/pigeon/downloads_publisher_adapter.dart';
import 'downloads_publisher_types.dart';

/// Android 公共 Downloads 发布器：旧 MethodChannel → MediaStore。
///
/// 通道实现见
/// `android/app/src/main/kotlin/top/stillmisty/molia/downloads/DownloadsPublisherHost.kt`
/// （`top.stillmisty.molia/downloads`，API 29+ `MediaStore.Downloads` insert +
/// openOutputStream，无需存储权限）。issue #80 起 Pigeon transport 是主路径，
/// 本类保留为 fallback，直到契约测试 / Android 冒烟通过。
///
/// 其余 IO 平台（桌面 / iOS）与通道缺失（测试 / 独立服务）一律按不支持处理：
/// 发布返回 null、删除返回 false，调用方只记日志，不崩。
class MethodChannelDownloadsPublisher implements DownloadsPublisher {
  MethodChannelDownloadsPublisher({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('top.stillmisty.molia/downloads');

  final MethodChannel _channel;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<String?> publicRoot() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('publicRoot');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('publish', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': mimeType,
        'relativeDir': relativeDir,
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

/// Pigeon 优先、旧通道兜底的组合发布器（issue #80）。
///
/// 只有 transport 不可用（首次调用异常 / 原生未注册 Pigeon）时才回退旧通道；
/// Pigeon 正常返回 null / false 视为真实结果，不重试，避免重复发布公共副本。
class PigeonFirstDownloadsPublisher implements DownloadsPublisher {
  PigeonFirstDownloadsPublisher({
    DownloadsPublisherTransport? pigeon,
    DownloadsPublisher? fallback,
  }) : _pigeon = pigeon ?? PigeonDownloadsPublisherAdapter(),
       _fallback = fallback ?? MethodChannelDownloadsPublisher();

  final DownloadsPublisherTransport _pigeon;
  final DownloadsPublisher _fallback;

  @override
  bool get supported => _pigeon.supported;

  @override
  Future<String?> publicRoot() => _viaPigeonOrFallback(
    primary: _pigeon.publicRoot,
    fallback: _fallback.publicRoot,
  );

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) => _viaPigeonOrFallback(
    primary: () => _pigeon.publish(
      sourcePath: sourcePath,
      displayName: displayName,
      mimeType: mimeType,
      relativeDir: relativeDir,
    ),
    fallback: () => _fallback.publish(
      sourcePath: sourcePath,
      displayName: displayName,
      mimeType: mimeType,
      relativeDir: relativeDir,
    ),
  );

  @override
  Future<bool> remove(String uri) => _viaPigeonOrFallback(
    primary: () => _pigeon.remove(uri),
    fallback: () => _fallback.remove(uri),
  );

  /// 正常完成且 transport 仍可用时返回 Pigeon 结果；否则回退旧通道。
  ///
  /// transport 可能已经吞掉异常并把结果降级成 null（适配器语义），
  /// 所以完成后还要复查 [DownloadsPublisherTransport.transportAvailable]。
  Future<T> _viaPigeonOrFallback<T>({
    required Future<T> Function() primary,
    required Future<T> Function() fallback,
  }) async {
    if (_pigeon.transportAvailable) {
      try {
        final value = await primary();
        if (_pigeon.transportAvailable) return value;
      } catch (_) {
        // transport 异常：落到旧通道。
      }
    }
    return fallback();
  }
}

/// 工厂：`downloads_publisher.dart` 的唯一入口。
///
/// Android 优先 Pigeon channel，失败回退旧 MethodChannel；其余平台保持
/// `NoopDownloadsPublisher` 语义（supported=false / null / false）。
DownloadsPublisher createDownloadsPublisher() {
  if (!Platform.isAndroid) return const NoopDownloadsPublisher();
  return PigeonFirstDownloadsPublisher();
}
