/// 下载任务产物写入器：sidecar 路径、登记先于写入、收尾隔离与分项失败语义。
///
/// 依赖全部是假端口（活跃输出 / 记录读写 / 标签补写）+ 真
/// `DownloadFileLayout` 与内存 `FakeDownloadStorage`：不构造
/// `DownloadService`，也不需要 drift / 取链 / 曲目解析。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_file_layout.dart';
import 'package:molia/services/download/download_task_artifacts.dart';

import '../support/fake_download_storage.dart';

void main() {
  late _RecordingOutputs outputs;
  late _FakeArtifactRecords records;
  late _ObservingStorage storage;
  late List<Track> embeddedTracks;
  late List<String> writes;
  late List<Set<String>> registryAtWrite;
  late DownloadTaskArtifacts artifacts;

  Track makeTrack({String sourceKey = 'kw', String songId = '1'}) => Track(
    id: TrackId(sourceKey, songId),
    title: '测试歌曲',
    artists: const [Artist(name: '歌手')],
    album: '专辑',
    origin: TrackOrigin.builtin,
  );

  DownloadTaskArtifacts makeArtifacts() => DownloadTaskArtifacts(
    outputs: outputs,
    layout: DownloadFileLayout(storage: storage),
    records: records,
    embedTags: (track) async => embeddedTracks.add(track),
  );

  setUp(() {
    outputs = _RecordingOutputs();
    records = _FakeArtifactRecords();
    embeddedTracks = [];
    writes = [];
    registryAtWrite = [];
    storage = _ObservingStorage((path) {
      writes.add(path);
      registryAtWrite.add(outputs.paths);
    });
    artifacts = makeArtifacts();
  });

  test('歌词：主文件与翻译边车先登记再写', () async {
    const lyricPath = '/downloads/lyrics/歌手 - 测试歌曲.lrc';
    const translationPath = '/downloads/lyrics/歌手 - 测试歌曲.t.lrc';

    final path = await artifacts.writeLyrics(
      root: '/downloads',
      base: '歌手 - 测试歌曲',
      lyrics: const DownloadLyrics(
        lyric: '[00:01]原文',
        translation: '[00:01]译文',
      ),
    );

    expect(path, lyricPath);
    expect(writes, [lyricPath, translationPath]);
    expect(
      registryAtWrite,
      everyElement(containsAll([lyricPath, translationPath])),
      reason: '两条期望路径都必须在写第一笔前登记',
    );
    expect(await storage.readString(lyricPath), '[00:01]原文');
    expect(await storage.readString(translationPath), '[00:01]译文');
  });

  test('封面：扩展名按 URL 推断，期望路径先登记再写', () async {
    const coverPath = '/downloads/covers/歌手 - 测试歌曲.png';
    final cover = DownloadResolvedCover(
      bytes: Uint8List.fromList([9, 8]),
      url: 'https://img.example.com/cover.png',
      mimeType: 'image/png',
    );

    final path = await artifacts.writeCover(
      root: '/downloads',
      base: '歌手 - 测试歌曲',
      cover: cover,
    );

    expect(path, coverPath);
    expect(writes, [coverPath]);
    expect(registryAtWrite.single, contains(coverPath));
    expect(storage.files[coverPath], [9, 8]);
  });

  test('封面：自定义 WebP 无 URL 时按 MIME 落 .webp，不写成 .jpg', () async {
    const coverPath = '/downloads/covers/自定义.webp';
    final cover = DownloadResolvedCover(
      bytes: Uint8List.fromList([0x52, 0x49, 0x46, 0x46]),
      url: null,
      mimeType: 'image/webp',
    );

    final path = await artifacts.writeCover(
      root: '/downloads',
      base: '自定义',
      cover: cover,
    );

    expect(path, coverPath);
    expect(registryAtWrite.single, contains(coverPath));
    expect(storage.files[coverPath], cover.bytes);
  });

  test('close：只撤销本任务登记的输出，别的任务不受影响', () {
    const otherTaskPath = '/downloads/other-task.mp3';
    outputs.add(otherTaskPath);
    final first = makeArtifacts();
    final second = makeArtifacts();
    first.register('/downloads/a.mp3');
    first.register('/downloads/a.mp3.part');
    first.register(null);
    first.register('');
    second.register('/downloads/lyrics/b.lrc');

    first.close();

    expect(outputs.paths, {otherTaskPath, '/downloads/lyrics/b.lrc'});
    expect(outputs.removals.single, {
      '/downloads/a.mp3',
      '/downloads/a.mp3.part',
    });

    second.close();
    expect(outputs.paths, {otherTaskPath});
  });

  test('独立歌词：基名跟随已有音频，写成功后分项落库并补标签', () async {
    final track = makeTrack();
    records.records['kw:1'] = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: '1',
      title: '测试歌曲',
      filePath: '/downloads/歌手 - 测试歌曲.mp3',
      downloadedAt: 1,
    );

    await artifacts.saveLyricsPart(
      track,
      root: '/downloads',
      lyrics: const DownloadLyrics(lyric: '[00:01]词'),
    );

    expect(writes, ['/downloads/lyrics/歌手 - 测试歌曲.lrc']);
    expect(records.upserts.single.lyricPath, writes.single);
    expect(records.upserts.single.coverPath, isNull);
    expect(embeddedTracks, [track]);
  });

  test('独立封面：无音频时复用已有封面基名，写成功后分项落库并补标签', () async {
    final track = makeTrack(sourceKey: 'tx', songId: '2');
    records.records['tx:2'] = DownloadedTrack(
      originSourceKey: 'tx',
      originSongId: '2',
      title: '测试歌曲',
      coverPath: '/downloads/covers/旧封面.jpg',
      downloadedAt: 1,
    );
    final cover = DownloadResolvedCover(
      bytes: Uint8List.fromList([7, 7]),
      url: 'https://img.example.com/new.png',
      mimeType: 'image/png',
    );

    await artifacts.saveCoverPart(track, root: '/downloads', cover: cover);

    expect(writes, ['/downloads/covers/旧封面.png']);
    expect(records.upserts.single.coverPath, writes.single);
    expect(records.upserts.single.lyricPath, isNull);
    expect(embeddedTracks, [track]);
  });

  test('独立分项写失败：抛 downloadFailed，不落库也不补标签', () async {
    final track = makeTrack();
    storage.failWrites = true;

    await expectLater(
      artifacts.saveLyricsPart(
        track,
        root: '/downloads',
        lyrics: const DownloadLyrics(lyric: '[00:01]词'),
      ),
      throwsA(
        predicate(
          (e) =>
              e is SourceFailure &&
              e.kind == FailureKind.unknown &&
              e.l10nKey == 'downloadFailed',
        ),
      ),
    );
    await expectLater(
      artifacts.saveCoverPart(
        track,
        root: '/downloads',
        cover: DownloadResolvedCover(
          bytes: Uint8List.fromList([7]),
          url: null,
          mimeType: 'image/jpeg',
        ),
      ),
      throwsA(
        predicate(
          (e) =>
              e is SourceFailure &&
              e.kind == FailureKind.unknown &&
              e.l10nKey == 'downloadFailed',
        ),
      ),
    );

    expect(records.upserts, isEmpty);
    expect(embeddedTracks, isEmpty);
  });

  test('活跃输出集合：add / removeAll 维护只读快照', () {
    final active = DownloadActiveOutputs();
    active.add('/downloads/a.mp3');
    active.add('/downloads/b.lrc');
    final snapshot = active.paths;

    active.add('/downloads/c.jpg');
    expect(snapshot, {'/downloads/a.mp3', '/downloads/b.lrc'});

    active.removeAll(['/downloads/a.mp3']);
    expect(active.paths, {'/downloads/b.lrc', '/downloads/c.jpg'});
  });
}

