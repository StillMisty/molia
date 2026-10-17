import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'download_notifications_types.dart';

/// 通道名（与原生 `DownloadNotifications.CHANNEL` 对齐）。
const String kDownloadNotificationsChannel =
    'top.stillmisty.molia/download_notifications';

/// Android 下载通知实现：MethodChannel → 前台服务 + 系统通知。
///
/// 通道实现见 `android/app/src/main/kotlin/top/stillmisty/molia/
/// DownloadNotificationService.kt` 的 `DownloadNotifications` 对象
/// （dataSync 前台服务 + 进度通知；未授予通知权限时降级为「无通知但继续下载」）。
///
/// 其余 IO 平台（桌面 / iOS）与通道缺失（测试 / 独立服务）一律按不支持处理：
/// 所有方法 no-op，只记日志，不崩。
class MethodChannelDownloadNotifications implements DownloadNotifications {
  MethodChannelDownloadNotifications({MethodChannel? channel, bool? supported})
      : _channel =
            channel ?? const MethodChannel(kDownloadNotificationsChannel),
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
  }) =>
      _invoke('start', {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'index': index,
        'total': total,
        'progress': progress,
        'max': max,
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
  }) =>
      _invoke('update', {
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
      _logger.warning('下载通知 $method 失败（忽略）: $e');
    }
  }
}

/// 工厂：`download_notifications.dart` 的唯一入口。
DownloadNotifications createDownloadNotifications() =>
    MethodChannelDownloadNotifications();
