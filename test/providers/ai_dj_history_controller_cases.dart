import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/ai_dj_history_controller.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 21, 12);

int _idSeed = 0;

AiDjBatch _batch(
  String id, {
  int itemCount = 3,
  DateTime? generatedAt,
  AiDjOrigin origin = AiDjOrigin.refresh,
}) =>
    AiDjBatch(
      id: id,
      items: [
        for (var i = 0; i < itemCount; i++)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: '$id-$i',
              artist: 'Artist',
              reason: 'reason $id-$i',
            ),
            track: Track(
              id: TrackId('wy', '$id-$i-${_idSeed++}'),
              title: '$id-$i',
              artists: const [Artist(name: 'Artist')],
              duration: const Duration(seconds: 100),
              origin: TrackOrigin.builtin,
            ),
            sourceName: '网易云音乐',
          ),
      ],
      generatedAt: generatedAt ?? _now,
      origin: origin,
    );

StoredAiBatch _encode(AiDjBatch batch) => StoredAiBatch(
      id: batch.id,
      items: [
        for (final item in batch.items)
          StoredAiBatchItem(
            sourceKey: item.track.id.sourceKey,
            songId: item.track.id.id,
            title: item.track.title,
            artist: item.track.artistLabel,
            album: item.track.album ?? '',
            reason: item.source.reason,
          ),
      ],
      unresolved: batch.unresolved,
      generatedAt: batch.generatedAt,
      origin: batch.origin,
      preferences: batch.preferences,
    );

AiDjBatch _decode(StoredAiBatch stored) => AiDjBatch(
      id: stored.id,
      items: [
        for (final item in stored.items)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: item.title,
              artist: item.artist,
              reason: item.reason,
            ),
            track: Track(
              id: TrackId(item.sourceKey, item.songId),
              title: item.title,
              artists: [Artist(name: item.artist)],
              duration: item.durationMs == null
                  ? null
                  : Duration(milliseconds: item.durationMs!),
              origin: TrackOrigin.builtin,
            ),
            sourceName: item.sourceName,
          ),
      ],
      unresolved: stored.unresolved,
      generatedAt: stored.generatedAt,
      origin: stored.origin,
      preferences: stored.preferences,
    );

/// 统计批次键读取次数，验证按需加载缓存命中。
class _CountingStore extends AiRecommendationStore {
  _CountingStore({super.preferences, super.clock});

  int loadBatchCalls = 0;

  @override
  Future<StoredAiBatch?> loadBatch(String id) {
    loadBatchCalls++;
    return super.loadBatch(id);
  }
}

/// 所有存储操作都抛错：验证控制器降级到内存账本。
class _ThrowingStore extends AiRecommendationStore {
  @override
  Future<AiDjHistoryIndex> loadIndex() async => throw StateError('loadIndex');

  @override
  Future<StoredAiBatch?> loadBatch(String id) async =>
      throw StateError('loadBatch');

  @override
  Future<void> saveBatch(
    StoredAiBatch batch, {
    bool makeActive = false,
  }) async =>
      throw StateError('saveBatch');

  @override
  Future<void> setActive(String? id) async => throw StateError('setActive');

  @override
  Future<AiDjHistoryMutationResult> deleteBatch(String id) async =>
      throw StateError('deleteBatch');

