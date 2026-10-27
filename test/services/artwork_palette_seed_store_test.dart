import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/artwork_palette_seed_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可注入的内存 `SharedPreferences`：记录 `setString` 次数（验证同 seed 不重复
/// 落盘），并可模拟平台通道异常。
class _RecordingPrefs implements SharedPreferences {
  _RecordingPrefs([Map<String, Object>? initial]) : values = {...?initial};

  final Map<String, Object> values;
  int setStringCalls = 0;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  @override
  Set<String> getKeys() => Set.of(values.keys);

  @override
  Object? get(String key) =>
      throwOnRead ? throw StateError('read') : values[key];

  @override
  bool? getBool(String key) =>
      throwOnRead ? throw StateError('read') : values[key] as bool?;

  @override
  int? getInt(String key) =>
      throwOnRead ? throw StateError('read') : values[key] as int?;

  @override
  double? getDouble(String key) =>
      throwOnRead ? throw StateError('read') : values[key] as double?;

  @override
  String? getString(String key) =>
      throwOnRead ? throw StateError('read') : values[key] as String?;

  @override
  bool containsKey(String key) => values.containsKey(key);

  @override
  List<String>? getStringList(String key) =>
      (values[key] as List<dynamic>?)?.cast<String>();

  Future<bool> _set(String key, Object value) async {
    if (throwOnWrite) throw StateError('write');
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) => _set(key, value);

  @override
  Future<bool> setInt(String key, int value) => _set(key, value);

  @override
  Future<bool> setDouble(String key, double value) => _set(key, value);

