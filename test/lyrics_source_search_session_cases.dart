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
  LyricsPayload? payload;
  Object? fetchError;

  /// 按 songId 覆盖 payload（预览快速切换时验证旧结果被丢弃）。
  final Map<String, LyricsPayload?> payloads = {};

  /// 非空时搜索直接抛错（验证失败来源与重试）。
  Object? searchError;
  int searchCalls = 0;
  int fetchCalls = 0;

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
    final error = searchError;
    if (error != null) throw error;
    return matches.take(limit).toList();
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    fetchCalls++;
    final gate = fetchGate;
    if (gate != null) await gate.future;
    if (fetchError != null) throw fetchError!;
    return payloads.containsKey(match.songId)
        ? payloads[match.songId]
        : payload;
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
    List<String>? channelOrder,
    String? album,
    Duration? duration,
    bool disposeOnTearDown = true,
  }) {
    final lyricsProvider = LyricsProvider(
      service: service ?? _FakeLyricsService(),
    );
    if (disposeOnTearDown) addTearDown(lyricsProvider.dispose);
    final session = LyricsSourceSearchSession(
      strategies: sources,
      enabledChannelKeys: enabledChannelKeys,
      channelOrder: channelOrder,
      lyricsProvider: lyricsProvider,
      trackId: 'bili:1',
      trackTitle: '晴天',
      trackArtist: '周杰伦',
      trackAlbum: album,
      trackDuration: duration,
    );
    if (disposeOnTearDown) addTearDown(session.dispose);
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

  test('渠道开关过滤：停用渠道不进会话，非渠道来源不受影响', () {
    final session = buildSession(
      [
        strategy(_FakeLyricProvider('enabled'), channelKey: 'enabled'),
        strategy(_FakeLyricProvider('disabled'), channelKey: 'disabled'),
        strategy(
          _FakeLyricProvider('external'),
          channelKey: 'external',
          isChannel: false,
        ),
      ],
      enabledChannelKeys: {'enabled'},
    );

    expect(session.strategies.map((strategy) => strategy.channelKey), [
      'enabled',
      'external',
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
    ], reason: '不可用来源即使没有结果也要出 header 挂登录提示');
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
    expect(
      session.entries
          .where((entry) => entry.type == LyricsSearchEntryType.header)
          .map((entry) => entry.strategy!.channelKey),
      ['tx'],
      reason: '登录后 B 站不再有不可用原因，空结果不强行出标题',
    );
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

  test('选中拉预览但不写缓存；确认复用预览 payload 后规范化写入手动歌词', () async {
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
    final result = session.resultsOf('qq').single;
    session.select(result);

    expect(session.isSelected(result), isTrue);
    expect(service.saved, isEmpty, reason: '点选不写缓存');
    await Future<void>.delayed(Duration.zero);
    expect(session.preview?.status, LyricsPreviewStatus.ready);
    expect(qq.fetchCalls, 1, reason: '点选只拉预览');

    final outcome = await session.applySelected();

    expect(outcome, isA<LyricsSelectionSuccess>());
    expect(qq.fetchCalls, 1, reason: '确认复用预览 payload，不重复取词');
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

  test('确认：无选中 → none，无歌词 → notFound，取词抛错 → failed，并发 → busy', () async {
    final service = _FakeLyricsService();

    final empty = _FakeLyricProvider('empty', matches: [sunnyDay('e-1')]);
    final emptySession = buildSession([strategy(empty)], service: service);
    expect(
      await emptySession.applySelected(),
      isA<LyricsSelectionNone>(),
      reason: '未选中时确认只 no-op',
    );
    await emptySession.search('晴天 周杰伦');
    emptySession.select(emptySession.resultsOf('empty').single);
    expect(await emptySession.applySelected(), isA<LyricsSelectionNotFound>());

    final error = StateError('network down');
    final broken = _FakeLyricProvider(
      'broken',
      matches: [sunnyDay('b-1')],
      fetchError: error,
    );
    final brokenSession = buildSession([strategy(broken)], service: service);
    await brokenSession.search('晴天 周杰伦');
    brokenSession.select(brokenSession.resultsOf('broken').single);
    final failed = await brokenSession.applySelected();
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
    slowSession.select(slowSession.resultsOf('slow').single);
    final inFlight = slowSession.applySelected();
    expect(await slowSession.applySelected(), isA<LyricsSelectionBusy>());
    gate.complete();
    expect(await inFlight, isA<LyricsSelectionSuccess>());
    expect(slowSession.isFetchingLyric, isFalse);

    expect(service.saved, hasLength(1), reason: '只有成功的一次写入缓存');
  });

  test('取词在途：select 与 search 都不改当前选中/查询/结果', () async {
    final service = _FakeLyricsService();
    final gate = Completer<void>();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        sunnyDay('A'),
        SongMatch(songId: 'B', title: '晴天 B', artist: '周杰伦'),
      ],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    )..fetchGate = gate;
    final session = buildSession([strategy(qq)], service: service);

    await session.search('晴天 周杰伦');
    final results = session.resultsOf('qq');
    session.select(results.first);
    final pending = session.applySelected();
    expect(session.isFetchingLyric, isTrue);

    // 界面上可能排队的回调：都不能改选中项 / 清掉结果。
    session.select(results.last);
    await session.search('另一首歌');

    expect(session.isSelected(results.first), isTrue);
    expect(session.query, '晴天 周杰伦');
    expect(session.resultsOf('qq'), hasLength(2));

    gate.complete();
    expect(await pending, isA<LyricsSelectionSuccess>());
    expect(qq.fetchCalls, 1, reason: '只取确认时的 A');
    expect(service.saved, hasLength(1));
  });

  test('search 开始清空选中；retryFailed 只重搜失败源', () async {
    final service = _FakeLyricsService();
    final good = _FakeLyricProvider('good', matches: [sunnyDay('g-1')]);
    final flaky = _FakeLyricProvider('flaky', matches: [sunnyDay('f-1')])
      ..searchError = StateError('network down');
    final session = buildSession([
      strategy(good),
      strategy(flaky),
    ], service: service);

    await session.search('晴天 周杰伦');
    expect(session.failedStrategies.map((item) => item.provider.name), [
      'flaky',
    ]);
    session.select(session.resultsOf('good').single);
    expect(session.selected, isNotNull);

    await session.search('晴天');
    expect(session.selected, isNull, reason: '新查询不能留着旧选中项');

    flaky.searchError = null;
    final goodCalls = good.searchCalls;
    await session.retryFailed();

    expect(session.stateOf('flaky'), ProviderSearchState.loaded);
    expect(session.resultsOf('flaky').single.match.songId, 'f-1');
    expect(session.failedStrategies, isEmpty);
    expect(good.searchCalls, goodCalls, reason: '重试不重搜成功来源');
  });

  test('entriesFor：全部列出有结果或有不可用原因的来源，单源不要 header', () async {
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        sunnyDay('qq-1'),
        SongMatch(songId: 'qq-2', title: '晴天 live', artist: '周杰伦'),
      ],
    );
    final bili = _FakeLyricProvider('bili');
    final empty = _FakeLyricProvider('empty');
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(
        bili,
        channelKey: 'bili',
        unavailable: () => LyricsSourceUnavailable.biliLoginRequired,
      ),
      strategy(empty, channelKey: 'wy'),
    ]);

    await session.search('晴天 周杰伦');

    final all = session.entriesFor(null);
    expect(
      all
          .where((entry) => entry.type == LyricsSearchEntryType.header)
          .map((entry) => entry.strategy!.channelKey),
      ['tx', 'bili'],
      reason: '有结果的 tx 与未登录 B 站都出 header；普通空来源不出',
    );
    expect(
      all.where((entry) => entry.type == LyricsSearchEntryType.result).length,
      2,
    );

    final single = session.entriesFor('tx');
    expect(single, hasLength(2));
    expect(
      single.every((entry) => entry.type == LyricsSearchEntryType.result),
      isTrue,
      reason: '单源筛选不再重复分组头',
    );
    expect(session.entriesFor('bili'), isEmpty);
    expect(session.entriesFor('unknown'), isEmpty);
  });

  test('来源筛选由会话持有：空串 = 全部，跨搜索 / 选中保留且只影响展示', () async {
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('qq-1')]);
    final wy = _FakeLyricProvider(
      'wy',
      matches: [SongMatch(songId: 'wy-1', title: '晴天 网易', artist: '周杰伦')],
    );
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(wy, channelKey: 'wy'),
    ]);

    await session.search('晴天 周杰伦');
    expect(session.activeSourceKey, isEmpty, reason: '默认全部');
    expect(
      session.entries
          .where((entry) => entry.type == LyricsSearchEntryType.result)
          .map((entry) => entry.result!.match.songId),
      ['qq-1', 'wy-1'],
    );

    session.selectSource('tx');
    expect(session.activeSourceKey, 'tx');
    expect(
      session.entries.every(
        (entry) => entry.type == LyricsSearchEntryType.result,
      ),
      isTrue,
      reason: '单源筛选不重复分组头',
    );
    expect(session.entries.map((entry) => entry.result!.match.songId), [
      'qq-1',
    ]);
    expect(session.resultsOf('wy'), isNotEmpty, reason: '筛选只影响展示，不丢其它来源结果');

    // 选中与筛选互不影响：切筛选不改选中，选中也不复位筛选。
    session.select(session.resultsOf('qq').single);
    expect(session.selected, isNotNull);
    expect(session.activeSourceKey, 'tx');

    await session.search('告白气球');
    expect(session.activeSourceKey, 'tx', reason: '新搜索保留筛选');
    expect(session.entries.map((entry) => entry.result!.match.songId), [
      'qq-1',
    ]);

    await session.search('');
    expect(session.activeSourceKey, 'tx', reason: '清空查询也保留筛选');
    expect(session.entries, isEmpty);

    session.selectSource('');
    expect(session.activeSourceKey, isEmpty);
    expect(session.entriesFor(), isEmpty, reason: '清空查询后「全部」也没有条目');
  });

  test('筛选到无结果 / 陌生来源：列表为空，分组头只在全部模式出现', () async {
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('qq-1')]);
    final bili = _FakeLyricProvider('bili');
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(
        bili,
        channelKey: 'bili',
        unavailable: () => LyricsSourceUnavailable.biliLoginRequired,
      ),
    ]);

    await session.search('晴天 周杰伦');
    expect(
      session.entries
          .where((entry) => entry.type == LyricsSearchEntryType.header)
          .map((entry) => entry.strategy!.channelKey),
      ['tx', 'bili'],
      reason: '全部模式保留未登录 B 站的提示头',
    );

    session.selectSource('bili');
    expect(session.entries, isEmpty, reason: '单源筛选不重复分组头；未登录 B 站没有结果');
    expect(session.unavailableReasons, [
      LyricsSourceUnavailable.biliLoginRequired,
    ], reason: '空态登录提示仍可读');

    session.selectSource('unknown');
    expect(session.activeSourceKey, 'unknown');
    expect(session.entries, isEmpty, reason: '陌生 key 不匹配任何来源');
    expect(session.resultsOf('qq'), isNotEmpty, reason: '陌生筛选只影响展示，不清其它来源结果');
  });

  test('selectSource 只在筛选变化时通知，且不改查询 / 选中', () async {
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('qq-1')]);
    final session = buildSession([strategy(qq, channelKey: 'tx')]);

    await session.search('晴天 周杰伦');
    final result = session.resultsOf('qq').single;
    session.select(result);

    var notifications = 0;
    session.addListener(() => notifications++);

    session.selectSource('tx');
    expect(notifications, 1);
    session.selectSource('tx');
    expect(notifications, 1, reason: '同一筛选不重复通知');
    session.selectSource('');
    expect(notifications, 2);

    expect(session.query, '晴天 周杰伦');
    expect(session.selected, same(result), reason: '切筛选不丢选中项');
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

  test('每源抓 10 条；最佳匹配排组内第一并进入全部模式前 3 条预览', () async {
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        for (var index = 0; index < 12; index++)
          if (index == 3)
            SongMatch(
              songId: 'best',
              title: '晴天',
              artist: '周杰伦',
              album: '叶惠美',
              duration: const Duration(minutes: 4, seconds: 29),
            )
          else
            SongMatch(
              songId: 'qq-$index',
              title: '晴天 翻唱$index',
              artist: '某UP主',
              duration: Duration(minutes: 3, seconds: index),
            ),
      ],
    );
    final session = buildSession(
      [strategy(qq)],
      album: '叶惠美',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    await session.search('晴天 周杰伦');

    expect(session.resultsOf('qq'), hasLength(10), reason: '每源最多抓 10 条');
    expect(
      session.resultsOf('qq').first.match.songId,
      'best',
      reason: '最佳匹配排到组内第一',
    );
    final previewResults = session.entries
        .where((entry) => entry.type == LyricsSearchEntryType.result)
        .toList();
    expect(previewResults, hasLength(3), reason: '全部模式每组只预览前 3 条');
    expect(previewResults.first.result!.match.songId, 'best');
    expect(session.displayedCountOf('qq'), 3);
    expect(session.hasMoreOf(session.strategies.single), isTrue);

    session.selectSource('qq');
    expect(session.displayedCountOf('qq'), 10);
    expect(
      session.hasMoreOf(session.strategies.single),
      isFalse,
      reason: '单源模式展示完整结果，不再有「查看全部」',
    );
  });

  test('全部模式只标记一个全局最佳；单源模式只标记该来源最佳', () async {
    final qqBest = SongMatch(
      songId: 'qq-best',
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );
    final biliBest = SongMatch(
      songId: 'bili-best',
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        SongMatch(songId: 'qq-other', title: '晴天 翻唱', artist: '某UP主'),
        qqBest,
      ],
    );
    final bili = _FakeLyricProvider(
      'bili',
      matches: [
        SongMatch(songId: 'bili-other', title: '晴天 现场', artist: '某UP主'),
        biliBest,
      ],
    );
    final session = buildSession([
      strategy(qq, channelKey: 'tx'),
      strategy(bili, channelKey: 'bili'),
    ]);

    await session.search('晴天 周杰伦');

    expect(session.bestMatchOf(qq)!.match, same(qqBest));
    expect(session.bestMatchOf(bili)!.match, same(biliBest));
    expect(
      session.isBestMatch(session.resultsOf('qq').first),
      isTrue,
      reason: '全部模式只有一个全局最佳',
    );
    expect(
      session.allResults.where((result) => session.isBestMatch(result)).length,
      1,
    );

    session.selectSource('tx');
    expect(session.isBestMatch(session.resultsOf('qq').first), isTrue);
    expect(session.isBestMatch(session.resultsOf('bili').first), isFalse);

    session.selectSource('bili');
    expect(session.isBestMatch(session.resultsOf('bili').first), isTrue);
    expect(session.isBestMatch(session.resultsOf('qq').first), isFalse);
  });

  test('来源顺序跟随 channelOrder：已知渠道按表，未知渠道随后，非渠道最后', () {
    LyricsSourceStrategy source(
      String name,
      String key, {
      bool channel = true,
    }) =>
        strategy(_FakeLyricProvider(name), channelKey: key, isChannel: channel);

    final declared = [
      source('lrclib', 'lrclib', channel: false),
      source('bili', 'bili'),
      source('netease', 'wy'),
      source('qq', 'tx'),
      source('custom', 'custom'),
    ];

    final first = buildSession(declared, channelOrder: ['wy', 'tx', 'kg']);
    expect(first.strategies.map((item) => item.channelKey), [
      'wy',
      'tx',
      'bili',
      'custom',
      'lrclib',
    ]);

    final second = buildSession(declared, channelOrder: ['bili', 'wy']);
    expect(second.strategies.map((item) => item.channelKey), [
      'bili',
      'wy',
      'tx',
      'custom',
      'lrclib',
    ], reason: '重新提供渠道顺序时按新顺序排列，非渠道仍最后');
  });

  test('预览：loading → ready、快速切换丢弃旧结果、缓存按 provider+songId 复用', () async {
    final gate = Completer<void>();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        SongMatch(songId: 'A', title: '晴天 A', artist: '周杰伦'),
        SongMatch(songId: 'B', title: '晴天 B', artist: '周杰伦'),
      ],
    )..fetchGate = gate;
    qq.payloads['A'] = const LyricsPayload(
      lyric:
          '[ti:晴天]\n'
          '[00:01.00]第一句\n'
          '[00:02.00]第二句\n'
          '[00:03.00]第三句\n'
          '[00:04.00]第四句',
    );
    qq.payloads['B'] = const LyricsPayload(
      lyric: '[ti:晴天]\n[ar:周杰伦]\n\n第一行\n第二行\n第三行\n第四行',
    );
    final session = buildSession([strategy(qq)]);

    await session.search('晴天 周杰伦');
    final results = session.resultsOf('qq');
    session.select(results.first);
    expect(session.preview?.status, LyricsPreviewStatus.loading);
    expect(session.isSelectedVisible, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(qq.fetchCalls, 1, reason: 'A 的预览请求已经发出');

    // 第一段请求还没回来就点另一条：只保留 B 的预览。
    session.select(results.last);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(session.preview?.status, LyricsPreviewStatus.ready);
    expect(session.preview!.lines, ['第一行', '第二行', '第三行']);
    expect(qq.fetchCalls, 2, reason: '两条都发过请求，但只有当前选中项落地');

    // B 已缓存：点回来不再请求；A 的结果被代际丢弃，需要重新取词。
    session.select(results.last);
    expect(session.preview!.lines, ['第一行', '第二行', '第三行']);
    expect(qq.fetchCalls, 2);
    session.select(results.first);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(session.preview!.lines, ['第一句', '第二句', '第三句']);
    expect(qq.fetchCalls, 3);
  });

  test('预览空：状态 empty，确认时重新取词一次', () async {
    final service = _FakeLyricsService();
    final qq = _FakeLyricProvider('qq', matches: [sunnyDay('empty')]);
    final session = buildSession([strategy(qq)], service: service);

    await session.search('晴天 周杰伦');
    session.select(session.resultsOf('qq').single);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(session.preview?.status, LyricsPreviewStatus.empty);
    final outcome = await session.applySelected();

    expect(outcome, isA<LyricsSelectionNotFound>());
    expect(qq.fetchCalls, 2, reason: '预览为空时确认重新取词一次');
    expect(service.saved, isEmpty);
  });

  test('预览失败：状态 failed、重试成功；失败后确认也会重新取词', () async {
    final service = _FakeLyricsService();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: 'A', title: '晴天', artist: '周杰伦')],
      fetchError: StateError('preview down'),
    );
    final session = buildSession([strategy(qq)], service: service);

    await session.search('晴天 周杰伦');
    session.select(session.resultsOf('qq').single);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(session.preview?.status, LyricsPreviewStatus.failed);

    qq
      ..fetchError = null
      ..payload = const LyricsPayload(lyric: '[00:01.00]晴天');
    session.retryPreview();
    expect(session.preview?.status, LyricsPreviewStatus.loading);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(session.preview?.status, LyricsPreviewStatus.ready);
    expect(qq.fetchCalls, 2);

    // 另一轮：失败状态下直接确认，确认内部重新取词一次。
    final broken = _FakeLyricProvider(
      'broken',
      matches: [SongMatch(songId: 'B', title: '晴天 B', artist: '周杰伦')],
      fetchError: StateError('preview down'),
    );
    final brokenSession = buildSession([strategy(broken)], service: service);
    await brokenSession.search('晴天 周杰伦');
    brokenSession.select(brokenSession.resultsOf('broken').single);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(brokenSession.preview?.status, LyricsPreviewStatus.failed);

    broken
      ..fetchError = null
      ..payload = const LyricsPayload(lyric: '[00:01.00]晴天');
    final outcome = await brokenSession.applySelected();
    expect(outcome, isA<LyricsSelectionSuccess>());
    expect(broken.fetchCalls, 2);
  });

  test('dispose 后预览请求晚到：不通知、不抛错', () async {
    final gate = Completer<void>();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [sunnyDay('A')],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    )..fetchGate = gate;
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final session = LyricsSourceSearchSession(
      strategies: [strategy(qq)],
      lyricsProvider: lyricsProvider,
      trackId: 'bili:1',
      trackTitle: '晴天',
      trackArtist: '周杰伦',
    );
    await session.search('晴天 周杰伦');
    session.select(session.resultsOf('qq').single);
    await Future<void>.delayed(Duration.zero);
    expect(qq.fetchCalls, 1, reason: '预览请求已经发出');

    session.dispose();
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(qq.fetchCalls, 1, reason: '请求已经发出，但结果被 dispose 丢弃');
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
