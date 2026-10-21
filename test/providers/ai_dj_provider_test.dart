import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

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
            sourceName: '网易云音乐',
          ),
      ],
      unresolved: const [AiRecommendation(title: 'Ghost', artist: 'X')],
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
  late FakeAiDjGenerator generator;
  late MemorySettingsSecretStore secrets;
  late AiDjProvider provider;

  Future<void> pumpProvider({
    bool withConfig = true,
    FakeAiDjGenerator? customGenerator,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (withConfig) {
      await AiSettingsStore(
              settings:
                  testSettingsRegistry(preferences: prefs, secrets: secrets))
          .saveConfig(
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
      settingsStore: AiSettingsStore(
          settings: testSettingsRegistry(preferences: prefs, secrets: secrets)),
    );
    await provider.init();
  }

  /// 启用 + 已有当前推荐列表（生成一次）。
  Future<void> enableWithList({int count = 3}) async {
    await provider.grantConsent();
    await provider.setEnabled(true);
    expect(provider.recommendations?.items, hasLength(count));
  }

  /// 让电台进入 playing（起播当前列表）。
  Future<void> startRadio() async {
    await provider.startRadio();
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: _tracks(0, 20),
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySettingsSecretStore();
    backend = FakePlaybackBackend();
    playbackProvider = buildTestPlaybackProvider(backend: backend);
    await playbackProvider.preferencesReady;
    libraryProvider = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playbackProvider,
    );
    generator = FakeAiDjGenerator(batchFactory: () => _batch(0, 3));
    await pumpProvider();
  });

  tearDown(() {
    provider.dispose();
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  test('init 读取配置 / 隐私 / 启用状态与偏好默认值', () async {
    expect(provider.hasConfig, isTrue);
    expect(provider.consentGranted, isFalse);
    expect(provider.enabled, isFalse);
    expect(provider.preferences.batchSize, 20);
    expect(provider.preferences.autoFeed, isTrue);
    expect(provider.historyEntries, isEmpty);

    await provider.grantConsent();

    expect(provider.consentGranted, isTrue);
  });

  test('启用生成当前推荐，但不接管播放；历史含当前批', () async {
    await enableWithList();

    expect(provider.enabled, isTrue);
    expect(provider.status, AiDjStatus.off, reason: '仅启用，不进电台');
    expect(backend.calls, isEmpty, reason: '不自动播放');
    expect(generator.calls, 1);
    expect(provider.historyEntries, hasLength(1));
    expect(provider.historyEntries.single.origin, AiDjOrigin.refresh);

    await provider.ensureRecommendations();
    expect(generator.calls, 1);
  });

  test('连续换两批：旧两批留在历史，active 为最新，旧批可按需加载', () async {
    await enableWithList();
    final firstId = provider.recommendations!.id;

    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    final secondId = provider.recommendations!.id;

    generator.batchFactory = () => _batch(20, 3);
    await provider.refreshRecommendations();
    final thirdId = provider.recommendations!.id;

    expect({firstId, secondId, thirdId}, hasLength(3));
    expect(provider.historyEntries, hasLength(3));
    expect(provider.activeBatchId, thirdId);
    expect(provider.historyEntries.first.id, thirdId);
    expect(await provider.loadHistoryBatch(firstId), isNotNull);
    expect(provider.recommendations!.items.first.track.id.id, '20');
  });

  test('批次大小：保存后下一次生成 count=30，历史元数据同步', () async {
    await provider.grantConsent();
    await provider
        .savePreferences(provider.preferences.copyWith(batchSize: 30));
    expect(provider.preferences.batchSize, 30);
    expect(generator.calls, 0, reason: '保存偏好不自动生成');

    generator.batchFactory = () => _batch(0, 30);
    await provider.setEnabled(true);

    expect(generator.lastCount, 30);
    expect(provider.recommendations!.preferences!.batchSize, 30);
    expect(provider.historyEntries.single.itemCount, 30);
  });

  test('偏好保存后不自动生成；当前批次偏好不一致时提示换一批', () async {
    await enableWithList();
    final activeId = provider.activeBatchId;
    expect(provider.preferencesOutdated, isFalse);

    await provider.savePreferences(
      provider.preferences.copyWith(styles: ['pop'], autoFeed: false),
    );

    expect(generator.calls, 1, reason: '保存不生成');
    expect(provider.activeBatchId, activeId);
    expect(provider.preferencesOutdated, isTrue);
  });

  test('startRadio：用当前推荐替换队列并从指定首起播', () async {
    await enableWithList();

    await provider.startRadio(fromIndex: 1);

    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.map((t) => t.title).toList(),
        ['Song 0', 'Song 1', 'Song 2']);
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
    expect(provider.queuedCount, 2);
    expect(provider.recommendations?.items, hasLength(3));
  });

  test('enqueueRecommendations：只追加未入队曲目，不重复追加', () async {
    await enableWithList();
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: [_track(0), ..._tracks(100, 10)],
      currentIndex: 0,
    ));
    provider.onPlaybackChanged();

    await provider.enqueueRecommendations();

    expect(backend.lastEnqueued?.map((t) => t.id.id).toList(), ['1', '2']);
    expect(provider.queuedCount, 2);

    backend.lastEnqueued = null;
    await provider.enqueueRecommendations();
    expect(backend.lastEnqueued, isNull);
  });

  test('自动补歌：静默追加队列 + 写历史，不切换 active、不设置进度', () async {
    generator.batchFactory = () => _batch(0, 20);
    await enableWithList(count: 20);
    await startRadio();
    final activeId = provider.activeBatchId;
    final activeItems = provider.recommendations!.items
        .map((item) => item.track.id.id)
        .toList();

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
    expect(provider.activeBatchId, activeId, reason: '不切换 active');
    expect(
      provider.recommendations!.items.map((item) => item.track.id.id).toList(),
      activeItems,
    );
    expect(provider.historyEntries, hasLength(2));
    expect(provider.historyEntries.first.origin, AiDjOrigin.autoFeed);
    expect(provider.progress, isNull);
    expect(provider.isBusy, isFalse);
    expect(provider.lastError, isNull);
    expect(provider.status, AiDjStatus.playing);
  });

  test('自动补歌关闭 / 非 AI 队列时不触发', () async {
    await enableWithList();
    await startRadio();
    await provider.setAutoFeed(false);

    backend.emit(_radioSnapshot(
      current: _track(18),
      queue: _tracks(0, 20),
      currentIndex: 18,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 1);

    await provider.setAutoFeed(true);
    backend.emit(_radioSnapshot(
      current: _track(18),
      queue: _tracks(0, 20),
      currentIndex: 18,
      contextName: '我的收藏',
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 1);
    expect(provider.status, AiDjStatus.off);
  });

  test('自动补歌完成时队列已播完：从新追加的第一首续播', () async {
    generator.batchFactory = () => _batch(0, 6);
    await enableWithList(count: 6);
    await startRadio();
    final gate = Completer<void>();
    generator.gate = gate;
    generator.batchFactory = () => _batch(6, 6);

    backend.emit(_radioSnapshot(
      current: _track(5),
      queue: _tracks(0, 6),
      currentIndex: 5,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 2);

    // 生成期间队列播完。
    backend.emit(_radioSnapshot(
      current: _track(5),
      queue: _tracks(0, 6),
      currentIndex: 5,
      isPlaying: false,
      position: const Duration(seconds: 100),
    ));
    gate.complete();
    await pumpEventQueue();

    expect(backend.calls.any((call) => call.startsWith('playQueueIndex:')),
        isTrue);
    expect(provider.status, AiDjStatus.playing);
    expect(provider.activeBatchId, provider.historyEntries.last.id);
    expect(provider.progress, isNull);
  });

  test('未解析项重新找一次：不重新生成，合并结果并更新历史计数', () async {
    await enableWithList();
    final activeId = provider.activeBatchId;
    expect(provider.recommendations!.unresolved, hasLength(1));

    generator.unresolvedFactory = (batch) => batch.copyWith(
          items: [
            ...batch.items,
            ResolvedRecommendation(
              source: const AiRecommendation(
                title: 'Ghost',
                artist: 'X',
                reason: '补回',
              ),
              track: _track(77),
              sourceName: '网易云音乐',
            ),
          ],
          unresolved: const [],
        );

    await provider.retryUnresolved();

    expect(generator.unresolvedCalls, 1);
    expect(generator.calls, 1, reason: '不重新调 LLM');
    expect(provider.activeBatchId, activeId);
    expect(provider.recommendations!.unresolved, isEmpty);
    expect(provider.recommendations!.items.last.track.id.id, '77');
    expect(provider.historyEntries.single.unresolvedCount, 0);
    expect(provider.progress, isNull);
  });

  test('历史：功能关闭时播放这批按普通队列，不启动自动补歌', () async {
    await enableWithList();
    final firstId = provider.activeBatchId!;
    await provider.setEnabled(false);

    await provider.playHistoryBatch(firstId);

    expect(provider.status, AiDjStatus.off);
    expect(provider.enabled, isFalse);
    expect(backend.lastRequest?.context, isNull);
    expect(backend.lastRequest?.tracks, hasLength(3));
  });

  test('自动补歌连续 3 次失败停止，不打断播放、不写主错误', () async {
    await enableWithList();
    await startRadio();
    final activeId = provider.activeBatchId;
    generator.error = StateError('boom');

    for (var i = 0; i < 3; i++) {
      backend.emit(_radioSnapshot(
        current: _track(18),
        queue: _tracks(0, 20),
        currentIndex: 18,
      ));
      provider.onPlaybackChanged();
      await pumpEventQueue();
    }

    expect(provider.autoFeedHalted, isTrue);
    expect(provider.autoFeedFailures, 3);
    expect(provider.autoFeedError, isNotNull);
    expect(provider.lastError, isNull, reason: '静默失败不写显式错误');
    expect(provider.status, AiDjStatus.playing);
    expect(provider.activeBatchId, activeId);
    expect(backend.lastEnqueued, isNull);

    generator.calls = 0;
    backend.emit(_radioSnapshot(
      current: _track(18),
      queue: _tracks(0, 20),
      currentIndex: 18,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 0, reason: '停止后不再自动补歌');
  });

  test('显式生成优先：取消在途静默补歌，静默结果不追加', () async {
    await enableWithList();
    await startRadio();
    final gate = Completer<void>();
    generator.gate = gate;
    generator.batchFactory = () => _batch(20, 3);

    backend.emit(_radioSnapshot(
      current: _track(18),
      queue: _tracks(0, 20),
      currentIndex: 18,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();
    expect(generator.calls, 2);

    generator.gate = null;
    generator.batchFactory = () => _batch(50, 60);
    await provider.refreshRecommendations();
    gate.complete();
    await pumpEventQueue();

    expect(provider.recommendations!.items.first.track.id.id, '50');
    expect(backend.lastEnqueued, isNull, reason: '被取消的静默批次不追加');
  });

  test('手动「补一批到队尾」：追加且写 manualFeed，不切换 active', () async {
    await enableWithList();
    await startRadio();
    final activeId = provider.activeBatchId;

    generator.batchFactory = () => _batch(30, 3);
    await provider.feedMore();

    expect(
        backend.lastEnqueued?.map((t) => t.id.id).toList(), ['30', '31', '32']);
    expect(provider.activeBatchId, activeId);
    expect(provider.historyEntries.first.origin, AiDjOrigin.manualFeed);
    expect(provider.progress, isNull);
    expect(provider.status, AiDjStatus.playing);
  });

  test('换一首：原位替换列表项；已在队列则跟随替换', () async {
    await enableWithList();
    await startRadio();

    generator.batchFactory = () => _batch(7, 1);
    await provider.replaceRecommendation(0);

    expect(provider.recommendations?.items[0].track.id.id, '7');
    expect(generator.lastCount, 1);
    expect(generator.lastExcluded, hasLength(3), reason: '排除列表内已有曲目');
    expect(backend.calls, contains('replaceQueueTrack:wy:0'));
  });

  test('不感兴趣跨重启保留；撤销时移除', () async {
    await enableWithList();
    final uri = provider.recommendations!.items[1].track.id.uri;

    await provider.markNotInterested(uri);
    expect(provider.recommendations?.items.map((i) => i.track.id.id).toList(),
        ['0', '2']);
    expect(provider.rememberedSkippedLabels, contains('Song 1 - Artist'));

    await provider.undoNotInterested(uri);
    expect(
        provider.rememberedSkippedLabels, isNot(contains('Song 1 - Artist')));

    // 再次标记后重启：长期记忆仍在。
    await provider.markNotInterested(uri);
    provider.dispose();
    await pumpProvider();
    expect(provider.rememberedSkippedLabels, contains('Song 1 - Artist'));

    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    expect(generator.lastSkipped, contains('Song 1 - Artist'));
  });

  test('喜欢回流并跨重启保留', () async {
    await enableWithList();
    await startRadio();
    await libraryProvider.toggleFavoriteTrack(_track(0));

    generator.batchFactory = () => _batch(9, 3);
    await provider.refreshRecommendations();

    expect(generator.lastLiked, contains('Song 0 - Artist'));
    expect(provider.rememberedLikedLabels, contains('Song 0 - Artist'));

    provider.dispose();
    await pumpProvider();
    expect(provider.rememberedLikedLabels, contains('Song 0 - Artist'));
  });

  test('种子：加入后进入下一批 prompt，成功后消费并持久化', () async {
    await enableWithList();
    await provider.addSeed('晴天 - 周杰伦');
    expect(provider.seeds, ['晴天 - 周杰伦']);

    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();

    expect(generator.lastPreferences!.seeds, ['晴天 - 周杰伦']);
    expect(provider.seeds, isEmpty);

    provider.dispose();
    await pumpProvider();
    expect(provider.seeds, isEmpty);
  });

  test('清空 AI 记忆', () async {
    await enableWithList();
    final uri = provider.recommendations!.items.first.track.id.uri;
    await provider.markNotInterested(uri);
    await provider.addSeed('某歌 - 某人');

    await provider.clearFeedbackMemory();

    expect(provider.rememberedSkippedLabels, isEmpty);
    expect(provider.seeds, isEmpty);
    expect(provider.notInterestedItems, hasLength(1), reason: '已移出列表不回插');
  });

  test('历史：删除 active 回退最近一批；删除最后一批清空', () async {
    await enableWithList();
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    final firstId = provider.historyEntries.last.id;
    final activeId = provider.activeBatchId!;

    await provider.deleteHistoryBatch(activeId);

    expect(provider.activeBatchId, firstId);
    expect(provider.historyEntries.map((entry) => entry.id), [firstId]);

    await provider.deleteHistoryBatch(firstId);
    expect(provider.recommendations, isNull);
    expect(provider.historyEntries, isEmpty);
  });

  test('历史：播放这批强制替换队列并切换 active；加入队列不切换', () async {
    await enableWithList();
    final firstId = provider.activeBatchId!;
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    final secondId = provider.activeBatchId!;

    await provider.enqueueHistoryBatch(firstId);
    expect(provider.activeBatchId, secondId);
    expect(backend.lastEnqueued?.first.id.id, '0');

    await provider.playHistoryBatch(firstId);
    expect(provider.activeBatchId, firstId);
    expect(backend.lastRequest?.tracks.map((t) => t.id.id).toList(),
        ['0', '1', '2']);
  });

  test('历史：设为当前只切换浏览列表，不动队列', () async {
    await enableWithList();
    final firstId = provider.activeBatchId!;
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    backend.calls.clear();

    await provider.setActiveBatch(firstId);

    expect(provider.activeBatchId, firstId);
    expect(backend.calls, isEmpty);
  });

  test('清空历史保留 active', () async {
    await enableWithList();
    final activeId = provider.activeBatchId!;
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
    final newActiveId = provider.activeBatchId!;

    await provider.clearHistory();

    expect(provider.activeBatchId, newActiveId);
    expect(provider.historyEntries, hasLength(1));
    expect(provider.historyEntries.single.id, newActiveId);
    expect(activeId, isNot(newActiveId));
  });

  test('缓存过期标记只影响续推消费（不提示）', () async {
    generator.batchFactory = () => _batch(0, 3);
    await enableWithList();
    await startRadio();

    expect(provider.isRecommendationsExpired, isFalse);
  });

  test('跳过判定回流：未达有效阈值被切走 → 记入本轮反馈', () async {
    generator.batchFactory = () => _batch(0, 1);
    await enableWithList(count: 1);
    await startRadio();
    // startRadio 用 20 首队列会触发自动补歌；换成长队列避免干扰。
    backend.emit(_radioSnapshot(
      current: _track(0),
      queue: [_track(0), _track(99), ..._tracks(200, 18)],
      currentIndex: 0,
      position: const Duration(seconds: 10),
    ));
    provider.onPlaybackChanged();
    provider.onPositionChanged();

    backend.emit(_radioSnapshot(
      current: _track(99),
      queue: [_track(0), _track(99), ..._tracks(200, 18)],
      currentIndex: 1,
    ));
    provider.onPlaybackChanged();
    await pumpEventQueue();

    expect(provider.skippedLabels, ['Song 0 - Artist']);
  });

  test('生成失败：记录错误且不自动重试', () async {
    await provider.grantConsent();
    generator.error = StateError('boom');
    await provider.setEnabled(true);

    expect(provider.recommendations, isNull);
    expect(provider.lastError, isNotNull);
    expect(generator.calls, 1);

    await provider.ensureRecommendations();
    expect(generator.calls, 1);
  });

  test('启动时恢复持久化的当前推荐与历史（raw 原样）', () async {
    await enableWithList();
    final activeId = provider.activeBatchId;
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();

    provider.dispose();
    await pumpProvider();

    expect(provider.recommendations, isNotNull);
    expect(provider.recommendations!.id, isNot(activeId));
    expect(provider.historyEntries, hasLength(2));
    expect(provider.recommendations!.items.first.track.title, 'Song 10');
  });

  test('startRadio 无列表且无配置 → 不播放（保持现状）', () async {
    provider.dispose();
    await pumpProvider(withConfig: false);
    await provider.setEnabled(true);

    await provider.startRadio();

    expect(backend.calls, isEmpty);
    expect(provider.recommendations, isNull);
  });
}
