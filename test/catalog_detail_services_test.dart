import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/album_service.dart';
import 'package:molia/data/catalog/artist_service.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/failure.dart';

/// 专辑 / 歌手服务：类型化适配器的 key 形状、分页透传、失效与错误归一化。
void main() {
  group('album service', () {
    Album albumOf(String id, int page) => Album(id: id, name: '专辑 $page');

    late List<({String source, String albumId, int page, int limit})> calls;
    late AlbumService service;

    setUp(() {
      calls = [];
      service = AlbumService(
        fetch: (sourceKey, albumId, {required page, required limit}) async {
          calls.add((
            source: sourceKey,
            albumId: albumId,
            page: page,
            limit: limit,
          ));
          return albumOf(albumId, page);
        },
      );
    });

    test('page / limit / source 透传；同页命中缓存', () async {
      await service.load('wy', '32311');
      await service.load('wy', '32311');
      expect(calls, hasLength(1));

      await service.load('wy', '32311', page: 2, limit: 20);
      await service.load('wy', 'other');
      await service.load('tx', '32311');
      expect(calls, hasLength(4));
      expect(calls[1], (source: 'wy', albumId: '32311', page: 2, limit: 20));
      expect(calls[2], (source: 'wy', albumId: 'other', page: 1, limit: 50));
      expect(calls[3], (source: 'tx', albumId: '32311', page: 1, limit: 50));
    });

    test('invalidateAlbum 清该专辑全部页；其他专辑不受影响', () async {
      await service.load('wy', '32311');
      await service.load('wy', '32311', page: 2);
      await service.load('wy', 'other');
      expect(service.countForAlbum('wy', '32311'), 2);

      service.invalidateAlbum('wy', '32311');
      expect(service.countForAlbum('wy', '32311'), 0);
      expect(service.countForAlbum('wy', 'other'), 1);

      await service.load('wy', '32311');
      expect(calls, hasLength(4), reason: '失效后重新取数');
    });

    test('clearCache 清空全部专辑页（托盘隐藏释放）', () async {
      await service.load('wy', '32311');
      await service.load('wy', '32311', page: 2);
      await service.load('tx', 'other');
      expect(service.countForAlbum('wy', '32311'), 2);
      expect(service.countForAlbum('tx', 'other'), 1);

      service.clearCache();
      expect(service.countForAlbum('wy', '32311'), 0);
      expect(service.countForAlbum('tx', 'other'), 0);

      await service.load('wy', '32311');
      expect(calls, hasLength(4), reason: '清空后重新取数');
    });

    test('cacheKey 含平台 / 专辑 / 页 / 每页条数', () {
      expect(
        AlbumService.cacheKey('wy', '32311', page: 2),
        'album:wy:32311:2:50',
      );
      expect(
        AlbumService.cacheKey('wy', '32311', page: 2, limit: 20),
        'album:wy:32311:2:20',
      );
      expect(
        AlbumService.albumCacheKeyPrefix('wy', '32311'),
        'album:wy:32311:',
      );
    });

    test('任意异常归一化为 SourceFailure', () async {
      service = AlbumService(
        fetch: (sourceKey, albumId, {required page, required limit}) async =>
            throw StateError('boom'),
      );
      await expectLater(
        service.load('wy', '1'),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unknown,
          ),
        ),
      );
    });
  });

  group('artist service', () {
    ArtistDetail artistOf(String id, int page) =>
        ArtistDetail(id: id, name: '歌手 $page');

    late List<({String source, String artistId, int page, int limit})> calls;
    late ArtistService service;

    setUp(() {
      calls = [];
      service = ArtistService(
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
    });

    test('page / limit / source 透传；同页命中缓存', () async {
      await service.load('wy', '6452');
      await service.load('wy', '6452');
      expect(calls, hasLength(1));

      await service.load('wy', '6452', page: 2, limit: 20);
      await service.load('wy', 'other');
      await service.load('tx', '6452');
      expect(calls, hasLength(4));
      expect(calls[1], (source: 'wy', artistId: '6452', page: 2, limit: 20));
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

    test('clearCache 清空全部歌手页（托盘隐藏释放）', () async {
      await service.load('wy', '6452');
      await service.load('wy', '6452', page: 2);
      await service.load('tx', 'other');
      expect(service.countForArtist('wy', '6452'), 2);
      expect(service.countForArtist('tx', 'other'), 1);

      service.clearCache();
      expect(service.countForArtist('wy', '6452'), 0);
      expect(service.countForArtist('tx', 'other'), 0);

      await service.load('wy', '6452');
      expect(calls, hasLength(4), reason: '清空后重新取数');
    });

    test('cacheKey 含平台 / 歌手 / 页 / 每页条数', () {
      expect(
        ArtistService.cacheKey('wy', '6452', page: 2),
        'artist:wy:6452:2:50',
      );
      expect(
        ArtistService.cacheKey('wy', '6452', page: 2, limit: 20),
        'artist:wy:6452:2:20',
      );
      expect(
        ArtistService.artistCacheKeyPrefix('wy', '6452'),
        'artist:wy:6452:',
      );
    });

    test('任意异常归一化为 SourceFailure', () async {
      service = ArtistService(
        fetch: (sourceKey, artistId, {required page, required limit}) async =>
            throw StateError('boom'),
      );
      await expectLater(
        service.load('wy', '1'),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unknown,
          ),
        ),
      );
    });
  });
}
