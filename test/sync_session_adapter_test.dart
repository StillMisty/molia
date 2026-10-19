import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/data/sync/adapters/session_sync_adapter.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/playback_session_sync.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/sync_test_support.dart';
import 'support/settings_test_support.dart';

/// 上次播放会话适配器：版本戳登记、远端应用/删除、本地清空检出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late SyncStateStore state;
  late PlaybackSessionStore store;
  late PlaybackSessionCoordinator coordinator;
  late SessionSyncAdapter adapter;
  var now = 5000;
  var changedCount = 0;

  PlaybackSession session({int index = 0, int positionMs = 42000}) =>
      PlaybackSession(
        tracks: [
          Track(
            id: const TrackId('fake', 'a'),
            title: 'Title a',
            artists: const [Artist(name: 'Artist a')],
            duration: const Duration(seconds: 60),
            origin: TrackOrigin.lx,
            payload: const {'id': 'a'},
          ),
        ],
        index: index,
        position: Duration(milliseconds: positionMs),
        mode: PlayMode.shuffle,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = 5000;
    changedCount = 0;
    state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
    store = PlaybackSessionStore(
      preferences: prefs,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    // 生产接线：同步适配器只拿到会话端口（协调者），远端写入与本地落盘
    // 共用同一个写队列；这里的 store 只是同一队列的种子 / 断言入口。
    coordinator = PlaybackSessionCoordinator(
      settings: testSettingsRegistry(),
      facade: DefaultPlaybackFacade(backend: FakePlaybackBackend()),
      store: store,
    );
    addTearDown(coordinator.dispose);
    adapter = SessionSyncAdapter(
      port: coordinator,
      state: state,
      onChanged: () async => changedCount++,
    );
  });

  test('本地会话导出：savedAt 是内容时间，版本戳来自发号器', () async {
    await store.save(session());
    final collected = await adapter.collect();
    final record = collected[SyncCategory.session]!.single;
    expect(record.deleted, isFalse);
    expect(record.version.physical, 5000);
    expect(record.version.deviceId, 'devA');
    expect(record.data!['savedAt'], 5000);
    expect(record.data!['positionMs'], 42000);
    expect(record.data!['mode'], 'shuffle');
    expect((record.data!['tracks'] as List), hasLength(1));
  });

  test('本地写入刷新后重新取戳；未变化时保持原戳', () async {
    await store.save(session());
    await adapter.collect();

    now = 9000;
    await store.save(session(positionMs: 60000));
    final refreshed = await adapter.collect();
    expect(refreshed[SyncCategory.session]!.single.version.physical, 9000);

    final stable = await adapter.collect();
    expect(stable[SyncCategory.session]!.single.version.physical, 9000);
  });

  test('应用远端会话：写入存储、更新登记、触发回调；重复应用幂等', () async {
    await adapter.collect();
    final remote = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {
        'savedAt': 20000,
        'index': 0,
        'positionMs': 12345,
        'mode': 'sequential',
        'tracks': [
          {
            'sourceKey': 'fake',
            'id': 'b',
            'title': 'Remote Song',
            'artists': [
              {'name': 'Remote Artist'},
            ],
            'origin': 'lx',
            'payload': {'id': 'b'},
          },
        ],
      },
    );
    final result = await adapter.apply({
      SyncCategory.session: [remote],
    });
    expect(result.applied, 1);
    expect(changedCount, 1);
    final loaded = await store.load();
    expect(loaded!.current!.title, 'Remote Song');
    expect(loaded.position, const Duration(milliseconds: 12345));

    final again = await adapter.apply({
      SyncCategory.session: [remote],
    });
    expect(again.applied, 0);
    expect(again.skipped, 1);
    expect(changedCount, 1);
  });

  test('旧记录被跳过：本地更新的会话胜出', () async {
    now = 30000;
    await store.save(session());
    await adapter.collect();

    final stale = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 10000, deviceId: 'devB'),
      data: {'savedAt': 10000, 'positionMs': 1},
    );
    final result = await adapter.apply({
      SyncCategory.session: [stale],
    });
    expect(result.applied, 0);
    final loaded = await store.load();
    expect(loaded!.position, const Duration(milliseconds: 42000));
  });

  test('本地清空（停止播放）不回传删除：不产生记录，远端旧会话也不复活', () async {
    await store.save(session());
    await adapter.collect();

    now = 40000;
    await store.clear();
    final collected = await adapter.collect();
    expect(collected[SyncCategory.session], isNull);

    // 与本地登记同戳的旧会话不会把已清空的会话填回来。
    final sameStamp = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 5000, deviceId: 'devA'),
      data: {'savedAt': 5000, 'positionMs': 1},
    );
    final result = await adapter.apply({
      SyncCategory.session: [sameStamp],
    });
    expect(result.applied, 0);
    expect(await store.load(), isNull);
  });

  test('远端删除会话：清空存储并撤下恢复态回调', () async {
    await store.save(session());
    await adapter.collect();

    final result = await adapter.apply({
      SyncCategory.session: [
        SyncRecord.tombstone(
          key: SyncRecordKeys.sessionKey,
          version: const SyncVersion(physical: 60000, deviceId: 'devB'),
        ),
      ],
    });
    expect(result.applied, 1);
    expect(await store.load(), isNull);
    expect(changedCount, 1);
  });

  test('会话里的本地下载曲目导出时过滤，并按删除数校正下标', () async {
    await store.save(PlaybackSession(
      tracks: [
        Track(
          id: const TrackId('wy', '1'),
          title: '在线曲目',
          origin: TrackOrigin.builtin,
          payload: const {'songId': '1'},
        ),
        Track(
          id: const TrackId('local', 'wy:9'),
          title: '本地下载',
          origin: TrackOrigin.localFile,
          payload: const {'path': '/data/a.mp3', 'songId': 'wy:9'},
        ),
        Track(
          id: const TrackId('wy', '2'),
          title: '在线曲目 2',
          origin: TrackOrigin.builtin,
          payload: const {'songId': '2'},
        ),
      ],
      index: 2,
    ));

    final collected = await adapter.collect();
    final data = collected[SyncCategory.session]!.single.data!;
    final tracks = (data['tracks'] as List).cast<Map>();
    expect(tracks.map((track) => track['sourceKey']), ['wy', 'wy']);
    // 被移除的本地曲目在当前曲目之前：下标前移一位。
    expect(data['index'], 1);
  });

  test('会话里全是本地曲目：不回传同步记录', () async {
    await store.save(PlaybackSession(
      tracks: [
        Track(
          id: const TrackId('local', 'wy:9'),
          title: '本地下载',
          origin: TrackOrigin.localFile,
          payload: const {'path': '/data/a.mp3', 'songId': 'wy:9'},
        ),
      ],
      index: 0,
    ));

    final collected = await adapter.collect();
    expect(collected, isEmpty);
  });

  test('远端应用/删除只经注入的会话端口，不直连具体存储', () async {
    final port = _RecordingSessionPort();
    var changes = 0;
    final isolated = SessionSyncAdapter(
      port: port,
      state: state,
      onChanged: () async => changes++,
    );

    // 收集读端口。
    await isolated.collect();
    expect(port.calls, ['loadRaw']);

    final remote = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {
        kPlaybackSessionSavedAtKey: 20000,
        'index': 0,
        'positionMs': 12345,
        'mode': 'sequential',
        'tracks': [
          {
            'sourceKey': 'fake',
            'id': 'b',
            'title': 'Remote Song',
            'origin': 'lx',
            'payload': {'id': 'b'},
          },
        ],
      },
    );
    await isolated.apply({
      SyncCategory.session: [remote],
    });
    expect(port.calls, ['loadRaw', 'applyRemote']);
    expect(port.raw?[kPlaybackSessionSavedAtKey], 20000);
    expect(port.raw, isNot(same(remote.data)));

    // 远端删除同样只走端口；具体 store 没有被适配器碰过。
    await isolated.apply({
      SyncCategory.session: [
        SyncRecord.tombstone(
          key: SyncRecordKeys.sessionKey,
          version: const SyncVersion(physical: 30000, deviceId: 'devB'),
        ),
      ],
    });
    expect(port.calls, ['loadRaw', 'applyRemote', 'clearRemote']);
    expect(port.raw, isNull);
    expect(await store.loadRaw(), isNull);
    expect(changes, 2);
  });
}

/// 记录调用面的假会话端口：证明适配器只依赖端口，不依赖具体 store。
class _RecordingSessionPort implements PlaybackSessionSyncPort {
  final List<String> calls = [];
  Map<String, dynamic>? raw;

  @override
  Future<Map<String, dynamic>?> loadRaw() async {
    calls.add('loadRaw');
    final value = raw;
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> applyRemote(Map<String, dynamic> value) async {
    calls.add('applyRemote');
    // 复制一份：适配器后续不应依赖调用方持有的 map。
    raw = Map<String, dynamic>.from(value);
  }

  @override
  Future<void> clearRemote() async {
    calls.add('clearRemote');
    raw = null;
  }
}
