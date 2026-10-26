/// 手动歌词换源会话：逐源搜索、不可用来源跳过、旧查询丢弃、选中写缓存与
/// 结果收口（不依赖 widget 生命周期）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/lyrics_source_search_session.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/services/lyrics_service.dart';

typedef _SavedLyrics = ({
  String trackId,
  String lyric,
  String provider,
  String? translation,
  String? roma,
  String? lxlyric,
});

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService() : super(providers: const []);

  final List<_SavedLyrics> saved = [];

  @override
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName, {
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    saved.add((
      trackId: trackId,
      lyric: lyric,
      provider: providerName,
      translation: translation,
      roma: roma,
      lxlyric: lxlyric,
    ));
  }
}

class _FakeLyricProvider extends LyricProvider {
  _FakeLyricProvider(
    this.name, {
    this.matches = const [],
    this.payload,
    this.fetchError,
  });

  @override
  final String name;

  final List<SongMatch> matches;
  final LyricsPayload? payload;
  final Object? fetchError;

  int searchCalls = 0;

  /// 非空时取词挂起，直到测试放行（用于并发点击）。
  Completer<void>? fetchGate;

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final results = await searchMultiple(title, artist, limit: 1);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async {
    searchCalls++;
    return matches.take(limit).toList();
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    final gate = fetchGate;
    if (gate != null) await gate.future;
    if (fetchError != null) throw fetchError!;
    return payload;
  }

  @override
  Future<String?> fetchLyric(String songId) async => payload?.lyric;
}

/// 手动控制每次搜索何时返回（验证旧查询晚到）。
class _QueuedLyricProvider extends LyricProvider {
  _QueuedLyricProvider(this.name);

  @override
  final String name;

