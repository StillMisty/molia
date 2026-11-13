import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/diagnostics/database_counts.dart';
import 'package:molia/data/diagnostics/source_health_probe.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/diagnostics/settings_snapshot.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/diagnostics/app_info.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/log_file_sink.dart';
import 'package:molia/services/diagnostics/redaction.dart';
import 'package:molia/services/diagnostics/source_health_checker.dart';

import '../support/fake_music_source.dart';
import '../support/memory_database.dart';

void main() {
  group('脱敏', () {
    test('Cookie / Authorization / 结构化字段 / URL 密钥都被替换，上下文保留', () {
      final input = [
        'Cookie: SESSDATA=abc; bili_jct=def',
        'Set-Cookie: session=xyz',
        'Authorization: Bearer abcdefghijklmnop',
        '{"password":"pa55","access_token":"tok","apiKey":"key-value"}',
        'https://user:pass@example.com/music?token=abc&w_rid=xyz&id=42',
        'sk-1234567890abcdefghijklmnop',
      ].join('\n');
      final output = redactSecrets(input);

      expect(output, contains('Cookie: [redacted]'));
      expect(output, isNot(contains('SESSDATA=abc')));
      expect(output, isNot(contains('abcdefghijklmnop')));
      expect(output, contains('"password":[redacted]'));
      expect(output, isNot(contains('pa55')));
      expect(output, contains('https://[redacted]@example.com/music?'));
      expect(output, contains('token=[redacted]'));
      expect(output, contains('w_rid=[redacted]'));
      expect(output, contains('id=42'));
      expect(output, isNot(contains('sk-1234567890')));
    });

    test('平台 Cookie 名在头外也被识别，普通正文里的 key 不被误伤', () {
      final output = redactSecrets(
        'MUSIC_U=abc123; qm_keyst=qq456\n'
        '这首歌的 key 是 C 大调',
      );
      expect(output, isNot(contains('abc123')));
      expect(output, isNot(contains('qq456')));
      expect(output, contains('这首歌的 key 是 C 大调'));
    });

    test('幂等，畸形输入与超长行不抛异常', () {
      final input =
          'password="a b"\nhttps://host/path?sign=%E0%A4%A'
          '\n${'x' * 200000}';
      final once = redactSecrets(input);
      expect(redactSecrets(once), once);
    });

    test('头 Map 与个人路径规范化', () {
      expect(
        redactHeaders({'Cookie': 'a=b', 'Referer': 'https://e.test/x?token=1'}),
        {
          'Cookie': '[redacted]',
          'Referer': 'https://e.test/x?token=[redacted]',
        },
      );
      expect(
        normalizePersonalPaths(
          '/home/alice/Music/a.mp3',
          homeDirectories: ['/home/alice'],
        ),
        '~/Music/a.mp3',
      );
    });
  });

  group('最近失败缓冲', () {
    test('容量 20、FIFO、快照不可变且不保存 message', () {
      final buffer = FailureRingBuffer(capacity: 20);
      for (var i = 0; i < 25; i++) {
        buffer.recordFailure(
          failure: SourceFailure(
            kind: FailureKind.network,
            message: 'secret cookie=$i',
          ),
          channelKey: 'kw',
          channelDisplayName: '酷我',
        );
      }
      final records = buffer.records;
      expect(records.length, 20);
      expect(records.first.channelKey, 'kw');
      expect(records.first.channelDisplayName, '酷我');
      expect(records.first.kind, FailureKind.network);
      expect(
        records.any((record) => record.toString().contains('secret cookie')),
        isFalse,
      );
      expect(() => records.add(records.first), throwsUnsupportedError);
    });
  });

  group('轮转文件日志', () {
    late Directory root;
    late StreamController<LogRecord> records;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('molia_diag_logs_');
      records = StreamController<LogRecord>.broadcast();
    });

    tearDown(() async {
      await records.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    RotatingFileLogSink buildSink({int maxBytes = 5 * 1024 * 1024}) {
      final sink = RotatingFileLogSink(
        directory: () async => root,
        maxBytes: maxBytes,
        maxFiles: 3,
        maxMessageBytes: 1024,
        flushInterval: Duration.zero,
      );
      sink.attach(records.stream);
      addTearDown(sink.close);
      return sink;
    }

    test('molia FINE 保留、依赖 FINE 过滤、依赖 INFO 保留，含日期 / 级别 / logger', () async {
      final sink = buildSink();
      records
        ..add(LogRecord(Level.FINE, 'fine-molia', 'molia.source'))
        ..add(LogRecord(Level.FINE, 'fine-dependency', 'just_audio'))
        ..add(LogRecord(Level.INFO, 'info-dependency', 'just_audio'));
      await Future<void>.delayed(Duration.zero);
      await sink.flush();
      final text = File('${root.path}/${RotatingFileLogSink.activeFileName}')
          .readAsStringSync();
      expect(text, contains('fine-molia'));
      expect(text, isNot(contains('fine-dependency')));
      expect(text, contains('info-dependency'));
      expect(text, contains('FINE'));
      expect(text, contains('molia.source'));
      expect(text, matches(RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.')));
    });

    test('超出 cap 轮转，最多 3 个文件且总字节有界', () async {
      final sink = buildSink(maxBytes: 220);
      for (var i = 0; i < 12; i++) {
        records.add(LogRecord(Level.INFO, 'line-$i-${'x' * 80}', 'molia.test'));
      }
      await Future<void>.delayed(Duration.zero);
      await sink.flush();
      final files = root
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.log'))
          .toList();
      expect(files.length, lessThanOrEqualTo(3));
      final total = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
      expect(total, lessThanOrEqualTo(3 * 220 + 10));
      expect(files.any((file) => file.path.endsWith('molia.1.log')), isTrue);
    });

    test('启动时超限活动文件裁到预算内', () async {
      final active = File('${root.path}/${RotatingFileLogSink.activeFileName}')
        ..writeAsStringSync('y' * 5000);
      final sink = buildSink(maxBytes: 200);
      records.add(LogRecord(Level.INFO, 'after-trim', 'molia.test'));
      await Future<void>.delayed(Duration.zero);
      await sink.flush();
      expect(active.lengthSync(), lessThanOrEqualTo(300));
      expect(active.readAsStringSync(), contains('after-trim'));
    });

    test('写入失败不向调用方抛异常，连续失败后标记不可用', () async {
      final sink = RotatingFileLogSink(
        directory: () async => root,
        store: _ThrowingStore(),
        maxBytes: 1024,
        flushInterval: Duration.zero,
      )..attach(records.stream);
      addTearDown(sink.close);
      for (var i = 0; i < 5; i++) {
        records.add(LogRecord(Level.INFO, 'line-$i', 'molia.test'));
        await Future<void>.delayed(Duration.zero);
        await sink.flush();
      }
      expect(sink.status, DiagnosticLogStatus.unavailable);
    });

    test('停写期间积压按优先级丢弃并写一次 dropped 标记', () async {
      final gate = Completer<void>();
      final store = _BlockingStore(gate);
      final sink = RotatingFileLogSink(
        directory: () async => root,
        store: store,
        maxBytes: 100000,
        backlogLimit: 4,
        flushInterval: Duration.zero,
      )..attach(records.stream);
      addTearDown(sink.close);
      // 先阻塞一次写入，再堆入高优先级与低优先级记录。
      records.add(LogRecord(Level.INFO, 'first', 'molia.test'));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 8; i++) {
        records.add(LogRecord(Level.FINE, 'fine-$i', 'molia.test'));
      }
      records.add(LogRecord(Level.SEVERE, 'severe', 'molia.test'));
      gate.complete();
      await sink.flush();
      final text = File('${root.path}/${RotatingFileLogSink.activeFileName}')
          .readAsStringSync();
      expect(text, contains('severe'));
      expect(text, contains('log lines dropped'));
    });
  });

  group('失败记录边界', () {
    test('目录搜索失败在归一化边界记录一次渠道信息（不存 message）', () async {
      final recorder = _RecordingFailures();
      final source = FakeMusicSource('kw')..fail = true;
      final catalog = CatalogService(
        registry: FakeSourceRegistry({'kw': source}),
        failures: recorder,
      );
      await expectLater(
        catalog.search('kw', const SearchQuery(keyword: 'a')),
        throwsA(isA<SourceFailure>()),
      );
      expect(recorder.records, hasLength(1));
      expect(recorder.records.single.channelKey, 'kw');
      expect(recorder.records.single.kind, FailureKind.network);
      expect(
        recorder.records.single.toString().contains('fake search failure'),
        isFalse,
      );
    });

    test('resolve 失败不在目录边界记录（留给播放边界记录一次）', () async {
      final recorder = _RecordingFailures();
      final source =
          FakeMusicSource(
              'kw',
              capabilities: const SourceCapabilities(
                search: true,
                resolveUrl: true,
              ),
            )
            ..onResolve = (_, _) => Future.error(
              const SourceFailure(
                kind: FailureKind.network,
                message: 'resolve boom',
              ),
            );
      final catalog = CatalogService(
        registry: FakeSourceRegistry({'kw': source}),
        failures: recorder,
      );
      final track = Track(
        id: const TrackId('kw', '1'),
        title: 'Song',
        origin: TrackOrigin.builtin,
      );
      await expectLater(catalog.resolve(track), throwsA(isA<SourceFailure>()));
      expect(recorder.records, isEmpty);
    });

    test('健康检查取链使用当前偏好音质', () async {
      final source = FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, resolveUrl: true),
      )..resolveUrl = 'https://example.test/a.mp3';
      final probe = CatalogSourceHealthProbe(
        registry: FakeSourceRegistry({'kw': source}),
        preferredQuality: () => '128k',
      );
      final track = Track(
        id: const TrackId('kw', '1'),
        title: 'Song',
        origin: TrackOrigin.builtin,
        qualities: const [
          AudioQuality(type: '320k'),
          AudioQuality(type: '128k'),
        ],
      );
      await probe.resolve(
        const SourceHealthTarget(
          key: 'kw',
          displayName: '酷我',
          canResolve: true,
        ),
        track,
      );
      expect(source.lastResolveQuality?.type, '128k');
    });

    test('健康检查目标只含启用且可搜索的渠道', () {
      final registry = FakeSourceRegistry(
        {
          'kw': FakeMusicSource('kw'),
          'disabled': FakeMusicSource(
            'disabled',
            capabilities: const SourceCapabilities(search: true),
          )..items = const [],
          'artist': FakeMusicSource(
            'artist',
            capabilities: const SourceCapabilities(artist: true),
          ),
        },
        disabled: {'disabled'},
      );
      final targets = CatalogSourceHealthProbe(registry: registry).targets;
      expect(targets.map((target) => target.key), ['kw']);
    });
  });

  group('音源健康检查', () {
    test('顺序探测、每渠道一次搜索 + 一次取链，类型化状态与延迟', () async {
      final probe = _FakeProbe([
        const SourceHealthTarget(
          key: 'kw',
          displayName: '酷我',
          canResolve: true,
        ),
        const SourceHealthTarget(
          key: 'tx',
          displayName: 'QQ',
          canResolve: false,
        ),
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

      expect(await checker.start(), isTrue);
      await _settle();
      expect(checker.running, isFalse);
      final run = checker.runs.single;
      expect(run.results.map((r) => r.channelKey), ['kw', 'tx']);
      expect(probe.searchCalls, ['kw', 'tx']);
      expect(probe.resolveCalls, ['kw']);
      expect(run.results.first.search.status, HealthStepStatus.ok);
      expect(run.results.first.resolve?.status, HealthStepStatus.ok);
      expect(run.results.last.resolve, isNull);
      expect(run.results.first.latencyMs, greaterThanOrEqualTo(0));
    });

    test('空结果 / 搜索失败 / 取链失败 / 超时都是类型化结果，不存原始异常', () async {
      final probe = _FakeProbe(
        const [
          SourceHealthTarget(key: 'empty', displayName: 'Empty'),
          SourceHealthTarget(key: 'searchfail', displayName: 'SearchFail'),
          SourceHealthTarget(
            key: 'resolvefail',
            displayName: 'ResolveFail',
            canResolve: true,
          ),
          SourceHealthTarget(key: 'timeout', displayName: 'Timeout'),
        ],
        searchErrors: {
          'searchfail': const SourceFailure(
            kind: FailureKind.unauthorized,
            message: 'raw body secret',
          ),
          'timeout': TimeoutException('slow'),
        },
        resolveErrors: {
          'resolvefail': const SourceFailure(
            kind: FailureKind.rateLimited,
            message: 'raw body secret',
          ),
        },
      );
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
          searchTimeout: Duration(milliseconds: 20),
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      await checker.start();
      await _settle();
      final results = checker.runs.single.results;
      expect(results[0].search.status, HealthStepStatus.empty);
      expect(results[1].search.status, HealthStepStatus.failed);
      expect(results[1].search.failure?.kind, FailureKind.unauthorized);
      expect(
        results[1].search.failure.toString(),
        isNot(contains('raw body secret')),
      );
      expect(results[2].search.status, HealthStepStatus.ok);
      expect(results[2].resolve?.status, HealthStepStatus.failed);
      expect(results[2].resolve?.failure?.kind, FailureKind.rateLimited);
      expect(results[3].search.failure?.kind, FailureKind.timeout);
    });

    test('取消停止后续渠道、丢弃迟到结果并保留部分运行', () async {
      final gate = Completer<void>();
      final probe = _FakeProbe([
        const SourceHealthTarget(key: 'a', displayName: 'A'),
        const SourceHealthTarget(key: 'b', displayName: 'B'),
      ], searchGate: gate);
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(
          cooldown: Duration.zero,
          gap: Duration.zero,
        ),
        delay: (_) async {},
      );
      addTearDown(checker.dispose);
      await checker.start();
      await Future<void>.delayed(Duration.zero);
      checker.cancel();
      gate.complete();
      await _settle();
      expect(probe.searchCalls, ['a']);
      expect(checker.runs.single.cancelled, isTrue);
      expect(checker.runs.single.results, isEmpty);
    });

    test('冷却阻止立即再次开始', () async {
      final probe = _FakeProbe([
        const SourceHealthTarget(key: 'a', displayName: 'A'),
      ]);
      final checker = SourceHealthChecker(
        probe: probe,
        config: const SourceHealthConfig(gap: Duration.zero),
      );
      addTearDown(checker.dispose);
      expect(await checker.start(), isTrue);
      await _settle();
      expect(await checker.start(), isFalse);
    });
  });

  group('诊断包', () {
    test('包含承诺的全部段落、未上传声明，且不泄露种子密钥', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14, 12, 30),
        timezoneOffset: const Duration(hours: 8),
        app: const DiagnosticsAppInfo(
          version: '1.2.3',
          buildNumber: '7',
          platform: 'linux',
          osVersion: 'Linux 6',
        ),
        settings: const DiagnosticsSettingsSnapshot(
          values: {'theme_mode': 'system', 'sync_category_settings': true},
          credentials: {'ai_api_key': true, 'sync_passphrase': false},
        ),
        sources: const DiagnosticsSourcesSnapshot(
          entries: [
            DiagnosticsSourceEntry(
              key: 'kw',
              displayName: '酷我',
              kind: 'builtin',
              enabled: true,
              discoverable: true,
              capabilities: ['search', 'resolve'],
            ),
          ],
        ),
        failures: [
          DiagnosticFailureRecord(
            at: DateTime(2026, 11, 14, 12),
            channelKey: 'kw',
            channelDisplayName: '酷我',
            kind: FailureKind.network,
          ),
        ],
        healthRuns: [
          HealthRun(
            startedAt: DateTime(2026, 11, 14, 12),
            finishedAt: DateTime(2026, 11, 14, 12, 1),
            results: [
              const HealthChannelResult(
                channelKey: 'kw',
                channelDisplayName: '酷我',
                search: HealthStepResult(
                  status: HealthStepStatus.ok,
                  latencyMs: 120,
                ),
                latencyMs: 150,
              ),
            ],
          ),
        ],
        database: const DiagnosticsDatabaseCounts(
          schemaVersion: 2,
          counts: {'playlists': 3, 'favorites': 2},
          hasSavedSession: true,
        ),
        logs: const [
          DiagnosticsLogFile(
            name: 'molia.log',
            content: 'Cookie: SESSDATA=super-secret\npassword=hidden',
          ),
        ],
        homeDirectories: const ['/home/alice'],
      );
      final text = renderDiagnosticsBundle(data);
      for (final section in [
        '## App and device',
        '## Settings',
        '## Sources',
        '## Recent issues',
        '## Source health',
        '## Database',
        '## Logs',
      ]) {
        expect(text, contains(section));
      }
      expect(text, contains('not uploaded automatically'));
      expect(text, contains('theme_mode: system'));
      expect(text, contains('ai_api_key: configured'));
      expect(text, contains('sync_passphrase: not configured'));
      expect(text, isNot(contains('super-secret')));
      expect(text, isNot(contains('hidden')));
      expect(text.contains('/home/alice'), isFalse);
    });

    test('缺失日志 / 数据库 / 健康结果各自给出说明', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: const [],
        healthRuns: const [],
        databaseNote: 'Database counts unavailable.',
        logsNote: 'The local log directory could not be read.',
      );
      final text = renderDiagnosticsBundle(data);
      expect(text, contains('No recent issues recorded.'));
      expect(text, contains('No channel check has been run yet.'));
      expect(text, contains('Database counts unavailable.'));
      expect(text, contains('The local log directory could not be read.'));
    });

    test('健康检查段落包含类型化 l10n key', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: const [],
        healthRuns: [
          HealthRun(
            startedAt: DateTime(2026, 11, 14),
            finishedAt: DateTime(2026, 11, 14, 0, 1),
            results: const [
              HealthChannelResult(
                channelKey: 'bili',
                channelDisplayName: '哔哩哔哩',
                search: HealthStepResult(
                  status: HealthStepStatus.failed,
                  latencyMs: 12,
                  failure: HealthFailure(
                    kind: FailureKind.unauthorized,
                    l10nKey: 'biliLoginRequired',
                    retryable: true,
                  ),
                ),
                latencyMs: 12,
              ),
            ],
          ),
        ],
      );
      final text = renderDiagnosticsBundle(data);
      expect(text, contains('key=biliLoginRequired'));
      expect(text, contains('retryable'));
    });

    test('截断边界上被切开的密钥不会留下残片', () {
      final filler = List.generate(
        120,
        (index) => 'old-$index-${'x' * 100}',
      ).join('\n');
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: const [],
        healthRuns: const [],
        logs: [
          DiagnosticsLogFile(
            name: 'molia.log',
            content: '$filler\ntoken=SUPERSECRET-STANDING-ACROSS-BOUNDARY',
          ),
        ],
      );
      final text = renderDiagnosticsBundle(data, maxBytes: 2600);
      expect(text, contains('token=[redacted]'));
      expect(text, isNot(contains('SUPERSECRET')));
      expect(text, isNot(contains('STANDING-ACROSS-BOUNDARY')));
    });

    test('病态日志集按上限截断并声明省略', () {
      final data = DiagnosticsBundleData(
        generatedAt: DateTime(2026, 11, 14),
        timezoneOffset: Duration.zero,
        app: const DiagnosticsAppInfo(),
        settings: const DiagnosticsSettingsSnapshot(),
        sources: const DiagnosticsSourcesSnapshot(),
        failures: const [],
        healthRuns: const [],
        logs: [DiagnosticsLogFile(name: 'molia.log', content: 'z' * 5000)],
      );
      final text = renderDiagnosticsBundle(data, maxBytes: 2000);
      expect(utf8.encode(text).length, lessThanOrEqualTo(2200));
      expect(text, contains('Log section truncated'));
    });
  });

  test('导出前 flush 文件日志队列', () async {
    final directory = await Directory.systemTemp.createTemp(
      'molia_diag_export_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final sink = _FlushRecordingSink(directory: () async => directory);
    final service = DiagnosticsService(logSink: sink);
    addTearDown(service.dispose);
    final exporter = DiagnosticsExporter(
      service: service,
      appInfo: DiagnosticsAppInfoGatherer(),
      settings: () async => const DiagnosticsSettingsSnapshot(),
      sources: () async => const DiagnosticsSourcesSnapshot(),
      database: () async => const DiagnosticsDatabaseCounts(schemaVersion: 2),
      logDirectory: sink.directory,
      runInIsolate: false,
    );
    await exporter.buildBytes();
    expect(sink.flushed, isTrue);
  });

  test('设置快照只读允许表，凭证只报布尔', () async {
    final snapshot = await gatherDiagnosticsSettings(
      registry: _registryWithSecrets(),
      extraValues: const {'data_saver_enabled': true},
    );
    expect(snapshot.values['data_saver_enabled'], isTrue);
    expect(snapshot.credentials['ai_api_key'], isTrue);
    expect(snapshot.credentials.containsKey('sync_passphrase'), isFalse);
    expect(snapshot.values.containsKey('not_listed_secret'), isFalse);
  });

  test('数据库计数：内存库可读且包含收藏数', () async {
    final db = openMemoryDatabase();
    addTearDown(db.close);
    final counts = await gatherDiagnosticsDatabaseCounts(database: () => db);
    expect(counts.schemaVersion, greaterThanOrEqualTo(1));
    expect(counts.counts.keys, contains('favorites'));
    expect(counts.hasSavedSession, isFalse);
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 60));
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _RecordingFailures implements FailureRecorder {
  final List<DiagnosticFailureRecord> records = [];

  @override
  void recordFailure({
    required SourceFailure failure,
    required String channelKey,
    required String channelDisplayName,
  }) {
    records.add(
      DiagnosticFailureRecord(
        at: DateTime(2026, 1, 1),
        channelKey: channelKey,
        channelDisplayName: channelDisplayName,
        kind: failure.kind,
      ),
    );
  }
}

class _FlushRecordingSink extends RotatingFileLogSink {
  _FlushRecordingSink({required super.directory});

  bool flushed = false;

  @override
  Future<void> flush() {
    flushed = true;
    return super.flush();
  }
}

class _ThrowingStore extends IoDiagnosticLogStore {
  @override
  Future<void> writeAppend(String path, String text) async {
    throw const FileSystemException('disk full');
  }
}

class _BlockingStore extends IoDiagnosticLogStore {
  _BlockingStore(this.gate);

  final Completer<void> gate;

  @override
  Future<void> writeAppend(String path, String text) async {
    await gate.future;
    await super.writeAppend(path, text);
  }
}

class _FakeProbe implements SourceHealthProbe {
  _FakeProbe(
    this.targets, {
    this.searchErrors = const {},
    this.resolveErrors = const {},
    this.searchGate,
  });

  @override
  final List<SourceHealthTarget> targets;
  final Map<String, Object> searchErrors;
  final Map<String, Object> resolveErrors;
  final Completer<void>? searchGate;
  final List<String> searchCalls = [];
  final List<String> resolveCalls = [];

  @override
  Future<Track?> search(SourceHealthTarget target) async {
    searchCalls.add(target.key);
    if (searchGate != null) await searchGate!.future;
    final error = searchErrors[target.key];
    if (error != null) throw error;
    if (target.key == 'empty') return null;
    return Track(
      id: TrackId(target.key, '1'),
      title: 'Song',
      origin: TrackOrigin.builtin,
    );
  }

  @override
  Future<void> resolve(SourceHealthTarget target, Track track) async {
    resolveCalls.add(target.key);
    final error = resolveErrors[target.key];
    if (error != null) throw error;
  }
}

SettingsRegistry _registryWithSecrets() {
  // 只为了证明凭证键只贡献布尔值；密钥盒内容不会进入快照。
  final secrets = _MemorySecrets();
  secrets.data['ai_dj_api_key'] = 'sk-should-never-appear-1234567890';
  secrets.data['sync_passphrase_v2'] = 'should-never-appear';
  return SettingsRegistry(keys: const [], secrets: secrets);
}

class _MemorySecrets implements SettingsSecretStore {
  final Map<String, String> data = {};

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}
