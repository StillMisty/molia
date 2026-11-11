import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/adapters/session_sync_adapter.dart';
import 'package:molia/data/sync/sync_journal.dart';
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
  late _RecordingJournal journal;
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
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    // 生产接线：同步适配器只拿到会话端口（协调者），远端写入与本地落盘
    // 共用同一个写队列；这里的 store 只是同一队列的种子 / 断言入口。
    coordinator = PlaybackSessionCoordinator(
      settings: testSettingsRegistry(),
      facade: FakePlaybackFacade(),
      store: store,
    );
    addTearDown(coordinator.dispose);
    journal = _RecordingJournal();
    adapter = SessionSyncAdapter(
      port: coordinator,
      state: state,
      journal: journal,
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

  test('本机保存：同队列立即追加游标，60 秒窗口内不重复', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'b'},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();
    expect(journal.changes, isEmpty);

    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );
    await adapter.noteLocalSave();
    expect(journal.changes, hasLength(1));
    final immediate = journal.changes.single.record.data!;
    expect(immediate['kind'], 'sessionCursor');
    expect(immediate.containsKey('tracks'), isFalse);
    expect(immediate['index'], 1);
    expect(immediate['savedAt'], 9000);

    now = 9000 + 59999;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 3),
      ),
    );
    await adapter.noteLocalSave();
    expect(journal.changes, hasLength(1), reason: '窗口内保存不重复追加');

    now = 9000 + 60000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 4),
      ),
    );
    await adapter.noteLocalSave();
    expect(journal.changes, hasLength(2), reason: '窗口外的保存重新追加');
    expect(journal.changes.last.record.data?['kind'], 'sessionCursor');
  });

  test('本机保存：没有整份底稿时首次保存仍追加整份队列', () async {
    await store.save(session());
    await adapter.collect();

    // 模拟进程重启：登记还在，但进程内的「已发整份」缓存为空。
    final restartedJournal = _RecordingJournal();
    final restarted = SessionSyncAdapter(
      port: coordinator,
      state: state,
      journal: restartedJournal,
    );
    now = 9000;
    await store.save(session(positionMs: 60000));
    await restarted.noteLocalSave();

    expect(restartedJournal.changes, hasLength(1));
    final data = restartedJournal.changes.single.record.data!;
    expect(data['kind'], isNull);
    expect(data['tracks'], hasLength(1));
  });

  test('fresh 收集：整份记录不再重复写日志，后续同队列变更仍走游标', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'b'},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();
    expect(journal.changes, isEmpty, reason: '首次登记不追加日志');

    // 同队列只改游标：正常情况下会追加一条游标增量。
    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );

    // fresh 直接返回整份记录，不再额外写一条 MB 级日志。
    final fresh = await adapter.collect(fresh: true);
    final freshData = fresh[SyncCategory.session]!.single.data!;
    expect(freshData['kind'], isNull);
    expect(freshData['tracks'], hasLength(2));
    expect(journal.changes, isEmpty, reason: '全量快照已携带 tracks');

    // fresh 之后同队列的新变更仍由普通收集追加游标增量。
    now = 10000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 3),
      ),
    );
    final nonFresh = await adapter.collect();
    expect(
      nonFresh[SyncCategory.session]!.single.data?['kind'],
      'sessionCursor',
    );
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.data?['kind'], 'sessionCursor');
  });

  test('同队列仅切歌：只上行游标增量，不重复整份队列', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: {'id': 'a', 'blob': 'x' * 4096},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: {'id': 'b', 'blob': 'y' * 4096},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    final first = await adapter.collect();
    final full = prefs.getString('playback_session_v1');
    final fullData = first[SyncCategory.session]!.single.data!;
    expect(fullData['tracks'], hasLength(2));
    expect(journal.changes, isEmpty, reason: '首次登记不是变更，不追加日志');

    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );
    // 整份 JSON 没有重写（同一队列列表）：savedAt / 下标来自游标键，仍要上行。
    expect(prefs.getString('playback_session_v1'), full);

    final collected = await adapter.collect();
    final data = collected[SyncCategory.session]!.single.data!;
    expect(data['kind'], 'sessionCursor');
    expect(data['v'], 1);
    expect(data.containsKey('tracks'), isFalse);
    expect(data['queueHash'], isA<String>());
    expect(data['index'], 1);
    expect(data['savedAt'], 9000);
    expect(data['positionMs'], 2000);

    expect(journal.changes, hasLength(1));
    final appended = journal.changes.single.record.data!;
    expect(appended['kind'], 'sessionCursor');
    expect(appended.containsKey('tracks'), isFalse);
    // 游标增量远小于整份队列（测试数据每首 4KB payload）。
    expect(jsonEncode(appended).length, lessThan(1024));
    expect(jsonEncode(fullData).length, greaterThan(8 * 1024));
  });

  test('队列内容变化：重新外发整份会话', () async {
    await store.save(session());
    await adapter.collect();

    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: [
          Track(
            id: const TrackId('fake', 'b'),
            title: 'Title b',
            artists: const [Artist(name: 'Artist b')],
            origin: TrackOrigin.lx,
            payload: const {'id': 'b'},
          ),
        ],
        index: 0,
        position: const Duration(seconds: 2),
      ),
    );

    final collected = await adapter.collect();
    final data = collected[SyncCategory.session]!.single.data!;
    expect(data['kind'], isNull);
    expect(data['tracks'], hasLength(1));
    expect((data['tracks'] as List).single['id'], 'b');
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.data?['tracks'], hasLength(1));
  });

  test('fresh 收集：队列未变也返回含 tracks 的整份记录', () async {
    await store.save(session());
    await adapter.collect();

    final fresh = await adapter.collect(fresh: true);
    final freshData = fresh[SyncCategory.session]!.single.data!;
    expect(freshData['kind'], isNull, reason: '全量快照不能带游标增量');
    expect(freshData['tracks'], hasLength(1));

    // fresh 之后仍记得整份底稿：同队列的下一轮增量继续用游标。
    now = 9000;
    await store.save(session(positionMs: 60000));
    final nonFresh = await adapter.collect();
    expect(
      nonFresh[SyncCategory.session]!.single.data?['kind'],
      'sessionCursor',
    );
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

  test('应用游标增量：队列一致时只合并游标字段，tracks 不动', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'b'},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();

    // 先让本机产生一次同队列游标，拿到发送端会写到记录里的队列哈希。
    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 2),
      ),
    );
    final localCursor =
        (await adapter.collect())[SyncCategory.session]!.single.data!;

    final remote = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {
        'kind': 'sessionCursor',
        'v': 1,
        'queueHash': localCursor['queueHash'],
        'savedAt': 20000,
        'index': 1,
        'positionMs': 12345,
        'mode': 'sequential',
        'context': {'name': 'Remote', 'type': 'playlist', 'uri': 'uri:1'},
      },
    );
    final result = await adapter.apply({
      SyncCategory.session: [remote],
    });
    expect(result.applied, 1);
    expect(changedCount, 1);

    final loaded = await store.load();
    expect(loaded!.tracks, hasLength(2), reason: '游标记录不带 tracks');
    expect(loaded.current!.id, const TrackId('fake', 'b'));
    expect(loaded.position, const Duration(milliseconds: 12345));
    expect(loaded.mode, PlayMode.sequential);
    expect(loaded.context?.name, 'Remote');
  });

  test('应用游标增量：本地下载曲目存在时把过滤后下标映射回原队列', () async {
    final onlineA = Track(
      id: const TrackId('fake', 'a'),
      title: 'Title a',
      artists: const [Artist(name: 'Artist a')],
      origin: TrackOrigin.lx,
      payload: const {'id': 'a'},
    );
    final local = Track(
      id: const TrackId('local', 'wy:9'),
      title: '本地下载',
      origin: TrackOrigin.localFile,
      payload: const {'path': '/data/a.mp3', 'songId': 'wy:9'},
    );
    final onlineB = Track(
      id: const TrackId('fake', 'b'),
      title: 'Title b',
      artists: const [Artist(name: 'Artist b')],
      origin: TrackOrigin.lx,
      payload: const {'id': 'b'},
    );
    final tracks = [onlineA, local, onlineB];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();

    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 2,
        position: const Duration(seconds: 2),
      ),
    );
    final cursor =
        (await adapter.collect())[SyncCategory.session]!.single.data!;
    expect(cursor['index'], 1, reason: '过滤本地曲目后的下标');

    final remote = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {...cursor, 'savedAt': 20000, 'index': 1, 'positionMs': 12345},
    );
    final result = await adapter.apply({
      SyncCategory.session: [remote],
    });

    expect(result.applied, 1);
    final loaded = await store.load();
    expect(loaded!.tracks, hasLength(3), reason: '本地曲目仍保留');
    expect(loaded.current!.id, onlineB.id, reason: '映射回本地原始下标 2');
    expect(loaded.position, const Duration(milliseconds: 12345));
  });

  test('应用游标增量：本地缺失或队列哈希不一致时跳过', () async {
    // 本地没有会话：游标没有可合并的底稿。
    final missing = await adapter.apply({
      SyncCategory.session: [
        SyncRecord(
          key: SyncRecordKeys.sessionKey,
          version: const SyncVersion(physical: 20000, deviceId: 'devB'),
          data: {
            'kind': 'sessionCursor',
            'v': 1,
            'queueHash': 'unknown',
            'savedAt': 20000,
            'index': 0,
            'positionMs': 1,
            'mode': 'shuffle',
            'context': null,
          },
        ),
      ],
    });
    expect(missing.applied, 0);
    expect(missing.skipped, 1);
    expect(await store.load(), isNull);
    expect(changedCount, 0);

    // 本地队列已变：发送方的游标对应另一份队列，不能套用。
    await store.save(session());
    await adapter.collect();
    now = 9000;
    await store.save(session(positionMs: 60000));
    final cursorData =
        (await adapter.collect())[SyncCategory.session]!.single.data!;

    now = 10000;
    await store.save(
      PlaybackSession(
        tracks: [
          Track(
            id: const TrackId('fake', 'b'),
            title: 'Title b',
            artists: const [Artist(name: 'Artist b')],
            origin: TrackOrigin.lx,
            payload: const {'id': 'b'},
          ),
        ],
        index: 0,
        position: const Duration(seconds: 3),
      ),
    );
    final before = await store.loadRaw();

    final mismatched = await adapter.apply({
      SyncCategory.session: [
        SyncRecord(
          key: SyncRecordKeys.sessionKey,
          version: const SyncVersion(physical: 30000, deviceId: 'devB'),
          data: {
            ...cursorData,
            'savedAt': 30000,
            'index': 0,
            'positionMs': 999,
          },
        ),
      ],
    });
    expect(mismatched.applied, 0);
    expect(mismatched.skipped, 1);
    expect(jsonEncode(await store.loadRaw()), jsonEncode(before));
    final loaded = await store.load();
    expect(loaded!.current!.id, const TrackId('fake', 'b'));
    expect(loaded.position, const Duration(seconds: 3));
  });

  test('同一批记录：版本更大的游标胜过旧整份', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'b'},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();
    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );
    final cursorData =
        (await adapter.collect())[SyncCategory.session]!.single.data!;

    final full = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 10000, deviceId: 'devB'),
      data: {
        'savedAt': 10000,
        'index': 0,
        'positionMs': 1,
        'mode': 'listLoop',
        'tracks': [
          {
            'sourceKey': 'fake',
            'id': 'remote',
            'title': 'Remote Song',
            'origin': 'lx',
            'payload': {'id': 'remote'},
          },
        ],
      },
    );
    final cursor = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {
        ...cursorData,
        'savedAt': 20000,
        'index': 0,
        'positionMs': 12345,
        'mode': 'sequential',
      },
    );

    final result = await adapter.apply({
      SyncCategory.session: [full, cursor],
    });
    expect(result.applied, 1);
    final loaded = await store.load();
    expect(loaded!.tracks, hasLength(2), reason: '整份没有被应用');
    expect(loaded.current!.id, const TrackId('fake', 'a'));
    expect(loaded.position, const Duration(milliseconds: 12345));
    expect(loaded.mode, PlayMode.sequential);
  });

  test('同一批记录：游标在前、旧整份在后仍由更大版本胜出', () async {
    final tracks = [
      Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      Track(
        id: const TrackId('fake', 'b'),
        title: 'Title b',
        artists: const [Artist(name: 'Artist b')],
        origin: TrackOrigin.lx,
        payload: const {'id': 'b'},
      ),
    ];
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await adapter.collect();
    now = 9000;
    await store.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );
    final cursorData =
        (await adapter.collect())[SyncCategory.session]!.single.data!;

    final cursor = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {
        ...cursorData,
        'savedAt': 20000,
        'index': 0,
        'positionMs': 12345,
        'mode': 'sequential',
      },
    );
    final full = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 10000, deviceId: 'devB'),
      data: {
        'savedAt': 10000,
        'index': 0,
        'positionMs': 1,
        'mode': 'listLoop',
        'tracks': [
          {
            'sourceKey': 'fake',
            'id': 'remote',
            'title': 'Remote Song',
            'origin': 'lx',
            'payload': {'id': 'remote'},
          },
        ],
      },
    );

    final result = await adapter.apply({
      SyncCategory.session: [cursor, full],
    });
    expect(result.applied, 1);
    final loaded = await store.load();
    expect(loaded!.tracks, hasLength(2), reason: '旧整份没有覆盖当前队列');
    expect(loaded.current!.id, const TrackId('fake', 'a'));
    expect(loaded.position, const Duration(milliseconds: 12345));
    expect(loaded.mode, PlayMode.sequential);
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
    await store.save(
      PlaybackSession(
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
      ),
    );

    final collected = await adapter.collect();
    final data = collected[SyncCategory.session]!.single.data!;
    final tracks = (data['tracks'] as List).cast<Map>();
    expect(tracks.map((track) => track['sourceKey']), ['wy', 'wy']);
    // 被移除的本地曲目在当前曲目之前：下标前移一位。
    expect(data['index'], 1);
  });

  test('会话里全是本地曲目：不回传同步记录', () async {
    await store.save(
      PlaybackSession(
        tracks: [
          Track(
            id: const TrackId('local', 'wy:9'),
            title: '本地下载',
            origin: TrackOrigin.localFile,
            payload: const {'path': '/data/a.mp3', 'songId': 'wy:9'},
          ),
        ],
        index: 0,
      ),
    );

    final collected = await adapter.collect();
    expect(collected, isEmpty);
  });

  test('没有 savedAt 的会话：本机不外发、远端记录跳过', () async {
    final port = _RecordingSessionPort()
      ..raw = {
        'index': 0,
        'positionMs': 1,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'a', 'title': 'Title a', 'origin': 'lx'},
        ],
      };
    final isolated = SessionSyncAdapter(port: port, state: state);

    expect(await isolated.collect(), isEmpty, reason: '旧会话缺 savedAt 不上行');
    expect(state.sessionStamp, isNull, reason: '不登记没有 savedAt 的会话');
    expect(port.calls, ['loadRaw']);

    final remote = SyncRecord(
      key: SyncRecordKeys.sessionKey,
      version: const SyncVersion(physical: 20000, deviceId: 'devB'),
      data: {'index': 0, 'positionMs': 1},
    );
    final result = await isolated.apply({
      SyncCategory.session: [remote],
    });
    expect(result.applied, 0);
    expect(result.skipped, 1);
    expect(port.calls, ['loadRaw'], reason: '缺 savedAt 的远端会话不写入');
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

/// 记录追加载荷的日志替身：用来断言会话写的是整份还是游标增量。
class _RecordingJournal implements SyncJournalAppender {
  final List<SyncJournalChange> changes = [];

  @override
  Future<List<int>> appendAll(Iterable<SyncJournalChange> changes) async {
    final list = changes.toList();
    final start = this.changes.length;
    this.changes.addAll(list);
    return [for (var i = 0; i < list.length; i++) start + i + 1];
  }
}
