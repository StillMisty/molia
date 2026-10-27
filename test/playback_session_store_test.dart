/// 播放会话存储的落盘口径：整份队列 / 游标 / 轻量进度分开写，全部经同一个
/// `pendingWrite` 队列按调用顺序串行。
///
/// 为什么单独测：跨设备同步曾经另建一个 store（第二个队列）写同一组 prefs 键；
/// 单写者的核心保证不是「最后写入者胜出」，而是**后一个写请求必须等前一个
/// 完成**。这里用可暂停的平台写入把「在途」状态固定住，断言远端应用不会插到
/// 本地保存中间。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 仅测试用：把平台写入变慢，才能观察到队列；不是 lib 的依赖。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const String _fullKey = 'playback_session_v1';
const String _stateKey = 'playback_session_state_v1';
const String _positionKey = 'playback_session_position_v1';

/// 可暂停的 prefs 平台实现：会话键的写入停在 [gate] 上，释放后继续。
class _GatedPrefsStore extends InMemorySharedPreferencesStore {
  _GatedPrefsStore() : super.empty();

  final List<String> writes = [];
  final List<String> removes = [];
  Completer<void>? gate;

  /// `SharedPreferences.reload()` 会整表回读；用它观察是否只在失败路径回读。
  int getAllCalls = 0;

  @override
  Future<Map<String, Object>> getAll() {
    getAllCalls++;
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    final current = gate;
    if (current != null && key.endsWith('playback_session_v1')) {
      await current.future;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    removes.add(key);
    return super.remove(key);
  }
}

/// 可让完整会话键写入失败 N 次的平台实现：验证缓存只在写成功后提交。
class _FailingFullWriteStore extends _GatedPrefsStore {
  int failuresLeft = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failuresLeft > 0 && key.endsWith('playback_session_v1')) {
      failuresLeft--;
      writes.add(key);
      throw StateError('模拟完整会话写入失败');
    }
    return super.setValue(valueType, key, value);
  }
}

