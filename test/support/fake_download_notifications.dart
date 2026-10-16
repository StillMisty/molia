import 'package:molia/data/downloads/download_notifications.dart';

/// 一次下载通知调用（下载服务测试断言用）。
typedef DownloadNotificationEvent = ({
  String method,
  String id,
  String? title,
  String? subtitle,
  int? index,
  int? total,
  int? progress,
  int? max,
});

/// 内存下载通知（下载服务测试用）：记录生命周期调用，可控制支持与否。
class FakeDownloadNotifications implements DownloadNotifications {
  FakeDownloadNotifications({this.supported = true});

  /// [supported] 为 false 时模拟非 Android 平台（通知整体 no-op）。
  @override
  bool supported;

  /// 生命周期调用（按调用顺序）。
  final List<DownloadNotificationEvent> events = [];

  /// 只取方法名的简写（断言顺序用，如 `['start', 'update', 'stop']`）。
  List<String> get methods => [for (final event in events) event.method];

  @override
  Future<void> start({
    required String id,
    required String title,
    String subtitle = '',
    int? index,
    int? total,
    int? progress,
    int? max,
  }) async {
    if (!supported) return;
    events.add((
      method: 'start',
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
    ));
  }

  @override
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  }) async {
    if (!supported) return;
    events.add((
      method: 'update',
      id: id,
      title: title,
      subtitle: subtitle,
      index: index,
      total: total,
      progress: progress,
      max: max,
    ));
  }

  @override
  Future<void> stop(String id) async {
    if (!supported) return;
    events.add((
      method: 'stop',
      id: id,
      title: null,
      subtitle: null,
      index: null,
      total: null,
      progress: null,
      max: null,
    ));
  }
}
