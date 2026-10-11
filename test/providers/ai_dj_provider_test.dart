import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 假生成器：脚本化批次与失败（不触碰 LLM/网络）。
class _FakeGenerator implements AiRecommendationGenerator {
  _FakeGenerator(this.batchFactory);

  AiDjBatch Function() batchFactory;
  Object? error;
  int calls = 0;
  List<String> lastSkipped = const [];
  List<String> lastLiked = const [];

  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
  }) async {
    calls++;
    lastSkipped = skippedLabels;
    lastLiked = likedLabels;
    final failure = error;
    if (failure != null) throw failure;
    return batchFactory();
  }

  @override
  Future<void> testConnection(LlmConfig config) async {}
}

/// 内存密钥存储替身。
class _MemorySecrets implements AiSecretStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

Track _track(int index, {Duration duration = const Duration(seconds: 100)}) =>
    Track(
      id: TrackId('wy', '$index'),
      title: 'Song $index',
      artists: const [Artist(name: 'Artist')],
      duration: duration,
      origin: TrackOrigin.builtin,
    );

List<Track> _tracks(int from, int count,
        {Duration duration = const Duration(seconds: 100)}) =>
    [for (var i = 0; i < count; i++) _track(from + i, duration: duration)];

AiDjBatch _batch(int from, int count) => AiDjBatch(
      items: [
        for (var i = 0; i < count; i++)
          ResolvedRecommendation(
            source: AiRecommendation(title: 'Song ${from + i}', artist: 'Artist'),
            track: _track(from + i),
          ),
      ],
      generatedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playbackProvider;
  late LibraryProvider libraryProvider;
  late _FakeGenerator generator;
  late _MemorySecrets secrets;
  late AiDjProvider provider;

  Future<void> pumpProvider({
    bool withConfig = true,
    _FakeGenerator? customGenerator,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (withConfig) {
      await AiSettingsStore(secrets: secrets, preferences: prefs).saveConfig(
        const LlmConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          model: 'm',
        ),
      );
    } else {
      secrets.data.clear();
    }
    provider = AiDjProvider(
      playbackProvider: playbackProvider,
      libraryProvider: libraryProvider,
      recommendationService: customGenerator ?? generator,
      settingsStore: AiSettingsStore(secrets: secrets, preferences: prefs),
    );
    await provider.init();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = _MemorySecrets();
    backend = FakePlaybackBackend();
    playbackProvider = buildTestPlaybackProvider(backend: backend);
    await playbackProvider.preferencesReady;
    libraryProvider = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playbackProvider,
    );
    generator = _FakeGenerator(() => _batch(0, 3));
    await pumpProvider();
  });

  tearDown(() {
    provider.dispose();
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  test('init 读取配置与隐私确认；grantConsent 持久化', () async {
    expect(provider.hasConfig, isTrue);
    expect(provider.consentGranted, isFalse);

    await provider.grantConsent();

    expect(provider.consentGranted, isTrue);
  });

  test('未配置时 start 进入 error 且不播放', () async {
    await pumpProvider(withConfig: false);

    await provider.start();

    expect(provider.status, AiDjStatus.error);
    expect(provider.lastError?.l10nKey, 'aiDjNotConfigured');
    expect(backend.calls, isEmpty);
  });

  test('start 生成并起播第一批（上下文名 AI 推歌）', () async {
    await provider.start();

    expect(provider.status, AiDjStatus.playing);
    expect(
      backend.lastRequest?.tracks.map((track) => track.title),
      ['Song 0', 'Song 1', 'Song 2'],
    );
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
    expect(provider.queuedCount, 3);
    expect(provider.currentBatch, isNotNull);
  });

  test('低水位（≤5 首剩余）自动续推并追加队列；充足时不触发', () async {
    generator.batchFactory = () => _batch(0, 20);
    await provider.start();
    expect(generator.calls, 1);

    // 剩余充足（currentIndex 0 / 队列 20）：不续推。
    backend.emit(BackendSnapshot(
      current: _track(0),
      queue: _tracks(0, 20),
      currentIndex: 0,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 1);

    // 剩余 3 首：自动续推并追加。
    generator.batchFactory = () => _batch(20, 20);
    backend.emit(BackendSnapshot(
      current: _track(16),
      queue: _tracks(0, 20),
      currentIndex: 16,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(generator.calls, 2);
    expect(backend.lastEnqueued, hasLength(20));
    expect(backend.lastEnqueued?.first.id.id, '20');
    expect(provider.queuedCount, 40);
  });

  test('跳过判定：未达有效阈值被切走 → 反馈回流；听完不算跳过', () async {
    generator.batchFactory = () => _batch(0, 1);
    await provider.start();
    expect(provider.status, AiDjStatus.playing, reason: 'start 应成功');
    expect(generator.calls, 1);

    final aiTrack = _track(0);
    final filler = _track(99);

    // 记录当前 AI 曲目，推进到 10s（< min(30s, 50%) = 30s）。
    backend.emit(BackendSnapshot(
      current: aiTrack,
      queue: [aiTrack, filler],
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(seconds: 10),
    ));
    provider.onPlaybackChanged();
    expect(generator.calls, 2, reason: '低水位触发续推');
    expect(provider.skippedLabels, isEmpty);
    provider.onPositionChanged();

    // 被切走 → 记为跳过。
    backend.emit(BackendSnapshot(
      current: filler,
      queue: [aiTrack, filler],
      currentIndex: 1,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(provider.skippedLabels, ['Song 0 - Artist']);

    // 再推一批：跳过反馈随下一批请求回流。
    await provider.feedMore();
    expect(generator.lastSkipped, ['Song 0 - Artist']);
  });

  test('听完（接近末尾）不算跳过', () async {
    generator.batchFactory = () => _batch(0, 1);
    await provider.start();

    final aiTrack = _track(0);
    final filler = _track(99);
    backend.emit(BackendSnapshot(
      current: aiTrack,
      queue: [aiTrack, filler],
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(milliseconds: 99500),
    ));
    provider.onPlaybackChanged();
    provider.onPositionChanged();

    backend.emit(BackendSnapshot(
      current: filler,
      queue: [aiTrack, filler],
      currentIndex: 1,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(provider.skippedLabels, isEmpty);
  });

  test('收藏作为喜欢回流到下一批', () async {
    generator.batchFactory = () => _batch(0, 2);
    await provider.start();

    await libraryProvider.toggleFavoriteTrack(_track(0));

    generator.batchFactory = () => _batch(2, 2);
    await provider.feedMore();

    expect(generator.lastLiked, contains('Song 0 - Artist'));
    expect(provider.likedLabels, contains('Song 0 - Artist'));
  });

  test('连续 3 次续推失败自动停止续推（保留队列）', () async {
    await provider.start();
    generator.error = const SourceFailure(
      kind: FailureKind.network,
      message: '断网',
    );

    await provider.feedMore();
    expect(provider.status, AiDjStatus.playing, reason: '单次失败保留模式');
    await provider.feedMore();
    await provider.feedMore();

    expect(provider.status, AiDjStatus.off);
    expect(provider.lastError, isNotNull);
  });

  test('退出默认保留队列；keepQueue=false 停止播放', () async {
    await provider.start();

    await provider.stop();

    expect(provider.status, AiDjStatus.off);
    expect(backend.calls, isNot(contains('stop')));

    await provider.start();
    await provider.stop(keepQueue: false);

    expect(backend.calls, contains('stop'));
  });

  test('播放被外部停止（current 为 null）→ 模式自动结束', () async {
    await provider.start();

    backend.emit(BackendSnapshot.empty);
    provider.onPlaybackChanged();

    expect(provider.status, AiDjStatus.off);
  });

  test('首批没有可播放曲目 → error（不改变当前播放）', () async {
    generator.batchFactory = () => AiDjBatch(
          items: const [],
          unresolved: const [AiRecommendation(title: 'x')],
          generatedAt: DateTime(2026, 1, 1),
        );

    await provider.start();

    expect(provider.status, AiDjStatus.error);
    expect(provider.lastError?.l10nKey, 'aiDjNothingResolved');
    expect(backend.calls, isEmpty);
  });
}
