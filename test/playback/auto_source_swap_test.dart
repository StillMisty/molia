import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/source_swap/source_swap_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 播放失败自动换源：同源重试 → 严格找回 → 队列替换；开关/守卫/级联有界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(
    String sourceKey,
    String id, {
    TrackOrigin origin = TrackOrigin.builtin,
  }) =>
      Track(
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

  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;
  late SourceSwapSettings settings;

  setUp(() {
    backend = FakePlaybackBackend();
    facade = DefaultPlaybackFacade(backend: backend);
    settings = SourceSwapSettings(settings: testSettingsRegistry());
  });

  (PlaybackProvider, List<({String uri, Set<String> exclude})>) buildProvider({
    Future<Track?> Function(Track seed, Set<String> exclude)? resolver,
    CatalogService? catalogService,
  }) {
    final calls = <({String uri, Set<String> exclude})>[];
    final provider = PlaybackProvider(
      settings: testSettingsRegistry(),
      facade: facade,
      messenger: FakeMessenger(),
      catalogService: catalogService,
      autoSwapSettings: settings,
      autoSwapResolver: (t, {required excludeSourceKeys}) {
        calls.add((uri: t.id.uri, exclude: excludeSourceKeys));
        return resolver?.call(t, excludeSourceKeys) ?? Future.value(null);
      },
    );
    return (provider, calls);
  }

  void emitError(Track failing) {
    backend.emit(BackendSnapshot(
      current: failing,
      queue: [failing],
      currentIndex: 0,
      isPlaying: false,
      error: failure,
    ));
  }

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

    backend.emit(BackendSnapshot(
      current: failing,
      queue: [failing],
      currentIndex: 0,
      isPlaying: false,
      error: const SourceFailure(
        kind: FailureKind.cancelled,
        message: 'cancelled',
      ),
    ));
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
}
