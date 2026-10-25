/// 下载记录装配模块：四种形态（完整下载 / 分项更新 / 本地导入 / 补发布）的
/// 字段映射与合并语义钉死。
///
/// 只经公开意图方法断言 `DownloadedTrack` 的字段结果；时钟注入
/// （`downloadedAt` 是内容时间，记录既有时间不被重新取值）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_record_assembler.dart';

void main() {
  late DownloadRecordAssembler assembler;

  setUp(() {
    assembler = DownloadRecordAssembler(clock: () => 1000);
  });

  Track makeTrack({
    String sourceKey = 'kw',
    String songId = '1',
    String title = '测试歌曲',
    String artist = '歌手',
  }) =>
      Track(
        id: TrackId(sourceKey, songId),
        title: title,
        artists: [Artist(name: artist)],
        album: '专辑',
        duration: const Duration(minutes: 3),
        artwork: Artwork(uri: Uri.parse('https://img.example.com/a.jpg')),
        origin: TrackOrigin.builtin,
        payload: {'songmid': songId},
      );

  DownloadedTrack makeExisting() => const DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: '1',
        title: '旧标题',
        artist: '旧歌手',
        album: '旧专辑',
        coverUrl: 'https://img.example.com/old.jpg',
        durationMs: 111,
        raw: {'songmid': 'old'},
        quality: '128k',
        filePath: '/downloads/旧标题.mp3',
        sizeBytes: 9,
        lyricPath: '/downloads/lyrics/旧标题.lrc',
        coverPath: '/downloads/covers/旧标题.jpg',
        publicUri: 'content://old',
        downloadedAt: 500,
      );

  test('完整下载：曲目快照 + 本次产物，下载时间走注入时钟', () {
    final track = makeTrack();
    final record = assembler.forAudioDownload(
      track: track,
      quality: '320k',
      filePath: '/downloads/歌手 - 测试歌曲.mp3',
      sizeBytes: 4,
    );

    expect(record.originSourceKey, 'kw');
    expect(record.originSongId, '1');
    expect(record.key, 'kw:1');
    expect(record.title, '测试歌曲');
    expect(record.artist, '歌手');
    expect(record.album, '专辑');
    expect(record.coverUrl, 'https://img.example.com/a.jpg');
    expect(record.durationMs, 180000);
    expect(record.raw, {'songmid': '1'});
    expect(identical(record.raw, track.payload), isFalse, reason: 'raw 是快照副本');
    expect(record.quality, '320k');
    expect(record.filePath, '/downloads/歌手 - 测试歌曲.mp3');
    expect(record.sizeBytes, 4);
    expect(record.lyricPath, isNull);
    expect(record.coverPath, isNull);
    expect(record.publicUri, isNull);
    expect(record.imported, isFalse);
    expect(record.downloadedAt, 1000);
  });

  test('完整下载：分项合并——本次产物优先，缺失回退上一条记录', () {
    final previous = makeExisting();

    // 本次未带分项：保留上一条记录的歌词 / 封面 / 公共副本。
    final merged = assembler.forAudioDownload(
      track: makeTrack(),
      quality: '320k',
      filePath: '/downloads/A.mp3',
      sizeBytes: 2,
      previous: previous,
    );
    expect(merged.lyricPath, '/downloads/lyrics/旧标题.lrc');
    expect(merged.coverPath, '/downloads/covers/旧标题.jpg');
    expect(merged.publicUri, 'content://old');

    // 本次产物覆盖上一条记录。
    final fresh = assembler.forAudioDownload(
      track: makeTrack(),
      quality: '320k',
      filePath: '/downloads/A.mp3',
      sizeBytes: 2,
      lyricPath: '/downloads/lyrics/A.lrc',
      coverPath: '/downloads/covers/A.jpg',
      publicUri: 'content://new',
      previous: previous,
    );
    expect(fresh.lyricPath, '/downloads/lyrics/A.lrc');
    expect(fresh.coverPath, '/downloads/covers/A.jpg');
    expect(fresh.publicUri, 'content://new');
  });

  test('分项更新：无旧记录 → 只有歌词的记录（可空音频）', () {
    final record = assembler.forPartialDownload(
      makeTrack(),
      lyricPath: '/downloads/lyrics/歌手 - 测试歌曲.lrc',
    );

    expect(record.hasAudio, isFalse);
    expect(record.hasLyrics, isTrue);
    expect(record.filePath, isNull);
    expect(record.quality, '');
    expect(record.sizeBytes, 0);
    expect(record.imported, isFalse);
    expect(record.publicUri, isNull);
    expect(record.raw, {'songmid': '1'});
    expect(record.downloadedAt, 1000);
  });

  test('分项更新：保留已有音频与另一分项，快照刷新但时间不重取', () {
    final existing = makeExisting();
    final record = assembler.forPartialDownload(
      makeTrack(title: '新标题', artist: '新歌手'),
      existing: existing,
      coverPath: '/downloads/covers/新标题.jpg',
    );

    // 曲目快照刷新（标题 / 歌手以曲目为准）。
    expect(record.title, '新标题');
    expect(record.artist, '新歌手');
    expect(record.album, '专辑');
    expect(record.raw, {'songmid': '1'});
    // 已有音频与元数据保留。
    expect(record.filePath, '/downloads/旧标题.mp3');
    expect(record.quality, '128k');
    expect(record.sizeBytes, 9);
    expect(record.publicUri, 'content://old');
    // 本次分项覆盖，另一分项保留。
    expect(record.coverPath, '/downloads/covers/新标题.jpg');
    expect(record.lyricPath, '/downloads/lyrics/旧标题.lrc');
    // 下载时间沿用记录既有值。
    expect(record.downloadedAt, 500);
  });

  test('本地导入：就地引用 + 只有文件元数据', () {
    final record = assembler.forLocalImport(
      filePath: '/music/a.mp3',
      sizeBytes: 12,
      title: 'A',
      artist: 'B',
      album: 'C',
      durationMs: 1000,
    );

    expect(record.originSourceKey, kLocalSourceKey);
    expect(record.originSongId, '/music/a.mp3');
    expect(record.key, 'local:/music/a.mp3');
    expect(record.imported, isTrue);
    expect(record.title, 'A');
    expect(record.artist, 'B');
    expect(record.album, 'C');
    expect(record.durationMs, 1000);
    expect(record.filePath, '/music/a.mp3');
    expect(record.sizeBytes, 12);
    expect(record.raw, isEmpty);
    expect(record.quality, '');
    expect(record.coverUrl, isNull);
    expect(record.lyricPath, isNull);
    expect(record.coverPath, isNull);
    expect(record.publicUri, isNull);
    expect(record.downloadedAt, 1000);
  });

  test('补发布：只补公共副本定位，其余字段原样保留', () {
    final record = makeExisting();
    final republished = assembler.republished(record, 'content://new');

    expect(republished.publicUri, 'content://new');
    expect(republished.hasPublicCopy, isTrue);
    expect(republished.filePath, record.filePath);
    expect(republished.lyricPath, record.lyricPath);
    expect(republished.coverPath, record.coverPath);
    expect(republished.quality, record.quality);
    expect(republished.sizeBytes, record.sizeBytes);
    expect(republished.downloadedAt, record.downloadedAt);
    expect(republished.raw, record.raw);
  });
}
