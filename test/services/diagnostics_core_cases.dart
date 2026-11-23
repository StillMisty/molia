import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/device_settings.dart';
import 'package:molia/data/settings/device_settings_keys.dart';
import 'package:molia/domain/models/diagnostics.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/services/diagnostics/app_info.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_history_store.dart';
import 'package:molia/services/diagnostics/diagnostics_runner.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/diagnostics_session_store.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/log_tail_reader.dart';
import 'package:molia/services/diagnostics/playback_attempt_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一检查 / 会话 / 历史 / 日志读取的核心用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('统一检查聚合', () {
    test('overallStatus：failed 优先，warning 次之，否则 ok', () {
      DiagnosticCheckRun run(List<DiagnosticCheckStatus> statuses) =>
          DiagnosticCheckRun(
            startedAt: DateTime(2026, 1, 1),
            results: [
              for (var i = 0; i < statuses.length; i++)
                DiagnosticCheckResult(
                  id: DiagnosticCheckId.values[i],
                  group: DiagnosticCheckGroup.app,
                  status: statuses[i],
                  at: DateTime(2026, 1, 1),
                ),
            ],
          );

      expect(
        run([DiagnosticCheckStatus.ok, DiagnosticCheckStatus.skipped])
            .overallStatus,
        DiagnosticCheckStatus.ok,
      );
      expect(
        run([DiagnosticCheckStatus.ok, DiagnosticCheckStatus.warning])
            .overallStatus,
        DiagnosticCheckStatus.warning,
      );
      expect(
        run([DiagnosticCheckStatus.warning, DiagnosticCheckStatus.failed])
            .overallStatus,
        DiagnosticCheckStatus.failed,
      );
      expect(run(const []).overallStatus, DiagnosticCheckStatus.ok);
    });

    test('问题分组按 channel + kind 聚合，采用最近记录的展示信息', () {
      final groups = groupDiagnosticFailures([
        DiagnosticFailureRecord(
          at: DateTime(2026, 1, 1, 10),
          channelKey: 'kw',
          channelDisplayName: '旧酷我',
          kind: FailureKind.network,
          l10nKey: 'oldKey',
        ),
        DiagnosticFailureRecord(
          at: DateTime(2026, 1, 1, 12),
          channelKey: 'kw',
          channelDisplayName: '酷我',
          kind: FailureKind.network,
          l10nKey: 'newKey',
          retryable: true,
        ),
        DiagnosticFailureRecord(
          at: DateTime(2026, 1, 1, 11),
          channelKey: 'kw',
          channelDisplayName: '酷我',
          kind: FailureKind.timeout,
        ),
        DiagnosticFailureRecord(
          at: DateTime(2026, 1, 1, 9),
          channelKey: 'tx',
          channelDisplayName: 'QQ',
          kind: FailureKind.network,
        ),
      ]);

      expect(groups, hasLength(3));
      final kwNetwork = groups.firstWhere(
        (group) =>
            group.channelKey == 'kw' && group.kind == FailureKind.network,
      );
      expect(kwNetwork.count, 2);
      expect(kwNetwork.channelDisplayName, '酷我');
      expect(kwNetwork.l10nKey, 'newKey');
      expect(kwNetwork.retryable, isTrue);
      expect(kwNetwork.firstAt, DateTime(2026, 1, 1, 10));
      expect(kwNetwork.lastAt, DateTime(2026, 1, 1, 12));
      expect(groups.first.lastAt, DateTime(2026, 1, 1, 12));
      expect(() => groups.add(groups.first), throwsUnsupportedError);
    });
  });

  group('检查执行器', () {
    test('本地与网络检查顺序执行；includeNetwork=false 时网络检查标 skipped', () async {
      final order = <String>[];
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.appVersion,
            body: (context) async {
              order.add('app');
              context.addResult(_result(context, DiagnosticCheckId.appVersion));
            },
          ),
          _FakeCheck(
            key: DiagnosticCheckId.channelSearch,
            group: DiagnosticCheckGroup.sources,
            requiresNetwork: true,
            body: (context) async {
              order.add('network');
              context.addResult(
                _result(
                  context,
                  DiagnosticCheckId.channelSearch,
                  group: DiagnosticCheckGroup.sources,
                ),
              );
            },
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(seconds: 1),
        ),
      );
      addTearDown(runner.dispose);

      expect(await runner.start(includeNetwork: false), isTrue);
      await runner.idle;
      expect(order, ['app']);
      final run = runner.runs.single;
      expect(run.results.map((result) => result.status), [
        DiagnosticCheckStatus.ok,
        DiagnosticCheckStatus.skipped,
      ]);
      expect(run.overallStatus, DiagnosticCheckStatus.ok);

      expect(await runner.start(), isTrue);
      await runner.idle;
      expect(order, ['app', 'app', 'network']);
      expect(runner.runs.first.overallStatus, DiagnosticCheckStatus.ok);
    });

    test('取消丢弃迟到结果并保留已完成的运行', () async {
      final gate = Completer<void>();
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.appVersion,
            body: (context) async {
              await gate.future;
              // 取消后才写：必须被丢弃。
              context.addResult(_result(context, DiagnosticCheckId.appVersion));
            },
          ),
          _FakeCheck(
            key: DiagnosticCheckId.sessionExit,
            body: (context) async {
              context.addResult(
                _result(context, DiagnosticCheckId.sessionExit),
              );
            },
          ),
        ],
      );
      addTearDown(runner.dispose);

      await runner.start();
      await Future<void>.delayed(Duration.zero);
      expect(runner.running, isTrue);
      runner.cancel();
      expect(runner.running, isFalse);
      expect(runner.runs.single.cancelled, isTrue);
      expect(runner.runs.single.results, isEmpty);
      gate.complete();
      await runner.idle;
      await Future<void>.delayed(Duration.zero);
      expect(runner.runs.single.results, isEmpty, reason: '迟到结果不入队');
    });

    test('单项超时归一为 failed(timeout)，迟到的结果不进入运行', () async {
      final gate = Completer<void>();
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.databaseIntegrity,
            group: DiagnosticCheckGroup.storage,
            body: (context) async {
              await gate.future;
              context.addResult(
                _result(
                  context,
                  DiagnosticCheckId.databaseIntegrity,
                  group: DiagnosticCheckGroup.storage,
                ),
              );
            },
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(milliseconds: 20),
        ),
      );
      addTearDown(runner.dispose);

      await runner.start();
      await runner.idle;
      final result = runner.runs.single.results.single;
      expect(result.status, DiagnosticCheckStatus.failed);
      expect(result.failure?.kind, FailureKind.timeout);
      expect(result.failure?.retryable, isTrue);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(runner.runs.single.results, hasLength(1));
    });

    test('检查抛错归一为 failed，不向调用方抛出', () async {
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.syncTransport,
            group: DiagnosticCheckGroup.sync,
            body: (_) async => throw const SourceFailure(
              kind: FailureKind.unauthorized,
              message: 'raw secret body token=abc',
            ),
          ),
        ],
      );
      addTearDown(runner.dispose);

      expect(await runner.start(), isTrue);
      await runner.idle;
      final result = runner.runs.single.results.single;
      expect(result.status, DiagnosticCheckStatus.failed);
      expect(result.failure?.kind, FailureKind.unauthorized);
      expect(result.toString(), isNot(contains('raw secret')));
    });

    test('检查先写 ok 后超时：仍追加检查级 failed(timeout)', () async {
      final gate = Completer<void>();
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.databaseIntegrity,
            group: DiagnosticCheckGroup.storage,
            body: (context) async {
              context.addResult(
                _result(
                  context,
                  DiagnosticCheckId.databaseIntegrity,
                  group: DiagnosticCheckGroup.storage,
                ),
              );
              await gate.future;
            },
          ),
        ],
        config: const DiagnosticRunnerConfig(
          checkTimeout: Duration(milliseconds: 20),
        ),
      );
      addTearDown(runner.dispose);

      await runner.start();
      await runner.idle;
      final results = runner.runs.single.results;
      expect(results, hasLength(2));
      expect(results.first.status, DiagnosticCheckStatus.ok);
      expect(results.last.id, DiagnosticCheckId.databaseIntegrity);
      expect(results.last.status, DiagnosticCheckStatus.failed);
      expect(results.last.failure?.kind, FailureKind.timeout);
      expect(
        runner.runs.single.overallStatus,
        DiagnosticCheckStatus.failed,
        reason: '部分成功不能让页面误以为检查通过',
      );

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(runner.runs.single.results, hasLength(2), reason: '迟到结果不入队');
    });

    test('检查先写 ok 后抛错：仍追加检查级 failed', () async {
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.syncTransport,
            group: DiagnosticCheckGroup.sync,
            body: (context) async {
              context.addResult(
                _result(
                  context,
                  DiagnosticCheckId.syncTransport,
                  group: DiagnosticCheckGroup.sync,
                ),
              );
              throw const SourceFailure(
                kind: FailureKind.network,
                message: 'raw secret body',
              );
            },
          ),
        ],
      );
      addTearDown(runner.dispose);

      await runner.start();
      await runner.idle;
      final results = runner.runs.single.results;
      expect(results, hasLength(2));
      expect(results.first.status, DiagnosticCheckStatus.ok);
      expect(results.last.id, DiagnosticCheckId.syncTransport);
      expect(results.last.status, DiagnosticCheckStatus.failed);
      expect(results.last.failure?.kind, FailureKind.network);
      expect(results.toString(), isNot(contains('raw secret body')));
    });

    test('运行历史上限 3，冷却阻止重复开始', () async {
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.appVersion,
            body: (context) async {
              context.addResult(_result(context, DiagnosticCheckId.appVersion));
            },
          ),
        ],
        config: const DiagnosticRunnerConfig(cooldown: Duration(hours: 1)),
      );
      addTearDown(runner.dispose);

      expect(await runner.start(), isTrue);
      await runner.idle;
      expect(runner.canStart, isFalse);
      expect(await runner.start(), isFalse);
    });

    test('maxRuns 只保留最近三次', () async {
      final runner = DiagnosticsRunner(
        checks: [
          _FakeCheck(
            key: DiagnosticCheckId.appVersion,
            body: (context) async {
              context.addResult(_result(context, DiagnosticCheckId.appVersion));
            },
          ),
        ],
      );
      addTearDown(runner.dispose);

      for (var i = 0; i < 4; i++) {
        expect(await runner.start(), isTrue);
        await runner.idle;
      }
      expect(runner.runs, hasLength(3));
    });
  });

  group('会话状态迁移', () {
    test('只有上次前台才判异常；后台 / 正常关闭不误报', () async {
      final first = DiagnosticSessionTracker(
        now: () => DateTime(2026, 1, 1, 10),
        version: () => '1.0.0',
      );
      final firstInfo = await first.start();
      expect(firstInfo.previousAbnormalExit, isFalse);

      await first.onPaused();
      final second = DiagnosticSessionTracker(
        now: () => DateTime(2026, 1, 1, 11),
        version: () => '1.0.1',
      );
      final secondInfo = await second.start();
      expect(secondInfo.previousAbnormalExit, isFalse);
      expect(secondInfo.previousVersion, '1.0.0');
      expect(secondInfo.previousExitAt, DateTime(2026, 1, 1, 10));

      // 第二次进程停在前台（未正常关闭）→ 下一次启动判为异常。
      final third = DiagnosticSessionTracker(
        now: () => DateTime(2026, 1, 1, 12),
        version: () => '1.0.2',
      );
      final thirdInfo = await third.start();
      expect(thirdInfo.previousAbnormalExit, isTrue);
      expect(thirdInfo.previousExitAt, DateTime(2026, 1, 1, 11));

      await third.onDetached();
      final fourth = DiagnosticSessionTracker(
        now: () => DateTime(2026, 1, 1, 13),
        version: () => '1.0.3',
      );
      final fourthInfo = await fourth.start();
      expect(fourthInfo.previousAbnormalExit, isFalse);
    });

    test('存储不可用时仍返回启动信息，不阻塞生命周期', () async {
      final tracker = DiagnosticSessionTracker(
        settings: DeviceSettings.withOpener(
          () async => throw StateError('prefs unavailable'),
        ),
        now: () => DateTime(2026, 1, 1),
      );

      final info = await tracker.start();
      expect(info.previousAbnormalExit, isFalse);
      await expectLater(tracker.onResumed(), completes);
      await expectLater(tracker.onHidden(), completes);
      await expectLater(tracker.markCleanExit(), completes);
    });
  });

  group('问题历史持久化', () {
    DiagnosticFailureRecord record(int index, {FailureKind? kind}) =>
        DiagnosticFailureRecord(
          at: DateTime(2026, 1, 1, 0, 0, index),
          channelKey: 'channel$index',
          channelDisplayName: '渠道 $index',
          kind: kind ?? FailureKind.network,
          l10nKey: 'key$index',
          retryable: index.isEven,
        );

    test('写入后跨实例读取，只保留类型化字段', () async {
      final store = DiagnosticsHistoryStore(
        settings: DeviceSettings(),
        debounce: Duration.zero,
      );
      store.persist([record(1), record(2, kind: FailureKind.timeout)]);
      await store.flush();

      final loaded = await DiagnosticsHistoryStore().load();
      expect(loaded, hasLength(2));
      expect(loaded.first.channelKey, 'channel1');
      expect(loaded.last.kind, FailureKind.timeout);
      expect(loaded.last.l10nKey, 'key2');
      expect(loaded.first.retryable, isFalse);
      expect(loaded.toString(), isNot(contains('secret')));
    });

    test('容量 20，最新记录胜出；损坏元素跳过', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kDiagnosticFailureHistoryKey.name,
        jsonEncode([
          {
            'at': 0,
            'channelKey': 'bad',
            'channelDisplayName': 'bad',
            'kind': 1,
          },
          {
            'at': DateTime(2026, 1, 1).millisecondsSinceEpoch,
            'channelKey': 'ok',
            'channelDisplayName': 'OK',
            'kind': 'network',
            'retryable': false,
          },
        ]),
      );
      final loaded = await DiagnosticsHistoryStore().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.channelKey, 'ok');

      final store = DiagnosticsHistoryStore(debounce: Duration.zero);
      store.persist([for (var i = 0; i < 25; i++) record(i)]);
      await store.flush();
      final trimmed = await DiagnosticsHistoryStore().load();
      expect(trimmed, hasLength(20));
      expect(trimmed.first.channelKey, 'channel5');
      expect(trimmed.last.channelKey, 'channel24');
    });

    test('去抖中的快照在 dispose 前落盘', () async {
      final store = DiagnosticsHistoryStore(debounce: const Duration(hours: 1));
      store.persist([record(7)]);
      await store.dispose();

      final loaded = await DiagnosticsHistoryStore().load();
      expect(loaded.single.channelKey, 'channel7');
    });

    test('merge 恢复：历史在前、内存记录在后，按时间排序并去重', () {
      final buffer = FailureRingBuffer(capacity: 10);
      final at0 = DateTime(2026, 1, 1, 10);
      DiagnosticFailureRecord entry(
        DateTime at,
        String channel, {
        String? display,
      }) => DiagnosticFailureRecord(
        at: at,
        channelKey: channel,
        channelDisplayName: display ?? channel,
        kind: FailureKind.network,
      );

      final history = [
        entry(at0, 'old'),
        entry(at0.add(const Duration(minutes: 2)), 'later'),
      ];
      final early = entry(at0, 'old', display: '本次记录');
      buffer.restore([early]);
      buffer.restore([...history], merge: true);

      expect(buffer.records.map((record) => record.channelKey), [
        'old',
        'later',
      ]);
      expect(
        buffer.records.first.channelDisplayName,
        '本次记录',
        reason: '同时间 / 渠道 / 类别视为同一条，保留内存里的最新展示信息',
      );

      // 超出 capacity 时保留最新的记录。
      final small = FailureRingBuffer(capacity: 2);
      small.restore([
        entry(at0, 'a'),
        entry(at0.add(const Duration(minutes: 1)), 'b'),
        entry(at0.add(const Duration(minutes: 2)), 'c'),
      ], merge: true);
      expect(small.records.map((record) => record.channelKey), ['b', 'c']);
    });
  });

  group('诊断服务集成', () {
    test('启动恢复历史；recordFailure 持久化；导出 flush', () async {
      final seed = DiagnosticsHistoryStore(debounce: Duration.zero)
        ..persist([
          DiagnosticFailureRecord(
            at: DateTime(2026, 1, 1),
            channelKey: 'seed',
            channelDisplayName: '种子',
            kind: FailureKind.timeout,
          ),
        ]);
      await seed.flush();

      final history = DiagnosticsHistoryStore(debounce: Duration.zero);
      final service = DiagnosticsService(history: history);
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.failures.records.single.channelKey, 'seed');

      service.recordFailure(
        failure: const SourceFailure(
          kind: FailureKind.network,
          message: 'Cookie: SESSDATA=secret',
        ),
        channelKey: 'kw',
        channelDisplayName: '酷我',
      );
      await service.flushPendingWrites();

      final loaded = await DiagnosticsHistoryStore().load();
      expect(loaded, hasLength(2));
      expect(loaded.last.channelKey, 'kw');
      expect(loaded.last.kind, FailureKind.network);
      expect(loaded.toString(), isNot(contains('secret')));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(kDiagnosticFailureHistoryKey.name),
        isNot(contains('secret')),
        reason: '持久化只写类型化字段，不落 message / Cookie',
      );
      expect(service.issues, hasLength(2));
    });

    test('initialize 合并历史与启动早期失败，不丢当前记录', () async {
      final seed = DiagnosticsHistoryStore(debounce: Duration.zero)
        ..persist([
          DiagnosticFailureRecord(
            at: DateTime(2026, 1, 1, 10),
            channelKey: 'seed',
            channelDisplayName: '历史记录',
            kind: FailureKind.timeout,
          ),
        ]);
      await seed.flush();

      final service = DiagnosticsService();
      addTearDown(service.dispose);
      service.recordFailure(
        failure: const SourceFailure(
          kind: FailureKind.network,
          message: 'boom',
        ),
        channelKey: 'early',
        channelDisplayName: '启动早期',
      );
      await service.initialize();

      expect(service.failures.records.map((record) => record.channelKey), [
        'seed',
        'early',
      ]);
      expect(service.failures.records.first.kind, FailureKind.timeout);
      expect(service.failures.records.last.kind, FailureKind.network);
    });

    test('播放尝试有界记录并合并进 changes', () async {
      final attempts = PlaybackAttemptLog();
      final service = DiagnosticsService(attempts: attempts);
      addTearDown(service.dispose);
      var changed = 0;
      final subscription = service.changes.listen((_) => changed++);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 25; i++) {
        attempts.recordPlaybackAttempt(
          phase: PlaybackAttemptPhase.values[i % 4],
          sourceKey: 's$i',
          succeeded: i.isEven,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(service.playbackAttempts, hasLength(20));
      expect(service.playbackAttempts.first.sourceKey, 's5');
      expect(changed, greaterThan(0));
    });
  });

  group('日志尾部读取', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('molia_log_tail_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    File logFile(String name) => File('${root.path}/$name');

    test('活动文件 + 归档按时间顺序解析，续行并入 detail，密钥再脱敏', () async {
      logFile('molia.1.log').writeAsStringSync(
        '2026-11-14 12:00:00.000 INFO    molia.source: old line\n',
      );
      logFile('molia.log').writeAsStringSync(
        '2026-11-14 12:00:01.000 WARNING molia.playback: new line\n'
        '    error: SocketException\n'
        '    at fake.stack\n'
        '2026-11-14 12:00:02.000 SEVERE  molia.auth: token=SECRET-VALUE\n',
      );

      final entries = await LogTailReader(directory: () async => root).read();
      expect(entries, hasLength(3));
      expect(entries.first.message, 'old line');
      expect(entries[1].level, 'WARNING');
      expect(entries[1].logger, 'molia.playback');
      expect(entries[1].detail, contains('SocketException'));
      expect(entries[1].detail, contains('fake.stack'));
      expect(entries[2].message, isNot(contains('SECRET-VALUE')));
      expect(entries[2].message, contains('[redacted]'));
    });

    test('按级别 / 关键词过滤并渲染纯文本', () async {
      logFile('molia.log').writeAsStringSync(
        '2026-11-14 12:00:00.000 INFO    molia.a: hello world\n'
        '2026-11-14 12:00:01.000 WARNING molia.b: socket failed\n'
        '2026-11-14 12:00:02.000 SEVERE  molia.c: fatal token=SECRET\n',
      );
      final reader = LogTailReader(directory: () async => root);
      final entries = await reader.read();

      expect(filterLogEntries(entries, level: 'warning'), hasLength(1));
      expect(filterLogEntries(entries, keyword: 'SOCKET'), hasLength(1));
      expect(
        filterLogEntries(entries, level: 'SEVERE', keyword: 'fatal'),
        hasLength(1),
      );
      final text = renderLogEntries(entries);
      expect(text, contains('2026-11-14 12:00:01.000 WARNING'));
      expect(text, contains('socket failed'));
      expect(text, isNot(contains('SECRET')));
    });

    test('最多保留最新条目；目录不可用返回空', () async {
      logFile('molia.log').writeAsStringSync(
        '2026-11-14 12:00:00.000 INFO    molia.a: one\n'
        '2026-11-14 12:00:01.000 INFO    molia.a: two\n'
        '2026-11-14 12:00:02.000 INFO    molia.a: three\n',
      );
      final entries = await LogTailReader(
        directory: () async => root,
        maxEntries: 2,
      ).read();
      expect(entries.map((entry) => entry.message), ['two', 'three']);

      final missing = await LogTailReader(directory: () async => null).read();
      expect(missing, isEmpty);
    });

    test('只读尾部字节：从半行开始时不产生伪记录', () async {
      final content = StringBuffer();
      for (var i = 0; i < 200; i++) {
        content.writeln(
          '2026-11-14 12:00:00.000 INFO    molia.a: line-$i-${'x' * 40}',
        );
      }
      logFile('molia.log').writeAsStringSync(content.toString());
      final entries = await LogTailReader(
        directory: () async => root,
        maxBytes: 3000,
      ).read();
      expect(entries, isNotEmpty);
      expect(entries.last.message, startsWith('line-199'));
      expect(
        entries.every((entry) => entry.message.startsWith('line-')),
        isTrue,
      );
    });
  });

  group('诊断包扩展', () {
    test('包含 Checks / Session / Playback attempts / Issue groups，且不含原始异常', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14, 12),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(version: '1.2.3'),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: [
          DiagnosticFailureRecord(
            at: DateTime(2026, 11, 14, 11),
            channelKey: 'kw',
            channelDisplayName: '酷我',
            kind: FailureKind.network,
          ),
        ],
        healthRuns: const [],
        checks: [
          DiagnosticCheckRun(
            startedAt: DateTime(2026, 11, 14, 12),
            finishedAt: DateTime(2026, 11, 14, 12, 1),
            results: [
              DiagnosticCheckResult(
                id: DiagnosticCheckId.databaseSchema,
                group: DiagnosticCheckGroup.storage,
                status: DiagnosticCheckStatus.ok,
                at: DateTime(2026, 11, 14, 12),
                latencyMs: 12,
                stableValue: 'v2',
              ),
              DiagnosticCheckResult(
                id: DiagnosticCheckId.biliAccount,
                group: DiagnosticCheckGroup.sync,
                status: DiagnosticCheckStatus.warning,
                at: DateTime(2026, 11, 14, 12),
                failure: HealthFailure(
                  kind: FailureKind.unauthorized,
                  l10nKey: 'biliLoginRequired',
                  retryable: true,
                ),
              ),
            ],
          ),
        ],
        session: DiagnosticSessionInfo(
          startedAt: DateTime(2026, 11, 14, 12),
          previousExitAt: DateTime(2026, 11, 14, 11),
          previousVersion: '1.2.2',
          previousAbnormalExit: true,
        ),
        playbackAttempts: [
          PlaybackAttempt(
            at: DateTime(2026, 11, 14, 12),
            phase: PlaybackAttemptPhase.autoSwap,
            sourceKey: 'kw',
            succeeded: false,
            failure: const HealthFailure(kind: FailureKind.network),
          ),
        ],
        issues: groupDiagnosticFailures([
          DiagnosticFailureRecord(
            at: DateTime(2026, 11, 14, 11),
            channelKey: 'kw',
            channelDisplayName: '酷我',
            kind: FailureKind.network,
          ),
        ]),
      );

      final text = renderDiagnosticsBundle(data);
      for (final section in [
        '## Checks',
        '## Session',
        '## Playback attempts',
        '## Issue groups',
      ]) {
        expect(text, contains(section));
      }
      expect(text, contains('storage/databaseSchema: ok'));
      expect(text, isNot(contains('stableValue')));
      expect(text, contains('v2'));
      expect(text, contains('biliLoginRequired'));
      expect(text, contains('previous exit abnormal: yes'));
      expect(text, contains('version 1.2.2'));
      expect(text, contains('autoSwap | kw | failed'));
      expect(text, contains('count=1'));
      expect(text, isNot(contains('SourceFailure')));
    });

    test('maxBytes 严格上限：前置段落超限时也截断并省略日志', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14, 12),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(version: '1.2.3'),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: [
          for (var i = 0; i < 30; i++)
            DiagnosticFailureRecord(
              at: DateTime(2026, 11, 14, 11).add(Duration(minutes: i)),
              channelKey: 'channel$i',
              channelDisplayName: '很长的渠道名称 $i ${'x' * 30}',
              kind: FailureKind.network,
            ),
        ],
        healthRuns: const [],
        logs: const [
          DiagnosticsLogFile(
            name: 'molia.log',
            content:
                'token=SEED-SECRET-VALUE\nCookie: SESSDATA=SEED-SECRET-VALUE',
          ),
        ],
      );

      final text = renderDiagnosticsBundle(data, maxBytes: 400);
      expect(utf8.encode(text).length, lessThanOrEqualTo(400));
      expect(text, contains('[Report truncated'));
      expect(text, isNot(contains('SEED-SECRET-VALUE')));
      expect(text, isNot(contains('## Logs')), reason: '日志段已在硬上限之外');
    });

    test('导出器把 maxBytes 传给 render，并在导出前 flush 历史 / 日志', () async {
      final root = await Directory.systemTemp.createTemp('molia_export_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      File('${root.path}/molia.log').writeAsStringSync(
        List.generate(
          200,
          (index) =>
              '2026-11-14 12:00:00.000 INFO    molia.a: '
              'line-$index-${'x' * 80}',
        ).join('\n'),
      );

      final history = _FlushTrackingHistory();
      final service = DiagnosticsService(history: history);
      addTearDown(service.dispose);
      final exporter = DiagnosticsExporter(
        service: service,
        appInfo: DiagnosticsAppInfoGatherer(),
        settings: () async => const DiagnosticsSettingsSnapshot(),
        sources: () async => const DiagnosticsSourcesSnapshot(),
        database: () async => const DiagnosticsDatabaseCounts(schemaVersion: 2),
        logDirectory: () async => root,
        runInIsolate: false,
      );

      final text = await exporter.buildText(maxBytes: 4000);
      expect(history.flushed, isTrue);
      expect(text, contains('## Checks'));
      expect(text, contains('## Session'));
      expect(
        text,
        anyOf(
          contains('Log section omitted'),
          contains('Log section truncated'),
        ),
      );
      expect(utf8.encode(text).length, lessThanOrEqualTo(4000));
    });
  });
}

DiagnosticCheckResult _result(
  DiagnosticCheckContext context,
  DiagnosticCheckId id, {
  DiagnosticCheckGroup group = DiagnosticCheckGroup.app,
}) => DiagnosticCheckResult(
  id: id,
  group: group,
  status: DiagnosticCheckStatus.ok,
  at: context.now(),
);

class _FakeCheck implements DiagnosticCheck {
  _FakeCheck({
    required this.key,
    required this.body,
    this.group = DiagnosticCheckGroup.app,
    this.requiresNetwork = false,
  });

  @override
  final DiagnosticCheckId key;
  final Future<void> Function(DiagnosticCheckContext context) body;
  @override
  final DiagnosticCheckGroup group;
  @override
  final bool requiresNetwork;

  @override
  Future<void> run(DiagnosticCheckContext context) => body(context);
}

class _FlushTrackingHistory extends DiagnosticsHistoryStore {
  _FlushTrackingHistory() : super(debounce: Duration.zero);

  bool flushed = false;

  @override
  Future<void> flush() {
    flushed = true;
    return super.flush();
  }
}
