import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../../platform/pigeon/download_notifications_adapter.dart';
import 'download_notifications_types.dart';

/// 通道名（与原生 `DownloadNotifications.CHANNEL` 对齐）。
const String kDownloadNotificationsChannel =
    'top.stillmisty.molia/download_notifications';

/// Android 下载类任务通知的旧 MethodChannel 实现（歌曲下载 / 应用更新）：
/// MethodChannel → 前台服务 + 系统通知。
///
/// issue #82 起 Pigeon transport 是主路径，本类保留为 fallback，直到契约测试 /
/// Android 冒烟通过。通道实现见 `android/app/src/main/kotlin/top/stillmisty/
/// molia/DownloadNotificationService.kt` 的 `DownloadNotifications` 对象
/// （dataSync 前台服务 + 进度通知；未授予通知权限时降级为「无通知但继续下载」）。
///
/// 其余 IO 平台（桌面 / iOS）与通道缺失（测试 / 独立服务）一律按不支持处理：
/// 所有方法 no-op，只记日志，不崩。
class MethodChannelDownloadNotifications implements DownloadNotifications {
  MethodChannelDownloadNotifications({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(kDownloadNotificationsChannel),
      _supported = supported ?? Platform.isAndroid;

  final MethodChannel _channel;

  /// 平台探测可注入（测试在桌面宿主上验证通道契约）。
  final bool _supported;

  static final Logger _logger = Logger('molia.download_notifications');

  @override
  bool get supported => _supported;

  @override
  Future<void> start({
    required String id,
    required String title,
    String subtitle = '',
    int? index,
    int? total,
    int? progress,
    int? max,
    DownloadNotificationChannel channel = DownloadNotificationChannel.downloads,
  }) => _invoke('start', {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'index': index,
    'total': total,
    'progress': progress,
    'max': max,
    'channel': channel.wireName,
  });

  @override
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  }) => _invoke('update', {
    'id': id,
    // null 表示「不改」：原生的 update 只覆盖非空字段。
    'title': title,
    'subtitle': subtitle,
    'index': index,
    'total': total,
    'progress': progress,
    'max': max,
  });

  @override
  Future<void> stop(String id) => _invoke('stop', {'id': id});

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (e) {
      // 通道缺失 / 原生失败：按「没有通知」处理，下载本身不受影响。
      _logger.warning('下载 / 更新通知 $method 失败（忽略）: $e');
    }
  }
}

/// Pigeon 优先、旧通道兜底的组合通知实现（issue #82）。
///
/// 只有 transport 不可用（首次调用异常 / 原生未注册 Pigeon）时才回退旧通道；
/// Pigeon 正常完成（含原生的权限降级 no-op）不重试，避免同一条通知被重复
/// start / stop。
class PigeonFirstDownloadNotifications implements DownloadNotifications {
  PigeonFirstDownloadNotifications({
    DownloadNotificationsTransport? pigeon,
    DownloadNotifications? fallback,
  }) : _pigeon = pigeon ?? PigeonDownloadNotificationsAdapter(),
       _fallback = fallback ?? MethodChannelDownloadNotifications();

  final DownloadNotificationsTransport _pigeon;
  final DownloadNotifications _fallback;

  @override
  bool get supported => _pigeon.supported;

  @override
  Future<void> start({
    required String id,
    required String title,
    String subtitle = '',
    int? index,
    int? total,
    int? progress,
    int? max,
    DownloadNotificationChannel channel = DownloadNotificationChannel.downloads,
  }) => _viaPigeonOrFallback(
    primary: () => _pigeon.start(
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
      channel: channel.wireName,
    ),
    fallback: () => _fallback.start(
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
      channel: channel,
    ),
  );

  @override
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  }) => _viaPigeonOrFallback(
    primary: () => _pigeon.update(
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
    ),
    fallback: () => _fallback.update(
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
    ),
  );

  @override
  Future<void> stop(String id) => _viaPigeonOrFallback(
    primary: () => _pigeon.stop(id),
    fallback: () => _fallback.stop(id),
  );

  /// 正常完成且 transport 仍可用时算 Pigeon 成功；否则回退旧通道。
  ///
  /// transport 可能已经吞掉异常并把结果降级成 no-op（适配器语义），
  /// 所以完成后还要复查 [DownloadNotificationsTransport.transportAvailable]。
  Future<void> _viaPigeonOrFallback({
    required Future<void> Function() primary,
    required Future<void> Function() fallback,
  }) async {
    if (_pigeon.transportAvailable) {
      try {
        await primary();
        if (_pigeon.transportAvailable) return;
      } catch (_) {
        // transport 异常：落到旧通道。
      }
    }
    await fallback();
  }
}

/// 工厂：`download_notifications.dart` 的唯一入口。
///
/// Android 优先 Pigeon channel，失败回退旧 MethodChannel；其余平台保持
/// `NoopDownloadNotifications` 语义（supported=false / 全部 no-op）。
DownloadNotifications createDownloadNotifications() {
  if (!Platform.isAndroid) return const NoopDownloadNotifications();
  return PigeonFirstDownloadNotifications();
}
