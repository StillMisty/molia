import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/audio_title_editor.dart';
import 'package:molia/data/local_title_store.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/local/local_metadata_service.dart';
import 'package:molia/services/playback_session_store.dart';

import '../support/fake_download_storage.dart';
import '../support/fakes.dart';
import '../support/memory_database.dart';

/// 标题编辑：标签 + 一处数据库事务 + app-only 回退。
void main() {
  late dynamic db;
  late FakeDownloadStorage storage;
  late DownloadedTrack record;
  late DownloadRecords records;
  late LocalMetadataService service;

  const path = '/music/song.mp3';
  const localKey = 'file:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

  Uint8List id3WithTitle(String title) {
    final body = <int>[
      ...'TIT2'.codeUnits,
      0,
      0,
      0,
      1 + title.length,
      0,
      0,
      1,
      ...title.codeUnits,
    ];
    return Uint8List.fromList([
      0x49,
      0x44,
      0x33,
      3,
      0,
      0,
      (body.length >> 21) & 0x7F,
      (body.length >> 14) & 0x7F,
      (body.length >> 7) & 0x7F,
      body.length & 0x7F,
      ...body,
      0xFF,
      0xFB,
      0x90,
      0x00,
    ]);
  }

  setUp(() async {
    db = openMemoryDatabase();
    storage = FakeDownloadStorage();
    storage.files[path] = id3WithTitle('old');
    storage.directories.add('/music');
    record = const DownloadedTrack(
      originSourceKey: kLocalSourceKey,
      originSongId: localKey,
      title: 'old',
      artist: 'artist',
      album: 'album',
      filePath: path,
      sizeBytes: 10,
      imported: true,
      localKey: localKey,
      downloadedAt: 1,
    );
    records = DownloadRecords(
      records: [record],
      initialized: true,
      supported: true,
    );
    await db.customStatement(
      'INSERT INTO playlists (id, name, createdAt) VALUES (1, ?, 1)',
      ['收藏'],
    );
    await db.customStatement(
      'INSERT INTO downloads (originSourceKey, originSongId, title, filePath, '
      'sizeBytes, imported, localKey, downloadedAt) VALUES '
      "('local', ?, 'old', ?, 10, 1, ?, 1)",
      [localKey, path, localKey],
    );
    await db.customStatement(
      'INSERT INTO playlist_tracks (playlistId, sourceKey, songId, title, raw, '
      'addedAt, sortOrder, versionPhysical, versionCounter, deviceId) VALUES '
      "(1, 'local', ?, 'old', '{}', 1, 0, 0, 0, '')",
      [localKey],
    );
    await db.customStatement(
      'INSERT INTO play_history (sourceKey, songId, title, raw, playedAt, '
      'versionPhysical, versionCounter, deviceId) VALUES '
      "('local', ?, 'old', '{}', 1, 0, 0, '')",
      [localKey],
    );
    // 同一 songId 的在线行：标题不能跟着本地行变。
    await db.customStatement(
      "INSERT INTO play_history (sourceKey, songId, title, raw, playedAt, "
      "versionPhysical, versionCounter, deviceId) VALUES "
      "('wy', ?, 'online', '{}', 1, 0, 0, '')",
      [localKey],
    );
    await db.customStatement(
      'INSERT INTO play_tracks (sourceKey, songId, title, updatedAt) VALUES '
      "('local', ?, 'stats snapshot', 1)",
      [localKey],
    );
    await db.customStatement(
      'INSERT INTO playback_session_payloads (id, json, updatedAt) VALUES '
      '(1, ?, 1)',
      [
        jsonEncode({
          'v': 1,
          'index': 0,
          'positionMs': 5000,
          'savedAt': 7,
          'tracks': [
            {'sourceKey': 'local', 'id': localKey, 'title': 'old'},
            {'sourceKey': 'wy', 'id': localKey, 'title': 'online'},
          ],
        }),
      ],
    );
    await db.customStatement(
      'INSERT INTO playback_session_cursors (id, cursorIndex, positionMs, '
      'savedAt) VALUES (1, 0, 5000, 7)',
    );
    service = LocalMetadataService(
      storage: storage,
      store: LocalTitleStore(database: () => db),
      records: records,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('导入改标题：文件标签 + 下载行 / 列表 / 历史 / 会话；在线行与统计不变', () async {
    expect(
      await service.editTitle(record, '  新标题  '),
      LocalTitleEditStatus.written,
    );
    final written = Uint8List.fromList(storage.files[path]!);
    expect(debugReadTitle(written, extension: '.mp3'), '新标题');
    expect(records.recordFor(kLocalSourceKey, localKey)!.title, '新标题');

    final download = await db
        .customSelect('SELECT * FROM downloads')
        .getSingle();
    expect(download.data['title'], '新标题');
    final playlist = await db
        .customSelect('SELECT * FROM playlist_tracks')
        .getSingle();
    expect(playlist.data['title'], '新标题');
    final history = await db
        .customSelect('SELECT * FROM play_history ORDER BY sourceKey')
        .get();
    expect(history.map((row) => row.data['title']), ['新标题', 'online']);
    final stats = await db
        .customSelect('SELECT * FROM play_tracks')
        .getSingle();
    expect(stats.data['title'], 'stats snapshot', reason: '统计是历史快照');
    final session = await db
        .customSelect('SELECT * FROM playback_session_payloads WHERE id = 1')
        .getSingle();
    final sessionMap = jsonDecode(session.data['json'] as String) as Map;
    expect((sessionMap['tracks'] as List)[0]['title'], '新标题');
    expect((sessionMap['tracks'] as List)[1]['title'], 'online');
    expect(sessionMap['index'], 0);
    expect(sessionMap['positionMs'], 5000);
    expect(sessionMap['savedAt'], 7);
  });

  test('不支持标签的格式：先返回 app-only；选择后只改数据库，文件不变', () async {
    storage.files['/music/song.m4a'] = [1, 2, 3, 4];
    final m4a = record.copyWith(filePath: '/music/song.m4a', sizeBytes: 4);
    expect(
      await service.editTitle(m4a, '新标题'),
      LocalTitleEditStatus.appOnlyRequired,
    );
    expect(storage.files['/music/song.m4a'], [1, 2, 3, 4]);
    expect(
      await service.editTitle(m4a, '新标题', appOnly: true),
      LocalTitleEditStatus.written,
    );
    expect(storage.files['/music/song.m4a'], [1, 2, 3, 4]);
    final download = await db
        .customSelect('SELECT * FROM downloads')
        .getSingle();
    expect(download.data['title'], '新标题');
  });

  test('文件不见：直接 app-only；非法标题拒绝', () async {
    final missing = record.copyWith(filePath: '/music/gone.mp3');
    expect(
      await service.editTitle(missing, '新标题'),
      LocalTitleEditStatus.appOnlyRequired,
    );
    expect(
      await service.editTitle(record, '  '),
      LocalTitleEditStatus.invalidTitle,
    );
    expect(
      await service.editTitle(record, 'a\nb'),
      LocalTitleEditStatus.invalidTitle,
    );
  });

  test('提交成功后回调一次（播放快照刷新入口）', () async {
    final committed = <String>[];
    final service = LocalMetadataService(
      storage: storage,
      store: LocalTitleStore(database: () => db),
      records: records,
      onCommitted: (record) => committed.add(record.title),
    );
    expect(
      await service.editTitle(record, '新标题'),
      LocalTitleEditStatus.written,
    );
    expect(committed, ['新标题']);
  });

  test('下载副本：按原音源键更新本地行，不碰在线原曲', () async {
    const copy = DownloadedTrack(
      originSourceKey: 'wy',
      originSongId: '123',
      title: 'copy',
      filePath: '/downloads/123.mp3',
      sizeBytes: 4,
      downloadedAt: 1,
    );
    storage.files['/downloads/123.mp3'] = id3WithTitle('copy');
    await db.customStatement(
      "INSERT INTO downloads (originSourceKey, originSongId, title, filePath, "
      "sizeBytes, imported, downloadedAt) VALUES ('wy', '123', 'copy', ?, 4, 0, 1)",
      ['/downloads/123.mp3'],
    );
    await db.customStatement(
      "INSERT INTO playlist_tracks (playlistId, sourceKey, songId, title, raw, "
      "addedAt, sortOrder, versionPhysical, versionCounter, deviceId) VALUES "
      "(1, 'local', 'wy:123', 'copy', '{}', 1, 0, 0, 0, '')",
    );
    await db.customStatement(
      "INSERT INTO play_history (sourceKey, songId, title, raw, playedAt, "
      "versionPhysical, versionCounter, deviceId) VALUES "
      "('wy', '123', 'online original', '{}', 1, 0, 0, '')",
    );
    records.put(copy);
    expect(
      await service.editTitle(copy, '下载副本新标题'),
      LocalTitleEditStatus.written,
    );
    final download = await db
        .customSelect("SELECT * FROM downloads WHERE originSourceKey = 'wy'")
        .getSingle();
    expect(download.data['title'], '下载副本新标题');
    final localRow = await db
        .customSelect(
          "SELECT * FROM playlist_tracks WHERE sourceKey = 'local' "
          "AND songId = 'wy:123'",
        )
        .getSingle();
    expect(localRow.data['title'], '下载副本新标题');
    final onlineRow = await db
        .customSelect(
          "SELECT * FROM play_history WHERE sourceKey = 'wy' "
          "AND songId = '123'",
        )
        .getSingle();
    expect(onlineRow.data['title'], 'online original');
  });

  test('组合根接线：提交后同步刷新恢复态当前曲目标题', () async {
    final store = testSessionStore();
    final facade = FakePlaybackFacade();
    final coordinator = buildTestSessionCoordinator(
      facade: facade,
      sessionStore: store,
    );
    addTearDown(coordinator.dispose);
    await store.save(PlaybackSession(tracks: [record.localTrack!], index: 0));
    expect(await coordinator.load(), isTrue);
    expect(coordinator.displaySnapshot.current?.title, 'old');

    final wired = LocalMetadataService(
      storage: storage,
      store: LocalTitleStore(database: () => db),
      records: records,
      awaitSessionWrites: () => store.pendingWrite,
      onCommitted: (updated) {
        final track = updated.localTrack;
        if (track != null) coordinator.updateTrackMetadata(track);
      },
    );
    expect(await wired.editTitle(record, '新标题'), LocalTitleEditStatus.written);
    await Future<void>.delayed(Duration.zero);
    await store.pendingWrite;
    expect(coordinator.displaySnapshot.current?.title, '新标题');
  });
}
