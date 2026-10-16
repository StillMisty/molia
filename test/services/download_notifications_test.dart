import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/download_notifications.dart';
import 'package:molia/data/downloads/download_notifications_io.dart';

/// 下载通知端口：通道契约（方法名 / 参数）、异常吞掉、平台不支持时全部 no-op。
///
/// 真实通知 / 前台服务在原生侧（`DownloadNotificationService.kt` 的
/// `DownloadNotifications` 对象），这里只验证 Dart 契约与降级行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kDownloadNotificationsChannel);
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('空实现：不支持且所有方法 no-op', () async {
    const notifications = NoopDownloadNotifications();
    expect(notifications.supported, isFalse);
    await notifications.start(id: 'track:kw:1', title: '歌名');
    await notifications.update(id: 'track:kw:1', progress: 1, max: 2);
    await notifications.stop('track:kw:1');
    expect(calls, isEmpty);
  });

  test('不支持的平台（桌面 / Web）：不触碰通道', () async {
    final notifications = MethodChannelDownloadNotifications(supported: false);
    expect(notifications.supported, isFalse);
    await notifications.start(id: 'batch', title: '歌名', index: 1, total: 3);
    await notifications.update(id: 'batch', progress: 1024, max: 2048);
    await notifications.stop('batch');
    expect(calls, isEmpty);
  });

  test('start / update / stop：方法名与结构化参数一一对应', () async {
    final notifications = MethodChannelDownloadNotifications(supported: true);
    expect(notifications.supported, isTrue);

    await notifications.start(
      id: 'track:kw:1',
      title: '歌名',
      subtitle: '歌手',
      progress: 0,
      max: 4096,
    );
    await notifications.update(
      id: 'track:kw:1',
      progress: 2048,
      max: 4096,
    );
    // 批量的「不改」字段传 null，换曲目时 max 传 0（回到不确定进度条）。
    await notifications.update(
      id: 'batch',
      title: '下一首',
      subtitle: '歌手',
      index: 2,
      total: 5,
      progress: 0,
      max: 0,
    );
    await notifications.stop('track:kw:1');

    expect(
      [for (final call in calls) call.method],
      ['start', 'update', 'update', 'stop'],
    );
    expect(calls[0].arguments, {
      'id': 'track:kw:1',
      'title': '歌名',
      'subtitle': '歌手',
      'index': null,
      'total': null,
      'progress': 0,
      'max': 4096,
    });
    expect(calls[1].arguments, {
      'id': 'track:kw:1',
      'title': null,
      'subtitle': null,
      'index': null,
      'total': null,
      'progress': 2048,
      'max': 4096,
    });
    expect(calls[2].arguments, {
      'id': 'batch',
      'title': '下一首',
      'subtitle': '歌手',
      'index': 2,
      'total': 5,
      'progress': 0,
      'max': 0,
    });
    expect(calls[3].arguments, {'id': 'track:kw:1'});
  });

  test('通道异常 / 缺失：吞掉异常不抛（下载链路不受影响）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'DOWNLOAD_NOTIFICATION_ERROR');
    });
    final notifications = MethodChannelDownloadNotifications(supported: true);
    await expectLater(
      notifications.start(id: 'batch', title: '歌名'),
      completes,
    );
    await expectLater(
      notifications.update(id: 'batch', progress: 1, max: 2),
      completes,
    );
    await expectLater(notifications.stop('batch'), completes);
  });
}
