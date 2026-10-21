import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 推荐历史持久化：迁移、索引 / 多批、删除回退、保留策略、损坏降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AiRecommendationStore store;
  final now = DateTime(2026, 10, 21, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = AiRecommendationStore(preferences: prefs, clock: () => now);
  });

  StoredAiBatch batch(
    String id, {
    int count = 1,
    DateTime? generatedAt,
    AiDjOrigin origin = AiDjOrigin.refresh,
    AiPreferences? preferences,
  }) =>
      StoredAiBatch(
        id: id,
        items: [
          for (var i = 0; i < count; i++)
            StoredAiBatchItem(
              sourceKey: 'wy',
              songId: '$id-$i',
              title: 'Song $id-$i',
              artist: 'Artist',
              album: '',
              reason: 'reason',
              sourceName: '网易云音乐',
              raw: {'songmid': '$id-$i'},
            ),
        ],
        unresolved: const [AiRecommendation(title: 'Ghost', artist: 'X')],
        generatedAt: generatedAt ?? now,
        origin: origin,
        preferences: preferences,
      );

  test('迁移旧单批键：包装为 restored active，写新格式并删除旧键', () async {
    final generatedAt = DateTime(2026, 10, 1, 8);
    await prefs.setString(
      AiRecommendationStore.legacyStorageKey,
      jsonEncode({
        'generatedAt': generatedAt.millisecondsSinceEpoch,
        'items': [
          {
            'sourceKey': 'wy',
            'songId': 'legacy-1',
            'title': '旧推荐',
            'artist': '歌手',
            'album': '',
            'reason': '理由',
            'raw': {'songmid': 'legacy-1'},
          },
        ],
        'unresolved': [
          {'title': '旧未找到', 'artist': 'X', 'reason': ''},
        ],
      }),
    );

    final index = await store.loadIndex();

    expect(index.entries, hasLength(1));
    expect(
        index.activeBatchId, 'restored-${generatedAt.millisecondsSinceEpoch}');
    expect(index.entries.single.origin, AiDjOrigin.restored);
    expect(index.entries.single.preferences, isNull);
    expect(prefs.getString(AiRecommendationStore.legacyStorageKey), isNull);
    final migrated = await store.loadBatch(index.activeBatchId!);
    expect(migrated, isNotNull);
    expect(migrated!.items.single.title, '旧推荐');
    expect(migrated.unresolved.single.title, '旧未找到');
  });

  test('旧键损坏：不迁移、保留旧键下次再试', () async {
    await prefs.setString(
        AiRecommendationStore.legacyStorageKey, 'not-json{{{');

    final index = await store.loadIndex();

    expect(index.entries, isEmpty);
    expect(prefs.getString(AiRecommendationStore.legacyStorageKey), isNotNull);
  });

  test('索引 + 每批一键：多批保存；active 切换；详情按需加载', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(batch(
      'b',
      generatedAt: now.add(const Duration(minutes: 1)),
      origin: AiDjOrigin.autoFeed,
    ));
    await store.saveBatch(
      batch('c', generatedAt: now.add(const Duration(minutes: 2))),
      makeActive: true,
    );

    final index = await store.loadIndex();
    expect(index.entries.map((entry) => entry.id), ['c', 'b', 'a']);
    expect(index.activeBatchId, 'c');
    expect(index.entries[1].origin, AiDjOrigin.autoFeed);
    expect(
        prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'), isNotNull);
    expect((await store.loadBatch('b'))!.items.single.sourceName, '网易云音乐');
  });

  test('LLM 原始返回 / 提示词不进入持久化 JSON', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      StoredAiBatch(
        id: 'b',
        items: const [],
        unresolved: const [AiRecommendation(title: 'Ghost')],
        generatedAt: now,
        origin: AiDjOrigin.refresh,
      ),
    );
    for (final key in [
      '${AiRecommendationStore.batchKeyPrefix}a',
      '${AiRecommendationStore.batchKeyPrefix}b',
      AiRecommendationStore.indexKey,
    ]) {
      final raw = prefs.getString(key);
      expect(raw, isNotNull);
      expect(raw!.contains('rawResponse'), isFalse);
      expect(raw.contains('systemPrompt'), isFalse);
      expect(raw.contains('userPrompt'), isFalse);
    }
  });

  test('删除 active：回退到最近一批；删除最后一批清空 active', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
      makeActive: true,
    );

    final afterDelete = await store.deleteBatch('b');
    expect(afterDelete.activeBatchId, 'a');
    expect(afterDelete.entries.map((entry) => entry.id), ['a']);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}b'), isNull);

    final empty = await store.deleteBatch('a');
    expect(empty.activeBatchId, isNull);
    expect(empty.entries, isEmpty);
  });

  test('清空历史保留 active 与其批次键', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
    );
    await store.saveBatch(
      batch('c', generatedAt: now.add(const Duration(minutes: 2))),
    );

    final index = await store.clearHistory();

    expect(index.entries.map((entry) => entry.id), ['a']);
    expect(index.activeBatchId, 'a');
    expect(
        prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'), isNotNull);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}b'), isNull);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}c'), isNull);
  });

  test('保留策略：最多 20 批，active 永不自动清理', () async {
    await store.saveBatch(
      batch('old-active', generatedAt: now.subtract(const Duration(days: 1))),
      makeActive: true,
    );
    for (var i = 0; i < 24; i++) {
      await store.saveBatch(batch(
        'b$i',
        generatedAt: now.add(Duration(minutes: i)),
      ));
    }

    final index = await store.loadIndex();
    expect(index.entries, hasLength(20));
    expect(index.activeBatchId, 'old-active');
    expect(index.entries.any((entry) => entry.id == 'old-active'), isTrue);
    // 最老的非 active 批次键被同步删除。
    expect(
        prefs.getString('${AiRecommendationStore.batchKeyPrefix}b0'), isNull);
  });

  test('保留策略：最多 400 首', () async {
    for (var i = 0; i < 20; i++) {
      await store.saveBatch(
        batch(
          'b$i',
          count: 30,
          generatedAt: now.add(Duration(minutes: i)),
        ),
        makeActive: i == 19,
      );
    }

    final index = await store.loadIndex();
    final total = index.entries.fold<int>(
      0,
      (sum, entry) => sum + entry.itemCount,
    );
    expect(total, lessThanOrEqualTo(400));
    expect(index.activeBatchId, 'b19');
  });

  test('保留策略：超过 30 天的非 active 批次被清理', () async {
    await store.saveBatch(
      batch('old', generatedAt: now.subtract(const Duration(days: 31))),
      makeActive: true,
    );
    await store.saveBatch(
      batch('new', generatedAt: now.add(const Duration(minutes: 1))),
      makeActive: true,
    );

    final index = await store.loadIndex();
    expect(index.entries.map((entry) => entry.id), ['new']);
    expect(
        prefs.getString('${AiRecommendationStore.batchKeyPrefix}old'), isNull);
  });

  test('损坏索引 / 批次降级为空，不抛异常', () async {
    await prefs.setString(AiRecommendationStore.indexKey, 'not-json{{{');
    expect((await store.loadIndex()).entries, isEmpty);

    await prefs.setString(
      '${AiRecommendationStore.batchKeyPrefix}bad',
      '{"items":',
    );
    expect(await store.loadBatch('bad'), isNull);
    expect(await store.loadBatch('missing'), isNull);
  });
}
