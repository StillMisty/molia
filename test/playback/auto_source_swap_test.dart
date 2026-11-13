import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/ports/playback_facade.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_commands.dart';
import 'package:molia/playback/playback_error_recovery.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/services/source_swap/source_swap_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 记录命令面调用：验证重试 / 自动换源确实经协调者，而不是直写 facade。
class _RecordingCoordinator extends PlaybackSessionCoordinator {
  _RecordingCoordinator({
    required super.facade,
    required super.store,
    required super.settings,
  });

  final List<int> queueIndexes = [];
  final List<String> replacedUris = [];

  @override
  Future<PlaybackCommandOutcome> playQueueIndex(int index) {
    queueIndexes.add(index);
    return super.playQueueIndex(index);
  }

  @override
  Future<PlaybackCommandOutcome> replaceQueueTrack(
    String trackUri,
    Track newTrack,
  ) {
    replacedUris.add(trackUri);
    return super.replaceQueueTrack(trackUri, newTrack);
  }
}

/// 记录失败边界写入次数（去重用例）。
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

/// 恢复策略直测用的命令面替身：只记录写入，不碰真实播放 / 会话。
class _RecordingCommands implements PlaybackCommandPort {
  final List<int> playedIndexes = [];
  final List<({String uri, Track track})> replacements = [];

  /// 非空时对应命令抛错（验证失败路径不会卡住守卫）。
  Object? playError;
  Object? replaceError;

  @override
  Future<PlaybackCommandOutcome> playQueueIndex(int index) async {
    playedIndexes.add(index);
    final error = playError;
    if (error != null) throw error;
    return PlaybackCommandOutcome.trackOnly;
  }

  @override
  Future<PlaybackCommandOutcome> replaceQueueTrack(
    String trackUri,
    Track newTrack,
  ) async {
    replacements.add((uri: trackUri, track: newTrack));
    final error = replaceError;
    if (error != null) throw error;
    return PlaybackCommandOutcome.trackAndQueue;
  }

  @override
  Future<PlaybackCommandOutcome> play() async => PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> pause() async => PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> togglePlayPause() async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> skipToNext() async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> skipToPrevious() async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> moveQueueIndex(int from, int to) async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> removeQueueIndex(int index) async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> setCurrentQuality(String quality) async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> seekToPosition(Duration position) async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> setPlayMode(PlayMode mode) async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> togglePlayMode() async =>
      PlaybackCommandOutcome.none;

  @override
  Future<PlaybackCommandOutcome> stop() async => PlaybackCommandOutcome.none;
}

class _SnapshotBox {
  _SnapshotBox(this.value);

  PlaybackSnapshot value;
}

