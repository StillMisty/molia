/// 播放会话存储的写队列：整份保存 / 轻量进度 / 远端原样写入 / 清除共用
/// 同一个 `pendingWrite`，按调用顺序串行。
///
/// 为什么单独测：跨设备同步曾经另建一个 store（第二个队列）写同一组 prefs 键；
/// 单写者的核心保证不是「最后写入者胜出」，而是**后一个写请求必须等前一个
/// 完成**。这里用可暂停的平台写入把「在途」状态固定住，断言远端应用不会插到
/// 本地保存中间。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 仅测试用：把平台写入变慢，才能观察到队列；不是 lib 的依赖。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 可暂停的 prefs 平台实现：会话键的写入停在 [gate] 上，释放后继续。
class _GatedPrefsStore extends InMemorySharedPreferencesStore {
  _GatedPrefsStore() : super.empty();

  final List<String> writes = [];
  final List<String> removes = [];
  Completer<void>? gate;

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
    // 会话键 + 进度键各两次：本地保存先写完，远端写入再开始。
    expect(platform.writes, hasLength(4));

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
    expect(platform.removes, hasLength(2));
    expect(await store.loadRaw(), isNull);
  });
}