/// 活跃输出端口的假件：保留路径集合并记录每次撤销的批次。
class _RecordingOutputs implements DownloadOutputRegistry {
  final Set<String> paths = <String>{};
  final List<Set<String>> removals = [];

  @override
  void add(String path) => paths.add(path);

  @override
  void removeAll(Iterable<String> paths) {
    final batch = paths.toSet();
    removals.add(batch);
    this.paths.removeAll(batch);
  }
}

/// 记录端口的假件：按曲目键查记录，记录分项 upsert。
class _FakeArtifactRecords implements DownloadArtifactRecords {
  final Map<String, DownloadedTrack> records = {};
  final List<({Track track, String? lyricPath, String? coverPath})> upserts =
      [];

  @override
  DownloadedTrack? recordForTrack(Track track) =>
      records['${track.id.sourceKey}:${track.id.id}'];

  @override
  Future<void> upsertPart(
    Track track, {
    String? lyricPath,
    String? coverPath,
  }) async {
    upserts.add((track: track, lyricPath: lyricPath, coverPath: coverPath));
  }
}

/// 内存存储 + 写入观测：回调在真正落盘前触发，用来断言登记时机。
class _ObservingStorage extends FakeDownloadStorage {
  _ObservingStorage(this.onWrite);

  final void Function(String path) onWrite;
  bool failWrites = false;

  Future<void> _beforeWrite(String path) async {
    onWrite(path);
    if (failWrites) throw StateError('write failed');
  }

  @override
  Future<void> writeString(String path, String content) async {
    await _beforeWrite(path);
    await super.writeString(path, content);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    await _beforeWrite(path);
    await super.writeBytes(path, bytes);
  }
}
