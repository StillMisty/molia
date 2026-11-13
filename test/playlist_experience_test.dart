import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playlist_folders.dart';
import 'package:molia/services/playlist/playlist_export_builder.dart';
import 'package:molia/services/playlist/playlist_file_codec.dart';
import 'package:molia/services/playlist/playlist_import_service.dart';
import 'package:molia/services/poster/playlist_poster_layout.dart';
import 'package:molia/services/poster/playlist_poster_renderer.dart';
import 'package:molia/theme/poster_palette.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('播放列表文件编解码', () {
    test('M3U8：BOM / CRLF / #PLAYLIST / EXTINF 逗号 / #MOLIA 绑定下一行', () {
      final text =
          '\uFEFF#EXTM3U\r\n'
          '#PLAYLIST:通勤, 早上\r\n'
          '#EXTINF:183,Artist, with comma - Song: one\r\n'
          '#MOLIA:wy:123\r\n'
          'https://music.163.com/#/song?id=123\r\n'
          '#EXTINF:-1,Only title\r\n'
          '/music/a b.mp3\r\n';
      final parsed = parsePlaylistFile(
        text,
        fileName: 'x.m3u8',
        baseDirectory: '/base',
      );
      expect(parsed.name, '通勤, 早上');
      expect(parsed.problems, isEmpty);
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].moliaKey, 'wy:123');
      expect(parsed.entries[0].title, 'Song: one');
      expect(parsed.entries[0].artist, 'Artist, with comma');
      expect(parsed.entries[0].durationMs, 183000);
      expect(parsed.entries[0].kind, PlaylistLocationKind.onlineUrl);
      expect(parsed.entries[1].kind, PlaylistLocationKind.localPath);
      expect(parsed.entries[1].location, '/music/a b.mp3');
      expect(parsed.entries[1].moliaKey, isNull);
    });

    test('本地路径：绝对 / file URI / 相对 / Windows 盘符', () {
      final parsed = parsePlaylistFile(
        '/abs/a.mp3\n'
        'file:///music/b.mp3\n'
        'sub/c.mp3\n'
        r'D:\Music\d.mp3',
        fileName: 'x.m3u',
        baseDirectory: '/base',
      );
      expect(parsed.entries[0].location, '/abs/a.mp3');
      expect(parsed.entries[1].location, '/music/b.mp3');
      expect(parsed.entries[2].location, '/base/sub/c.mp3');
      expect(parsed.entries[3].kind, PlaylistLocationKind.localPath);
      expect(parsed.entries[3].location, contains('d.mp3'));
    });

    test('molia:// 回退地址可解析回曲目键', () {
      final uri = moliaTrackUri('local:file:abc');
      final parsed = parsePlaylistFile(uri, fileName: 'x.m3u8');
      expect(parsed.entries.single.kind, PlaylistLocationKind.moliaUri);
      expect(parsed.entries.single.location, 'local:file:abc');
      expect(parseMoliaTrackUri('molia://track/not-base64%'), isNull);
    });

    test('PLS：稀疏编号 / Title / Length / Molia 扩展', () {
      final parsed = parsePlaylistFile(
        '[playlist]\nFile3=/a.mp3\nTitle3=A - B\nLength3=120\n'
        'File7=/b.mp3\nMolia7=kw:9\nNumberOfEntries=2\n',
        fileName: 'x.pls',
      );
      expect(parsed.name, isNull);
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].location, '/a.mp3');
      expect(parsed.entries[0].title, 'A - B');
      expect(parsed.entries[0].artist, 'A');
      expect(parsed.entries[0].durationMs, 120000);
      expect(parsed.entries[1].moliaKey, 'kw:9');
    });

    test('坏行与坏条目进入 problems，不抛异常、不静默丢', () {
      final parsed = parsePlaylistFile(
        '#MOLIA:badkey\n/a.mp3\n#EXTINF:12,Orphan\n',
        fileName: 'x.m3u',
      );
      expect(parsed.entries, hasLength(1));
      expect(parsed.problems, hasLength(2));
      expect(parsed.problems.first.kind, PlaylistFileProblemKind.malformedLine);
      expect(parsed.problems.last.kind, PlaylistFileProblemKind.malformedEntry);
    });

    test('M3U8 序列化：EXTINF / #MOLIA / 位置转义可往返', () {
      final text = encodeM3u8Playlist(
        name: 'A\nB',
        entries: const [
          PlaylistExportEntry(
            title: 'Title',
            artist: 'Artist',
            durationMs: 61000,
            moliaKey: 'wy:1',
            location: 'https://example.com/song/1',
          ),
          PlaylistExportEntry(
            title: '',
            artist: '',
            durationMs: null,
            location: '/tmp/line\nbreak.mp3',
          ),
        ],
      );
      expect(text, startsWith('#EXTM3U\n#PLAYLIST:A B\n'));
      expect(text, contains('#EXTINF:61,Artist - Title\n#MOLIA:wy:1\n'));
      expect(text, contains('#EXTINF:-1,\n'));
      expect(text, isNot(contains('line\nbreak')));
      final parsed = parsePlaylistFile(text, fileName: 'x.m3u8');
      expect(parsed.name, 'A B');
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries.first.moliaKey, 'wy:1');
    });
  });

  group('列表分组投影', () {
    PlaylistInfo p(int id, String name, {String folder = ''}) => PlaylistInfo(
      id: id,
      name: name,
      createdAt: id,
      folder: folder,
      syncId: 's$id',
    );

    test('命名分组在前、未分组最后，组内保持传入顺序', () {
      final groups = groupPlaylistsByFolder([
        p(1, 'a', folder: 'Work'),
        p(2, 'b'),
        p(3, 'c', folder: 'Commute'),
        p(4, 'd', folder: 'Work'),
      ]);
      expect(groups.map((g) => g.folder), ['Commute', 'Work', '']);
      expect(groups[1].playlists.map((x) => x.name), ['a', 'd']);
      expect(groups.last.isUngrouped, isTrue);
    });

    test('收藏可排除；分组名 trim 后比较，空分组不产生条目', () {
      final groups = groupPlaylistsByFolder(
        [p(1, 'f'), p(2, 'x', folder: '  Work  ')],
        excludePlaylistIds: {1},
      );
      expect(groups.single.folder, 'Work');
      expect(
        hasNamedPlaylistFolders([p(1, 'a'), p(2, 'b', folder: ' ')]),
        isFalse,
      );
    });

    test('封面键由 syncId 推导且命名空间稳定', () {
      expect(p(1, 'a').effectiveCoverKey, 'playlist:s1');
      expect(
        PlaylistInfo(id: 1, name: 'a', createdAt: 1).effectiveCoverKey,
        isNull,
      );
      expect(playlistCoverKeyForSyncId(''), isNull);
      expect(isPlaylistCoverKey('playlist:x'), isTrue);
    });
  });

  group('导入流水线', () {
    PlaylistTrack track(String source, String id, {String title = 'Song'}) =>
        PlaylistTrack(
          playlistId: 0,
          sourceKey: source,
          songId: id,
          title: title,
          addedAt: 1,
        );

    test('本机路径走导入端口；Molia 键走解析端口；普通 URL 未解析', () async {
      final importer = _FakeLocalImporter({
        '/music/a.mp3': track('local', 'file:a'),
      });
      final resolver = _FakeResolver({
        'wy:1': track('wy', '1'),
        'wy:2': track('wy', '2'),
      });
      final service = PlaylistImportService(
        localImporter: importer,
        resolver: resolver,
      );
      final plan = await service.plan(
        parsePlaylistFile(
          '/music/a.mp3\n#MOLIA:wy:1\nhttps://example.com/x\n'
          'https://example.com/no-key\n'
          '#MOLIA:wy:2\nfile:///music/b.mp3\n',
          fileName: 'x.m3u8',
        ),
        fallbackName: 'Fallback',
        addedAt: 1,
      );
      expect(plan.resolved.map((t) => t.key), ['local:file:a', 'wy:1', 'wy:2']);
      expect(plan.issues, hasLength(1));
      expect(plan.issues.single.reason, PlaylistImportIssueReason.onlineUrl);
      expect(resolver.lookups, ['wy:1', 'wy:2']);
      expect(plan.totalEntries, 4);
    });

    test('同名冲突命名确定；提交只建一个列表并批量加入', () async {
      final target = _FakeTarget(existing: ['Trip', 'Trip (2)']);
      final service = PlaylistImportService(
        localImporter: _FakeLocalImporter({}),
        resolver: _FakeResolver({}),
      );
      final plan = PlaylistImportPlan(
        name: 'Trip',
        resolved: [track('wy', '1'), track('wy', '2'), track('wy', '1')],
        issues: const [],
        totalEntries: 3,
      );
      final result = await service.commit(
        plan: plan,
        target: target,
        existingNames: target.existing,
      );
      expect(result.name, 'Trip (3)');
      expect(target.created, ['Trip (3)']);
      expect(target.addedBatches.single, hasLength(3));
      expect(result.added, 3);
    });

    test('全部未解析：不创建列表；批量失败删除新列表', () async {
      final target = _FakeTarget();
      final service = PlaylistImportService(
        localImporter: _FakeLocalImporter({}),
        resolver: _FakeResolver({}),
      );
      final empty = PlaylistImportPlan(
        name: 'x',
        resolved: const [],
        issues: const [
          PlaylistImportIssue(
            displayName: 'a',
            reason: PlaylistImportIssueReason.localUnavailable,
          ),
        ],
        totalEntries: 1,
      );
      await expectLater(
        service.commit(plan: empty, target: target),
        throwsStateError,
      );
      expect(target.created, isEmpty);

      target.failAdd = true;
      final plan = PlaylistImportPlan(
        name: 'x',
        resolved: [track('wy', '1')],
        issues: const [],
        totalEntries: 1,
      );
      await expectLater(
        service.commit(plan: plan, target: target),
        throwsStateError,
      );
      expect(target.created, ['x']);
      expect(target.deleted, ['x']);
    });
  });

  group('M3U8 导出构建', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('molia_export_');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    PlaylistTrack track(
      String source,
      String id, {
      String? cover,
      int? duration,
    }) => PlaylistTrack(
      playlistId: 1,
      sourceKey: source,
      songId: id,
      title: 'Title $id',
      artist: 'Artist',
      coverUrl: cover,
      durationMs: duration,
      addedAt: 1,
    );

    test('下载行写原在线键 + 绝对路径；无页面地址走 molia 回退', () async {
      final file = File('${temp.path}/a.mp3');
      await file.writeAsBytes([1]);
      final downloaded = DownloadedTrack(
        originSourceKey: 'wy',
        originSongId: '1',
        title: 'Downloaded',
        filePath: file.path,
        downloadedAt: 1,
      );
      final imported = DownloadedTrack(
        originSourceKey: kLocalSourceKey,
        originSongId: 'file:abc',
        title: 'Imported',
        filePath: file.path,
        imported: true,
        localKey: 'file:abc',
        downloadedAt: 1,
      );
      final export =
          await PlaylistExportBuilder(
            pageUrlOf: (track) => track.songId == '2'
                ? null
                : 'https://pages.example/${track.songId}',
            downloadedRecordOf: (track) => switch (track.key) {
              'wy:1' => downloaded,
              'local:file:abc' => imported,
              _ => null,
            },
            fileExists: (path) => File(path).exists(),
          ).buildM3u8(
            name: 'Trip',
            tracks: [
              track('wy', '1'),
              track('wy', '2'),
              track('local', 'file:abc'),
            ],
          );
      expect(export.text, contains('#MOLIA:wy:1\n${file.path}'));
      expect(export.text, contains('#MOLIA:wy:2\nmolia://track/'));
      expect(export.text, contains('#MOLIA:local:file:abc\n${file.path}'));
      expect(export.missingFiles, 0);
    });

    test('缺失文件仍写出并计入摘要', () async {
      final export = await PlaylistExportBuilder(
        pageUrlOf: (_) => null,
        downloadedRecordOf: (_) => null,
        fileExists: (_) async => false,
      ).buildM3u8(name: 'Trip', tracks: [track('local', 'file:missing')]);
      expect(export.text, contains('molia://track/'));
      expect(export.missingFiles, 1);
    });
  });

  group('列表分享布局与海报', () {
    PlaylistShareContent content({
      required int trackCount,
      int coverCount = 0,
    }) => PlaylistShareContent(
      name: 'My playlist',
      description: 'desc',
      trackCountLabel: '$trackCount 首',
      coverCount: coverCount,
      andMoreLabel: (count) => '还有 $count 首',
      tracks: [
        for (var index = 0; index < trackCount; index++)
          PlaylistShareTrack(title: 'T$index', artist: 'A$index'),
      ],
    );

    test('马赛克槽位：空槽中性、不重复封面', () {
      expect(content(trackCount: 0).mosaicSlotIndices, everyElement(isNull));
      expect(content(trackCount: 3, coverCount: 1).mosaicSlotIndices, [
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
      ]);
      final nine = content(trackCount: 9, coverCount: 9).mosaicSlotIndices;
      expect(nine, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      final more = content(trackCount: 9, coverCount: 20).mosaicSlotIndices;
      expect(more, hasLength(9));
      expect(more.last, 8);
    });

    test('前五首 / 还有 N 首 / 500 条文本上限', () {
      expect(content(trackCount: 7).posterTracks, hasLength(5));
      expect(content(trackCount: 7).posterExtraCount, 2);
      final text = content(trackCount: 509).toShareText();
      expect(text, contains('500. T499'));
      expect(text, isNot(contains('501. T500')));
      expect(text, contains('还有 9 首'));
      expect(text, isNot(contains('/')));
    });

    test('渲染：无封面 / 一张 / 九张都产出 1440 宽 PNG', () async {
      Future<Uint8List> png(Color color) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 300, 300),
          Paint()..color = color,
        );
        final picture = recorder.endRecording();
        try {
          final image = await picture.toImage(300, 300);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            return data!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
        }
      }

      final cover = await png(const Color(0xFF336699));
      for (final count in [0, 1, 9]) {
        final bytes = await const PlaylistPosterRenderer().render(
          content: content(trackCount: 9, coverCount: count),
          covers: [for (var i = 0; i < count; i++) cover],
          palette: PosterPalette.fromScheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
          ),
        );
        expect(bytes, isNotEmpty);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, kPlaylistPosterWidth);
        expect(frame.image.height, kPlaylistPosterMaxHeight);
        frame.image.dispose();
        codec.dispose();
      }
    });
  });
}

