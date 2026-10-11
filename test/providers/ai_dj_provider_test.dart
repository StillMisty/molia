import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_pending_batch_store.dart';
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
            source:
                AiRecommendation(title: 'Song ${from + i}', artist: 'Artist'),
            track: _track(from + i),
          ),
      ],
      generatedAt: DateTime.now(),
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

    // 起播后后台预取"下一批"（carousel 展示用）。
    await pumpEventQueue();
    expect(generator.calls, 2);
    expect(provider.hasPendingBatch, isTrue);
  });

  test('低水位（≤5 首剩余）追加待播批次，并继续预取下一批；充足时不触发', () async {
    generator.batchFactory = () => _batch(0, 20);
    await provider.start();
    await pumpEventQueue();
    expect(generator.calls, 2, reason: 'start + 预取');
    expect(provider.pendingBatch?.items.first.track.id.id, '0');

    // 剩余充足（currentIndex 0 / 队列 20）：不续推。
    backend.emit(BackendSnapshot(
      current: _track(0),
      queue: _tracks(0, 20),
      currentIndex: 0,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 2);
    expect(backend.lastEnqueued, isNull);

    // 剩余 3 首：追加已预取的批次（不再重新生成），随后预取下一批。
    generator.batchFactory = () => _batch(20, 20);
    backend.emit(BackendSnapshot(
      current: _track(16),
      queue: _tracks(0, 20),
      currentIndex: 16,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(backend.lastEnqueued, hasLength(20));
    expect(backend.lastEnqueued?.first.id.id, '0', reason: '追加的是已预取批次');
    expect(provider.queuedCount, 40);
    await pumpEventQueue();
    expect(provider.pendingBatch?.items.first.track.id.id, '20',
        reason: '追加后立即预取下一批');
  });

  test('跳过判定：未达有效阈值被切走 → 反馈回流；听完不算跳过', () async {
    generator.batchFactory = () => _batch(0, 1);
    await provider.start();
    expect(provider.status, AiDjStatus.playing, reason: 'start 应成功');

    final aiTrack = _track(0);
    final filler = _track(99);
    final longQueue = [aiTrack, filler, ..._tracks(200, 18)];

    // 记录当前 AI 曲目，推进到 10s（< min(30s, 50%) = 30s）。
    backend.emit(BackendSnapshot(
      current: aiTrack,
      queue: longQueue,
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(seconds: 10),
    ));
    provider.onPlaybackChanged();
    expect(provider.skippedLabels, isEmpty);
    provider.onPositionChanged();

    // 被切走 → 记为跳过。
    backend.emit(BackendSnapshot(
      current: filler,
      queue: longQueue,
      currentIndex: 1,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(provider.skippedLabels, ['Song 0 - Artist']);

    // 换一批（重新生成）：跳过反馈随下一批请求回流。
    await provider.refreshPendingBatch();
    expect(generator.lastSkipped, ['Song 0 - Artist']);
  });

  test('听完（接近末尾）不算跳过', () async {
    generator.batchFactory = () => _batch(0, 1);
    await provider.start();

    final aiTrack = _track(0);
    final filler = _track(99);
    final longQueue = [aiTrack, filler, ..._tracks(200, 18)];
    backend.emit(BackendSnapshot(
      current: aiTrack,
      queue: longQueue,
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(milliseconds: 99500),
    ));
    provider.onPlaybackChanged();
    provider.onPositionChanged();

    backend.emit(BackendSnapshot(
      current: filler,
      queue: longQueue,
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

    // 换一批会重新生成：收藏反馈随生成请求回流。
    generator.batchFactory = () => _batch(2, 2);
    await provider.refreshPendingBatch();

    expect(generator.lastLiked, contains('Song 0 - Artist'));
    expect(provider.likedLabels, contains('Song 0 - Artist'));
  });

  test('连续 3 次续推失败自动停止续推（保留队列）', () async {
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();

    // 起播后生成开始失败：入队后的预取失败 → 无待播批次。
    generator.batchFactory = () => AiDjBatch(
          items: const [],
          generatedAt: DateTime.now(),
        );
    await provider.playFromPending(0);
    await pumpEventQueue();
    expect(provider.status, AiDjStatus.playing);
    expect(provider.hasPendingBatch, isFalse);

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

  test('ensurePendingBatch：生成并缓存待播批次；TTL 内不重复生成', () async {
    await provider.grantConsent();
    expect(provider.hasPendingBatch, isFalse);

    await provider.ensurePendingBatch();

    expect(provider.hasPendingBatch, isTrue);
    expect(generator.calls, 1);
    expect(provider.pendingBatch?.items, hasLength(3));

    await provider.ensurePendingBatch();
    expect(generator.calls, 1, reason: 'TTL 内不重复生成');
  });

  test('未配置 / 未确认隐私时不生成待播批次', () async {
    await pumpProvider(withConfig: false);
    await provider.ensurePendingBatch();
    expect(provider.hasPendingBatch, isFalse);
    expect(generator.calls, 0);

    await pumpProvider();
    await provider.ensurePendingBatch();
    expect(provider.hasPendingBatch, isFalse);
    expect(generator.calls, 0);
  });

  test('playFromPending：整批入队从该首起播并接管；随后预取下一批', () async {
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();

    await provider.playFromPending(1);

    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.map((t) => t.title).toList(),
        ['Song 0', 'Song 1', 'Song 2']);
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
    expect(provider.hasPendingBatch, isFalse, reason: '批次已入队');

    await pumpEventQueue();
    expect(provider.hasPendingBatch, isTrue, reason: '入队后预取下一批');
  });

  test('推歌中点已在队列的卡片 → 直接跳转，不替换队列', () async {
    await provider.grantConsent();
    generator.batchFactory = () => _batch(5, 1);
    await provider.ensurePendingBatch();

    backend.emit(BackendSnapshot(
      current: _track(5),
      queue: _tracks(5, 3),
      currentIndex: 0,
      isPlaying: true,
    ));
    provider.onPlaybackChanged();

    await provider.playFromPending(0);

    expect(backend.calls, contains('playQueueIndex:0'));
    expect(backend.lastRequest, isNull, reason: '不重新 load 队列');
  });

  test('refreshPendingBatch 替换待播批次', () async {
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 2);
    await provider.ensurePendingBatch();
    expect(provider.pendingBatch?.items.first.track.id.id, '0');

    generator.batchFactory = () => _batch(9, 2);
    await provider.refreshPendingBatch();

    expect(provider.pendingBatch?.items.first.track.id.id, '9');
  });

  test('启动时恢复持久化的待播批次（raw 原样）', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = AiPendingBatchStore(preferences: prefs);
    await store.save(AiDjBatch(
      items: [
        ResolvedRecommendation(
          source:
              const AiRecommendation(title: '旧推荐', artist: '歌手', reason: '理由'),
          track: Track(
            id: const TrackId('wy', 'restored-1'),
            title: '旧推荐',
            artists: const [Artist(name: '歌手')],
            duration: const Duration(seconds: 200),
            origin: TrackOrigin.builtin,
            payload: const {'songmid': 'restored-1'},
          ),
        ),
      ],
      generatedAt: DateTime.now(),
    ));

    await pumpProvider();
    await provider.grantConsent();

    expect(provider.hasPendingBatch, isTrue);
    final restored = provider.pendingBatch!.items.single;
    expect(restored.track.title, '旧推荐');
    expect(restored.track.id.uri, 'wy:restored-1');
    expect(restored.track.payload['songmid'], 'restored-1');
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
