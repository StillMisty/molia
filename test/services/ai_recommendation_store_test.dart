import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 推荐历史持久化：索引 / 多批、删除回退、保留策略、损坏降级。
/// 只让索引写入失败的内存 SharedPreferences：验证「先写索引、后删载荷」。
class _FailingIndexPrefs implements SharedPreferences {
  _FailingIndexPrefs(this.values);

  final Map<String, Object> values;
  bool failIndexWrites = true;

  Future<bool> _set(String key, Object value) async {
    if (failIndexWrites && key == AiRecommendationStore.indexKey) return false;
    values[key] = value;
    return true;
  }

  @override
  Set<String> getKeys() => Set.of(values.keys);

  @override
  Object? get(String key) => values[key];

  @override
  bool? getBool(String key) => values[key] as bool?;

  @override
  int? getInt(String key) => values[key] as int?;

  @override
  double? getDouble(String key) => values[key] as double?;

  @override
  String? getString(String key) => values[key] as String?;

  @override
  bool containsKey(String key) => values.containsKey(key);

  @override
  List<String>? getStringList(String key) =>
      (values[key] as List<dynamic>?)?.cast<String>();

  @override
  Future<bool> setBool(String key, bool value) => _set(key, value);

  @override
  Future<bool> setInt(String key, int value) => _set(key, value);

  @override
  Future<bool> setDouble(String key, double value) => _set(key, value);

  @override
  Future<bool> setString(String key, String value) => _set(key, value);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, value);

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> commit() async => true;

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<void> reload() async {}
}

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

  test('索引 + 每批一键：多批保存；active 切换；详情按需加载', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch(
        'b',
        generatedAt: now.add(const Duration(minutes: 1)),
        origin: AiDjOrigin.autoFeed,
      ),
    );
    await store.saveBatch(
      batch('c', generatedAt: now.add(const Duration(minutes: 2))),
      makeActive: true,
    );

    final index = await store.loadIndex();
    expect(index.entries.map((entry) => entry.id), ['c', 'b', 'a']);
    expect(index.activeBatchId, 'c');
    expect(index.entries[1].origin, AiDjOrigin.autoFeed);
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'),
      isNotNull,
    );
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
    expect(afterDelete.ok, isTrue);
    expect(afterDelete.index.activeBatchId, 'a');
    expect(afterDelete.index.entries.map((entry) => entry.id), ['a']);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}b'), isNull);

    final empty = await store.deleteBatch('a');
    expect(empty.ok, isTrue);
    expect(empty.index.activeBatchId, isNull);
    expect(empty.index.entries, isEmpty);
  });

  test('删除批次的写序：索引写失败时保留载荷，成功后才删', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
      makeActive: true,
    );
    final values = <String, Object>{
      for (final key in prefs.getKeys()) key: prefs.get(key)!,
    };
    final failing = _FailingIndexPrefs(values);
    final failingStore = AiRecommendationStore(
      preferences: failing,
      clock: () => now,
    );

    final failed = await failingStore.deleteBatch('a');

    expect(failed.ok, isFalse);
    expect(failingStore.loadBatch('a'), isNotNull, reason: '索引没写成功，批次载荷不能先被删掉');
    expect(
      (await failingStore.loadIndex()).entries.map((entry) => entry.id),
      containsAll(['a', 'b']),
    );

    failing.failIndexWrites = false;
    final ok = await failingStore.deleteBatch('a');

    expect(ok.ok, isTrue);
    expect(values['${AiRecommendationStore.batchKeyPrefix}a'], isNull);
  });

  test('清空历史的写序：索引写失败时保留非 active 载荷', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
    );
    final values = <String, Object>{
      for (final key in prefs.getKeys()) key: prefs.get(key)!,
    };
    final failing = _FailingIndexPrefs(values);
    final failingStore = AiRecommendationStore(
      preferences: failing,
      clock: () => now,
    );

    final failed = await failingStore.clearHistory();

    expect(failed.ok, isFalse);
    expect(
      failingStore.loadBatch('b'),
      isNotNull,
      reason: '索引没写成功，非 active 载荷不能先被删掉',
    );

    failing.failIndexWrites = false;
    final ok = await failingStore.clearHistory();

    expect(ok.ok, isTrue);
    expect(values['${AiRecommendationStore.batchKeyPrefix}b'], isNull);
    expect(values['${AiRecommendationStore.batchKeyPrefix}a'], isNotNull);
  });

  test('清空历史保留 active 与其批次键', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
    );
    await store.saveBatch(
      batch('c', generatedAt: now.add(const Duration(minutes: 2))),
    );

    final result = await store.clearHistory();

    expect(result.ok, isTrue);
    expect(result.index.entries.map((entry) => entry.id), ['a']);
    expect(result.index.activeBatchId, 'a');
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'),
      isNotNull,
    );
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}b'), isNull);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}c'), isNull);
  });

  test('保留策略：最多 20 批，active 永不自动清理', () async {
    await store.saveBatch(
      batch('old-active', generatedAt: now.subtract(const Duration(days: 1))),
      makeActive: true,
    );
    for (var i = 0; i < 24; i++) {
      await store.saveBatch(
        batch('b$i', generatedAt: now.add(Duration(minutes: i))),
      );
    }

    final index = await store.loadIndex();
    expect(index.entries, hasLength(20));
    expect(index.activeBatchId, 'old-active');
    expect(index.entries.any((entry) => entry.id == 'old-active'), isTrue);
    // 最老的非 active 批次键被同步删除。
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}b0'),
      isNull,
    );
  });

  test('保留策略：最多 400 首', () async {
    for (var i = 0; i < 20; i++) {
      await store.saveBatch(
        batch('b$i', count: 30, generatedAt: now.add(Duration(minutes: i))),
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
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}old'),
      isNull,
    );
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