  final List<Completer<List<SongMatch>>> pending = [];

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) {
    final completer = Completer<List<SongMatch>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<String?> fetchLyric(String songId) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LyricsSourceSearchSession buildSession(
    List<LyricsSourceStrategy> sources, {
    LyricsService? service,
    Set<String>? enabledChannelKeys,
  }) {
    final lyricsProvider = LyricsProvider(
      service: service ?? _FakeLyricsService(),
    );
    addTearDown(lyricsProvider.dispose);
    final session = LyricsSourceSearchSession(
      strategies: sources,
      enabledChannelKeys: enabledChannelKeys,
      lyricsProvider: lyricsProvider,
      trackId: 'bili:1',
      trackTitle: '晴天',
      trackArtist: '周杰伦',
    );
    addTearDown(session.dispose);
    return session;
  }

  LyricsSourceStrategy strategy(
    LyricProvider provider, {
    String? channelKey,
    bool isChannel = true,
    LyricsSourceUnavailable? Function()? unavailable,
  }) {
    return LyricsSourceStrategy(
      channelKey: channelKey ?? provider.name,
      provider: provider,
      isChannel: isChannel,
      unavailable: unavailable,
    );
  }

  SongMatch sunnyDay(String songId, {String artist = '周杰伦'}) =>
      SongMatch(songId: songId, title: '晴天', artist: artist);

  test('渠道开关过滤：停用渠道不进会话，LRCLIB 不受影响', () {
    final session = buildSession(
      [
        strategy(_FakeLyricProvider('enabled'), channelKey: 'enabled'),
        strategy(_FakeLyricProvider('disabled'), channelKey: 'disabled'),
        strategy(
          _FakeLyricProvider('lrclib'),
          channelKey: 'lrclib',
          isChannel: false,
        ),
      ],
      enabledChannelKeys: {'enabled'},
    );

    expect(session.strategies.map((strategy) => strategy.channelKey), [
      'enabled',
      'lrclib',
    ]);
  });

  test('不可用来源不发请求：仍保留分组头并报告原因，且每次读取都重新求值', () async {
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('qq-1')]);
    final bili = _FakeLyricProvider('bili');
    var loggedIn = false;
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(
        bili,
        channelKey: 'bili',
        unavailable: () =>
            loggedIn ? null : LyricsSourceUnavailable.biliLoginRequired,
      ),
    ]);

    await session.search('晴天 周杰伦');

    expect(qq.searchCalls, 1);
    expect(bili.searchCalls, 0, reason: '不可用来源不发请求');
    expect(session.stateOf('qq'), ProviderSearchState.loaded);
    expect(session.stateOf('bili'), ProviderSearchState.unavailable);
    expect(session.unavailableReasons, [
      LyricsSourceUnavailable.biliLoginRequired,
    ]);

    final headers = session.entries
        .where((entry) => entry.type == LyricsSearchEntryType.header)
        .toList();
    expect(headers.map((entry) => entry.strategy!.channelKey), [
      'tx',
      'bili',
    ], reason: '不可用来源的分组头仍然渲染「怎么办」');
    expect(
      session.entries.any(
        (entry) =>
            entry.type == LyricsSearchEntryType.result &&
            entry.result!.match.songId == 'qq-1',
      ),
      isTrue,
    );

    // 登录状态变化不需要重建会话：可用性在读取时求值。
    loggedIn = true;
    expect(session.unavailableReasonOf(session.strategies.last), isNull);
  });

  test('旧查询的结果晚到：丢弃，不覆盖当前查询', () async {
    final qq = _QueuedLyricProvider('qq');
    final session = buildSession([strategy(qq)]);

    final first = session.search('晴天 周杰伦');
    final second = session.search('告白气球 周杰伦');
    expect(qq.pending, hasLength(2));

    qq.pending[1].complete([
      SongMatch(songId: 'new', title: '告白气球', artist: '周杰伦'),
    ]);
    await second;
    expect(session.resultsOf('qq').single.match.songId, 'new');

    qq.pending[0].complete([sunnyDay('old')]);
    await first;

    expect(
      session.resultsOf('qq').single.match.songId,
      'new',
      reason: '旧查询晚到的结果不能覆盖新查询',
    );
    expect(session.query, '告白气球 周杰伦');
    expect(session.stateOf('qq'), ProviderSearchState.loaded);
  });

  test('选中结果：规范化文本并写入手动歌词（provider 名保留）', () async {
    final service = _FakeLyricsService();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [sunnyDay('qq-1')],
      payload: const LyricsPayload(
        lyric: '  [00:01.00]晴天\r\n\r\n',
        translation: ' 翻译 ',
        roma: '   ',
        lxlyric: '<0,100>晴',
      ),
    );
    final session = buildSession([strategy(qq)], service: service);

    await session.search('晴天 周杰伦');
    final outcome = await session.select(session.resultsOf('qq').single);

    expect(outcome, isA<LyricsSelectionSuccess>());
    final selection = (outcome as LyricsSelectionSuccess).selection;
    expect(selection.lyrics, '[00:01.00]晴天');
    expect(selection.provider, 'qq');

    final saved = service.saved.single;
    expect(saved.trackId, 'bili:1');
    expect(saved.lyric, '[00:01.00]晴天');
    expect(saved.provider, 'qq');
    expect(saved.translation, '翻译');
    expect(saved.roma, isNull, reason: '空白扩展字段按「无」处理');
    expect(saved.lxlyric, '<0,100>晴');
    expect(session.isFetchingLyric, isFalse);
  });

  test('选中结果：无歌词 → notFound，取词抛错 → failed，并发点击 → busy', () async {
    final service = _FakeLyricsService();

    final empty = _FakeLyricProvider('empty', matches: [sunnyDay('e-1')]);
    final emptySession = buildSession([strategy(empty)], service: service);
    await emptySession.search('晴天 周杰伦');
    expect(
      await emptySession.select(emptySession.resultsOf('empty').single),
      isA<LyricsSelectionNotFound>(),
    );

    final error = StateError('network down');
    final broken = _FakeLyricProvider(
      'broken',
      matches: [sunnyDay('b-1')],
      fetchError: error,
    );
    final brokenSession = buildSession([strategy(broken)], service: service);
    await brokenSession.search('晴天 周杰伦');
    final failed = await brokenSession.select(
      brokenSession.resultsOf('broken').single,
    );
    expect(failed, isA<LyricsSelectionFailed>());
    expect((failed as LyricsSelectionFailed).error, same(error));

    final gate = Completer<void>();
    final slow = _FakeLyricProvider(
      'slow',
      matches: [sunnyDay('s-1')],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    )..fetchGate = gate;
    final slowSession = buildSession([strategy(slow)], service: service);
    await slowSession.search('晴天 周杰伦');
    final inFlight = slowSession.select(slowSession.resultsOf('slow').single);
    expect(
      await slowSession.select(slowSession.resultsOf('slow').single),
      isA<LyricsSelectionBusy>(),
    );
    gate.complete();
    expect(await inFlight, isA<LyricsSelectionSuccess>());
    expect(slowSession.isFetchingLyric, isFalse);

    expect(service.saved, hasLength(1), reason: '只有成功的一次写入缓存');
  });

  test('最佳匹配按来源各自挑选，不串组', () async {
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        sunnyDay('cover', artist: '某UP主'),
        sunnyDay('real'),
      ],
    );
    final bili = _FakeLyricProvider(
      'bili',
      matches: [SongMatch(songId: 'bili-1', title: '晴天 翻唱', artist: '某UP主')],
    );
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(bili, channelKey: 'bili'),
    ]);

    await session.search('晴天 周杰伦');

    expect(session.bestMatchOf(qq)!.match, same(qq.matches[1]));
    expect(session.bestMatchOf(bili)!.match, same(bili.matches.single));
    expect(
      session.bestMatchOf(_FakeLyricProvider('unknown')),
      isNull,
      reason: '没有结果的来源没有最佳匹配',
    );
  });

  test('空查询：清空查询与来源状态，并丢弃在途结果', () async {
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('qq-1')]);
    final session = buildSession([strategy(qq)]);

    await session.search('晴天 周杰伦');
    expect(session.query, '晴天 周杰伦');
    expect(session.allResults, isNotEmpty);

    await session.search('   ');

    expect(session.query, isEmpty);
    expect(session.allResults, isEmpty);
    expect(session.entries, isEmpty);
    expect(session.stateOf('qq'), ProviderSearchState.idle);
    expect(session.resultsOf('qq'), isEmpty);
    expect(session.isAnyProviderLoading, isFalse);

    final queued = _QueuedLyricProvider('qq');
    final waiting = buildSession([strategy(queued)]);
    final inFlight = waiting.search('晴天 周杰伦');
    expect(waiting.isAnyProviderLoading, isTrue);

    await waiting.search('');

    queued.pending.single.complete([sunnyDay('late')]);
    await inFlight;

    expect(waiting.stateOf('qq'), ProviderSearchState.idle);
    expect(waiting.allResults, isEmpty, reason: '清空后旧结果不能再落回列表');
  });
}
