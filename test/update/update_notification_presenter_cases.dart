/// 应用更新通知 presenter：固定 id / update 渠道 / 500ms 节流 / 幂等收尾。
///
/// 真依赖 `FakeDownloadNotifications` 端口，只经公开事件断言 start / update /
/// stop，不读 presenter 私有状态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/download_notifications.dart';
import 'package:molia/services/app_branding_service.dart';
import 'package:molia/services/update/update_notification_presenter.dart';

import '../support/fake_download_notifications.dart';

void main() {
  late FakeDownloadNotifications port;
  late UpdateNotificationPresenter presenter;
  var now = 1000;

  setUp(() {
    now = 1000;
    port = FakeDownloadNotifications();
    presenter = UpdateNotificationPresenter(
      notifications: port,
      clock: () => now,
    );
  });

  test('start：固定 id / update 渠道 / 版本副标题 / 0 进度', () {
    presenter.start(version: '1.2.3');

    expect(port.methods, ['start']);
    final event = port.events.single;
    expect(event.id, UpdateNotificationPresenter.notificationId);
    expect(event.title, 'Molia');
    expect(event.subtitle, '1.2.3');
    expect(event.progress, 0);
    expect(event.channel, DownloadNotificationChannel.update);
  });

  test('标题默认跟随应用显示名（AppBrandingService.titleNotifier）', () {
    final original = AppBrandingService.titleNotifier.value;
    addTearDown(() => AppBrandingService.titleNotifier.value = original);
    AppBrandingService.titleNotifier.value = '我的播放器';

    // presenter 在 setUp 里已构造：标题在 start 时读取，改名后立刻生效。
    presenter.start(version: '1.2.3');

    expect(port.events.single.title, '我的播放器');
  });

  test('标题可通过构造参数注入（测试 / 宿主自定义）', () {
    final injected = UpdateNotificationPresenter(
      notifications: port,
      title: () => '自定义标题',
      clock: () => now,
    );

    injected.start(version: '1.2.3');

    expect(port.events.single.title, '自定义标题');
  });

  test('进度：首个分片立即 / 500ms 窗口节流 / 100% 立即突破', () {
    presenter.start(version: '1.2.3');

    // 首个分片无条件推送。
    presenter.updateProgress(1024, 4096);
    expect(port.methods, ['start', 'update']);
    expect(port.events.last.progress, 1024);
    expect(port.events.last.max, 4096);

    // 500ms 窗口内不推送（系统对通知更新有频率限制）。
    now += 100;
    presenter.updateProgress(2048, 4096);
    expect(port.methods, ['start', 'update']);

    // 窗口未满 500ms 仍不推送。
    now += 399;
    presenter.updateProgress(3072, 4096);
    expect(port.methods, ['start', 'update']);

    // 窗口过后推送新进度。
    now += 1;
    presenter.updateProgress(3072, 4096);
    expect(port.methods, ['start', 'update', 'update']);
    expect(port.events.last.progress, 3072);

    // 100% 不等窗口：最后一片立即推送，避免停在 99%。
    now += 1;
    presenter.updateProgress(4096, 4096);
    expect(port.methods, ['start', 'update', 'update', 'update']);
    expect(port.events.last.progress, 4096);
  });

  test('总大小未知（total ≤ 0）：max 传 0，通知显示不确定进度', () {
    presenter.start(version: '1.2.3');

    presenter.updateProgress(100, -1);
    expect(port.events.last.progress, 100);
    expect(port.events.last.max, 0);

    // 没有「完成」可突破：窗口内不推送。
    presenter.updateProgress(200, 0);
    expect(port.methods, ['start', 'update']);

    now += 500;
    presenter.updateProgress(300, -1);
    expect(port.events.last.progress, 300);
    expect(port.events.last.max, 0);
  });

  test('stop：未 start 过不动端口；重复调用幂等', () {
    presenter.stop();
    expect(port.events, isEmpty);

    presenter.start(version: '1.2.3');
    presenter.stop();
    expect(port.methods, ['start', 'stop']);
    expect(port.events.last.id, UpdateNotificationPresenter.notificationId);

    presenter.stop();
    expect(port.methods, ['start', 'stop']);
  });

  test('未 start 前收到进度：忽略（不凭空起通知）', () {
    presenter.updateProgress(1024, 4096);
    expect(port.events, isEmpty);
  });

  test('平台不支持（桌面 / 测试）：start / update / stop 全部 no-op', () {
    final unsupported = FakeDownloadNotifications(supported: false);
    final noopPresenter = UpdateNotificationPresenter(
      notifications: unsupported,
      clock: () => now,
    );

    expect(noopPresenter.supported, isFalse);
    noopPresenter.start(version: '1.2.3');
    noopPresenter.updateProgress(1024, 4096);
    noopPresenter.stop();

    expect(unsupported.events, isEmpty);
  });
}
