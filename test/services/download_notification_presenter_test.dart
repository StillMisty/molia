/// 下载通知 presenter：id 分配、批量共享一条「N/N」、系统频率节流与
/// 收尾不残留的唯一实现。
///
/// 真依赖（`FakeDownloadNotifications` 端口 + 真 `DownloadSettings` 开关）：
/// 只经公开事件方法断言端口收到的 start / update / stop，不读私有状态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_notification_presenter.dart';
import 'package:molia/services/download/download_settings.dart';

import '../support/fake_download_notifications.dart';

void main() {
  late FakeDownloadNotifications port;
  late DownloadNotificationPresenter presenter;
  var now = 1000;

  Track makeTrack({String title = '测试歌曲', String artist = '歌手'}) => Track(
        id: const TrackId('kw', '1'),
        title: title,
        artists: artist.isEmpty ? const [] : [Artist(name: artist)],
        origin: TrackOrigin.builtin,
      );

  List<DownloadNotificationEvent> updatesOf(
    FakeDownloadNotifications port,
  ) =>
      [
        for (final event in port.events)
          if (event.method == 'update') event,
      ];

  setUp(() {
    now = 1000;
    port = FakeDownloadNotifications();
    presenter = DownloadNotificationPresenter(
      notifications: port,
      clock: () => now,
    );
  });

  test('单任务：start → 进度节流（首片 / 500ms 窗口 / 完成突破）→ stop', () {
    presenter.startTask('kw:1', makeTrack());
    expect(port.methods, ['start']);
    expect(port.events.single.id, 'track:kw:1');
    expect(port.events.single.title, '测试歌曲');
    expect(port.events.single.subtitle, '歌手');

    // 首个分片无条件推送。
    presenter.reportProgress('kw:1', 1024, 4096);
    expect(port.methods, ['start', 'update']);
    expect(port.events.last.progress, 1024);
    expect(port.events.last.max, 4096);

    // 500ms 窗口内不推送（系统对通知更新有频率限制）。
    presenter.reportProgress('kw:1', 2048, 4096);
    expect(port.methods, ['start', 'update']);

    // 窗口过后推送新进度。
    now += 600;
    presenter.reportProgress('kw:1', 3072, 4096);
    expect(port.events.last.progress, 3072);

    // 已到最后一个分片：节流不拦收尾进度。
    presenter.reportProgress('kw:1', 4096, 4096);
    expect(port.events.last.progress, 4096);

    presenter.stopTask('kw:1');
    expect(port.methods.last, 'stop');
    expect(port.events.last.id, 'track:kw:1');
  });

  test('总大小未知：节流窗口内不推送（没有「完成」可突破）', () {
    presenter.startTask('kw:1', makeTrack());
    presenter.reportProgress('kw:1', 1, null);
    expect(updatesOf(port), hasLength(1));
    expect(port.events.last.max, isNull);

    presenter.reportProgress('kw:1', 2, null);
    expect(updatesOf(port), hasLength(1));

    now += 600;
    presenter.reportProgress('kw:1', 3, null);
    expect(updatesOf(port), hasLength(2));
  });

  test('开关关闭 / 平台不支持：全部 no-op；收尾不受开关影响', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();

    // 开关关闭：start 与进度都不发通知。
    final offPort = FakeDownloadNotifications();
    final off = DownloadNotificationPresenter(
      notifications: offPort,
      settings: settings,
      clock: () => now,
    );
    await settings.setNotifications(false);
    off.startTask('kw:1', makeTrack());
    off.reportProgress('kw:1', 1, 10);
    expect(offPort.events, isEmpty);
    expect(off.supported, isTrue, reason: '端口支持与开关是两回事');

    // 起过之后关掉开关：收尾仍然移除（只收自己起过的，不残留）。
    await settings.setNotifications(true);
    off.startTask('kw:1', makeTrack());
    expect(offPort.methods, ['start']);
    await settings.setNotifications(false);
    off.stopTask('kw:1');
    expect(offPort.methods, ['start', 'stop']);

    // 平台不支持（桌面 / iOS）：同样整体 no-op。
    final unsupportedPort = FakeDownloadNotifications(supported: false);
    final unsupported = DownloadNotificationPresenter(
      notifications: unsupportedPort,
      clock: () => now,
    );
    expect(unsupported.supported, isFalse);
    unsupported.startTask('kw:1', makeTrack());
    unsupported.reportProgress('kw:1', 1, 10);
    expect(unsupportedPort.events, isEmpty);
  });

  test('批量：整批共享一条「N/N」；批内单任务被抑制、进度路由批量 id', () {
    expect(presenter.beginBatch(3), isTrue);
    presenter.enterBatch(index: 1, key: 'kw:1', track: makeTrack(title: '第一首'));
    expect(port.methods, ['start']);
    expect(port.events.single.id, 'batch');
    expect(port.events.single.title, '第一首');
    expect(port.events.single.index, 1);
    expect(port.events.single.total, 3);

    // 批内当前曲目：单任务通知被抑制（否则逐条通知会闪成一串）。
    presenter.startTask('kw:1', makeTrack());
    expect(port.methods, ['start']);

    // 批内进度：走批量通知（同一条 id）。
    presenter.reportProgress('kw:1', 100, 1000);
    expect(port.events.last.id, 'batch');
    expect(port.events.last.progress, 100);

    // 进入下一首：update 顺延序号，进度条回到不确定态。
    now += 600;
    presenter.enterBatch(index: 2, key: 'tx:2', track: makeTrack(title: '第二首'));
    expect(port.events.last.method, 'update');
    expect(port.events.last.id, 'batch');
    expect(port.events.last.title, '第二首');
    expect(port.events.last.index, 2);
    expect(port.events.last.total, 3);
    expect(port.events.last.progress, 0);
    expect(port.events.last.max, 0);

    // 批内当前曲目的单任务收尾同样被抑制（批量通知统一表达）。
    presenter.stopTask('tx:2');
    expect(port.methods.where((method) => method == 'stop'), isEmpty);

    presenter.endBatch();
    expect(port.methods.last, 'stop');
    expect(port.events.last.id, 'batch');
  });

  test('批量：并发调用不抢占、空批量不起通知、结束后可再起', () {
    expect(presenter.beginBatch(0), isFalse, reason: '空批量没有「N/N」可言');
    expect(presenter.beginBatch(2), isTrue);
    expect(presenter.beginBatch(2), isFalse, reason: '已有批量在跑（服务端只有一个批量 id）');
    presenter.enterBatch(index: 1, key: 'kw:1', track: makeTrack());
    presenter.endBatch();
    expect(presenter.beginBatch(2), isTrue, reason: '上一批结束后可再起');
    presenter.enterBatch(index: 1, key: 'kw:1', track: makeTrack());
    expect(port.events.first.id, 'batch');
    presenter.endBatch();
    expect(port.methods.last, 'stop');
  });
}
