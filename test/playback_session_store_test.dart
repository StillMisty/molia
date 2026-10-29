/// 播放会话存储：主库 payload / cursor 两表、动作落盘、旧 prefs 清理。
///
/// 关键断言：
/// - 队列实例未变时只写 cursor 单行，payload 行内容与时间都不动；
/// - 队列 / 模式 / 上下文变化时 payload + cursor 同一事务写入；
/// - 远端应用与本地保存共用同一个 `pendingWrite` 队列；
/// - 旧 prefs 三个键首次读取时删除且不导入内容。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/playback_session_repository.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 仅测试用：模拟平台 remove 返回 false（不是 lib 的依赖）。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/memory_database.dart';

/// 可拒绝删除旧会话键的平台实现：验证 false 不被当作成功永久缓存。
class _RejectingRemovePrefsStore extends InMemorySharedPreferencesStore {
  _RejectingRemovePrefsStore(super.data) : super.withData();

  bool reject = true;
  final List<String> rejected = [];

  @override
  Future<bool> remove(String key) async {
    if (reject && key.contains('playback_session')) {
      rejected.add(key);
      return false;
    }
    return super.remove(key);
  }
}

/// 记录写入口径并可暂停 saveAll 的仓库（验证串行队列）。
class _GatedRepository extends PlaybackSessionRepository {
  _GatedRepository(MoliaDatabase db) : super(database: () => db);

  final List<String> writes = [];
  Completer<void>? gate;

  @override
  Future<void> saveAll({
    required Map<String, dynamic> payload,
    required int savedAt,
    required int index,
    required int positionMs,
  }) async {
    writes.add('saveAll');
    final pending = gate;
    if (pending != null) await pending.future;
    return super.saveAll(
      payload: payload,
      savedAt: savedAt,
      index: index,
      positionMs: positionMs,
    );
  }

  @override
  Future<void> saveCursor({
    required int index,
    required int positionMs,
    required int savedAt,
  }) {
    writes.add('cursor');
    return super.saveCursor(
      index: index,
      positionMs: positionMs,
      savedAt: savedAt,
    );
  }

  @override
  Future<void> clear() {
    writes.add('clear');
    return super.clear();
  }
}