  @override
  Future<bool> setString(String key, String value) async {
    setStringCalls++;
    return _set(key, value);
  }

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, value);

  @override
  Future<bool> remove(String key) async {
    if (throwOnWrite) throw StateError('remove');
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

/// 读出单键 JSON 里的 entries（断言结构 / LRU 顺序用）。
Map<String, dynamic> _entriesOf(SharedPreferences prefs) {
  final raw = prefs.getString(ArtworkPaletteSeedStore.storageKey);
  expect(raw, isNotNull, reason: '写入后应存在单键 JSON');
  final decoded = jsonDecode(raw!) as Map<String, dynamic>;
  return (decoded['entries'] as Map).cast<String, dynamic>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkPaletteSeedStore', () {
    test('写入 / 读取 round-trip；新实例读同一份 prefs 也命中', () async {
      final prefs = _RecordingPrefs();
      final store = ArtworkPaletteSeedStore(preferences: prefs);

      await store.write('cover:a', 0xFF112233);

      expect(await store.read('cover:a'), 0xFF112233);
      expect(await store.read('cover:missing'), isNull);

      final decoded = jsonDecode(
        prefs.getString(ArtworkPaletteSeedStore.storageKey)!,
      ) as Map;
      expect(decoded['v'], ArtworkPaletteSeedStore.formatVersion);
      expect(decoded['entries'], {'cover:a': 0xFF112233});

      // 换实例（模拟下次启动）只依赖持久化内容，不依赖进程内状态。
      final restarted = ArtworkPaletteSeedStore(preferences: prefs);
      expect(await restarted.read('cover:a'), 0xFF112233);
    });

    test('未注入 prefs 时懒加载 SharedPreferences 单例', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ArtworkPaletteSeedStore();

      await store.write('cover:lazy', 42);
      expect(await store.read('cover:lazy'), 42);

      final restarted = ArtworkPaletteSeedStore();
      expect(await restarted.read('cover:lazy'), 42);
    });

    test('版本不符 / 损坏 JSON / 非 int 都静默当空', () async {
      final corruptPayloads = <String>[
        jsonEncode({
          'v': 2,
          'entries': {'a': 7},
        }),
        '{"v":1,"entries":',
        jsonEncode({
          'v': 1,
          'entries': {'a': 'not-an-int'},
        }),
        jsonEncode({
          'v': 1,
          'entries': {'a': 1, 'b': 'bad'},
        }),
        jsonEncode({'v': 1, 'entries': []}),
      ];

      for (final raw in corruptPayloads) {
        final prefs = _RecordingPrefs({
          ArtworkPaletteSeedStore.storageKey: raw,
        });
        final store = ArtworkPaletteSeedStore(preferences: prefs);
        expect(await store.read('a'), isNull, reason: '无效内容应回退 null：$raw');
        expect(await store.read('b'), isNull, reason: '任一条目类型错误时整份不可信：$raw');
      }
    });

    test('损坏记录后的写入会重建合法 JSON', () async {
      final prefs = _RecordingPrefs({
        ArtworkPaletteSeedStore.storageKey: 'not-json',
      });
      final store = ArtworkPaletteSeedStore(preferences: prefs);
      expect(await store.read('a'), isNull);

      await store.write('a', 5);

      expect(await store.read('a'), 5);
      final decoded = jsonDecode(
        prefs.getString(ArtworkPaletteSeedStore.storageKey)!,
      ) as Map;
      expect(decoded['v'], ArtworkPaletteSeedStore.formatVersion);
    });

    test('超过 32 条淘汰最旧；改写同 key 会刷新 LRU 位置', () async {
      final prefs = _RecordingPrefs();
      final store = ArtworkPaletteSeedStore(preferences: prefs);
      const max = ArtworkPaletteSeedStore.maxEntries;

      for (var i = 0; i < max; i++) {
        await store.write('k$i', i + 1);
      }
      // 同 key 新 seed：先删再插到末尾，k1 成为最旧条目。
      await store.write('k0', 999);
      await store.write('k$max', max + 1);

      expect(await store.read('k0'), 999);
      expect(await store.read('k1'), isNull, reason: 'k1 应被淘汰');
      expect(await store.read('k2'), 3);
      expect(await store.read('k$max'), max + 1);

      final entries = _entriesOf(prefs);
      expect(entries.length, max);
      expect(entries.keys.first, 'k2');
      expect(entries.keys.last, 'k$max');
    });

    test('相同 seed 不重复写', () async {
      final prefs = _RecordingPrefs();
      final store = ArtworkPaletteSeedStore(preferences: prefs);

      await store.write('cover:a', 7);
      expect(prefs.setStringCalls, 1);

      await store.write('cover:a', 7);
      expect(prefs.setStringCalls, 1, reason: '内容未变不应重复整键写入');
      expect(await store.read('cover:a'), 7);
    });

    test('并发 write 串行落盘，不丢 key', () async {
      final prefs = _RecordingPrefs();
      final store = ArtworkPaletteSeedStore(preferences: prefs);
      const count = 12;

      await Future.wait([
        for (var i = 0; i < count; i++) store.write('k$i', 1000 + i),
      ]);

      for (var i = 0; i < count; i++) {
        expect(await store.read('k$i'), 1000 + i);
      }
      expect(_entriesOf(prefs).length, count);
    });

    test('clear 清空缓存，之后可再次写入', () async {
      final prefs = _RecordingPrefs();
      final store = ArtworkPaletteSeedStore(preferences: prefs);

      await store.write('a', 1);
      await store.clear();

      expect(await store.read('a'), isNull);
      expect(
        prefs.values.containsKey(ArtworkPaletteSeedStore.storageKey),
        isFalse,
      );

      await store.write('b', 2);
      expect(await store.read('b'), 2);
    });

    test('平台异常只记日志：read 回 null，write / clear 不抛且队列继续', () async {
      final readFail = _RecordingPrefs()..throwOnRead = true;
      final readStore = ArtworkPaletteSeedStore(preferences: readFail);
      expect(await readStore.read('a'), isNull);

      final writeFail = _RecordingPrefs()..throwOnWrite = true;
      final writeStore = ArtworkPaletteSeedStore(preferences: writeFail);
      await expectLater(writeStore.write('a', 1), completes);
      await expectLater(writeStore.clear(), completes);

      // 失败不能毒化写队列：恢复后下一次 write 仍按序落盘。
      writeFail.throwOnWrite = false;
      await writeStore.write('b', 2);
      expect(await writeStore.read('b'), 2);
    });
  });
}
