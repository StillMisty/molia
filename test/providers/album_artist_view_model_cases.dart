import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/album_repository.dart';
import 'package:molia/domain/ports/artist_repository.dart';
import 'package:molia/providers/album_view_model.dart';
import 'package:molia/providers/artist_view_model.dart';

/// 专辑 / 歌手页 ViewModel：首屏 / 加载更多 / 失败重试 / 过期响应丢弃。
void main() {
  Track trackOf(String id) => Track(
    id: TrackId('wy', id),
    title: '曲目 $id',
    origin: TrackOrigin.builtin,
  );

  group('AlbumViewModel', () {
    late _FakeAlbumRepository repository;
    late AlbumViewModel viewModel;

    Album albumOf(String name, {required bool hasMore, List<Track>? tracks}) =>
        Album(
          id: '1',
          name: name,
          tracks: tracks ?? [trackOf(name)],
          hasMore: hasMore,
        );

    setUp(() {
      repository = _FakeAlbumRepository();
      viewModel = AlbumViewModel(
        repository: repository,
        sourceKey: 'wy',
        albumId: '1',
      );
    });

    tearDown(() => viewModel.dispose());

    test('首屏发布实体与曲目', () async {
      repository.next = (_) async =>
          albumOf('专辑', hasMore: true, tracks: [trackOf('1')]);

      await viewModel.loadFirstPage();

      expect(viewModel.state.items.map((track) => track.id.uri), ['wy:1']);
      expect(viewModel.state.album?.name, '专辑');
      expect(viewModel.state.page.hasMore, isTrue);
      expect(repository.requestedPages, [1]);
    });

    test('加载更多追加下一页', () async {
      repository.next = (page) async =>
          albumOf('专辑', hasMore: page == 1, tracks: [trackOf('$page')]);

      await viewModel.loadFirstPage();
      await viewModel.loadMore();

      expect(viewModel.state.items.map((track) => track.id.uri), [
        'wy:1',
        'wy:2',
      ]);
      expect(viewModel.state.page.hasMore, isFalse);
      expect(repository.requestedPages, [1, 2]);
    });

    test('失败重试重新取首屏并清空失败态', () async {
      repository.next = (_) async =>
          throw const SourceFailure(kind: FailureKind.network, message: 'boom');
      await viewModel.loadFirstPage();
      expect(viewModel.state.page.failed, isTrue);
      expect(viewModel.state.album, isNull);

      repository.next = (_) async => albumOf('恢复', hasMore: false);
      await viewModel.retry();

      expect(viewModel.state.page.failed, isFalse);
      expect(viewModel.state.items, hasLength(1));
      expect(viewModel.state.album?.name, '恢复');
    });

    test('快照随分页状态更新并通知 changes', () async {
      var notifications = 0;
      viewModel.changes.addListener(() => notifications++);
      repository.next = (_) async => albumOf('快照', hasMore: true);

      await viewModel.loadFirstPage();

      expect(notifications, greaterThan(0));
      final snapshot = viewModel.state;
      expect(snapshot.album?.name, '快照');
      expect(snapshot.items.single.id.uri, 'wy:快照');
      expect(identical(snapshot.items, snapshot.page.items), isTrue);
      expect(
        () => snapshot.items.add(snapshot.items.single),
        throwsUnsupportedError,
        reason: '分页结果用零拷贝只读视图',
      );
    });

    test('过期响应丢弃：重试后先返回的旧页不覆盖新状态', () async {
      final stale = Completer<Album>();
      var calls = 0;
      repository.next = (_) {
        calls++;
        if (calls == 1) return stale.future;
        return Future.value(
          albumOf('新', hasMore: false, tracks: [trackOf('2')]),
        );
      };

      final firstLoad = viewModel.loadFirstPage();
      final retryLoad = viewModel.retry();
      await retryLoad.timeout(const Duration(seconds: 1));

      stale.complete(albumOf('旧', hasMore: true, tracks: [trackOf('1')]));
      await firstLoad.timeout(const Duration(seconds: 1));

      expect(viewModel.state.album?.name, '新');
      expect(viewModel.state.items.map((track) => track.id.uri), ['wy:2']);
    });
  });

  group('ArtistViewModel', () {
    late _FakeArtistRepository repository;
    late ArtistViewModel viewModel;

    ArtistDetail artistOf(
      String name, {
      required bool hasMore,
      List<Track>? tracks,
    }) => ArtistDetail(
      id: '1',
      name: name,
      tracks: tracks ?? [trackOf(name)],
      hasMore: hasMore,
    );

    setUp(() {
      repository = _FakeArtistRepository();
      viewModel = ArtistViewModel(
        repository: repository,
        sourceKey: 'wy',
        artistId: '1',
      );
    });

    tearDown(() => viewModel.dispose());

    test('首屏发布实体与曲目', () async {
      repository.next = (_) async =>
          artistOf('歌手', hasMore: true, tracks: [trackOf('1')]);

      await viewModel.loadFirstPage();

      expect(viewModel.state.items.map((track) => track.id.uri), ['wy:1']);
      expect(viewModel.state.artist?.name, '歌手');
      expect(repository.requestedPages, [1]);
    });

    test('加载更多追加下一页', () async {
      repository.next = (page) async =>
          artistOf('歌手', hasMore: page == 1, tracks: [trackOf('$page')]);

      await viewModel.loadFirstPage();
      await viewModel.loadMore();

      expect(viewModel.state.items.map((track) => track.id.uri), [
        'wy:1',
        'wy:2',
      ]);
      expect(repository.requestedPages, [1, 2]);
    });

    test('失败重试重新取首屏并清空失败态', () async {
      repository.next = (_) async =>
          throw const SourceFailure(kind: FailureKind.network, message: 'boom');
      await viewModel.loadFirstPage();
      expect(viewModel.state.page.failed, isTrue);
      expect(viewModel.state.artist, isNull);

      repository.next = (_) async => artistOf('恢复', hasMore: false);
      await viewModel.retry();

      expect(viewModel.state.page.failed, isFalse);
      expect(viewModel.state.items, hasLength(1));
      expect(viewModel.state.artist?.name, '恢复');
    });

    test('快照随分页状态更新并通知 changes', () async {
      var notifications = 0;
      viewModel.changes.addListener(() => notifications++);
      repository.next = (_) async => artistOf('快照', hasMore: true);

      await viewModel.loadFirstPage();

      expect(notifications, greaterThan(0));
      final snapshot = viewModel.state;
      expect(snapshot.artist?.name, '快照');
      expect(snapshot.items.single.id.uri, 'wy:快照');
      expect(identical(snapshot.items, snapshot.page.items), isTrue);
    });

    test('过期响应丢弃：重试后先返回的旧页不覆盖新状态', () async {
      final stale = Completer<ArtistDetail>();
      var calls = 0;
      repository.next = (_) {
        calls++;
        if (calls == 1) return stale.future;
        return Future.value(
          artistOf('新', hasMore: false, tracks: [trackOf('2')]),
        );
      };

      final firstLoad = viewModel.loadFirstPage();
      final retryLoad = viewModel.retry();
      await retryLoad.timeout(const Duration(seconds: 1));

      stale.complete(artistOf('旧', hasMore: true, tracks: [trackOf('1')]));
      await firstLoad.timeout(const Duration(seconds: 1));

      expect(viewModel.state.artist?.name, '新');
      expect(viewModel.state.items.map((track) => track.id.uri), ['wy:2']);
    });
  });
}

class _FakeAlbumRepository implements AlbumRepository {
  Future<Album> Function(int page)? next;
  final List<int> requestedPages = [];

  @override
  Future<Album> loadAlbumPage(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    requestedPages.add(page);
    return next!(page);
  }
}

class _FakeArtistRepository implements ArtistRepository {
  Future<ArtistDetail> Function(int page)? next;
  final List<int> requestedPages = [];

  @override
  Future<ArtistDetail> loadArtistPage(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    requestedPages.add(page);
    return next!(page);
  }
}
