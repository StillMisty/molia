import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/app_presence.dart';

/// 窗口存在态：三态翻转、幂等与通知次数。
///
/// 消费面（内存守卫 / 预取门控 / 托盘休眠）都按「值变化才动作」假设实现，
/// 因此这里把「重复置位不通知」也钉住。
void main() {
  test('初始可见；三态互转', () {
    final presence = AppPresence();
    expect(presence.value, AppPresenceState.visible);
    expect(presence.isVisible, isTrue);
    expect(presence.isBackgrounded, isFalse);
    expect(presence.isTrayHidden, isFalse);

    presence.markTrayHidden();
    expect(presence.value, AppPresenceState.trayHidden);
    expect(presence.isBackgrounded, isTrue);
    expect(presence.isTrayHidden, isTrue);

    presence.markMinimized();
    expect(presence.value, AppPresenceState.minimized);
    expect(presence.isTrayHidden, isFalse);

    presence.markVisible();
    expect(presence.value, AppPresenceState.visible);
    expect(presence.isVisible, isTrue);
  });

  test('重复置位同一状态不通知', () {
    final presence = AppPresence();
    var notifications = 0;
    presence.addListener(() => notifications++);

    presence.markVisible();
    expect(notifications, 0);

    presence.markTrayHidden();
    presence.markTrayHidden();
    expect(notifications, 1);

    presence.markVisible();
    presence.markVisible();
    expect(notifications, 2);

    presence.dispose();
  });

  test('可指定初始状态（启动即托盘隐藏的校正路径）', () {
    final presence = AppPresence(AppPresenceState.trayHidden);
    expect(presence.isTrayHidden, isTrue);
    presence.dispose();
  });
}
