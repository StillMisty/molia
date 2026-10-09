import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics_display/audio_route_monitor.dart';

/// A2DP 门控信号：探测 + 变化流（不触平台通道）。
void main() {
  test('探测初始值，变化流更新并通知', () async {
    final controller = StreamController<bool>.broadcast();
    final monitor = AudioRouteMonitor(
      probe: () async => true,
      changes: controller.stream,
    );
    final notifications = <bool>[];
    monitor.addListener(() => notifications.add(monitor.connected));

    await monitor.init();
    expect(monitor.connected, isTrue);
    // 初始探测本身是一次状态变化，清空后只验证后续变化。
    notifications.clear();

    controller.add(false);
    await pumpEventQueue();
    expect(monitor.connected, isFalse);
    expect(notifications, [false]);

    // 相同值不重复通知。
    controller.add(false);
    await pumpEventQueue();
    expect(notifications, [false]);

    monitor.dispose();
    await controller.close();
  });

  test('探测失败时保持未连接', () async {
    final monitor = AudioRouteMonitor(
      probe: () async => throw Exception('boom'),
      changes: const Stream<bool>.empty(),
    );
    await monitor.init();
    expect(monitor.connected, isFalse);
    monitor.dispose();
  });
}
