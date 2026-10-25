import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/artist_service.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';

/// 歌手服务：缓存 key 形状、失效 + 错误归一化。
void main() {
  ArtistDetail artistOf(String id, int page, {bool hasMore = true}) =>
      ArtistDetail(
        id: id,
        name: '歌手 $id',
        tracks: [
          for (var i = 0; i < 3; i++)
            Track(
              id: TrackId('wy', '$id-$page-$i'),
              title: '曲目 $page-$i',
              origin: TrackOrigin.builtin,
            ),
        ],
        hasMore: hasMore,
      );

  late List<({String source, String artistId, int page, int limit})> calls;
  late ArtistService service;

  ArtistService buildService() => ArtistService(
        fetch: (sourceKey, artistId, {required page, required limit}) async {
          calls.add((
            source: sourceKey,
            artistId: artistId,
            page: page,
            limit: limit,
          ));
          return artistOf(artistId, page);
        },
      );

  setUp(() {
    calls = [];
    service = buildService();
  });

  test('不同页 / 歌手 / 平台各自取数：page/limit/source 透传 fetch', () async {
    await service.load('wy', '6452');
    await service.load('wy', '6452', page: 2);
    await service.load('wy', 'other');
    await service.load('tx', '6452');
    expect(calls, hasLength(4));
    expect(calls[1], (source: 'wy', artistId: '6452', page: 2, limit: 50));
    expect(calls[2], (source: 'wy', artistId: 'other', page: 1, limit: 50));
    expect(calls[3], (source: 'tx', artistId: '6452', page: 1, limit: 50));
  });

  test('invalidateArtist 清该歌手全部页；其他歌手不受影响', () async {
    await service.load('wy', '6452');
    await service.load('wy', '6452', page: 2);
    await service.load('wy', 'other');
    expect(service.countForArtist('wy', '6452'), 2);

    service.invalidateArtist('wy', '6452');
    expect(service.countForArtist('wy', '6452'), 0);
    expect(service.countForArtist('wy', 'other'), 1);

    await service.load('wy', '6452');
    expect(calls, hasLength(4), reason: '失效后重新取数');
  });

  test('任意异常归一化为 SourceFailure', () async {
    service = ArtistService(
      fetch: (sourceKey, artistId, {required page, required limit}) async =>
          throw StateError('boom'),
    );
    await expectLater(
      service.load('wy', '1'),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.unknown),
      ),
    );
  });

  test('cacheKey 含平台 / 歌手 / 页 / 每页条数', () {
    expect(
      ArtistService.cacheKey('wy', '6452', page: 2),
      'artist:wy:6452:2:50',
    );
    expect(ArtistService.artistCacheKeyPrefix('wy', '6452'), 'artist:wy:6452:');
  });
}