class _FakeLocalImporter implements PlaylistLocalImporter {
  _FakeLocalImporter(this.paths);

  final Map<String, PlaylistTrack?> paths;
  final List<String> calls = [];

  @override
  Future<PlaylistTrack?> importPath(String path) async {
    calls.add(path);
    return paths[path];
  }
}

class _FakeResolver implements PlaylistKeyResolver {
  _FakeResolver(this.keys);

  final Map<String, PlaylistTrack?> keys;
  final List<String> lookups = [];

  @override
  Future<PlaylistTrack?> resolve(String moliaKey) async {
    lookups.add(moliaKey);
    return keys[moliaKey];
  }
}

class _FakeTarget implements PlaylistImportTarget {
  _FakeTarget({this.existing = const []});

  final List<String> existing;
  final List<String> created = [];
  final List<List<PlaylistTrack>> addedBatches = [];
  final List<String> deleted = [];
  bool failAdd = false;

  @override
  Future<int> addTracks(int playlistId, List<PlaylistTrack> tracks) async {
    if (failAdd) throw StateError('add failed');
    addedBatches.add(tracks);
    return tracks.length;
  }

  @override
  Future<int> createPlaylist(String name) async {
    created.add(name);
    return created.length;
  }

  @override
  Future<void> deletePlaylist(int playlistId) async {
    deleted.add(created[playlistId - 1]);
  }
}
