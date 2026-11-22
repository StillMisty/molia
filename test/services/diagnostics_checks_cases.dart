import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/diagnostics/database_integrity.dart';
import 'package:molia/domain/models/diagnostics.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_runner.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/source_health_checker.dart';
import 'package:molia/services/diagnostics/system_checks.dart';
import 'package:molia/services/notification_permission.dart';

import '../support/memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DiagnosticCheckResult> runOne(DiagnosticCheck check) async {
    final runner = DiagnosticsRunner(
      checks: [check],
      config: const DiagnosticRunnerConfig(checkTimeout: Duration(seconds: 2)),
    );
    addTearDown(runner.dispose);
    await runner.start();
    await runner.idle;
    return runner.runs.single.results.single;
  }

  group('应用域检查', () {
    test('版本号取注入的包信息，失败不抛原始异常', () async {
      final result = await runOne(
        AppVersionCheck(
          load: () async => const DiagnosticsAppInfo(version: '1.2.3'),
        ),
      );
      expect(result.id, DiagnosticCheckId.appVersion);
      expect(result.status, DiagnosticCheckStatus.ok);
      expect(result.stableValue, '1.2.3');

      final failedRunner = DiagnosticsRunner(
        checks: [
          AppVersionCheck(load: () => Future.error(StateError('pkg boom'))),
        ],
      );
      addTearDown(failedRunner.dispose);
      await failedRunner.start();
      await failedRunner.idle;
      final failed = failedRunner.runs.single.results.single;
      expect(failed.status, DiagnosticCheckStatus.failed);
      expect(failed.failure?.kind, FailureKind.unknown);
      expect(failed.toString(), isNot(contains('pkg boom')));
    });

    test('异常退出 warning，正常退出 ok', () async {
      final abnormal = await runOne(
        SessionExitCheck(
          read: () => DiagnosticSessionInfo(
            startedAt: DateTime(2026, 1, 1),
            previousExitAt: DateTime(2026, 1, 1),
            previousAbnormalExit: true,
          ),
        ),
      );
      expect(abnormal.status, DiagnosticCheckStatus.warning);
      expect(abnormal.stableValue, 'abnormal');

      final clean = await runOne(
        SessionExitCheck(
          read: () => DiagnosticSessionInfo(
            startedAt: DateTime(2026, 1, 1),
            previousExitAt: DateTime(2026, 1, 1),
          ),
        ),
      );
      expect(clean.status, DiagnosticCheckStatus.ok);
      expect(clean.stableValue, 'clean');

      final unknown = await runOne(SessionExitCheck(read: () => null));
      expect(unknown.status, DiagnosticCheckStatus.skipped);
    });

    test('通知权限拒绝 warning，不支持 skipped', () async {
      expect(
        (await runOne(
          NotificationPermissionCheck(
            status: () async => NotificationPermissionStatus.granted,
          ),
        )).status,
        DiagnosticCheckStatus.ok,
      );
      final denied = await runOne(
        NotificationPermissionCheck(
          status: () async => NotificationPermissionStatus.denied,
        ),
      );
      expect(denied.status, DiagnosticCheckStatus.warning);
      expect(denied.failure?.kind, FailureKind.unauthorized);
      expect(
        (await runOne(
          NotificationPermissionCheck(
            status: () async => NotificationPermissionStatus.unsupported,
          ),
        )).status,
        DiagnosticCheckStatus.skipped,
      );
    });
  });

  group('播放后端检查', () {
    test('桌面音频不可用 failed(unsupported)，非桌面 skipped', () async {
      final failed = await runOne(
        AudioBackendCheck(available: () => false, isDesktop: () => true),
      );
      expect(failed.status, DiagnosticCheckStatus.failed);
      expect(failed.failure?.kind, FailureKind.unsupported);
      expect(failed.stableValue, 'unavailable');
      expect(failed.toString(), isNot(contains('libmpv')));

      final mobile = await runOne(
        AudioBackendCheck(available: () => false, isDesktop: () => false),
      );
      expect(mobile.status, DiagnosticCheckStatus.skipped);
    });
  });

  group('音源域检查', () {
    test('引擎失败映射 scriptError，稳定值只有脚本名；无脚本 skipped', () async {
      final failed = await runOne(
        SourceEngineCheck(
          engineReady: () => false,
          engineFailed: () => true,
          activeScriptName: () => '测试音源',
        ),
      );
      expect(failed.status, DiagnosticCheckStatus.failed);
      expect(failed.failure?.kind, FailureKind.scriptError);
      expect(failed.stableValue, '测试音源');

      final ready = await runOne(
        SourceEngineCheck(
          engineReady: () => true,
          engineFailed: () => false,
          activeScriptName: () => '测试音源',
        ),
      );
      expect(ready.status, DiagnosticCheckStatus.ok);

      final noScript = await runOne(
        SourceEngineCheck(
          engineReady: () => false,
          engineFailed: () => false,
          activeScriptName: () => null,
        ),
      );
      expect(noScript.status, DiagnosticCheckStatus.skipped);
    });

    test('渠道结果逐条写入，三个 id 都到达', () async {
      final probe = _FakeProbe([
        const SourceHealthTarget(key: 'a', displayName: 'A', canResolve: true),
        const SourceHealthTarget(key: 'b', displayName: 'B', canResolve: true),
        const SourceHealthTarget(key: 'c', displayName: 'C', canResolve: true),
      ]);
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      final runner = DiagnosticsRunner(
        checks: [
          SourceHealthCheck(
            checker: checker,
            pollInterval: const Duration(milliseconds: 1),
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(seconds: 5),
        ),
      );
      addTearDown(runner.dispose);
      final counts = <int>[];
      final subscription = runner.changes.listen((_) {
        final current = runner.current;
        if (current != null) counts.add(current.results.length);
      });
      addTearDown(subscription.cancel);

      await runner.start();
      await runner.idle;

      final results = runner.runs.single.results;
      expect(results, hasLength(9));
      expect(results.map((result) => result.id).toSet(), {
        DiagnosticCheckId.channelSearch,
        DiagnosticCheckId.channelResolve,
        DiagnosticCheckId.channelStream,
      });
      expect(
        counts.any((count) => count == 3),
        isTrue,
        reason: '第一个渠道完成时就应写入，而不是等整组结束',
      );
      expect(counts.last, 9);
    });

    test('runner 取消后 checker 停止且不再追加结果', () async {
      final gate = Completer<void>();
      final probe = _FakeProbe(
        [
          const SourceHealthTarget(
            key: 'a',
            displayName: 'A',
            canResolve: true,
          ),
          const SourceHealthTarget(
            key: 'b',
            displayName: 'B',
            canResolve: true,
          ),
          const SourceHealthTarget(
            key: 'c',
            displayName: 'C',
            canResolve: true,
          ),
        ],
        gates: {'b': gate},
      );
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
      });
      final runner = DiagnosticsRunner(
        checks: [
          SourceHealthCheck(
            checker: checker,
            pollInterval: const Duration(milliseconds: 2),
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(seconds: 10),
        ),
      );
      addTearDown(runner.dispose);

      await runner.start();
      while ((runner.current?.results.length ?? 0) < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      runner.cancel();
      final frozen = List<DiagnosticCheckResult>.of(runner.runs.first.results);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(runner.runs.first.cancelled, isTrue);
      expect(runner.runs.first.results, hasLength(frozen.length));
      expect(checker.running, isFalse);
    });

    test('整组超时保留已完成渠道并追加检查级 timeout', () async {
      final gate = Completer<void>();
      final probe = _FakeProbe(
        [
          const SourceHealthTarget(
            key: 'a',
            displayName: 'A',
            canResolve: true,
          ),
          const SourceHealthTarget(
            key: 'b',
            displayName: 'B',
            canResolve: true,
          ),
        ],
        gates: {'b': gate},
      );
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
      });
      final runner = DiagnosticsRunner(
        checks: [
          SourceHealthCheck(
            checker: checker,
            totalBudget: const Duration(milliseconds: 60),
            pollInterval: const Duration(milliseconds: 2),
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(seconds: 5),
        ),
      );
      addTearDown(runner.dispose);

      await runner.start();
      await runner.idle;

      final results = runner.runs.single.results;
      expect(
        results.any(
          (result) =>
              result.channelKey == 'a' &&
              result.status == DiagnosticCheckStatus.ok,
        ),
        isTrue,
        reason: '超时不能清掉已经写入的渠道结果',
      );
      expect(
        results.any(
          (result) =>
              result.status == DiagnosticCheckStatus.failed &&
              result.failure?.kind == FailureKind.timeout,
        ),
        isTrue,
      );
      expect(checker.running, isFalse);
    });

    test('runner 挂到诊断服务后可由 startChecks 触发来源检查', () async {
      final probe = _FakeProbe([
        const SourceHealthTarget(key: 'a', displayName: 'A', canResolve: true),
      ]);
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      final service = DiagnosticsService();
      addTearDown(service.dispose);
      service.attachHealth(checker);
      final runner = DiagnosticsRunner(
        checks: [
          SourceHealthCheck(
            checker: checker,
            pollInterval: const Duration(milliseconds: 1),
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(seconds: 5),
        ),
      );
      service.attachRunner(runner);

      expect(await service.startChecks(), isTrue);
      await runner.idle;
      expect(service.checkRuns.single.results, hasLength(3));
    });
  });

  group('存储域检查', () {
    test('日志不可用 failed，已停止 warning', () async {
      final unavailable = await runOne(
        LogWriteCheck(status: () => DiagnosticLogStatus.unavailable),
      );
      expect(unavailable.status, DiagnosticCheckStatus.failed);
      final stopped = await runOne(
        LogWriteCheck(status: () => DiagnosticLogStatus.stopped),
      );
      expect(stopped.status, DiagnosticCheckStatus.warning);
      final recording = await runOne(
        LogWriteCheck(status: () => DiagnosticLogStatus.recording),
      );
      expect(recording.status, DiagnosticCheckStatus.ok);
    });

    test('schema 版本不一致：旧库 warning，新库 failed', () async {
      final older = await runOne(
        DatabaseSchemaCheck(expectedVersion: 4, readVersion: () async => 3),
      );
      expect(older.status, DiagnosticCheckStatus.warning);
      expect(older.stableValue, '3/4');

      final newer = await runOne(
        DatabaseSchemaCheck(expectedVersion: 4, readVersion: () async => 5),
      );
      expect(newer.status, DiagnosticCheckStatus.failed);
    });

    test('quick_check 失败只写 corrupt，不暴露原始异常', () async {
      final healthy = await runOne(
        DatabaseIntegrityCheck(quickCheck: () async => true),
      );
      expect(healthy.status, DiagnosticCheckStatus.ok);
      expect(healthy.stableValue, 'ok');

      final corrupt = await runOne(
        DatabaseIntegrityCheck(
          quickCheck: () => Future.error(StateError('database disk image')),
        ),
      );
      expect(corrupt.status, DiagnosticCheckStatus.failed);
      expect(corrupt.failure?.kind, FailureKind.unknown);
      expect(corrupt.stableValue, 'corrupt');
      expect(corrupt.toString(), isNot(contains('disk image')));
    });

    test('内存库 quick_check 与 schema version 可读', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      expect(await moliaDatabaseQuickCheck(db), isTrue);
      expect(await readMoliaSchemaVersion(db), db.schemaVersion);
    });
  });

  group('账号与同步域检查', () {
    test('同步未启用 skipped；权限拒绝 failed(unauthorized)；运行正常 ok', () async {
      final off = await runOne(
        SyncTransportCheck(
          snapshot: () =>
              const DiagnosticsSyncSnapshot(enabled: false, transports: []),
        ),
      );
      expect(off.status, DiagnosticCheckStatus.skipped);

      final denied = await runOne(
        SyncTransportCheck(
          snapshot: () => const DiagnosticsSyncSnapshot(
            enabled: true,
            transports: [
              DiagnosticsSyncTransportSnapshot(
                name: 'lan',
                configured: true,
                enabled: true,
                running: false,
                unavailableReason: SyncUnavailableReason.permissionDenied,
              ),
            ],
          ),
        ),
      );
      expect(denied.status, DiagnosticCheckStatus.failed);
      expect(denied.failure?.kind, FailureKind.unauthorized);
      expect(denied.stableValue, 'lan:permission_denied');
      expect(denied.toString(), isNot(contains('192.168')));

      final running = await runOne(
        SyncTransportCheck(
          snapshot: () => const DiagnosticsSyncSnapshot(
            enabled: true,
            transports: [
              DiagnosticsSyncTransportSnapshot(
                name: 'webdav',
                configured: true,
                enabled: true,
                running: true,
              ),
            ],
          ),
        ),
      );
      expect(running.status, DiagnosticCheckStatus.ok);
      expect(running.stableValue, 'webdav:ok');
    });

    test('B 站未登录 skipped，过期 warning，已登录 ok', () async {
      final loggedOut = await runOne(
        BiliAccountCheck(read: () => (loggedIn: false, expired: false)),
      );
      expect(loggedOut.status, DiagnosticCheckStatus.skipped);

      final expired = await runOne(
        BiliAccountCheck(read: () => (loggedIn: true, expired: true)),
      );
      expect(expired.status, DiagnosticCheckStatus.warning);
      expect(expired.failure?.kind, FailureKind.unauthorized);

      final ok = await runOne(
        BiliAccountCheck(read: () => (loggedIn: true, expired: false)),
      );
      expect(ok.status, DiagnosticCheckStatus.ok);
    });
  });
}

class _FakeProbe implements SourceHealthProbe {
  _FakeProbe(this.targets, {this.gates = const {}});

  @override
  final List<SourceHealthTarget> targets;
  final Map<String, Completer<void>> gates;

  @override
  Future<Track?> search(SourceHealthTarget target) async {
    final gate = gates[target.key];
    if (gate != null) await gate.future;
    return Track(
      id: TrackId(target.key, '1'),
      title: 'Song',
      origin: TrackOrigin.builtin,
    );
  }

  @override
  Future<PlayableStream> resolve(
    SourceHealthTarget target,
    Track track,
  ) async => PlayableStream(
    Uri.parse('https://example.test/${target.key}.mp3'),
    headers: const {'Referer': 'https://example.test/'},
  );

  @override
  Future<void> stream(PlayableStream stream) async {}
}
