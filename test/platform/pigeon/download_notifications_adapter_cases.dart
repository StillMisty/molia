import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/download_notifications_io.dart';
import 'package:molia/data/downloads/download_notifications_types.dart';
import 'package:molia/platform/pigeon/download_notifications_adapter.dart';
import 'package:molia/platform/pigeon/download_notifications.g.dart';

/// 假 Pigeon host：覆盖成功、异常与非 Android 分支。
class _FakeHostApi implements DownloadNotificationsHostApi {
  bool throwOnStart = false;
  bool throwOnUpdate = false;
  bool throwOnStop = false;

  int startCalls = 0;
  int updateCalls = 0;
  int stopCalls = 0;

  StartRequest? lastStart;
  UpdateRequest? lastUpdate;
  String? lastStopId;

  @override
  Future<void> start(StartRequest request) async {
    startCalls++;
    lastStart = request;
    if (throwOnStart) throw StateError('pigeon start failed');
  }

  @override
  Future<void> update(UpdateRequest request) async {
    updateCalls++;
    lastUpdate = request;
    if (throwOnUpdate) throw StateError('pigeon update failed');
  }

  @override
  Future<void> stop(String id) async {
    stopCalls++;
    lastStopId = id;
    if (throwOnStop) throw StateError('pigeon stop failed');
  }
}

/// 旧通道 fallback 的假实现。
class _FakeFallbackNotifications implements DownloadNotifications {
  final List<String> calls = [];

  @override
  bool get supported => true;

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
  }) async {
    calls.add('start:$id:${channel.wireName}');
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
    calls.add('update:$id');
  }

  @override
  Future<void> stop(String id) async {
    calls.add('stop:$id');
  }
}

