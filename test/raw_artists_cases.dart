import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/sources/raw_track.dart';
import 'package:molia/sources/source_track.dart';

/// raw 歌手引用约定（`_artists` 内部字段）：解析、映射与往返保真。
void main() {
  SourceTrack sourceTrack({
    Map<String, dynamic>? raw,
    String artist = '周杰伦、温岚',
  }) =>
      SourceTrack(
        sourceKey: 'wy',
        origin: 'builtin',
        title: '屋顶',
        artist: artist,
        album: '有点野',
        raw: raw ?? const {'songmid': '298317'},
      );

  test('artistsFromRaw：解析名字 + id；缺省 / 结构不符返回空；忽略空名字', () {
    expect(artistsFromRaw(const {}), isEmpty);
    expect(artistsFromRaw(const {kRawArtistsField: 'not-a-list'}), isEmpty);
    expect(
      artistsFromRaw(const {
        kRawArtistsField: [
          {'name': '', 'id': '1'},
          {'id': '2'},
        ],
      }),
      isEmpty,
    );

    final artists = artistsFromRaw(const {
      kRawArtistsField: [
        {'name': '周杰伦', 'id': 6452},
        {'name': '温岚'},
      ],
    });
    expect(artists, hasLength(2));
    expect(artists[0], const SourceArtistRef(name: '周杰伦', id: '6452'));
    expect(artists[1], const SourceArtistRef(name: '温岚'));
  });

  test('SourceArtistRef：JSON 往返（空 id 不落盘）', () {
    const ref = SourceArtistRef(name: '周杰伦', id: '6452');
    expect(SourceArtistRef.fromJson(ref.toJson()), ref);
    const noId = SourceArtistRef(name: '温岚');
    expect(SourceArtistRef.fromJson(noId.toJson()), noId);
    expect(noId.toJson().containsKey('id'), isFalse);
  });

  test('trackFromSourceTrack：raw `_artists` → Track.artists（带平台内 id）', () {
    final track = trackFromSourceTrack(
      sourceTrack(
        raw: const {
          'songmid': '298317',
          kRawArtistsField: [
            {'name': '温岚', 'id': '9612'},
            {'name': '周杰伦', 'id': '6452'},
          ],
        },
      ),
    );

    expect(track.artists.map((artist) => (artist.name, artist.id)).toList(), [
      ('温岚', '9612'),
      ('周杰伦', '6452'),
    ]);
    // payload 原样透传（同一引用）。
    expect(track.payload[kRawArtistsField], isA<List>());
  });

  test('trackFromSourceTrack：无 `_artists` 时整串 artist 作为唯一条目（无 id）', () {
    final track = trackFromSourceTrack(sourceTrack());
    expect(track.artists, hasLength(1));
    expect(track.artists.single.name, '周杰伦、温岚');
    expect(track.artists.single.id, isNull);
  });

  test('收藏夹往返：raw `_artists` 保真（新收藏可进歌手页）', () {
    final track = trackFromSourceTrack(
      sourceTrack(
        raw: const {
          'songmid': '298317',
          kRawArtistsField: [
            {'name': '温岚', 'id': '9612'},
            {'name': '周杰伦', 'id': '6452'},
          ],
        },
      ),
    );
    final entry = PlaylistTrack.fromTrack(track, addedAt: 1);
    expect(entry.artist, '温岚, 周杰伦');
    expect(entry.raw[kRawArtistsField], isA<List>());

    // 库内条目还原（收藏页播放 / 歌曲信息页入口都走这里）。
    final restored = trackFromSourceTrack(
      SourceTrack(
        sourceKey: entry.sourceKey,
        origin: 'lx',
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        raw: entry.raw,
      ),
    );
    expect(
      restored.artists.map((artist) => (artist.name, artist.id)).toList(),
      [('温岚', '9612'), ('周杰伦', '6452')],
    );
  });
}
