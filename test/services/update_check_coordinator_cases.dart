import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/domain/models/source_script.dart';
import 'package:molia/services/update/update_check_coordinator.dart';

AppRelease _release(String version) =>
    AppRelease(channel: UpdateChannel.stable, version: version, build: 1);

void main() {
  const sourceUpdate = SourceScriptUpdate(
    id: 'script-1',
    name: '测试音源',
    currentVersion: '1.0.0',
    latestVersion: '1.1.0',
  );

  test('启动时检查：应用与音源合并成一条提示', () {
    fakeAsync((async) {
      var appChecks = 0;
      var sourceChecks = 0;
      final coordinator = UpdateCheckCoordinator(
        hooks: UpdateCheckHooks(
          checkOnStartup: () => true,
          checkDaily: () => false,
          lastCheckedAt: () => null,
          checkApp: () async {
            appChecks++;
            return _release('2.0.0');
          },
          checkSources: () async {
            sourceChecks++;
            return const [sourceUpdate];
          },
        ),
      );
      addTearDown(coordinator.dispose);

      coordinator.start();
      async.flushMicrotasks();

      expect(appChecks, 1);
      expect(sourceChecks, 1);
      expect(coordinator.notice.value?.appRelease?.version, '2.0.0');
      expect(coordinator.notice.value?.sourceUpdates, [sourceUpdate]);
    });
  });

  test('启动开关关闭时不检查；每日到期后自动补一轮', () {
    fakeAsync((async) {
      final startedAt = DateTime(2026, 1, 1, 9);
      var checks = 0;
      final coordinator = UpdateCheckCoordinator(
        now: () => startedAt.add(async.elapsed),
        hooks: UpdateCheckHooks(
          checkOnStartup: () => false,
          checkDaily: () => true,
          lastCheckedAt: () => startedAt,
          checkApp: () async {
            checks++;
            return null;
          },
          checkSources: () async => const [],
        ),
      );
      addTearDown(coordinator.dispose);

      coordinator.start();
      async.flushMicrotasks();
      expect(checks, 0);

      async.elapse(const Duration(hours: 23));
      expect(checks, 0);

      async.elapse(const Duration(hours: 1));
      async.flushMicrotasks();
      expect(checks, 1);
    });
  });

  test('应用检查失败不阻断音源提示', () {
    fakeAsync((async) {
      final coordinator = UpdateCheckCoordinator(
        hooks: UpdateCheckHooks(
          checkOnStartup: () => true,
          checkDaily: () => false,
          lastCheckedAt: () => null,
          checkApp: () async => throw StateError('network'),
          checkSources: () async => const [sourceUpdate],
        ),
      );
      addTearDown(coordinator.dispose);

      coordinator.start();
      async.flushMicrotasks();

      expect(coordinator.notice.value?.appRelease, isNull);
      expect(coordinator.notice.value?.sourceUpdates, [sourceUpdate]);
    });
  });

  test('两个开关都关闭：不检查也不排定时器', () {
    fakeAsync((async) {
      var checks = 0;
      final coordinator = UpdateCheckCoordinator(
        hooks: UpdateCheckHooks(
          checkOnStartup: () => false,
          checkDaily: () => false,
          lastCheckedAt: () => null,
          checkApp: () async {
            checks++;
            return _release('2.0.0');
          },
          checkSources: () async => const [],
        ),
      );
      addTearDown(coordinator.dispose);

      coordinator.start();
      async.elapse(const Duration(days: 3));

      expect(checks, 0);
      expect(coordinator.notice.value, isNull);
    });
  });
}