void main() {
  group('PigeonDownloadNotificationsAdapter', () {
    test('Android 成功路径：结构化参数原样传给生成 API', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadNotificationsAdapter(
        api: host,
        isAndroid: true,
      );

      expect(adapter.supported, isTrue);
      await adapter.start(
        id: 'track:kw:1',
        title: '歌名',
        subtitle: '歌手',
        progress: 0,
        max: 4096,
      );
      await adapter.update(
        id: 'track:kw:1',
        title: '下一首',
        subtitle: '歌手',
        index: 2,
        total: 5,
        progress: 0,
        max: 0,
      );
      await adapter.stop('track:kw:1');

      expect(host.startCalls, 1);
      expect(host.lastStart?.id, 'track:kw:1');
      expect(host.lastStart?.title, '歌名');
      expect(host.lastStart?.subtitle, '歌手');
      expect(host.lastStart?.index, isNull);
      expect(host.lastStart?.total, isNull);
      expect(host.lastStart?.progress, 0);
      expect(host.lastStart?.max, 4096);
      // 不传 channel 时保持「下载」渠道 wire 值。
      expect(host.lastStart?.channel, 'downloads');

      expect(host.updateCalls, 1);
      expect(host.lastUpdate?.id, 'track:kw:1');
      expect(host.lastUpdate?.index, 2);
      expect(host.lastUpdate?.total, 5);
      expect(host.lastUpdate?.progress, 0);
      // max 0 = 「总大小未知」，必须与「不改」（null）区分。
      expect(host.lastUpdate?.max, 0);

      expect(host.stopCalls, 1);
      expect(host.lastStopId, 'track:kw:1');
      expect(adapter.transportAvailable, isTrue);
    });

    test('update 的可空字段保持 null（表示不改）', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadNotificationsAdapter(
        api: host,
        isAndroid: true,
      );

      await adapter.update(id: 'batch');

      expect(host.lastUpdate?.id, 'batch');
      expect(host.lastUpdate?.title, isNull);
      expect(host.lastUpdate?.subtitle, isNull);
      expect(host.lastUpdate?.index, isNull);
      expect(host.lastUpdate?.total, isNull);
      expect(host.lastUpdate?.progress, isNull);
      expect(host.lastUpdate?.max, isNull);
    });

    test('空 id 不进原生：语义与旧通道 / 原生侧一致', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadNotificationsAdapter(
        api: host,
        isAndroid: true,
      );

      await adapter.start(id: '', title: '歌名');
      await adapter.update(id: '');
      await adapter.stop('');

      expect(host.startCalls, 0);
      expect(host.updateCalls, 0);
      expect(host.stopCalls, 0);
      expect(adapter.transportAvailable, isTrue);
    });

    test('异常静默降级，并永久标记 transport 不可用', () async {
      final host = _FakeHostApi()
        ..throwOnStart = true
        ..throwOnUpdate = true
        ..throwOnStop = true;
      final adapter = PigeonDownloadNotificationsAdapter(
        api: host,
        isAndroid: true,
      );

      await expectLater(adapter.start(id: 'batch', title: '歌名'), completes);
      expect(adapter.transportAvailable, isFalse);
      // 已标记不可用：后续调用不再触碰生成 API，也不抛。
      await expectLater(adapter.update(id: 'batch', progress: 1), completes);
      await expectLater(adapter.stop('batch'), completes);
      expect(host.updateCalls, 0);
      expect(host.stopCalls, 0);
    });

    test('非 Android：不触碰生成 API，保持 no-op 语义', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadNotificationsAdapter(
        api: host,
        isAndroid: false,
      );

      expect(adapter.supported, isFalse);
      expect(adapter.transportAvailable, isFalse);
      await adapter.start(id: 'batch', title: '歌名');
      await adapter.update(id: 'batch', progress: 1);
      await adapter.stop('batch');
      expect(host.startCalls, 0);
      expect(host.updateCalls, 0);
      expect(host.stopCalls, 0);
    });
  });

  group('PigeonFirstDownloadNotifications', () {
    test('Pigeon 正常时使用其结果，不调用旧通道', () async {
      final host = _FakeHostApi();
      final fallback = _FakeFallbackNotifications();
      final notifications = PigeonFirstDownloadNotifications(
        pigeon: PigeonDownloadNotificationsAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      expect(notifications.supported, isTrue);
      await notifications.start(
        id: 'app-update',
        title: 'Molia',
        subtitle: '1.2.3',
        channel: DownloadNotificationChannel.update,
      );
      await notifications.update(id: 'app-update', progress: 1, max: 2);
      await notifications.stop('app-update');

      // 渠道 enum 在 data 层映射成 wireName，平台层只认字符串。
      expect(host.lastStart?.channel, 'update');
      expect(host.startCalls, 1);
      expect(host.updateCalls, 1);
      expect(host.stopCalls, 1);
      expect(fallback.calls, isEmpty);
    });

    test('Pigeon transport 异常时回退旧通道（含渠道映射）', () async {
      final host = _FakeHostApi()
        ..throwOnStart = true
        ..throwOnUpdate = true
        ..throwOnStop = true;
      final fallback = _FakeFallbackNotifications();
      final notifications = PigeonFirstDownloadNotifications(
        pigeon: PigeonDownloadNotificationsAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      await notifications.start(
        id: 'app-update',
        title: 'Molia',
        channel: DownloadNotificationChannel.update,
      );
      await notifications.update(id: 'app-update', progress: 1, max: 2);
      await notifications.stop('app-update');

      expect(fallback.calls, [
        'start:app-update:update',
        'update:app-update',
        'stop:app-update',
      ]);
      // 首次异常后 transport 永久不可用，后续直接走旧通道。
      expect(host.updateCalls, 0);
      expect(host.stopCalls, 0);
    });

    test('Pigeon 正常完成的 no-op 不重试旧通道', () async {
      // 原生权限不可用时 start 正常返回、不抛异常：视为真实结果。
      final host = _FakeHostApi();
      final fallback = _FakeFallbackNotifications();
      final notifications = PigeonFirstDownloadNotifications(
        pigeon: PigeonDownloadNotificationsAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      await notifications.start(id: 'batch', title: '歌名');
      await notifications.start(id: 'batch', title: '歌名');

      expect(host.startCalls, 2);
      expect(fallback.calls, isEmpty);
    });

    test('非 Android 工厂返回 Noop 语义', () async {
      final notifications = createDownloadNotifications();
      expect(notifications.supported, isFalse);
      await notifications.start(id: 'batch', title: '歌名');
      await notifications.update(id: 'batch', progress: 1, max: 2);
      await notifications.stop('batch');
    });
  });
}
