import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 发现 provider 单测：多平台委托 / 错误归一化 / 播放 / 收藏 / 加入列表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late FakeDiscoverSource source;
  late DiscoverProvider discover;

  setUp(() {
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    source = FakeDiscoverSource();
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {'wy': source},
    );
  });

  tearDown(() async {
    discover.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  test('默认平台 wy；榜单表来自数据源；榜单曲目解析为发现曲目', () async {
    expect(discover.channelKey, 'wy');
    expect(discover.sourceKeys, ['wy']);
    expect(discover.leaderboards.single.name, '热歌榜');
    final tracks = await discover.loadLeaderboardTracks('3778678');
    expect(source.leaderboardCalls, 1);
    expect(tracks.single.title, '歌曲A');
    expect(tracks.single.songId, '111');
  });

  test('错误归一化为 DiscoverFailure（SourceFailure 包装）', () async {
    source.fail = true;
    await expectLater(
      discover.loadLeaderboardTracks('3778678'),
      throwsA(
        isA<DiscoverFailure>().having(
          (failure) => failure.failure.kind,
          'kind',
          FailureKind.unknown,
        ),
      ),
    );
    expect(discover.leaderboards, isNotEmpty); // 静态表不依赖网络
  });

  test('playTracks：raw 原样交给播放队列', () async {
    final tracks = await discover.loadLeaderboardTracks('3778678');
    await discover.playTracks(tracks, 0, contextName: '热歌榜');

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks, hasLength(1));
    expect(request.startIndex, 0);
    expect(request.context?.name, '热歌榜');
    expect(request.tracks.single.payload['songmid'], 111);
    expect(request.tracks.single.duration, const Duration(milliseconds: 245000));
  });

  test('收藏切换写入资料库并更新 isFavorite', () async {
    final tracks = await discover.loadLeaderboardTracks('3778678');
    final track = tracks.single;

    expect(discover.isFavorite(track), isFalse);
    final added = await discover.toggleFavorite(track);
    expect(added, isTrue);
    expect(discover.isFavorite(track), isTrue);
    expect(await repository.favoriteKeys(), contains('wy:111'));
  });

  test('加入列表：创建后写入、重复加入返回 false', () async {
    final playlistId = await repository.createPlaylist('我的列表');
    await library.refreshPlaylists(force: true);
    final track = (await discover.loadLeaderboardTracks('3778678')).single;

    expect(await discover.addToPlaylist(playlistId, track), isTrue);
    expect(await discover.addToPlaylist(playlistId, track), isFalse);

    final stored = await repository.listPlaylistTracks(playlistId);
    expect(stored, hasLength(1));
    expect(stored.single.songId, '111');
    expect(stored.single.raw['songmid'], 111);
  });

  test('加入我的收藏 / 播放历史', () async {
    final track = (await discover.loadLeaderboardTracks('3778678')).single;
    expect(await discover.addToFavorites(track), isTrue);
    expect(await discover.addToFavorites(track), isFalse);
    expect(await repository.favoriteKeys(), contains('wy:111'));

    await discover.addToHistory(track);
    expect((await repository.listHistory()).single.songId, '111');
  });

  test('导入歌单详情：同名复用且重复导入幂等', () async {
    final detail = await discover.loadPlaylistDetail('abc', 1);
    final first = await discover.importDetailToLibrary(detail);
    expect(first.added, 1);
    expect(first.total, 1);
    final stored = await repository.listPlaylistTracks(first.playlistId);
    expect(stored.single.songId, '111');
    expect(stored.single.raw['songmid'], 111);

    final again = await discover.importDetailToLibrary(detail);
    expect(again.playlistId, first.playlistId);
    expect(again.added, 0);
  });

  test('链接导入：按指定平台拉取；未接入平台归一化为 DiscoverFailure', () async {
    final result = await discover.importPlaylistFromLink('wy', 'abc');
    expect(result.added, 1);

    await expectLater(
      discover.importPlaylistFromLink('tx', 'abc'),
      throwsA(isA<DiscoverFailure>()),
    );
  });

  test('loadHotSearches：成功后缓存；失败静默为空', () async {
    await discover.loadHotSearches();
    expect(discover.hotSearches, ['晴天', '夜曲']);
    await discover.loadHotSearches();
    expect(source.hotSearchCalls, 1); // 幂等，不重复请求

    final failing = FakeDiscoverSource()..fail = true;
    final discover2 = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {'wy': failing},
    );
    addTearDown(discover2.dispose);
    await discover2.loadHotSearches();
    expect(discover2.hotSearches, isEmpty);
  });

  test('平台切换：数据源紧随，热搜按平台分别缓存', () async {
    final tx = FakeDiscoverSource(sourceKey: 'tx');
    final multi = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {'wy': source, 'tx': tx},
    );
    addTearDown(multi.dispose);
    expect(multi.sourceKeys, ['wy', 'tx']);

    await multi.loadHotSearches();
    expect(multi.hotSearches, ['晴天', '夜曲']);
    expect(source.hotSearchCalls, 1);

    multi.selectChannel('tx');
    expect(multi.channelKey, 'tx');
    expect(multi.hotSearches, isEmpty);
    await multi.loadHotSearches();
    expect(tx.hotSearchCalls, 1);

    multi.selectChannel('wy');
    expect(multi.hotSearches, ['晴天', '夜曲']);
    expect(source.hotSearchCalls, 1); // 命中缓存

    // 非发现渠道：允许选中但能力全部降级（资料页据此隐藏热榜/歌单）。
    multi.selectChannel('nope');
    expect(multi.channelKey, 'nope');
    expect(multi.hasDiscoverSource, isFalse);
    expect(multi.supportsLeaderboards, isFalse);
    expect(multi.supportsPlaylists, isFalse);
    expect(multi.supportsHotSearch, isFalse);
    expect(multi.leaderboards, isEmpty);
    expect(multi.hotSearches, isEmpty);
    await expectLater(
      multi.loadTags(),
      throwsA(isA<DiscoverFailure>()),
    );
  });

  test('标签 / 歌单列表 / 搜索 / 详情委托数据源', () async {
    final tags = await discover.loadTags();
    expect(tags.hotTags.single.name, '华语');
    expect(tags.categories.single.name, '语种');

    final page = await discover.loadPlaylists('华语', 1);
    expect(page.playlists.single.name, '测试歌单');
    expect(page.total, 1);

    final search = await discover.searchPlaylists('周杰伦', 1);
    expect(search.playlists.single.name, '搜索:周杰伦');

    final detail = await discover.loadPlaylistDetail('123', 1);
    expect(detail.info.id, '123');
    expect(detail.tracks.single.songId, '111');
  });

  test('资料库变化转发通知（收藏按钮响应）', () async {
    var notified = 0;
    discover.addListener(() => notified++);
    final playlistId = await repository.createPlaylist('列表');
    await library.refreshPlaylists(force: true);
    expect(playlistId, greaterThan(0));
    expect(notified, greaterThan(0));
  });
}