Track _track(String id) => Track(
  id: TrackId('fake', id),
  title: 'Title $id',
  artists: [Artist(name: 'Artist $id')],
  origin: TrackOrigin.lx,
  payload: {'songmid': 'mid_$id'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late _GatedRepository repository;
  var clockMs = 1000;

  setUp(() {
    db = openMemoryDatabase();
    repository = _GatedRepository(db);
    clockMs = 1000;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
  });

  PlaybackSessionStore store() => PlaybackSessionStore(
    repository: repository,
    clock: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
  );

  Future<PlaybackSessionPayload?> payloadRow() => (db.select(
    db.playbackSessionPayloads,
  )..where((row) => row.id.equals(playbackSessionRowId))).getSingleOrNull();

  Future<PlaybackSessionCursor?> cursorRow() => (db.select(
    db.playbackSessionCursors,
  )..where((row) => row.id.equals(playbackSessionRowId))).getSingleOrNull();

  test('往返：队列 / 下标 / 进度 / 模式 / 上下文 / raw payload 原样', () async {
    final value = store();
    var saved = 0;
    value.onSaved = () => saved++;

    await value.save(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 42),
        mode: PlayMode.shuffle,
        context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
      ),
    );

    final loaded = await value.load();
    expect(loaded, isNotNull);
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);
    expect(loaded.position, const Duration(seconds: 42));
    expect(loaded.mode, PlayMode.shuffle);
    expect(loaded.context?.name, '收藏');
    expect(loaded.tracks.first.payload['songmid'], 'mid_a');
    expect(saved, 1);
    expect((await payloadRow())!.updatedAt, 1000);
    expect((await cursorRow())!.savedAt, 1000);
  });

  test('新实例 load 后恢复缓存：第一次暂停 / seek 只写 cursor', () async {
    final writer = store();
    final session = PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 3),
      mode: PlayMode.shuffle,
      context: const PlaybackContext(name: 'ctx', type: 'lx', uri: 'lx:ctx'),
    );
    await writer.save(session);
    final payloadBefore = await payloadRow();

    // 模拟冷启动：新 store 实例从库里读回同一份 payload。
    final restored = store();
    final loaded = await restored.load();
    expect(loaded, isNotNull);
    final payloadAfterLoad = await payloadRow();
    expect(payloadAfterLoad!.updatedAt, payloadBefore!.updatedAt);
    expect(payloadAfterLoad.json, payloadBefore.json);

    // 恢复后第一次动作：队列 / 模式 / 上下文都没变，只改下标 / 进度。
    repository.writes.clear();
    clockMs = 2000;
    await restored.save(loaded!.copyWith(
      index: 1,
      position: const Duration(seconds: 9),
    ));

    expect(repository.writes, ['cursor'],
        reason: '同一份 payload 不应因恢复后的第一次动作重写');
    final payloadAfterSave = await payloadRow();
    expect(payloadAfterSave!.updatedAt, payloadBefore.updatedAt);
    expect(payloadAfterSave.json, payloadBefore.json);
    expect((await cursorRow())!.cursorIndex, 1);
    expect((await cursorRow())!.positionMs, 9000);
  });

  test('同队列切歌 / 暂停：只写 cursor，payload 行不变', () async {
    final value = store();
    final tracks = [_track('a'), _track('b')];
    await value.save(
      PlaybackSession(
        tracks: tracks,
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    final firstPayload = await payloadRow();
    repository.writes.clear();
    clockMs = 2000;

    await value.save(
      PlaybackSession(
        tracks: tracks,
        index: 1,
        position: const Duration(seconds: 2),
      ),
    );

    expect(repository.writes, ['cursor']);
    final payload = await payloadRow();
    expect(payload!.json, firstPayload!.json);
    expect(payload.updatedAt, 1000);
    expect((await cursorRow())!.cursorIndex, 1);
    expect((await cursorRow())!.positionMs, 2000);
    expect((await value.loadRaw())!['index'], 1);
    expect((await value.loadRaw())!['positionMs'], 2000);
  });

  test('队列 / 模式 / 上下文变化：payload + cursor 一起写', () async {
    final value = store();
    await value.save(PlaybackSession(tracks: [_track('a')], index: 0));
    repository.writes.clear();
    clockMs = 3000;

    final next = [_track('a'), _track('b')];
    await value.save(
      PlaybackSession(tracks: next, index: 1, mode: PlayMode.shuffle),
    );
    expect(repository.writes, ['saveAll', 'cursor']);
    final payload = await payloadRow();
    expect(payload!.updatedAt, 3000);
    expect((await cursorRow())!.cursorIndex, 1);
    final loaded = await value.load();
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);
    expect(loaded.mode, PlayMode.shuffle);

    // 同一列表实例只改模式：模式在 payload 里，必须重写。
    repository.writes.clear();
    await value.save(
      PlaybackSession(tracks: next, index: 1, mode: PlayMode.sequential),
    );
    expect(repository.writes, ['saveAll', 'cursor']);
    expect((await value.load())!.mode, PlayMode.sequential);
  });

  test('savedAt 合并：旧 cursor 不覆盖新 payload，新 cursor 覆盖下标进度', () async {
    await repository.saveAll(
      payload: {
        'index': 0,
        'positionMs': 1000,
        PlaybackSessionStore.savedAtKey: 5000,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'a', 'title': 'A', 'origin': 'lx'},
        ],
      },
      savedAt: 5000,
      index: 0,
      positionMs: 1000,
    );
    await repository.saveCursor(index: 1, positionMs: 9000, savedAt: 4000);
    var raw = await store().loadRaw();
    expect(raw!['index'], 0, reason: '旧 cursor 不属于这份 payload');
    expect(raw['positionMs'], 1000);
    expect(raw[PlaybackSessionStore.savedAtKey], 5000);

    await repository.saveCursor(index: 1, positionMs: 9000, savedAt: 6000);
    raw = await store().loadRaw();
    expect(raw!['index'], 1);
    expect(raw['positionMs'], 9000);
    expect(raw[PlaybackSessionStore.savedAtKey], 6000);
  });

  test('saveRaw 远端应用：payload + cursor 写入，本地保存保守重写', () async {
    final value = store();
    final localTracks = [_track('a')];
    await value.save(PlaybackSession(tracks: localTracks, index: 0));

    await value.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 1,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {
          'sourceKey': 'fake',
          'id': 'remote-a',
          'title': '远端 A',
          'origin': 'lx',
        },
        {
          'sourceKey': 'fake',
          'id': 'remote-b',
          'title': '远端 B',
          'origin': 'lx',
        },
      ],
    });
    final applied = await value.load();
    expect(applied!.index, 1);
    expect(applied.current!.id.id, 'remote-b');
    expect(applied.position, const Duration(seconds: 7));

    repository.writes.clear();
    await value.save(PlaybackSession(tracks: localTracks, index: 0));
    expect(repository.writes, ['saveAll', 'cursor']);
    expect((await value.load())!.current!.id.id, 'a');
  });

  test('savePosition 只更新 cursor 进度，不碰 payload / savedAt', () async {
    final value = store();
    await value.save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    repository.writes.clear();
    final payload = await payloadRow();

    await value.savePosition(8000);
    expect(repository.writes, isEmpty, reason: '进度更新直写仓库，不排队');
    expect((await cursorRow())!.positionMs, 8000);
    expect((await cursorRow())!.savedAt, 1000);
    expect((await payloadRow())!.json, payload!.json);
  });

  test('clear：删两行并清理旧 prefs 会话键', () async {
    SharedPreferences.setMockInitialValues({
      'playback_session_v1': '{"tracks":[{"id":"old"}]}',
      'playback_session_state_v1': '{"index":1}',
      'playback_session_position_v1': 1234,
      'keep_setting': true,
    });
    final value = store();
    await value.save(PlaybackSession(tracks: [_track('a')], index: 0));
    expect(await payloadRow(), isNotNull);
    expect(await cursorRow(), isNotNull);

    await value.clear();
    expect(await payloadRow(), isNull);
    expect(await cursorRow(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('playback_session_v1'), isFalse);
    expect(prefs.containsKey('playback_session_state_v1'), isFalse);
    expect(prefs.containsKey('playback_session_position_v1'), isFalse);
    expect(prefs.getBool('keep_setting'), isTrue);
  });

  test('旧 prefs 会话不导入：首次读取只删除，不返回旧队列', () async {
    SharedPreferences.setMockInitialValues({
      'playback_session_v1': '{"savedAt":1,"tracks":[{"sourceKey":"fake","id":"old","title":"Old"}]}',
      'playback_session_position_v1': 5000,
    });
    final value = store();

    expect(await value.load(), isNull);
    expect(await value.loadRaw(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('playback_session_v1'), isFalse);
    expect(prefs.containsKey('playback_session_position_v1'), isFalse);
  });

  test('旧 prefs 删除被平台拒绝：不缓存成功，下次读取重试', () async {
    final platform = _RejectingRemovePrefsStore({
      'flutter.playback_session_v1': '{"tracks":[{"id":"old"}]}',
      'flutter.playback_session_position_v1': 1234,
    });
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = platform;
    final value = store();

    expect(await value.loadRaw(), isNull);
    expect(platform.rejected, isNotEmpty);
    final firstRejects = platform.rejected.length;

    // 平台恢复后再次读取：清理重试成功。
    platform.reject = false;
    expect(await value.loadRaw(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('playback_session_v1'), isFalse);
    expect(prefs.containsKey('playback_session_position_v1'), isFalse);
    expect(platform.rejected.length, firstRejects,
        reason: '恢复后不应再被拒绝');
  });

  test('远端应用排在在途本地保存之后：同一个 pendingWrite 队列', () async {
    final value = store();
    final gate = Completer<void>();
    repository.gate = gate;

    final local = value.save(
      PlaybackSession(
        tracks: [_track('local')],
        index: 0,
        position: const Duration(seconds: 1),
      ),
    );
    await pumpEventQueue();
    expect(repository.writes, ['saveAll']);

    final remote = value.saveRaw({
      PlaybackSessionStore.savedAtKey: 9000,
      'index': 0,
      'positionMs': 7000,
      'tracks': [
        {'sourceKey': 'fake', 'id': 'remote', 'title': '远端', 'origin': 'lx'},
      ],
    });
    await pumpEventQueue();
    expect(repository.writes, ['saveAll'], reason: '远端写入还没开始');

    repository.gate = null;
    gate.complete();
    await Future.wait([local, remote]);
    expect(repository.writes, ['saveAll', 'cursor', 'saveAll', 'cursor']);
    final raw = await value.loadRaw();
    expect(raw![PlaybackSessionStore.savedAtKey], 9000);
    expect((raw['tracks'] as List).single['id'], 'remote');
  });
}
