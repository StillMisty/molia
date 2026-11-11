import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/app_lifecycle_coordinator.dart';

/// 生命周期扇出：三个事件各走各的注册表；paused 不触发 hidden 动作，
/// 避免桌面 hide 多提交一次播放会话。
void main() {
  test('resumed / paused / hidden 分别扇出并等待异步回调', () async {
    final log = <String>[];
    final coordinator = AppLifecycleCoordinator()
      ..register(
        AppLifecycleParticipant(
          onResumed: () async {
            await Future<void>.delayed(Duration.zero);
            log.add('sync:resume');
          },
          onPaused: () => log.add('sync:pause'),
          onHidden: () => log.add('sync:hide'),
        ),
      )
      ..register(
        AppLifecycleParticipant(
          onPaused: () async {
            await Future<void>.delayed(Duration.zero);
            log.add('session:pause');
          },
        ),
      );

    await coordinator.resumed();
    expect(log, ['sync:resume']);

    log.clear();
    await coordinator.paused();
    expect(log, ['sync:pause', 'session:pause'], reason: 'paused 不触发 hide 动作');

    log.clear();
    await coordinator.hidden();
    expect(log, ['sync:hide']);

    coordinator.dispose();
    await coordinator.resumed();
    expect(log, ['sync:hide'], reason: 'dispose 后注册表清空');
  });
}