  @override
  Future<AiDjHistoryMutationResult> clearHistory() async =>
      throw StateError('clearHistory');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    _idSeed = 0;
  });

  AiDjHistoryController buildController({
    AiRecommendationStore? store,
    DateTime Function()? clock,
  }) {
    final controller = AiDjHistoryController(
      store: store ??
          AiRecommendationStore(
            preferences: prefs,
            clock: clock ?? () => _now,
          ),
      decode: _decode,
      encode: _encode,
      clock: clock ?? () => _now,
    );
    return controller;
  }

  test('init 加载索引 + active，详情仍按需加载', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    await store.saveBatch(_encode(_batch('a')), makeActive: true);
    await store.saveBatch(
      _encode(_batch('b', generatedAt: _now.add(const Duration(minutes: 1)))),
    );
    final controller = buildController(store: store);

    await controller.init();

    expect(controller.active?.id, 'a');
    expect(controller.entries.map((entry) => entry.id), ['b', 'a']);
    expect(controller.count, 2);
    expect(controller.isActive('a'), isTrue);
    expect(controller.isActive('b'), isFalse);
  });

  test('archive：makeActive 切换 active；inactive 只写历史', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    final controller = buildController(store: store);
    await controller.init();

    await controller.archive(_batch('a'), makeActive: true);
    expect(controller.active?.id, 'a');
    expect(controller.entries.single.id, 'a');
    expect((await store.loadIndex()).activeBatchId, 'a');

    await controller.archive(
      _batch('b', generatedAt: _now.add(const Duration(minutes: 1))),
      makeActive: false,
    );
    expect(controller.active?.id, 'a');
    expect(controller.entries.map((entry) => entry.id), ['b', 'a']);
    expect((await store.loadIndex()).activeBatchId, 'a');
    expect(await store.loadBatch('b'), isNotNull);
  });

  test('updateActive：原位更新当前批并同步索引元数据', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    final controller = buildController(store: store);
    await controller.init();
    await controller.archive(_batch('a'), makeActive: true);

    await controller.updateActive(
      _batch('a',
          itemCount: 1, generatedAt: _now, origin: AiDjOrigin.manualFeed),
    );

    expect(controller.active?.items, hasLength(1));
    expect(controller.active?.origin, AiDjOrigin.manualFeed);
    expect(controller.entries.single.itemCount, 1);
    expect(controller.entries.single.origin, AiDjOrigin.manualFeed);
    final stored = await store.loadBatch('a');
    expect(stored?.items, hasLength(1));
  });

  test('load：active 直接返回；历史详情缓存命中后不再读存储', () async {
    final store = _CountingStore(preferences: prefs, clock: () => _now);
    await store.saveBatch(_encode(_batch('a')), makeActive: true);
    await store.saveBatch(_encode(_batch('b')));
    final controller = buildController(store: store);
    await controller.init();
    final callsAfterInit = store.loadBatchCalls;

    final loaded = await controller.load('b');
    expect(loaded?.id, 'b');
    expect(store.loadBatchCalls, callsAfterInit + 1);

    expect(await controller.load('b'), same(loaded));
    expect(store.loadBatchCalls, callsAfterInit + 1);

    expect(await controller.load('a'), same(controller.active));
    expect(store.loadBatchCalls, callsAfterInit + 1);
    expect(await controller.load('missing'), isNull);
  });

  test('setActive：只切换浏览批次；找不到时保持原 active', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    final controller = buildController(store: store);
    await controller.init();
    await controller.archive(_batch('a'), makeActive: true);
    await controller.archive(
      _batch('b', generatedAt: _now.add(const Duration(minutes: 1))),
      makeActive: false,
    );

    expect(await controller.setActive('b'), isTrue);
    expect(controller.active?.id, 'b');
    expect((await store.loadIndex()).activeBatchId, 'b');

    expect(await controller.setActive('missing'), isFalse);
    expect(controller.active?.id, 'b');
  });

  test('delete：删除 active 回退最近一批；删最后一批清空 active', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    final controller = buildController(store: store);
    await controller.init();
    await controller.archive(_batch('a'), makeActive: true);
    await controller.archive(
      _batch('b', generatedAt: _now.add(const Duration(minutes: 1))),
      makeActive: false,
    );

    expect(await controller.delete('a'), isTrue);
    expect(controller.active?.id, 'b');
    expect(controller.entries.single.id, 'b');
    expect((await store.loadIndex()).activeBatchId, 'b');

    expect(await controller.delete('b'), isTrue);
    expect(controller.active, isNull);
    expect(controller.entries, isEmpty);
    expect((await store.loadIndex()).activeBatchId, isNull);
  });

  test('clear：只保留 active 及其批次键', () async {
    final store = AiRecommendationStore(preferences: prefs, clock: () => _now);
    final controller = buildController(store: store);
    await controller.init();
    await controller.archive(_batch('a'), makeActive: true);
    await controller.archive(
      _batch('b', generatedAt: _now.add(const Duration(minutes: 1))),
      makeActive: false,
    );
    await controller.archive(
      _batch('c', generatedAt: _now.add(const Duration(minutes: 2))),
      makeActive: false,
    );

    expect(await controller.clear(), isTrue);

    expect(controller.active?.id, 'a');
    expect(controller.entries.single.id, 'a');
    expect((await store.loadIndex()).entries.single.id, 'a');
    expect(await store.loadBatch('b'), isNull);
    expect(await store.loadBatch('c'), isNull);
  });

  test('保留策略：20 批 / 30 天上限，active 永不清理', () async {
    final controller = buildController();
    await controller.init();
    final oldActive = _batch(
      'active',
      generatedAt: _now.subtract(const Duration(days: 45)),
    );
    await controller.archive(oldActive, makeActive: true);

    for (var i = 0; i < 25; i++) {
      await controller.archive(
        _batch(
          'b$i',
          itemCount: 1,
          generatedAt: _now.add(Duration(minutes: i)),
        ),
        makeActive: false,
      );
    }

    expect(controller.entries, hasLength(kAiDjHistoryMaxBatches));
    expect(controller.active?.id, 'active');
    expect(controller.entries.any((entry) => entry.id == 'active'), isTrue);
    expect(controller.entries.any((entry) => entry.id == 'b0'), isFalse);
    expect(controller.entries.first.id, 'b24');
  });

  test('store 失败降级：内存仍可写读切删，删除/清空保留原状态', () async {
    final controller = buildController(store: _ThrowingStore());
    await controller.init();
    expect(controller.entries, isEmpty);

    final batch = _batch('a');
    await controller.archive(batch, makeActive: true);
    expect(controller.active?.id, 'a');
    expect(controller.entries.single.id, 'a');

    expect(await controller.load('a'), same(batch));
    expect(await controller.load('missing'), isNull);
    expect(await controller.setActive('a'), isTrue);

    expect(await controller.delete('a'), isFalse);
    expect(controller.active?.id, 'a');
    expect(controller.entries.single.id, 'a');

    expect(await controller.clear(), isFalse);
    expect(controller.entries.single.id, 'a');
  });
}
