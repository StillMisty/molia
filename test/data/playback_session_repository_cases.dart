/// 播放会话仓库：单行 upsert、payload / cursor 分离、事务回滚。
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/playback_session_repository.dart';

import '../support/memory_database.dart';

void main() {
  late MoliaDatabase db;
  late PlaybackSessionRepository repository;

  setUp(() {
    db = openMemoryDatabase();
    repository = PlaybackSessionRepository(database: () => db);
  });

  tearDown(() => db.close());

  test('saveAll：payload 与 cursor 同一事务落盘，loadRaw 合并', () async {
    await repository.saveAll(
      payload: {
        'index': 0,
        'positionMs': 1000,
        'savedAt': 1000,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'a', 'title': 'A', 'origin': 'lx'},
        ],
      },
      savedAt: 1000,
      index: 0,
      positionMs: 1000,
    );

    final raw = await repository.loadRaw();
    expect(raw!['index'], 0);
    expect(raw['positionMs'], 1000);
    expect(raw['savedAt'], 1000);

    await repository.saveCursor(index: 1, positionMs: 9000, savedAt: 2000);
    final merged = await repository.loadRaw();
    expect(merged!['index'], 1);
    expect(merged['positionMs'], 9000);
    expect(merged['savedAt'], 2000);

    // 两表都只有一行（单行 upsert）。
    expect(await db.select(db.playbackSessionPayloads).get(), hasLength(1));
    expect(await db.select(db.playbackSessionCursors).get(), hasLength(1));
  });

  test('saveAll 中途序列化失败：事务回滚，旧 payload / cursor 不变', () async {
    await repository.saveAll(
      payload: {
        'index': 0,
        'savedAt': 1,
        'tracks': [
          {'sourceKey': 'fake', 'id': 'old', 'title': 'Old', 'origin': 'lx'},
        ],
      },
      savedAt: 1,
      index: 0,
      positionMs: 1000,
    );
    final beforePayload = await db
        .select(db.playbackSessionPayloads)
        .getSingle();
    final beforeCursor = await db.select(db.playbackSessionCursors).getSingle();

    expect(
      () => repository.saveAll(
        payload: {
          'index': 1,
          'savedAt': 2,
          // jsonEncode 无法序列化对象：payload 写入抛错，cursor 不应落盘。
          'tracks': <Object>[Object()],
        },
        savedAt: 2,
        index: 1,
        positionMs: 2000,
      ),
      throwsA(anything),
    );

    final afterPayload = await db
        .select(db.playbackSessionPayloads)
        .getSingle();
    final afterCursor = await db.select(db.playbackSessionCursors).getSingle();
    expect(afterPayload.json, beforePayload.json);
    expect(afterPayload.updatedAt, beforePayload.updatedAt);
    expect(afterCursor.cursorIndex, beforeCursor.cursorIndex);
    expect(afterCursor.positionMs, beforeCursor.positionMs);
    expect(afterCursor.savedAt, beforeCursor.savedAt);
  });

  test('updatePosition 不创建游标；存在时只改进度', () async {
    await repository.updatePosition(5000);
    expect(await db.select(db.playbackSessionCursors).get(), isEmpty);

    await repository.saveCursor(index: 2, positionMs: 1000, savedAt: 100);
    await repository.updatePosition(6000);
    final cursor = await db.select(db.playbackSessionCursors).getSingle();
    expect(cursor.cursorIndex, 2);
    expect(cursor.positionMs, 6000);
    expect(cursor.savedAt, 100);
  });

  test('clear 删除两行（幂等）', () async {
    await repository.saveAll(
      payload: const {'tracks': <Object>[]},
      savedAt: 1,
      index: 0,
      positionMs: 0,
    );
    await repository.clear();
    await repository.clear();
    expect(await repository.loadRaw(), isNull);
    expect(await db.select(db.playbackSessionPayloads).get(), isEmpty);
    expect(await db.select(db.playbackSessionCursors).get(), isEmpty);
  });

  test('payload 损坏：按无会话处理，不抛给上层', () async {
    await db
        .into(db.playbackSessionPayloads)
        .insert(
          PlaybackSessionPayloadsCompanion.insert(
            id: const Value(1),
            json: '{not json',
            updatedAt: 1,
          ),
        );
    expect(await repository.loadRaw(), isNull);
  });
}
