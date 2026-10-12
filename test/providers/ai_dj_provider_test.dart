import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 假生成器：脚本化推荐列表与失败（不触碰 LLM/网络）。
class _FakeGenerator implements AiRecommendationGenerator {
  _FakeGenerator(this.batchFactory);

  AiDjBatch Function() batchFactory;
  Object? error;
  int calls = 0;
  List<String> lastSkipped = const [];
  List<String> lastLiked = const [];
  List<String> lastExcluded = const [];
  int? lastCount;
  AiUpstreamSummary summary = AiUpstreamSummary.empty;

  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) async {
    calls++;
    lastCount = count;
    lastSkipped = skippedLabels;
    lastLiked = likedLabels;
    lastExcluded = excludeLabels;
    final failure = error;
    if (failure != null) throw failure;
    return batchFactory();
  }

  @override
  Future<void> testConnection(LlmConfig config) async {}

  @override
  Future<AiUpstreamSummary> summarizeUpstream() async => summary;
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

/// 与控制器一致的「AI 队列」快照（上下文名）。
BackendSnapshot _radioSnapshot({
  required Track current,
  required List<Track> queue,
  required int currentIndex,
  bool isPlaying = true,
  Duration position = Duration.zero,
  String? contextName = kAiDjContextName,
}) =>
    BackendSnapshot(
      current: current,
      queue: queue,
      currentIndex: currentIndex,
      isPlaying: isPlaying,
      position: position,
      context: contextName == null
          ? null
          : PlaybackContext(name: contextName, uri: 'lx:$contextName'),
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

  /// 启用 + 已有今日推荐列表（生成一次）。
  Future<void> enableWithList({int count = 3}) async {
    await provider.grantConsent();
    await provider.setEnabled(true);
    expect(provider.recommendations?.items, hasLength(count));
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

  test('init 读取配置 / 隐私 / 启用状态；grantConsent 持久化', () async {
    expect(provider.hasConfig, isTrue);
    expect(provider.consentGranted, isFalse);
    expect(provider.enabled, isFalse);

    await provider.grantConsent();

    expect(provider.consentGranted, isTrue);
  });

  test('启用功能生成今日推荐列表，但不接管播放', () async {
    await enableWithList();

    expect(provider.enabled, isTrue);
    expect(provider.status, AiDjStatus.off, reason: '仅启用，不进电台');
    expect(backend.calls, isEmpty, reason: '不自动播放');
    expect(generator.calls, 1);
    expect(provider.lastUpdatedAt, isNotNull);

    // 再次调用不重复生成（已有列表）。
    await provider.ensureRecommendations();
    expect(generator.calls, 1);
  });

  test('未配置 / 未确认隐私时不生成推荐列表', () async {
    await pumpProvider(withConfig: false);
    await provider.grantConsent();
    await provider.setEnabled(true);
    expect(provider.recommendations, isNull);
    expect(generator.calls, 0);

    SharedPreferences.setMockInitialValues({});
    await pumpProvider();
    await provider.setEnabled(true);
    expect(provider.recommendations, isNull, reason: '未确认隐私');
    expect(generator.calls, 0);
  });

  test('startRadio：用列表替换队列并从指定首起播；列表保留不消耗', () async {
    await enableWithList();

    await provider.startRadio(fromIndex: 1);

    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.map((t) => t.title).toList(),
        ['Song 0', 'Song 1', 'Song 2']);
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
    expect(provider.queuedCount, 2);
    expect(provider.recommendations?.items, hasLength(3),
        reason: '列表是常驻内容，不因起播消失');
  });

  test('已在队列的推荐 → 只跳转不替换队列', () async {
    await enableWithList();
    await provider.startRadio();
    // 长队列：避免低水位自动续推干扰（剩余 > 5）。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 10),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
    expect(provider.status, AiDjStatus.playing);

    final loadsBefore = backend.calls.where((c) => c == 'load').length;
    await provider.playRecommendation(1);

    expect(backend.calls, contains('playQueueIndex:1'));
    expect(backend.calls.where((c) => c == 'load').length, loadsBefore,
        reason: '已在队列只跳转，不重新 load 队列');
  });

  test('enqueueRecommendations：只追加未入队曲目，不重复追加', () async {
    await enableWithList();
    // 队列里只有第一首（其余是别的歌），且剩余 > 5 不触发自动续推。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: [_track(0), ..._tracks(100, 10)],
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();

    await provider.enqueueRecommendations();

    expect(backend.lastEnqueued?.map((t) => t.id.id).toList(), ['1', '2']);
    expect(provider.queuedCount, 2);

    // 再点一次：全部已在队列，不再追加。
    backend.lastEnqueued = null;
    await provider.enqueueRecommendations();
    expect(backend.lastEnqueued, isNull);
  });

  test('低水位续推：先吃列表剩余，吃完生成新批替换列表', () async {
    generator.batchFactory = () => _batch(0, 20);
    await enableWithList(count: 20);
    await provider.startRadio();
    expect(generator.calls, 1, reason: '起播不额外生成');

    // 剩余充足：不续推。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 20),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 1);
    expect(backend.lastEnqueued, isNull);

    // 剩余 3 首（列表 0..19 都已入队 → 生成新批）。
    generator.batchFactory = () => _batch(20, 20);
    backend.emit(_radioSnapshot(
      current: _track(16),
      queue: _tracks(0, 20),
      currentIndex: 16,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(generator.calls, 2);
    expect(backend.lastEnqueued?.first.id.id, '20');
    expect(provider.recommendations?.items.first.track.id.id, '20',
        reason: '新批替换持久化列表');
    expect(provider.queuedCount, 40);
  });

  test('缓存未过期时续推消费列表剩余（不生成新批）', () async {
    generator.batchFactory = () => _batch(0, 20);
    await enableWithList(count: 20);
    await provider.startRadio();
    await pumpEventQueue();

    // 队列只剩 1 首（列表剩余 19 首未入队）→ 直接追加列表剩余。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 1),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(generator.calls, 1, reason: '不生成新批');
    expect(backend.lastEnqueued?.map((t) => t.id.id).toList(),
        [for (var i = 1; i < 20; i++) '$i']);
  });

  test('列表过期（缓存有效期外）：续推不再消费旧列表，生成新批', () async {
    final prefs = await SharedPreferences.getInstance();
    await AiSettingsStore(secrets: secrets, preferences: prefs)
        .saveCacheTtlDays(1);
    await pumpProvider();
    await provider.setCacheTtlDays(1);
    await provider.grantConsent();
    // 构造一个 3 天前生成的列表。
    generator.batchFactory = () => AiDjBatch(
          items: [
            for (var i = 0; i < 3; i++)
              ResolvedRecommendation(
                source: AiRecommendation(title: 'Song $i', artist: 'Artist'),
                track: _track(i),
              ),
          ],
          generatedAt: DateTime.now().subtract(const Duration(days: 3)),
        );
    await provider.setEnabled(true);
    expect(provider.isRecommendationsExpired, isTrue);

    await provider.startRadio();
    generator.batchFactory = () => _batch(50, 3);
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 1),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(backend.lastEnqueued?.first.id.id, '50', reason: '过期列表不被消费');
    expect(provider.recommendations?.items.first.track.id.id, '50');
  });

  test('跳过判定回流：未达有效阈值被切走 → 记入反馈', () async {
    generator.batchFactory = () => _batch(0, 1);
    await enableWithList(count: 1);
    await provider.startRadio();

    final aiTrack = _track(0);
    final filler = _track(99);
    final longQueue = [aiTrack, filler, ..._tracks(200, 18)];

    backend.emit(_radioSnapshot(
      current: aiTrack,
      queue: longQueue,
      currentIndex: 0,
      position: const Duration(seconds: 10),
    ));
    provider.onPlaybackChanged();
    provider.onPositionChanged();

    backend.emit(_radioSnapshot(
      current: filler,
      queue: longQueue,
      currentIndex: 1,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(provider.skippedLabels, ['Song 0 - Artist']);

    await provider.refreshRecommendations();
    expect(generator.lastSkipped, ['Song 0 - Artist']);
  });

  test('听完不算跳过；收藏作为喜欢回流', () async {
    generator.batchFactory = () => _batch(0, 2);
    await enableWithList(count: 2);
    await provider.startRadio();

    final aiTrack = _track(0);
    final filler = _track(99);
    final longQueue = [aiTrack, filler, ..._tracks(200, 18)];
    backend.emit(_radioSnapshot(
      current: aiTrack,
      queue: longQueue,
      currentIndex: 0,
      position: const Duration(milliseconds: 99500),
    ));
    provider.onPlaybackChanged();
    provider.onPositionChanged();
    backend.emit(_radioSnapshot(
      current: filler,
      queue: longQueue,
      currentIndex: 1,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(provider.skippedLabels, isEmpty);

    await libraryProvider.toggleFavoriteTrack(_track(0));
    generator.batchFactory = () => _batch(9, 2);
    await provider.refreshRecommendations();

    expect(generator.lastLiked, contains('Song 0 - Artist'));
    expect(provider.likedLabels, contains('Song 0 - Artist'));
  });

  test('换一首：原位替换列表项；已在队列则跟随替换', () async {
    await enableWithList();
    await provider.startRadio();
    // 长队列：避免低水位自动续推与替换操作竞争。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 10),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();

    generator.batchFactory = () => _batch(7, 1);
    await provider.replaceRecommendation(0);

    expect(provider.recommendations?.items[0].track.id.id, '7');
    expect(generator.lastCount, 1);
    expect(generator.lastExcluded, hasLength(3), reason: '排除列表内已有曲目');
    expect(backend.calls, contains('replaceQueueTrack:wy:0'));
  });

  test('不感兴趣：从列表移除 + 会话排除；撤销原位插回', () async {
    await enableWithList();
    final uri = provider.recommendations!.items[1].track.id.uri;

    await provider.markNotInterested(uri);

    expect(provider.recommendations?.items.map((i) => i.track.id.id).toList(),
        ['0', '2']);
    expect(provider.notInterestedItems, hasLength(1));
    expect(provider.skippedLabels, contains('Song 1 - Artist'));

    await provider.undoNotInterested(uri);

    expect(provider.recommendations?.items.map((i) => i.track.id.id).toList(),
        ['0', '1', '2']);
    expect(provider.notInterestedItems, isEmpty);
    expect(provider.skippedLabels, isNot(contains('Song 1 - Artist')));
  });

  test('连续 3 次续推失败自动停止续推（功能与列表保留）', () async {
    await enableWithList();
    await provider.startRadio();
    // 列表已在队列且剩余充足：续推只能生成新批（制造失败路径）。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 10),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
    expect(provider.status, AiDjStatus.playing);
    generator.batchFactory = () => AiDjBatch(
          items: const [],
          generatedAt: DateTime.now(),
        );

    await provider.feedMore();
    expect(provider.status, AiDjStatus.playing, reason: '单次失败保留电台');
    await provider.feedMore();
    await provider.feedMore();

    expect(provider.status, AiDjStatus.off);
    expect(provider.enabled, isTrue, reason: '退出队列不关功能');
    expect(provider.recommendations, isNotNull, reason: '列表保留');
    expect(provider.lastError, isNotNull);
  });

  test('换听别的队列：电台结束但功能与列表保留', () async {
    await enableWithList();
    await provider.startRadio();
    expect(provider.status, AiDjStatus.playing);

    backend.emit(_radioSnapshot(
      current: _track(99),
      queue: _tracks(99, 5),
      currentIndex: 0,
      contextName: '我的收藏',
    ));
    provider.onPlaybackChanged();

    expect(provider.status, AiDjStatus.off);
    expect(provider.enabled, isTrue);
    expect(provider.recommendations, isNotNull);
  });

  test('播放被外部停止（current 为 null）→ 电台结束，功能保留', () async {
    await enableWithList();
    await provider.startRadio();

    backend.emit(BackendSnapshot.empty);
    provider.onPlaybackChanged();

    expect(provider.status, AiDjStatus.off);
    expect(provider.enabled, isTrue);
  });

  test('关闭功能：停止电台、列表缓存保留；再次启用不重复生成', () async {
    await enableWithList();
    await provider.startRadio();

    await provider.setEnabled(false);
    expect(provider.enabled, isFalse);
    expect(provider.status, AiDjStatus.off);
    expect(provider.recommendations, isNotNull);

    await provider.setEnabled(true);
    expect(generator.calls, 1, reason: '列表仍在，不重复生成');
  });

  test('refreshRecommendations：替换列表（推歌中不打断播放）', () async {
    await enableWithList();
    await provider.startRadio();
    generator.batchFactory = () => _batch(9, 2);

    await provider.refreshRecommendations();

    expect(provider.recommendations?.items.first.track.id.id, '9');
    expect(provider.status, AiDjStatus.playing, reason: '不打断当前播放');
    expect(backend.calls, isNot(contains('stop')));
  });

  test('生成失败：refreshRecommendations 记录错误且不自动重试', () async {
    await provider.grantConsent();
    generator.error = StateError('boom');
    await provider.setEnabled(true);

    expect(provider.recommendations, isNull);
    expect(provider.lastError, isNotNull);
    expect(generator.calls, 1, reason: '失败不自动重试');

    await provider.ensureRecommendations();
    expect(generator.calls, 1);
  });

  test('启动时恢复持久化的推荐列表（raw 原样）', () async {
    final list = AiDjBatch(
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
    );
    // 写入持久化后重建 provider，模拟重启恢复。
    final prefs = await SharedPreferences.getInstance();
    final store = AiRecommendationStore(preferences: prefs);
    await store.save(list);

    await pumpProvider();

    expect(provider.recommendations, isNotNull);
    final restored = provider.recommendations!.items.single;
    expect(restored.track.title, '旧推荐');
    expect(restored.track.id.uri, 'wy:restored-1');
    expect(restored.track.payload['songmid'], 'restored-1');
    expect(restored.source.reason, '理由');
  });

  test('startRadio 无列表且无配置 → 不播放（保持现状）', () async {
    await pumpProvider(withConfig: false);
    await provider.setEnabled(true);

    await provider.startRadio();

    expect(backend.calls, isEmpty);
    expect(provider.recommendations, isNull);
  });
}