/// 完整会话键写入返回 false（不抛异常）的平台实现：验证不落盘时也不写游标。
class _RejectingFullWriteStore extends _GatedPrefsStore {
  bool rejectFullWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (rejectFullWrites && key.endsWith('playback_session_v1')) {
      writes.add(key);
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// 仅在游标键写入时返回 false 的平台实现：验证进度键不会单独推进。
class _RejectingStateWriteStore extends _GatedPrefsStore {
  bool rejectStateWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (rejectStateWrites && key.endsWith('playback_session_state_v1')) {
      writes.add(key);
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// 仅在进度键写入时返回 false 的平台实现：验证旧进度被清掉。
class _RejectingPositionWriteStore extends _GatedPrefsStore {
  bool rejectPositionWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (rejectPositionWrites && key.endsWith('playback_session_position_v1')) {
      writes.add(key);
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// 平台层真实落盘的键（`SharedPreferences` 的内存缓存会先于平台写入更新，
/// 平台抛错时缓存里仍有值，不能拿它判断是否落盘）。
Future<bool> _persisted(_GatedPrefsStore store, String key) async =>
    (await store.getAll()).keys.any((persisted) => persisted.endsWith(key));

/// 平台层真实落盘的值（同上：绕过 `SharedPreferences` 内存缓存）。
Future<Object?> _persistedValue(_GatedPrefsStore store, String key) async {
  final all = await store.getAll();
  for (final entry in all.entries) {
    if (entry.key.endsWith(key)) return entry.value;
  }
  return null;
}

Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      origin: TrackOrigin.lx,
      payload: const {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GatedPrefsStore platform;

  setUp(() {
    SharedPreferences.resetStatic();
    platform = _GatedPrefsStore();
    SharedPreferencesStorePlatform.instance = platform;
  });

  tearDown(() {
    // 还原标准的内存实现，避免影响同进程内的其它测试。
    SharedPreferences.setMockInitialValues({});
  });

  test('远端应用排在在途本地保存之后：同一个 pendingWrite 队列', () async {
    // 协调者 applyRemote 最终落到 saveRaw：直接压底层写入验证队列顺序。
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final gate = Completer<void>();
    platform.gate = gate;

    final save = store.save(PlaybackSession(
      tracks: [_track('local')],
      index: 0,
      position: const Duration(seconds: 1),
    ));
    await pumpEventQueue();
    // 本地保存已进入平台写入并停在 gate 上。
    expect(platform.writes, hasLength(1));
    expect(platform.writes.single, endsWith('playback_session_v1'));

    final remote = store.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 0,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {
          'sourceKey': 'fake',
          'id': 'remote',
          'title': '远端曲目',
          'origin': 'lx',
          'payload': const <String, Object?>{},
        },
      ],
    });
    await pumpEventQueue();
    // 本地保存仍在途：远端写入尚未开始（若另有一个队列，这里会变成 2）。
    expect(platform.writes, hasLength(1));

    gate.complete();
    await Future.wait([save, remote]);
    // 每条保存 = 会话键 + 游标键 + 进度键；本地先写完三个键，远端才开始。
    expect(platform.writes, hasLength(6));
    expect(platform.writes.take(3), [
      endsWith('playback_session_v1'),
      endsWith('playback_session_state_v1'),
      endsWith('playback_session_position_v1'),
    ]);
    expect(platform.writes.skip(3), [
      endsWith('playback_session_v1'),
      endsWith('playback_session_state_v1'),
      endsWith('playback_session_position_v1'),
    ]);

    final raw = await store.loadRaw();
    expect(raw![PlaybackSessionStore.savedAtKey], 9000);
    expect((raw['tracks'] as List).single['id'], 'remote');
    expect(raw['positionMs'], 7000);
  });

  test('远端清除排在在途本地保存之后：不会被保存复活', () async {
    // 协调者 clearRemote 最终落到 clear：同样压底层写入验证队列。
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final gate = Completer<void>();
    platform.gate = gate;

    final save = store.save(PlaybackSession(
      tracks: [_track('local')],
      index: 0,
      position: const Duration(seconds: 1),
    ));
    await pumpEventQueue();
    expect(platform.writes, hasLength(1));

    final clear = store.clear();
    await pumpEventQueue();
    // 清除还在队列里等本地保存完成：一个 key 都还没删。
    expect(platform.removes, isEmpty);

    gate.complete();
    await Future.wait([save, clear]);
    expect(platform.removes, hasLength(3));
    expect(platform.removes, [
      endsWith('playback_session_v1'),
      endsWith('playback_session_state_v1'),
      endsWith('playback_session_position_v1'),
    ]);
    expect(await store.loadRaw(), isNull);
  });

  test('同队列切歌：只写游标键 + 进度键，loadRaw 合并新下标', () async {
    final prefs = await SharedPreferences.getInstance();
    var clockMs = 1000;
    final store = PlaybackSessionStore(
      preferences: prefs,
      clock: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
    );
    final tracks = [_track('a'), _track('b')];

    await store.save(PlaybackSession(
      tracks: tracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final full = prefs.getString(_fullKey);
    expect(full, isNotNull);
    expect(jsonDecode(full!)['index'], 0);
    expect(prefs.getString(_stateKey), isNotNull);

    platform.writes.clear();
    clockMs = 2000;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));

    // 队列列表实例相同：整份 JSON 原样未重写，只写游标 / 进度两个小键。
    expect(platform.writes, [
      endsWith('playback_session_state_v1'),
      endsWith('playback_session_position_v1'),
    ]);
    expect(prefs.getString(_fullKey), full);

    // 游标键补上整份 JSON 里过期的下标 / 进度 / 内容时间。
    final raw = await store.loadRaw();
    expect(raw!['index'], 1);
    expect(raw['positionMs'], 2000);
    expect(raw[PlaybackSessionStore.savedAtKey], 2000);
    expect((raw['tracks'] as List), hasLength(2));
    expect(prefs.getInt(_positionKey), 2000);
    final loaded = await store.load();
    expect(loaded!.index, 1);
    expect(loaded.current!.id.id, 'b');
  });

  test('队列 / 模式变化：重新写整份会话键', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    await store.save(PlaybackSession(tracks: [_track('a')], index: 0));
    final first = prefs.getString(_fullKey);

    // 队列列表实例变了：整份重写（load 能读到新队列）。
    platform.writes.clear();
    final next = [_track('a'), _track('b')];
    await store.save(PlaybackSession(tracks: next, index: 1));
    expect(platform.writes.first, endsWith('playback_session_v1'));
    expect(prefs.getString(_fullKey), isNot(first));
    final loaded = await store.load();
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);

    // 同一列表实例、只改模式：模式在整份 JSON 里，同样整份重写。
    final second = prefs.getString(_fullKey);
    platform.writes.clear();
    await store.save(
      PlaybackSession(tracks: next, index: 1, mode: PlayMode.shuffle),
    );
    expect(platform.writes.first, endsWith('playback_session_v1'));
    expect(prefs.getString(_fullKey), isNot(second));
    expect((await store.load())!.mode, PlayMode.shuffle);
  });

  test('远端原样写入后：本地保存保守重写整份会话', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final tracks = [_track('a')];
    await store.save(PlaybackSession(tracks: tracks, index: 0));

    await store.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 0,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote', 'title': '远端', 'origin': 'lx'},
      ],
    });
    expect((await store.load())!.current!.id.id, 'remote');

    // 远端覆盖过队列：同一个本地列表再保存时必须整份重写，否则会话键
    // 还是远端队列。
    platform.writes.clear();
    await store.save(PlaybackSession(tracks: tracks, index: 0));
    expect(platform.writes.first, endsWith('playback_session_v1'));
    final rewritten = jsonDecode(prefs.getString(_fullKey)!);
    expect((rewritten['tracks'] as List).single['id'], 'a');
    expect((await store.load())!.current!.id.id, 'a');
  });

  test('旧数据 / 外部整份改写：没有更新的游标键时以会话键为准', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);

    // 旧版本写的会话（没有游标键）：行为不变。
    await prefs.setString(
      _fullKey,
      jsonEncode({
        'index': 1,
        'positionMs': 4000,
        'mode': 'shuffle',
        'savedAt': 777,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'a', 'title': 'A', 'origin': 'lx'},
          {'sourceKey': 'fake', 'id': 'b', 'title': 'B', 'origin': 'lx'},
        ],
      }),
    );
    var raw = await store.loadRaw();
    expect(raw!['index'], 1);
    expect(raw['positionMs'], 4000);
    expect(raw[PlaybackSessionStore.savedAtKey], 777);
    expect((await store.load())!.index, 1);

    // 数据注入 / 旧版本整份改写会话键（savedAt 更新）：本实例缓存的游标键
    // 已不属于这份队列，不能按下标覆盖。
    const clockMs = 1000;
    final owned = PlaybackSessionStore(
      preferences: prefs,
      clock: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
    );
    await owned.save(PlaybackSession(tracks: [_track('a')], index: 0));
    await prefs.setString(
      _fullKey,
      jsonEncode({
        'index': 1,
        'positionMs': 0,
        'mode': 'shuffle',
        'savedAt': 999999,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'x', 'title': 'X', 'origin': 'lx'},
          {'sourceKey': 'fake', 'id': 'y', 'title': 'Y', 'origin': 'lx'},
        ],
      }),
    );
    raw = await owned.loadRaw();
    expect(raw!['index'], 1);
    expect(raw[PlaybackSessionStore.savedAtKey], 999999);
    expect((raw['tracks'] as List), hasLength(2));
  });

  test('完整会话写入失败：下一次同队列保存仍重试整份会话键', () async {
    final failing = _FailingFullWriteStore();
    SharedPreferencesStorePlatform.instance = failing;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final tracks = [_track('a'), _track('b')];

    failing.failuresLeft = 1;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    // 完整键写失败：平台层没有落盘，缓存不能记成「这份队列已落盘」；
    // 游标也不能单独写，否则旧队列会配上新下标。
    expect(await _persisted(failing, _fullKey), isFalse);
    expect(failing.writes, contains(endsWith('playback_session_v1')));
    expect(failing.writes, isNot(contains(endsWith(_stateKey))));

    failing.writes.clear();
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));
    expect(failing.writes.first, endsWith('playback_session_v1'),
        reason: '上次完整写入失败，同队列切歌也必须重写整份键');
    expect(await _persisted(failing, _fullKey), isTrue);
    final loaded = await store.load();
    expect(loaded!.index, 1);
    expect(loaded.tracks, hasLength(2));
    expect(loaded.current!.id.id, 'b');
  });

  test('完整会话写入被拒：内存缓存回到平台旧值，重试仍能落盘', () async {
    final rejecting = _RejectingFullWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final oldTracks = [_track('a'), _track('b')];
    // getInstance() 首次装载本身会整表读取，不计入写入路径的回读。
    rejecting.getAllCalls = 0;

    await store.save(PlaybackSession(
      tracks: oldTracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final oldFull = prefs.getString(_fullKey);
    final oldState = prefs.getString(_stateKey);
    expect(oldFull, isNotNull);
    expect(rejecting.getAllCalls, 0, reason: '正常写入不回读平台');

    // 平台拒绝落盘，但 setString 已把新 JSON 放进进程内缓存。
    final nextTracks = [_track('c')];
    rejecting.rejectFullWrites = true;
    await store.save(PlaybackSession(
      tracks: nextTracks,
      index: 0,
      position: const Duration(seconds: 2),
    ));
    expect(rejecting.getAllCalls, 1, reason: '只在失败路径回读一次');

    // 缓存必须回到平台真实值（旧会话），而不是被拒绝的新队列；否则同进程的
    // load() 会把没落盘的会话当成已保存。
    expect(prefs.getString(_fullKey), oldFull);
    expect(prefs.getString(_stateKey), oldState);
    expect(prefs.getInt(_positionKey), 1000);
    final staleLoad = await store.load();
    expect(staleLoad!.current!.id.id, 'a');
    expect(staleLoad.position, const Duration(seconds: 1));

    // 平台恢复后重试：缓存已与磁盘一致，整份键照常重写并落盘。
    rejecting.rejectFullWrites = false;
    await store.save(PlaybackSession(
      tracks: nextTracks,
      index: 0,
      position: const Duration(seconds: 2),
    ));
    expect(
      await _persistedValue(rejecting, _fullKey),
      prefs.getString(_fullKey),
    );
    expect(
      (jsonDecode(prefs.getString(_fullKey)!)['tracks'] as List).single['id'],
      'c',
    );
    final reloaded = await store.load();
    expect(reloaded!.current!.id.id, 'c');
    expect(reloaded.position, const Duration(seconds: 2));
  });

  test('远端原样写入被平台拒绝：不写游标，重启后仍是旧会话', () async {
    final rejecting = _RejectingFullWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final localTracks = [_track('a'), _track('b')];

    await store.save(PlaybackSession(
      tracks: localTracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final oldFull = prefs.getString(_fullKey);
    final oldState = prefs.getString(_stateKey);
    expect(oldFull, isNotNull);
    expect(oldState, isNotNull);

    rejecting.writes.clear();
    rejecting.rejectFullWrites = true;
    await store.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 1,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote-a', 'title': '远端 A', 'origin': 'lx'},
        {'sourceKey': 'fake', 'id': 'remote-b', 'title': '远端 B', 'origin': 'lx'},
      ],
    });

    // 完整键被平台拒绝：不能写远端游标，否则旧队列会配上远端下标。
    expect(rejecting.writes, contains(endsWith(_fullKey)));
    expect(rejecting.writes, isNot(contains(endsWith(_stateKey))));
    expect(await _persistedValue(rejecting, _fullKey), oldFull);
    expect(await _persistedValue(rejecting, _stateKey), oldState);
    expect(await _persistedValue(rejecting, _positionKey), 1000);

    // 模拟重启：平台层仍是旧会话 + 旧游标，下标与队列自洽。
    SharedPreferences.resetStatic();
    final oldSession = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(oldSession!.index, 0);
    expect(oldSession.current!.id.id, 'a');
    expect(oldSession.position, const Duration(seconds: 1));

    // 失败不粘滞：平台恢复后同一份远端会话能重新写入。
    rejecting.rejectFullWrites = false;
    rejecting.writes.clear();
    await store.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 1,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote-a', 'title': '远端 A', 'origin': 'lx'},
        {'sourceKey': 'fake', 'id': 'remote-b', 'title': '远端 B', 'origin': 'lx'},
      ],
    });
    expect(rejecting.writes.take(2), [
      endsWith(_fullKey),
      endsWith(_stateKey),
    ]);
    expect(await _persistedValue(rejecting, _positionKey), 7000);

    SharedPreferences.resetStatic();
    final applied = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(applied!.index, 1);
    expect(applied.current!.id.id, 'remote-b');
  });

  test('游标键写入被拒：跳过进度键，重启保持旧会话一致', () async {
    final rejecting = _RejectingStateWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final tracks = [_track('a'), _track('b')];

    await store.save(PlaybackSession(
      tracks: tracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final oldState = await _persistedValue(rejecting, _stateKey);
    expect(oldState, isNotNull);

    rejecting.writes.clear();
    rejecting.rejectStateWrites = true;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));

    // 游标被拒：本轮不能写进度键，否则旧曲目会配上新进度。
    expect(rejecting.writes, [endsWith(_stateKey)]);
    expect(await _persistedValue(rejecting, _stateKey), oldState);
    expect(await _persistedValue(rejecting, _positionKey), 1000);

    // 重启回到旧曲目 + 旧进度（一致），而不是旧曲目 + 新进度。
    SharedPreferences.resetStatic();
    final restarted = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(restarted!.index, 0);
    expect(restarted.current!.id.id, 'a');
    expect(restarted.position, const Duration(seconds: 1));

    // 平台恢复后同队列保存补齐游标 / 进度，重启读到新曲目。
    rejecting.rejectStateWrites = false;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));
    expect(await _persistedValue(rejecting, _stateKey), isNotNull);
    expect(await _persistedValue(rejecting, _positionKey), 2000);

    SharedPreferences.resetStatic();
    final resumed = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(resumed!.index, 1);
    expect(resumed.current!.id.id, 'b');
    expect(resumed.position, const Duration(seconds: 2));
  });

  test('整份写入成功但游标被拒：旧游标 / 进度被清掉，按完整 JSON 恢复', () async {
    final rejecting = _RejectingStateWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);

    await store.save(PlaybackSession(tracks: [_track('a')], index: 0));
    final next = [_track('a'), _track('b')];

    rejecting.writes.clear();
    rejecting.rejectStateWrites = true;
    await store.save(PlaybackSession(
      tracks: next,
      index: 1,
      position: const Duration(seconds: 3),
    ));

    // 完整键已写成新队列：旧游标可能压过它（savedAt 相等），旧进度也会
    // 盖掉新 position，因此失败时把两者删掉，读取回落到完整 JSON。
    expect(rejecting.writes, [endsWith(_fullKey), endsWith(_stateKey)]);
    expect(await _persistedValue(rejecting, _stateKey), isNull);
    expect(await _persistedValue(rejecting, _positionKey), isNull);

    SharedPreferences.resetStatic();
    final restarted = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(restarted!.index, 1);
    expect(restarted.current!.id.id, 'b');
    expect(restarted.position, const Duration(seconds: 3));

    // 完整键已成功，重试只需补游标 / 进度，不必重写整份 JSON。
    rejecting.rejectStateWrites = false;
    rejecting.writes.clear();
    await store.save(PlaybackSession(
      tracks: next,
      index: 1,
      position: const Duration(seconds: 3),
    ));
    expect(rejecting.writes, [
      endsWith(_stateKey),
      endsWith(_positionKey),
    ]);
  });

  test('远端原样写入游标被拒：移除旧游标，重启读到远端会话', () async {
    final rejecting = _RejectingStateWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);

    await store.save(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final remote = {
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 1,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote-a', 'title': '远端 A', 'origin': 'lx'},
        {'sourceKey': 'fake', 'id': 'remote-b', 'title': '远端 B', 'origin': 'lx'},
      ],
    };

    rejecting.writes.clear();
    rejecting.rejectStateWrites = true;
    await store.saveRaw(remote);

    // 新完整键已写入：旧游标 / 进度必须清掉，否则会盖在远端队列上。
    expect(rejecting.writes, [endsWith(_fullKey), endsWith(_stateKey)]);
    expect(await _persistedValue(rejecting, _stateKey), isNull);
    expect(await _persistedValue(rejecting, _positionKey), isNull);

    SharedPreferences.resetStatic();
    final applied = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(applied!.index, 1);
    expect(applied.current!.id.id, 'remote-b');
    expect(applied.position, const Duration(milliseconds: 7000));

    // 平台恢复后重试仍写完整键 + 游标 + 进度。
    rejecting.rejectStateWrites = false;
    rejecting.writes.clear();
    await store.saveRaw(remote);
    expect(rejecting.writes, [
      endsWith(_fullKey),
      endsWith(_stateKey),
      endsWith(_positionKey),
    ]);
  });

  test('进度键写入被拒：移除旧进度，重启按 state 恢复新进度', () async {
    final rejecting = _RejectingPositionWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final tracks = [_track('a'), _track('b')];

    await store.save(PlaybackSession(
      tracks: tracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    expect(await _persistedValue(rejecting, _positionKey), 1000);

    rejecting.writes.clear();
    rejecting.rejectPositionWrites = true;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));

    // 游标已写成功、进度被拒：旧进度必须删掉，否则读取时会盖掉 state 的新值。
    expect(rejecting.writes, [
      endsWith(_stateKey),
      endsWith(_positionKey),
    ]);
    expect(await _persistedValue(rejecting, _positionKey), isNull);
    final state = jsonDecode(
      await _persistedValue(rejecting, _stateKey) as String,
    );
    expect(state['index'], 1);
    expect(state['positionMs'], 2000);

    // 重启：曲目与进度都来自 state，而不是旧进度键。
    SharedPreferences.resetStatic();
    final restarted = PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    );
    final raw = await restarted.loadRaw();
    expect(raw!['index'], 1);
    expect(raw['positionMs'], 2000);
    final loaded = await restarted.load();
    expect(loaded!.current!.id.id, 'b');
    expect(loaded.position, const Duration(seconds: 2));

    // 平台恢复后进度能正常补写。
    rejecting.rejectPositionWrites = false;
    await store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));
    expect(await _persistedValue(rejecting, _positionKey), 2000);
  });

  test('远端原样写入进度键被拒：移除旧进度，重启按远端 state 恢复', () async {
    final rejecting = _RejectingPositionWriteStore();
    SharedPreferencesStorePlatform.instance = rejecting;
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);

    await store.save(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 1),
    ));
    final remote = {
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 1,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote-a', 'title': '远端 A', 'origin': 'lx'},
        {'sourceKey': 'fake', 'id': 'remote-b', 'title': '远端 B', 'origin': 'lx'},
      ],
    };

    rejecting.writes.clear();
    rejecting.rejectPositionWrites = true;
    await store.saveRaw(remote);

    // 完整键 / 游标已写成功，只丢进度：旧进度必须删掉，不能盖住远端 7s。
    expect(rejecting.writes, [
      endsWith(_fullKey),
      endsWith(_stateKey),
      endsWith(_positionKey),
    ]);
    expect(await _persistedValue(rejecting, _positionKey), isNull);

    SharedPreferences.resetStatic();
    final applied = await PlaybackSessionStore(
      preferences: await SharedPreferences.getInstance(),
    ).load();
    expect(applied!.index, 1);
    expect(applied.current!.id.id, 'remote-b');
    expect(applied.position, const Duration(milliseconds: 7000));
  });

  test('完整写入在途时的同队列保存：不能拿未落盘的缓存跳过整份键', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackSessionStore(preferences: prefs);
    final tracks = [_track('a'), _track('b')];
    final gate = Completer<void>();
    platform.gate = gate;

    final first = store.save(PlaybackSession(
      tracks: tracks,
      index: 0,
      position: const Duration(seconds: 1),
    ));
    await pumpEventQueue();
    expect(platform.writes, hasLength(1));

    // 第一次完整写入还没成功：第二次同队列保存也必须自己写整份键。
    final second = store.save(PlaybackSession(
      tracks: tracks,
      index: 1,
      position: const Duration(seconds: 2),
    ));
    await pumpEventQueue();
    expect(platform.writes, hasLength(1));

    gate.complete();
    await Future.wait([first, second]);
    expect(
      platform.writes.where((key) => key.endsWith('playback_session_v1')),
      hasLength(2),
    );
    final loaded = await store.load();
    expect(loaded!.index, 1);
    expect(loaded.current!.id.id, 'b');
  });
}
