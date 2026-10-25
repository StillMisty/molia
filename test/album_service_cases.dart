import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/album_service.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';

/// 专辑服务：缓存 key 形状、失效 + 错误归一化。
void main() {
  Album albumOf(String id, int page, {int limit = 50, bool hasMore = true}) =>
      Album(
        id: id,
        name: '专辑 $id',
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

  late List<({String source, String albumId, int page, int limit})> calls;
  late AlbumService service;

  AlbumService buildService() => AlbumService(
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

  setUp(() {
    calls = [];
    service = buildService();
  });

  test('不同页 / 专辑 / 平台各自取数：page/limit/source 透传 fetch', () async {
    await service.load('wy', '32311');
    await service.load('wy', '32311', page: 2);
    await service.load('wy', 'other');
    await service.load('tx', '32311');
    expect(calls, hasLength(4));
    expect(calls[1], (source: 'wy', albumId: '32311', page: 2, limit: 50));
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

  test('任意异常归一化为 SourceFailure', () async {
    service = AlbumService(
      fetch: (sourceKey, albumId, {required page, required limit}) async =>
          throw StateError('boom'),
    );
    await expectLater(
      service.load('wy', '1'),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.unknown),
      ),
    );
  });

  test('cacheKey 含平台 / 专辑 / 页 / 每页条数', () {
    expect(
      AlbumService.cacheKey('wy', '32311', page: 2),
      'album:wy:32311:2:50',
    );
    expect(
      AlbumService.albumCacheKeyPrefix('wy', '32311'),
      'album:wy:32311:',
    );
  });
}
