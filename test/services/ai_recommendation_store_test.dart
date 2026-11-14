import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:path/path.dart' as p;
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
  late Directory tempDir;
  final now = DateTime(2026, 10, 21, 12);

  File batchFile(String id) =>
      File(p.join(tempDir.path, '${sha1.convert(utf8.encode(id))}.json'));

  AiRecommendationStore buildStore({
    SharedPreferences? preferences,
    DateTime Function()? clock,
    Future<Directory> Function()? directoryProvider,
  }) => AiRecommendationStore(
    preferences: preferences,
    clock: clock ?? () => now,
    directoryProvider: directoryProvider ?? () async => tempDir,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempDir = await Directory.systemTemp.createTemp('molia-ai-history-');
    store = buildStore(preferences: prefs);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  StoredAiBatch batch(
    String id, {
    int count = 1,
    DateTime? generatedAt,
    AiDjOrigin origin = AiDjOrigin.refresh,
    AiPreferences? preferences,
  }) => StoredAiBatch(
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
          sourceName: '网易音乐',
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
    expect(await batchFile('a').exists(), isTrue);
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'),
      isNull,
      reason: '批次只进文件，prefs 只保留索引',
    );
    expect((await store.loadBatch('b'))!.items.single.sourceName, '网易音乐');
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
    final payloads = [
      prefs.getString(AiRecommendationStore.indexKey)!,
      await batchFile('a').readAsString(),
      await batchFile('b').readAsString(),
    ];
    for (final raw in payloads) {
      expect(raw.contains('rawResponse'), isFalse);
      expect(raw.contains('systemPrompt'), isFalse);
      expect(raw.contains('userPrompt'), isFalse);
    }
    for (final id in ['a', 'b']) {
      expect(
        prefs.getString('${AiRecommendationStore.batchKeyPrefix}$id'),
        isNull,
      );
    }
  });

  test('保存批次只写索引到 prefs，不产生旧批次键', () async {
    await store.saveBatch(batch('a'), makeActive: true);
    await store.saveBatch(
      batch('b', generatedAt: now.add(const Duration(minutes: 1))),
    );

    expect(prefs.getKeys(), {AiRecommendationStore.indexKey});
    expect(await batchFile('a').exists(), isTrue);
    expect(await batchFile('b').exists(), isTrue);
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
    expect(await batchFile('b').exists(), isFalse);

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
    final failingStore = buildStore(preferences: failing);

    final failed = await failingStore.deleteBatch('a');

    expect(failed.ok, isFalse);
    expect(
      await failingStore.loadBatch('a'),
      isNotNull,
      reason: '索引没写成功，批次载荷不能先被删掉',
    );
    expect(
      (await failingStore.loadIndex()).entries.map((entry) => entry.id),
      containsAll(['a', 'b']),
    );

    failing.failIndexWrites = false;
    final ok = await failingStore.deleteBatch('a');

    expect(ok.ok, isTrue);
    expect(await batchFile('a').exists(), isFalse);
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
    final failingStore = buildStore(preferences: failing);

    final failed = await failingStore.clearHistory();

    expect(failed.ok, isFalse);
    expect(
      await failingStore.loadBatch('b'),
      isNotNull,
      reason: '索引没写成功，非 active 载荷不能先被删掉',
    );

    failing.failIndexWrites = false;
    final ok = await failingStore.clearHistory();

    expect(ok.ok, isTrue);
    expect(await batchFile('b').exists(), isFalse);
    expect(await batchFile('a').exists(), isTrue);
  });

  test('清空历史保留 active 与其批次载荷', () async {
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
    expect(await batchFile('a').exists(), isTrue);
    expect(await batchFile('b').exists(), isFalse);
    expect(await batchFile('c').exists(), isFalse);
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
    // 最老的非 active 批次文件被同步删除。
    expect(await batchFile('b0').exists(), isFalse);
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
    expect(await batchFile('old').exists(), isFalse);
  });

  test('损坏索引 / 批次降级为空，不抛异常', () async {
    await prefs.setString(AiRecommendationStore.indexKey, 'not-json{{{');
    expect((await store.loadIndex()).entries, isEmpty);

    await batchFile('bad').writeAsString('{"items":');
    expect(await store.loadBatch('bad'), isNull);
    expect(await store.loadBatch('missing'), isNull);
  });

  test('启动迁移：旧 prefs 批次转文件后删键，loadBatch 也兜底', () async {
    final indexed = batch('indexed');
    await prefs.setString(
      AiRecommendationStore.indexKey,
      jsonEncode({
        'activeBatchId': indexed.id,
        'entries': [indexed.toHistoryEntry().toJson()],
      }),
    );
    await prefs.setString(
      '${AiRecommendationStore.batchKeyPrefix}indexed',
      jsonEncode(indexed.toJson()),
    );

    final migrated = buildStore(preferences: prefs);
    final index = await migrated.loadIndex();

    expect(index.entries.single.id, 'indexed');
    expect(index.activeBatchId, 'indexed');
    expect(await batchFile('indexed').exists(), isTrue);
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}indexed'),
      isNull,
      reason: '迁移成功才删旧键',
    );
    expect((await migrated.loadBatch('indexed'))!.id, 'indexed');

    // 索引迁移之后才出现的孤儿旧键（例如旧版本晚写），loadBatch 仍要兜底。
    final lazy = batch(
      'lazy',
      generatedAt: now.add(const Duration(minutes: 1)),
    );
    await prefs.setString(
      '${AiRecommendationStore.batchKeyPrefix}lazy',
      jsonEncode(lazy.toJson()),
    );

    expect((await migrated.loadBatch('lazy'))!.id, 'lazy');
    expect(await batchFile('lazy').exists(), isTrue);
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}lazy'),
      isNull,
    );

    // 幂等：再次读取不改变索引 / 文件。
    expect((await migrated.loadIndex()).entries.single.id, 'indexed');
    expect(await batchFile('lazy').exists(), isTrue);
  });

  test('迁移失败保留旧键，下次读取再试', () async {
    final raw = jsonEncode(batch('a').toJson());
    await prefs.setString('${AiRecommendationStore.batchKeyPrefix}a', raw);

    final unavailable = buildStore(
      preferences: prefs,
      directoryProvider: () async => throw const FileSystemException('nope'),
    );
    await unavailable.loadIndex();
    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'),
      isNotNull,
      reason: '目录不可用时不能删掉唯一的旧副本',
    );

    final retry = buildStore(preferences: prefs);
    await retry.loadIndex();
    expect(await batchFile('a').exists(), isTrue);
    expect(prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'), isNull);
  });

  test('目录不可用时退回旧 prefs 键，历史仍可读写', () async {
    final fallback = buildStore(
      preferences: prefs,
      directoryProvider: () async => throw const FileSystemException('nope'),
    );

    await fallback.saveBatch(batch('a'), makeActive: true);

    expect(
      prefs.getString('${AiRecommendationStore.batchKeyPrefix}a'),
      isNotNull,
    );
    expect((await fallback.loadBatch('a'))!.id, 'a');
    expect((await fallback.loadIndex()).activeBatchId, 'a');
  });
}