/// 播放失败自动换源：同源重试 → 严格找回 → 队列替换；开关/守卫/级联有界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(
    String sourceKey,
    String id, {
    TrackOrigin origin = TrackOrigin.builtin,
  }) => Track(
    id: TrackId(sourceKey, id),
    title: 'Title $id',
    artists: [Artist(name: 'Artist')],
    duration: const Duration(minutes: 3),
    origin: origin,
    payload: {'songmid': id, 'source': sourceKey},
  );

  const failure = SourceFailure(
    kind: FailureKind.network,
    message: 'boom',
    retryable: true,
  );

  late FakePlaybackFacade backend;
  late PlaybackFacade facade;
  late SourceSwapSettings settings;

  setUp(() {
    backend = FakePlaybackFacade();
    facade = backend;
    settings = SourceSwapSettings(settings: testSettingsRegistry());
  });

  (PlaybackProvider, List<({String uri, Set<String> exclude})>) buildProvider({
    Future<Track?> Function(Track seed, Set<String> exclude)? resolver,
    CatalogService? catalogService,
    PlaybackSessionCoordinator? sessionCoordinator,
  }) {
    final calls = <({String uri, Set<String> exclude})>[];
    final registry = testSettingsRegistry();
    final provider = PlaybackProvider(
      settings: registry,
      facade: facade,
      messenger: FakeMessenger(),
      catalogService: catalogService,
      sessionCoordinator:
          sessionCoordinator ??
          buildTestSessionCoordinator(facade: facade, settings: registry),
      autoSwapSettings: settings,
      autoSwapResolver: (t, {required excludeSourceKeys}) {
        calls.add((uri: t.id.uri, exclude: excludeSourceKeys));
        return resolver?.call(t, excludeSourceKeys) ?? Future.value(null);
      },
    );
    return (provider, calls);
  }

  void emitError(Track failing) {
    backend.emit(
      PlaybackSnapshot(
        current: failing,
        queue: [failing],
        currentIndex: 0,
        isPlaying: false,
        error: failure,
      ),
    );
  }

  _RecordingCoordinator recordingCoordinator() => _RecordingCoordinator(
    facade: facade,
    store: PlaybackSessionStore(),
    settings: testSettingsRegistry(),
  );

  test('失败 → 同源重试 → 仍失败：跨源严格换源并替换队列（静默）', () async {
    final failing = track('fake', 'a');
    final replacement = track('kg', 'a');
    final (provider, calls) = buildProvider(
      resolver: (seed, exclude) async => replacement,
    );
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(backend.calls, contains('playQueueIndex:0'));
    // 自动换源：provenance 含种子源。
    expect(calls, hasLength(1));
    expect(calls.single.uri, 'fake:a');
    expect(calls.single.exclude, {'fake'});
    expect(backend.lastReplacedTrackUri, 'fake:a');
    expect(backend.lastReplacedTrack, same(replacement));
    expect(provider.snapshot.current?.id.uri, 'kg:a');
  });

  test('失败只失效失败曲目的取链缓存，保留同音源其它曲目缓存', () async {
    final source = FakeMusicSource('fake')
      ..resolveUrl = 'https://cdn.example.com/fake.mp3';
    final catalog = CatalogService(
      registry: FakeSourceRegistry({'fake': source}),
    );
    final failing = track('fake', 'a');
    final other = track('fake', 'b');
    await catalog.resolve(failing);
    await catalog.resolve(other);
    expect(catalog.resolveCacheCountForTrack(failing), 1);
    expect(catalog.resolveCacheCountForTrack(other), 1);

    final (provider, _) = buildProvider(catalogService: catalog);
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(
      catalog.resolveCacheCountForTrack(failing),
      0,
      reason: '失败曲目重试要走新取链',
    );
    expect(
      catalog.resolveCacheCountForTrack(other),
      1,
      reason: '同音源其它曲目的缓存不应被连带失效',
    );
  });

  test('同源重试经命令面：playQueueIndex 由协调者路由', () async {
    final failing = track('fake', 'a');
    final coordinator = recordingCoordinator();
    final (provider, _) = buildProvider(sessionCoordinator: coordinator);
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    // 重试不是「直写 facade」：命令进协调者（live 路由 + 返回前已提交）。
    expect(coordinator.queueIndexes, [0]);
    expect(backend.calls, contains('playQueueIndex:0'));
  });

  test('自动换源经命令面：live 替换由协调者转发并提交会话', () async {
    final failing = track('fake', 'a');
    final replacement = track('kg', 'a');
    final coordinator = recordingCoordinator();
    final (provider, _) = buildProvider(
      resolver: (seed, exclude) async => replacement,
      sessionCoordinator: coordinator,
    );
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(coordinator.replacedUris, ['fake:a']);
    expect(backend.lastReplacedTrackUri, 'fake:a');
    expect(backend.lastReplacedTrack, same(replacement));
    // 换源结果已写进会话（返回前提交）：重开应用恢复的是新来源。
    final saved = await PlaybackSessionStore().load();
    expect(saved?.tracks.single.id.uri, 'kg:a');
  });

  test('无匹配：保持原错误与曲目，不替换', () async {
    final failing = track('fake', 'a');
    final (provider, calls) = buildProvider();
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(calls, hasLength(1));
    expect(backend.lastReplacedTrackUri, isNull);
    expect(provider.snapshot.current?.id.uri, 'fake:a');
  });

  test('开关关闭：不发起跨源找回（同源重试仍执行）', () async {
    await settings.setAutoEnabled(false);
    final failing = track('fake', 'a');
    final (provider, calls) = buildProvider(
      resolver: (seed, exclude) async => track('kg', 'a'),
    );
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(backend.calls, contains('playQueueIndex:0'));
    expect(calls, isEmpty);
    expect(backend.lastReplacedTrackUri, isNull);
  });

  test('本地文件跳过自动换源', () async {
    final failing = track('fake', 'a', origin: TrackOrigin.localFile);
    final (provider, calls) = buildProvider(
      resolver: (seed, exclude) async => track('kg', 'a'),
    );
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();

    expect(calls, isEmpty);
    expect(backend.lastReplacedTrackUri, isNull);
  });

  test('cancelled / unsupported 失败跳过自动换源', () async {
    final failing = track('fake', 'a');
    final (provider, calls) = buildProvider(
      resolver: (seed, exclude) async => track('kg', 'a'),
    );
    addTearDown(provider.dispose);

    backend.emit(
      PlaybackSnapshot(
        current: failing,
        queue: [failing],
        currentIndex: 0,
        isPlaying: false,
        error: const SourceFailure(
          kind: FailureKind.cancelled,
          message: 'cancelled',
        ),
      ),
    );
    await pumpEventQueue();
    expect(calls, isEmpty);
  });

  test('级联有界：换源后的候选再失败 → provenance 继续排除已尝试来源', () async {
    final failing = track('fake', 'a');
    final first = track('kg', 'a');
    final second = track('tx', 'a');
    final (provider, calls) = buildProvider(
      resolver: (seed, exclude) async {
        if (seed.id.uri == 'fake:a') return first;
        if (seed.id.uri == 'kg:a') return second;
        return null;
      },
    );
    addTearDown(provider.dispose);

    emitError(failing);
    await pumpEventQueue();
    expect(provider.snapshot.current?.id.uri, 'kg:a');

    // 新候选再次失败：同源重试 → 仍失败 → provenance 含 {fake, kg}。
    emitError(first);
    await pumpEventQueue();

    expect(backend.lastReplacedTrackUri, 'kg:a');
    expect(provider.snapshot.current?.id.uri, 'tx:a');
    expect(calls.map((call) => call.uri), ['fake:a', 'kg:a']);
    expect(calls.last.exclude, {'fake', 'kg'});
  });

  group('PlaybackErrorRecovery（策略模块直测）', () {
    const networkFailure = SourceFailure(
      kind: FailureKind.network,
      message: 'boom',
      retryable: true,
    );

    PlaybackSnapshot failureSnapshot(Track failing, {SourceFailure? error}) =>
        PlaybackSnapshot(
          current: failing,
          queue: [failing],
          currentIndex: 0,
          error: error ?? networkFailure,
        );

    ({
      PlaybackErrorRecovery recovery,
      _RecordingCommands commands,
      _SnapshotBox box,
      List<({String uri, Set<String> exclude})> calls,
      List<PlaybackCommandOutcome> outcomes,
      List<(Track, Track)> swapped,
    })
    buildRecovery({
      Future<Track?> Function(Track seed, Set<String> exclude)? resolver,
      SourceSwapSettings? swapSettings,
      FailureRecorder? failures,
      int provenanceCap = 64,
    }) {
      final commands = _RecordingCommands();
      final box = _SnapshotBox(PlaybackSnapshot.empty);
      final calls = <({String uri, Set<String> exclude})>[];
      final outcomes = <PlaybackCommandOutcome>[];
      final swapped = <(Track, Track)>[];
      final recovery = PlaybackErrorRecovery(
        commands: commands,
        readSnapshot: () => box.value,
        onOutcome: outcomes.add,
        autoSwapSettings:
            swapSettings ??
            SourceSwapSettings(settings: testSettingsRegistry()),
        autoSwapResolver: (seed, {required excludeSourceKeys}) {
          calls.add((uri: seed.id.uri, exclude: {...excludeSourceKeys}));
          return resolver?.call(seed, excludeSourceKeys) ??
              Future<Track?>.value(null);
        },
        onAutoSourceSwapped: (oldTrack, newTrack) async {
          swapped.add((oldTrack, newTrack));
        },
        failures: failures,
        provenanceCap: provenanceCap,
      );
      return (
        recovery: recovery,
        commands: commands,
        box: box,
        calls: calls,
        outcomes: outcomes,
        swapped: swapped,
      );
    }

    test('resolve 失败只由播放边界记录一次', () async {
      final recorder = _RecordingFailures();
      final source = FakeMusicSource('fake')
        ..onResolve = (_, _) => Future.error(networkFailure);
      final catalog = CatalogService(
        registry: FakeSourceRegistry({'fake': source}),
        failures: recorder,
      );
      final failing = track('fake', 'a');
      await expectLater(
        catalog.resolve(failing),
        throwsA(isA<SourceFailure>()),
      );
      expect(recorder.records, isEmpty, reason: '目录边界不再记录 resolve');

      final h = buildRecovery(failures: recorder);
      h.box.value = failureSnapshot(failing);
      h.recovery.onPlaybackError(h.box.value);
      expect(recorder.records, hasLength(1));
    });

    test('同一失败重复通知只写入一次最近失败', () {
      final recorder = _RecordingFailures();
      final failing = track('fake', 'a');
      final h = buildRecovery(failures: recorder);
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      h.recovery.onPlaybackError(h.box.value);
      h.recovery.onPlaybackError(h.box.value);

      expect(recorder.records, hasLength(1));
    });

    test('同一曲目只同源重试一次，切音质后重新允许', () async {
      final failing = track('fake', 'a');
      final h = buildRecovery();
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.commands.playedIndexes, [0]);
      expect(h.calls, hasLength(1), reason: '重试后仍失败，进入自动换源');

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.commands.playedIndexes, [0], reason: '同一曲目 key 不再同源重试');
      expect(h.calls, hasLength(2), reason: '直接尝试自动换源');

      h.recovery.resetRetryGuard();
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.commands.playedIndexes, [0, 0], reason: '切音质是新的取链动作');
    });

    test('同源重试命令失败：错误仍在时仍尝试自动换源', () async {
      final failing = track('fake', 'a');
      final replacement = track('kg', 'a');
      final h = buildRecovery(resolver: (seed, exclude) async => replacement);
      h.commands.playError = StateError('play failed');
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();

      expect(h.commands.playedIndexes, [0]);
      expect(h.calls.single.exclude, {'fake'});
      expect(h.commands.replacements.single.uri, 'fake:a');
      expect(h.swapped, hasLength(1));
      expect(h.swapped.single.$2, same(replacement));
      expect(h.outcomes.single, PlaybackCommandOutcome.trackAndQueue);
    });

    test('换源命令失败：不调用同步钩子、不发通知，守卫释放可再试', () async {
      final failing = track('fake', 'a');
      final replacement = track('kg', 'a');
      final h = buildRecovery(resolver: (seed, exclude) async => replacement);
      h.commands.replaceError = StateError('write failed');
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();

      expect(h.commands.replacements, hasLength(1));
      expect(h.swapped, isEmpty);
      expect(h.outcomes, isEmpty);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(
        h.commands.replacements,
        hasLength(2),
        reason: '失败后并发守卫已释放，下一次失败仍会尝试换源',
      );
    });

    test('本地文件与 cancelled / unsupported 失败不换源', () async {
      final local = track('local', 'a', origin: TrackOrigin.localFile);
      final localH = buildRecovery(
        resolver: (seed, exclude) async => track('kg', 'a'),
      );
      localH.box.value = failureSnapshot(local);
      localH.recovery.onPlaybackError(localH.box.value);
      await pumpEventQueue();

      expect(localH.commands.playedIndexes, [0], reason: '本地文件仍同源重试');
      expect(localH.calls, isEmpty);
      expect(localH.commands.replacements, isEmpty);

      for (final kind in [FailureKind.cancelled, FailureKind.unsupported]) {
        final failing = track('fake', 'a');
        final h = buildRecovery(
          resolver: (seed, exclude) async => track('kg', 'a'),
        );
        h.box.value = failureSnapshot(
          failing,
          error: SourceFailure(kind: kind, message: kind.name),
        );
        h.recovery.onPlaybackError(h.box.value);
        await pumpEventQueue();

        expect(h.calls, isEmpty, reason: '${kind.name} 不换源');
        expect(h.commands.replacements, isEmpty);
      }
    });

    test('搜索期间切歌：丢弃结果，不替换队列', () async {
      final failing = track('fake', 'a');
      final other = track('tx', 'z');
      final replacement = track('kg', 'a');
      final gate = Completer<Track?>();
      final h = buildRecovery(resolver: (seed, exclude) => gate.future);
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls, hasLength(1), reason: '重试后已进入跨源搜索');

      h.box.value = failureSnapshot(other);
      gate.complete(replacement);
      await pumpEventQueue();

      expect(h.commands.replacements, isEmpty);
      expect(h.swapped, isEmpty);
      expect(h.outcomes, isEmpty);
    });

    test('同一曲目换源并发只跑一次', () async {
      final failing = track('fake', 'a');
      final gate = Completer<Track?>();
      final h = buildRecovery(resolver: (seed, exclude) => gate.future);
      h.box.value = failureSnapshot(failing);

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls, hasLength(1));

      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls, hasLength(1), reason: '并发守卫吃掉重复触发');

      gate.complete(null);
      await pumpEventQueue();
    });

    test('级联每源至多一次：已尝试来源随候选传递', () async {
      final seed = track('s0', 'a');
      final first = track('s1', 'a');
      final second = track('s2', 'a');
      final h = buildRecovery(
        resolver: (track, exclude) async {
          if (track.id.uri == 's0:a') return first;
          if (track.id.uri == 's1:a') return second;
          return null;
        },
      );

      h.box.value = failureSnapshot(seed);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls.single.exclude, {'s0'});
      expect(h.commands.replacements.single.uri, 's0:a');

      h.box.value = failureSnapshot(first);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls.last.uri, 's1:a');
      expect(h.calls.last.exclude, {'s0', 's1'});

      h.box.value = failureSnapshot(second);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();
      expect(h.calls.last.uri, 's2:a');
      expect(h.calls.last.exclude, {'s0', 's1', 's2'});
      expect(h.commands.replacements, hasLength(2), reason: '无匹配后停止级联');
    });

    test('provenance 超过 cap 淘汰最早条目', () async {
      final a0 = track('s0', 'a');
      final a1 = track('s1', 'a');
      final b0 = track('s0', 'b');
      final b1 = track('s1', 'b');
      final h = buildRecovery(
        provenanceCap: 1,
        resolver: (track, exclude) async {
          if (track.id.uri == 's0:a') return a1;
          if (track.id.uri == 's0:b') return b1;
          return null;
        },
      );

      h.box.value = failureSnapshot(a0);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();

      h.box.value = failureSnapshot(b0);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();

      h.box.value = failureSnapshot(a1);
      h.recovery.onPlaybackError(h.box.value);
      await pumpEventQueue();

      expect(h.calls.last.uri, 's1:a');
      expect(h.calls.last.exclude, {'s1'}, reason: '最早条目已被 cap 淘汰');
    });
  });
}
