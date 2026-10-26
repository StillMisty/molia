import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/source_swap_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 换源状态机：并行分组检索 / 失败隔离 / 库内原位替换 / 队列跟随。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(String sourceKey, String id, {String title = 'Title'}) => Track(
        id: TrackId(sourceKey, id),
        title: title,
        artists: [Artist(name: 'Artist')],
        album: 'Album',
        duration: const Duration(minutes: 3),
        origin: TrackOrigin.builtin,
        payload: {'songmid': id, 'source': sourceKey},
      );

  late FakeLibraryRepository repository;
  late LibraryProvider library;
  late PlaybackProvider playback;
  late FakePlaybackBackend backend;

  late FakeMusicSource kg;
  late FakeMusicSource tx;
  late Map<String, FakeMusicSource> sources;

  setUp(() {
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    kg = FakeMusicSource('kg');
    tx = FakeMusicSource('tx');
    sources = {'kg': kg, 'tx': tx};
  });

  tearDown(() {
    library.dispose();
    playback.dispose();
    repository.dispose();
  });

  SourceSwapProvider buildProvider({SourceSwapTrackHook? onTrackSwapped}) =>
      SourceSwapProvider(
        catalogService: CatalogService(registry: FakeSourceRegistry(sources)),
        sourceRegistry: FakeSourceRegistry(sources),
        libraryProvider: library,
        playbackProvider: playback,
        onTrackSwapped: onTrackSwapped,
      );

  test('begin：其它音源并行检索，按源分组；排除种子源 / 空结果 / 失败隔离', () async {
    sources['wy'] = FakeMusicSource('wy'); // 种子源：必须被排除
    kg.items = [track('kg', '100'), track('kg', '101')];
    tx.fail = true;
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));

    expect(provider.isSearching, isFalse);
    expect(provider.noOtherSources, isFalse);
    // 只有 kg 有结果（tx 失败、wy 被排除；空源不产生分组）。
    expect(provider.groups.map((g) => g.sourceKey), ['kg']);
    expect(provider.activeSourceKey, 'kg');
    expect(provider.activeItems.map((t) => t.id.uri), ['kg:100', 'kg:101']);
    expect(provider.failedSourceKeys, {'tx'});
    expect(kg.lastQuery?.keyword, 'Title Artist');
    expect(sources['wy']!.searchCalls, 0, reason: '种子源被排除');
  });

  test('begin：B 站种子保留同源候选（换到其它投稿），关键词只用标题', () async {
    final bili = FakeMusicSource('bili');
    sources['bili'] = bili;
    final seed = track('bili', 'BV1');
    // 同源结果里混入种子自身：仍要按 URI 排除。
    bili.items = [seed, track('bili', 'BV2')];
    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.queue,
    ));

    expect(
      provider.groups.map((g) => g.sourceKey),
      containsAll(['kg', 'bili']),
    );
    final biliGroup = provider.groups.singleWhere((g) => g.sourceKey == 'bili');
    expect(biliGroup.items.map((t) => t.id.uri), ['bili:BV2'],
        reason: '种子自身仍从候选中排除');
    expect(bili.lastQuery?.keyword, 'Title', reason: 'UP 主不是歌手，不进关键词');
    expect(kg.lastQuery?.keyword, 'Title', reason: '搜索其它平台同样只用标题');
  });

  test('begin：非 B 站种子仍搜 B 站，关键词保持标题 + 歌手', () async {
    final bili = FakeMusicSource('bili')..items = [track('bili', 'BV1')];
    sources['bili'] = bili;
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));

    expect(provider.groups.map((g) => g.sourceKey), contains('bili'));
    expect(bili.lastQuery?.keyword, 'Title Artist');
  });

  test('begin：没有其它可搜索音源 → noOtherSources，不发起搜索', () async {
    final wy = FakeMusicSource('wy');
    sources
      ..clear()
      ..['wy'] = wy;
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));

    expect(provider.noOtherSources, isTrue);
    expect(provider.groups, isEmpty);
    expect(wy.searchCalls, 0);
  });

  test('retryFailed：失败源重搜成功后清空失败集并入组', () async {
    tx.fail = true;
    tx.items = [track('tx', '200')];
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));
    expect(provider.failedSourceKeys, {'tx'});
    expect(provider.groups, isEmpty);

    tx.fail = false;
    await provider.retryFailed();

    expect(provider.failedSourceKeys, isEmpty);
    expect(provider.groups.map((g) => g.sourceKey), ['tx']);
    expect(provider.activeSourceKey, 'tx');
  });

  test('failedSourceNames：按注册表顺序给出展示名，描述符缺失时回退 key', () async {
    kg.fail = true;
    tx.fail = true;
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));

    expect(provider.failedSourceKeys, {'kg', 'tx'});
    expect(provider.failedSourceNames, ['kg', 'tx']);

    // 会话期间音源被移除（注册表里找不到描述符）：仍需报出失败 key。
    sources.remove('tx');
    expect(provider.failedSourceNames, ['kg', 'tx']);
  });

  test('select：切换 tab 与选中项（不可变分组）', () async {
    kg.items = [track('kg', '100')];
    tx.items = [track('tx', '200')];
    final provider = buildProvider();
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));

    expect(provider.activeSourceKey, 'kg');
    provider.selectSource('tx');
    expect(provider.activeItems.map((t) => t.id.uri), ['tx:200']);
    provider.select(provider.activeItems.single);
    expect(provider.selected?.id.uri, 'tx:200');
  });

  test('apply（列表）：原位替换 + 队列命中跟随', () async {
    final playlistId = await repository.createPlaylist('L');
    await repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'wy',
        songId: '1',
        title: 'Title',
        raw: const {'songmid': 1},
        addedAt: 1,
      ),
    );
    // 种子正在播放：队列跟随应命中。
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));

    kg.items = [track('kg', '100', title: 'Title（新源）')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.playlist,
      playlistId: playlistId,
    ));
    provider.select(kg.items.single);

    final result = await provider.apply();

    expect(result.status, SourceSwapApplyStatus.swapped);
    expect(result.queueFollowed, isTrue);
    expect(backend.lastReplacedTrackUri, 'wy:1');
    final tracks = await repository.listPlaylistTracks(playlistId);
    expect(tracks.single.sourceKey, 'kg');
    expect(tracks.single.songId, '100');
    // payload 原样透传（换源后的取链依赖平台字段）。
    expect(tracks.single.raw['songmid'], '100');
  });

  test('apply（列表）：仓库写失败 → writeFailed，队列不跟随', () async {
    final playlistId = await repository.createPlaylist('L');
    await repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'wy',
        songId: '1',
        title: 'Title',
        raw: const {'songmid': 1},
        addedAt: 1,
      ),
    );
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));

    kg.items = [track('kg', '100', title: 'Title（新源）')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.playlist,
      playlistId: playlistId,
    ));
    provider.select(kg.items.single);

    repository.failTrackWrites = true;
    final result = await provider.apply();

    expect(result.status, SourceSwapApplyStatus.writeFailed);
    expect(result.queueFollowed, isFalse);
    expect(backend.lastReplacedTrackUri, isNull, reason: '库内写失败不能跟队列');
    final tracks = await repository.listPlaylistTracks(playlistId);
    expect(tracks.single.sourceKey, 'wy', reason: '列表保持原曲');
    expect(tracks.single.songId, '1');
    expect(playback.snapshot.current?.id.uri, 'wy:1', reason: '队列保持原曲');
  });

  test('apply（历史）：仓库写失败 → writeFailed，队列不跟随', () async {
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'Title',
      raw: const {'songmid': 1},
      playedAt: 100,
    ));
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));

    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.history,
      historyKey: (sourceKey: 'wy', songId: '1'),
    ));
    provider.select(kg.items.single);

    repository.failHistoryWrites = true;
    final result = await provider.apply();

    expect(result.status, SourceSwapApplyStatus.writeFailed);
    expect(result.queueFollowed, isFalse);
    expect(backend.lastReplacedTrackUri, isNull, reason: '库内写失败不能跟队列');
    final history = await repository.listHistory();
    expect(history.single.sourceKey, 'wy', reason: '历史保持原曲');
    expect(history.single.songId, '1');
    expect(playback.snapshot.current?.id.uri, 'wy:1', reason: '队列保持原曲');
  });

  test('apply（列表）：目标已存在 → 先要重复确认，确认后去重替换', () async {
    final playlistId = await repository.createPlaylist('L');
    for (final songId in ['1', '100']) {
      await repository.addTrackToPlaylist(
        playlistId,
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: songId == '1' ? 'wy' : 'kg',
          songId: songId,
          title: 'T$songId',
          raw: {'songmid': songId},
          addedAt: 1,
        ),
      );
    }

    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.playlist,
      playlistId: playlistId,
    ));
    provider.select(kg.items.single);

    final first = await provider.apply();
    expect(first.status, SourceSwapApplyStatus.duplicateConfirmationRequired);

    final second = await provider.apply(removeDuplicate: true);
    expect(second.status, SourceSwapApplyStatus.swapped);
    final tracks = await repository.listPlaylistTracks(playlistId);
    expect(tracks.map((t) => '${t.sourceKey}:${t.songId}'), ['kg:100']);
  });

  test('apply（历史）：保 playedAt 原位替换', () async {
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'Title',
      raw: const {'songmid': 1},
      playedAt: 100,
    ));

    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.history,
      historyKey: (sourceKey: 'wy', songId: '1'),
    ));
    provider.select(kg.items.single);

    final result = await provider.apply();

    expect(result.status, SourceSwapApplyStatus.swapped);
    final history = await repository.listHistory();
    expect(history.single.sourceKey, 'kg');
    expect(history.single.songId, '100');
    expect(history.single.playedAt, 100);
  });

  test('apply（仅队列）：命中替换；试听接管后确认视为已生效；未命中报 notFound', () async {
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));

    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.queue,
    ));
    provider.select(kg.items.single);

    final hit = await provider.apply();
    expect(hit.status, SourceSwapApplyStatus.swapped);
    expect(hit.queueFollowed, isTrue);

    // 试听接管（单曲队列已不含旧曲目）后确认：当前已是所选曲目 → 视为已生效。
    backend.emit(BackendSnapshot(
      current: kg.items.single,
      queue: [kg.items.single],
      currentIndex: 0,
      isPlaying: true,
    ));
    final afterPreview = await provider.apply();
    expect(afterPreview.status, SourceSwapApplyStatus.swapped);
    expect(afterPreview.queueFollowed, isTrue);

    // 目标已不在队列且当前不是所选曲目：换一个新会话验证 targetNotFound。
    backend.emit(BackendSnapshot(
      current: track('wy', '999'),
      queue: [track('wy', '999')],
      currentIndex: 0,
      isPlaying: true,
    ));
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.queue,
    ));
    provider.select(kg.items.single);
    final miss = await provider.apply();
    expect(miss.status, SourceSwapApplyStatus.targetNotFound);
  });

  test('apply 成功后回调种子与新曲目（本地封面跟随入口）', () async {
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));
    kg.items = [track('kg', '100')];
    final swapped = <(String, String)>[];
    final provider = buildProvider(
      onTrackSwapped: (oldTrack, newTrack) async {
        swapped.add((oldTrack.id.uri, newTrack.id.uri));
      },
    );
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.queue,
    ));
    provider.select(kg.items.single);

    final result = await provider.apply();
    expect(result.status, SourceSwapApplyStatus.swapped);
    expect(swapped, [('wy:1', 'kg:100')]);
  });

  test('apply（列表 / 历史）：成功换源只回调一次（封面跟随不重复）', () async {
    final playlistId = await repository.createPlaylist('L');
    await repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'wy',
        songId: '1',
        title: 'Title',
        raw: const {'songmid': 1},
        addedAt: 1,
      ),
    );
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'Title',
      raw: const {'songmid': 1},
      playedAt: 100,
    ));
    final seed = track('wy', '1');
    backend.emit(BackendSnapshot(
      current: seed,
      queue: [seed],
      currentIndex: 0,
      isPlaying: true,
    ));

    kg.items = [track('kg', '100')];
    final swapped = <(String, String)>[];
    final provider = buildProvider(
      onTrackSwapped: (oldTrack, newTrack) async {
        swapped.add((oldTrack.id.uri, newTrack.id.uri));
      },
    );
    addTearDown(provider.dispose);

    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.playlist,
      playlistId: playlistId,
    ));
    provider.select(kg.items.single);
    final playlistResult = await provider.apply();
    expect(playlistResult.status, SourceSwapApplyStatus.swapped);
    expect(swapped, [('wy:1', 'kg:100')], reason: '列表换源回调只跑一次');

    swapped.clear();
    await provider.begin(SourceSwapRequest(
      seed: seed,
      placement: SourceSwapPlacement.history,
      historyKey: (sourceKey: 'wy', songId: '1'),
    ));
    provider.select(kg.items.single);
    final historyResult = await provider.apply();
    expect(historyResult.status, SourceSwapApplyStatus.swapped);
    expect(swapped, [('wy:1', 'kg:100')], reason: '历史换源回调只跑一次');
  });

  test('apply（列表）：旧行已被移除 → targetNotFound', () async {
    final playlistId = await repository.createPlaylist('L');
    kg.items = [track('kg', '100')];
    final provider = buildProvider();
    addTearDown(provider.dispose);
    await provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.playlist,
      playlistId: playlistId,
    ));
    provider.select(kg.items.single);

    final result = await provider.apply();

    expect(result.status, SourceSwapApplyStatus.targetNotFound);
  });

  test('clear：过期在途结果被会话 id 守卫丢弃', () async {
    final gate = Completer<void>();
    kg.onSearch = (query) async {
      await gate.future;
      return SearchResult(items: [track('kg', '100')]);
    };
    final provider = buildProvider();
    addTearDown(provider.dispose);

    final pending = provider.begin(SourceSwapRequest(
      seed: track('wy', '1'),
      placement: SourceSwapPlacement.queue,
    ));
    provider.clear();
    gate.complete();
    await pending;

    expect(provider.hasSession, isFalse);
    expect(provider.groups, isEmpty);
    expect(provider.isSearching, isFalse);
  });
}
