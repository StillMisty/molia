import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/services/download/download_journal.dart';
import 'package:molia/services/download/download_record_store.dart';
import 'package:molia/services/download/download_records.dart';

import 'support/fake_download_storage.dart';
import 'support/memory_database.dart';

/// 下载记录写入：drift 行 / 内存记录 / 提交日志 marker 的同一顺序。
void main() {
  late MoliaDatabase db;
  late DownloadsRepository repository;
  late FakeDownloadStorage storage;
  late DownloadRecords records;
  late DownloadJournal journal;
  late DownloadRecordStore store;

  DownloadedTrack makeRecord({
    String sourceKey = 'kw',
    String songId = '1',
    String title = '测试歌曲',
    String? filePath = '/downloads/测试歌曲.mp3',
    int downloadedAt = 1000,
  }) => DownloadedTrack(
    originSourceKey: sourceKey,
    originSongId: songId,
    title: title,
    filePath: filePath,
    sizeBytes: 4,
    quality: '320k',
    raw: const {'songmid': '1'},
    downloadedAt: downloadedAt,
  );

  setUp(() {
    db = openMemoryDatabase();
    repository = DownloadsRepository(databaseProvider: () => db);
    storage = FakeDownloadStorage();
    records = DownloadRecords();
    journal = DownloadJournal(storage);
    store = DownloadRecordStore(
      repository: repository,
      journal: journal,
      records: records,
    );
  });

  tearDown(() async {
    records.dispose();
    await repository.dispose();
    await db.close();
  });

  test('save 同时写仓库与内存记录', () async {
    final record = makeRecord();

    await store.save(record);

    expect(identical(store.records, records), isTrue);
    expect(store.records.recordFor('kw', '1')?.title, '测试歌曲');
    final stored = await repository.findByOrigin('kw', '1');
    expect(stored, isNotNull);
    expect(stored!.filePath, '/downloads/测试歌曲.mp3');
    expect(stored.raw, const {'songmid': '1'});
  });

  test('save(clearJournal: true) 落库后删除 marker', () async {
    final record = makeRecord();
    expect(await store.markPending(record), isTrue);
    expect(await store.pending(), hasLength(1));

    await store.save(record, clearJournal: true);

    expect(store.records.recordFor('kw', '1'), isNotNull);
    expect(await journal.readAll(), isEmpty);
  });

  test('deleteRecord 删库行、内存记录与残留 marker', () async {
    final record = makeRecord();
    await store.save(record);
    expect(await store.markPending(record), isTrue);
    expect(await journal.readAll(), hasLength(1));

    await store.deleteRecord(record);

    expect(store.records.recordFor('kw', '1'), isNull);
    expect(await repository.findByOrigin('kw', '1'), isNull);
    expect(await journal.readAll(), isEmpty);
    expect(
      storage.files.keys.where((path) => path.startsWith('/download_journal/')),
      isEmpty,
    );
  });

  test('load 用仓库全表替换内存记录', () async {
    await repository.insert(makeRecord(songId: '9', title: '已有下载'));
    expect(store.records.recordFor('kw', '1'), isNull);

    // 预置一条不在库里的旧记录：load 后必须被整体替换掉。
    store.records.put(makeRecord(songId: 'stale', title: '过期'));
    await store.load();

    expect(store.records.recordFor('kw', '9')?.title, '已有下载');
    expect(store.records.recordFor('kw', 'stale'), isNull);
    expect(store.records.downloads, hasLength(1));
  });

  test('markPending / pending / removePending 往返', () async {
    final record = makeRecord(songId: 'pending', title: '待恢复');

    expect(await store.markPending(record), isTrue);
    final entries = await store.pending();
    expect(entries, hasLength(1));
    expect(entries.single.record.key, 'kw:pending');
    expect(entries.single.record.title, '待恢复');
    expect(entries.single.markerPath, isNotEmpty);

    await store.removePending(entries.single.markerPath);
    expect(await store.pending(), isEmpty);
  });

  test('removePendingByKey 只按记录键清 marker', () async {
    final record = makeRecord(songId: 'failed');
    expect(await store.markPending(record), isTrue);

    await store.removePendingByKey(record.key);

    expect(await store.pending(), isEmpty);
  });
}
