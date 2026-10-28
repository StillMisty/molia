import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/services/download/download_journal.dart';

import '../support/fake_download_storage.dart';

/// 下载提交日志：原子写 / 读取 / 清理 / 不可用降级。
void main() {
  DownloadedTrack record({String keyId = '1'}) => DownloadedTrack(
    originSourceKey: 'kw',
    originSongId: keyId,
    title: '恢复歌曲 $keyId',
    artist: '歌手',
    album: '专辑',
    coverUrl: 'https://img.example.com/cover.jpg',
    durationMs: 180000,
    raw: {
      'songmid': keyId,
      'nested': {
        'list': [1, 2, 3],
      },
    },
    quality: '320k',
    filePath: '/downloads/恢复歌曲 $keyId.mp3',
    sizeBytes: 1234,
    lyricPath: '/downloads/lyrics/恢复歌曲 $keyId.lrc',
    coverPath: '/downloads/covers/恢复歌曲 $keyId.jpg',
    publicUri: 'content://media/external/downloads/$keyId',
    imported: false,
    downloadedAt: 1700000000000,
  );

  test('write / readAll / remove：全部字段往返，md5 文件名', () async {
    final storage = FakeDownloadStorage();
    final journal = DownloadJournal(storage);
    final source = record();

    expect(await journal.write(source), isTrue);
    final entries = await journal.readAll();
    expect(entries, hasLength(1));
    final restored = entries.single.record;
    expect(restored.key, source.key);
    expect(restored.title, source.title);
    expect(restored.artist, source.artist);
    expect(restored.album, source.album);
    expect(restored.coverUrl, source.coverUrl);
    expect(restored.durationMs, source.durationMs);
    expect(restored.raw, source.raw);
    expect(restored.quality, source.quality);
    expect(restored.filePath, source.filePath);
    expect(restored.sizeBytes, source.sizeBytes);
    expect(restored.lyricPath, source.lyricPath);
    expect(restored.coverPath, source.coverPath);
    expect(restored.publicUri, source.publicUri);
    expect(restored.imported, isFalse);
    expect(restored.downloadedAt, source.downloadedAt);
    final markerName = '${crypto.md5.convert(utf8.encode(source.key))}.json';
    expect(entries.single.markerPath, endsWith(markerName));
    expect(entries.single.markerPath, startsWith('/download_journal/'));

    await journal.remove(source.key);
    expect(await journal.readAll(), isEmpty);
    expect(storage.files, isEmpty);
  });

  test('损坏 JSON 与 tmp 清理 / removePath', () async {
    final storage = FakeDownloadStorage();
    final journal = DownloadJournal(storage);
    final source = record();

    await journal.write(source);
    final marker = (await journal.readAll()).single.markerPath;
    storage.files[marker] = utf8.encode('{not json');
    storage.files['$marker.tmp'] = [1];

    expect(await journal.readAll(), isEmpty);
    expect(storage.files.containsKey(marker), isFalse);
    expect(storage.files.containsKey('$marker.tmp'), isFalse);

    await journal.write(source);
    final validMarker = (await journal.readAll()).single.markerPath;
    await journal.removePath(validMarker);
    expect(await journal.readAll(), isEmpty);
  });

  test('journalRoot 不可用：write / read / remove 全部安全 no-op', () async {
    final storage = FakeDownloadStorage(journalRootPath: null);
    final journal = DownloadJournal(storage);

    expect(await journal.write(record()), isFalse);
    expect(await journal.readAll(), isEmpty);
    await journal.remove('kw:1');
    await journal.removePath('/download_journal/missing.json');
    expect(storage.files, isEmpty);
  });

  test('重复写同一 key 只保留最新内容且无 tmp 残留', () async {
    final storage = FakeDownloadStorage();
    final journal = DownloadJournal(storage);
    final first = record();
    final second = DownloadedTrack(
      originSourceKey: first.originSourceKey,
      originSongId: first.originSongId,
      title: '新标题',
      filePath: first.filePath,
      sizeBytes: 1,
      downloadedAt: 1,
    );

    expect(await journal.write(first), isTrue);
    expect(await journal.write(second), isTrue);
    final entries = await journal.readAll();
    expect(entries, hasLength(1));
    expect(entries.single.record.title, '新标题');
    expect(storage.files.keys.where((path) => path.endsWith('.tmp')), isEmpty);
  });
}
