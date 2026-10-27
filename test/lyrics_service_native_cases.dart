import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_cache.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 取词链路：曲目原生优先、首个非空即返回、扩展行透传与落缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track trackFor(String sourceKey, String id) => Track(
    id: TrackId(sourceKey, id),
    title: '歌',
    artists: const [Artist(name: '手')],
    origin: TrackOrigin.builtin,
    payload: {'songmid': id},
  );

  Track track(String id) => trackFor('kw', id);

  test('曲目原生优先：loader 命中则不搜名字，并写入缓存', () async {
    var loaderCalls = 0;
    final provider = _RecordingProvider();
    final service = LyricsService(
      providers: [provider],
      trackLyricLoader: (t) async {
        loaderCalls++;
        return const LyricsResult(lyric: '[00:00.00]原生', provider: 'kw');
      },
    );

    final result = await service.getLyrics('歌', '手', 'kw:1', track: track('1'));
    expect(result?.provider, 'kw');
    expect(loaderCalls, 1);
    expect(provider.searchCalls, 0);

    // 缓存命中：不再调 loader。
    final again = await service.getLyrics('歌', '手', 'kw:1', track: track('1'));
    expect(again?.lyric, '[00:00.00]原生');
    expect(loaderCalls, 1);
  });

  test('原生失败回退名字搜索：首个非空即返回，不等最慢提供者', () async {
    final slow = Completer<LyricsPayload?>();
    final service = LyricsService(
      providers: [_SlowProvider(slow), _FastProvider()],
      trackLyricLoader: (t) async => null,
    );

    final result = await service.getLyrics('歌', '手', 'kw:2', track: track('2'));
    expect(result?.provider, 'fast');
    // 慢提供者仍在飞行：完成它不影响已返回的结果。
    slow.complete(null);
  });

  test('无 loader 时保持名字搜索行为', () async {
    final service = LyricsService(providers: [_FastProvider()]);
    final result = await service.getLyrics('歌', '手', 'kw:3');
    expect(result?.provider, 'fast');
  });

  test('同源优先：其它渠道更快也等本渠道（预算内）', () async {
    final service = LyricsService(
      providers: [
        _ChannelProvider(
          'qq',
          'tx',
          result: const LyricsPayload(lyric: '[00:00.00]QQ'),
          delay: const Duration(milliseconds: 40),
        ),
        _ChannelProvider(
          'netease',
          'wy',
          result: const LyricsPayload(lyric: '[00:00.00]WY'),
        ),
      ],
      trackLyricLoader: (t) async => null,
    );

    final result = await service.getLyrics(
      '歌',
      '手',
      'tx:src-1',
      track: trackFor('tx', 'src-1'),
    );
    expect(result?.provider, 'qq');
    expect(result?.lyric, '[00:00.00]QQ');
  });

  test('同源为空立即回退其它渠道', () async {
    final service = LyricsService(
      providers: [
        _ChannelProvider('qq', 'tx'),
        _ChannelProvider(
          'netease',
          'wy',
          result: const LyricsPayload(lyric: '[00:00.00]WY'),
        ),
      ],
      trackLyricLoader: (t) async => null,
    );

    final result = await service.getLyrics(
      '歌',
      '手',
      'tx:src-2',
      track: trackFor('tx', 'src-2'),
    );
    expect(result?.provider, 'netease');
  });

  test('同源抛错回退其它渠道', () async {
    final service = LyricsService(
      providers: [
        _ChannelProvider('qq', 'tx', throws: true),
        _ChannelProvider(
          'netease',
          'wy',
          result: const LyricsPayload(lyric: '[00:00.00]WY'),
        ),
      ],
      trackLyricLoader: (t) async => null,
    );

    final result = await service.getLyrics(
      '歌',
      '手',
      'tx:src-3',
      track: trackFor('tx', 'src-3'),
    );
    expect(result?.provider, 'netease');
  });

  test('同源超时：预算到点后用其它渠道', () async {
    final pending = Completer<LyricsPayload?>();
    final service = LyricsService(
      providers: [
        _ChannelProvider('qq', 'tx', pending: pending.future),
        _ChannelProvider(
          'netease',
          'wy',
          result: const LyricsPayload(lyric: '[00:00.00]WY'),
        ),
      ],
      trackLyricLoader: (t) async => null,
      sameSourceTimeout: const Duration(milliseconds: 30),
    );

    final result = await service.getLyrics(
      '歌',
      '手',
      'tx:src-4',
      track: trackFor('tx', 'src-4'),
    );
    expect(result?.provider, 'netease');
  });

  test('同源晚到仍可作为兜底', () async {
    final pending = Completer<LyricsPayload?>();
    final service = LyricsService(
      providers: [
        _ChannelProvider('qq', 'tx', pending: pending.future),
        _ChannelProvider('netease', 'wy'),
      ],
      trackLyricLoader: (t) async => null,
      sameSourceTimeout: const Duration(milliseconds: 20),
    );

    final future = service.getLyrics(
      '歌',
      '手',
      'tx:src-5',
      track: trackFor('tx', 'src-5'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    pending.complete(const LyricsPayload(lyric: '[00:00.00]QQ late'));
    expect((await future)?.provider, 'qq');
  });

  test('跨渠道缓存命中：不再请求本渠道', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);
    await cache.write(
      'tx:src-6',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:00.00]WY cached',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    final qq = _ChannelProvider(
      'qq',
      'tx',
      result: const LyricsPayload(lyric: '[00:00.00]QQ'),
    );
    final service = LyricsService(
      providers: [qq],
      lyricsCache: cache,
      trackLyricLoader: (t) async => null,
    );

    final result = await service.getLyrics(
      '歌',
      '手',
      'tx:src-6',
      track: trackFor('tx', 'src-6'),
    );
    expect(result?.provider, 'netease');
    expect(qq.getLyricsCalls, 0);
  });

  test('B 站登录后：缓存来源不同源则先试原生（忽略手动缓存）', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);
    final biliTrack = Track(
      id: const TrackId('bili', '1'),
      title: 'B 站歌',
      artists: const [Artist(name: 'UP')],
      origin: TrackOrigin.builtin,
    );
    await cache.write(
      'bili:1',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:01.00]网易云',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    var loaderCalls = 0;
    final service = LyricsService(
      providers: const [],
      lyricsCache: cache,
      trackLyricLoader: (t) async {
        loaderCalls++;
        return const LyricsResult(lyric: '[00:02.00]B 站', provider: 'bili');
      },
      nativeLyricAvailable: (t) => true,
    );

    final result = await service.getLyrics(
      'B 站歌',
      'UP',
      'bili:1',
      track: biliTrack,
    );
    expect(result?.provider, 'bili');
    expect(loaderCalls, 1);
  });

  test('B 站未登录：沿用缓存，不触原生', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);
    final biliTrack = Track(
      id: const TrackId('bili', '2'),
      title: 'B 站歌',
      artists: const [Artist(name: 'UP')],
      origin: TrackOrigin.builtin,
    );
    await cache.write(
      'bili:2',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:01.00]网易云',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    var loaderCalls = 0;
    final service = LyricsService(
      providers: const [],
      lyricsCache: cache,
      trackLyricLoader: (t) async {
        loaderCalls++;
        return const LyricsResult(lyric: '[00:02.00]B 站', provider: 'bili');
      },
      nativeLyricAvailable: (t) => false,
    );

    final result = await service.getLyrics(
      'B 站歌',
      'UP',
      'bili:2',
      track: biliTrack,
    );
    expect(result?.provider, 'netease');
    expect(loaderCalls, 0);
  });

  test('手动选择歌词不会被 B 站同源刷新覆盖', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);
    final service = LyricsService(
      providers: const [],
      lyricsCache: cache,
      trackLyricLoader: (t) async =>
          const LyricsResult(lyric: '[00:02.00]B 站', provider: 'bili'),
      nativeLyricAvailable: (t) => true,
    );
    await service.saveLyrics('bili:3', '[00:03.00]手动', 'netease');
    expect(await service.hasManualLyrics('bili:3'), isTrue);

    final biliTrack = Track(
      id: const TrackId('bili', '3'),
      title: 'B 站歌',
      artists: const [Artist(name: 'UP')],
      origin: TrackOrigin.builtin,
    );
    final result = await service.getLyrics(
      'B 站歌',
      'UP',
      'bili:3',
      track: biliTrack,
    );
    expect(result?.lyric, '[00:03.00]手动');
  });

  test('ignoreCache：跳过缓存强制取原生', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);
    final biliTrack = Track(
      id: const TrackId('bili', '4'),
      title: 'B 站歌',
      artists: const [Artist(name: 'UP')],
      origin: TrackOrigin.builtin,
    );
    await cache.write(
      'bili:4',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:01.00]网易云',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    var loaderCalls = 0;
    final service = LyricsService(
      providers: const [],
      lyricsCache: cache,
      trackLyricLoader: (t) async {
        loaderCalls++;
        return const LyricsResult(lyric: '[00:02.00]B 站', provider: 'bili');
      },
      nativeLyricAvailable: (t) => false,
    );

    final result = await service.getLyrics(
      'B 站歌',
      'UP',
      'bili:4',
      track: biliTrack,
      ignoreCache: true,
    );
    expect(result?.provider, 'bili');
    expect(loaderCalls, 1);
  });

  test('saveLyrics 透传翻译 / 罗马音 / 逐字（缓存可读回）', () async {
    final service = LyricsService(providers: const []);
    await service.saveLyrics(
      'kw:9',
      '[00:00.00]主',
      'kw',
      translation: '[00:00.00]译',
      lxlyric: '[00:00.00]<0,100>主',
    );

    final result = await service.getLyrics('x', 'y', 'kw:9');
    expect(result?.translation, '[00:00.00]译');
    expect(result?.lxlyric, contains('<0,100>'));
  });

  test('LyricsState 行携带逐字时间轴（lxlyric 对齐）', () async {
    final provider = LyricsProvider(
      service: _StubService(
        const LyricsResult(
          lyric: '[00:01.00]你好',
          lxlyric: '[00:01.00]<0,200>你<200,300>好',
          provider: 'kw',
        ),
      ),
    );
    await provider.load(track('10'));
    expect(provider.state.lines.single.words, hasLength(2));
    expect(provider.state.lines.single.words!.first.text, '你');
  });
}

/// 可指定渠道 / 结果 / 延迟 / 异常 / 挂起的歌词提供者。
class _ChannelProvider extends LyricProvider {
  _ChannelProvider(
    this._name,
    this._channelKey, {
    this.result,
    this.pending,
    this.delay = Duration.zero,
    this.throws = false,
  });

  final String _name;
  final String _channelKey;
  final LyricsPayload? result;
  final Future<LyricsPayload?>? pending;
  final Duration delay;
  final bool throws;
  int getLyricsCalls = 0;

  @override
  String get name => _name;

  @override
  String get channelKey => _channelKey;

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async => [];

  @override
  Future<String?> fetchLyric(String songId) async => null;

  @override
  Future<LyricsPayload?> getLyrics(String title, String artist) async {
    getLyricsCalls++;
    if (pending != null) return pending;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (throws) throw StateError('boom');
    return result;
  }
}

class _RecordingProvider extends LyricProvider {
  int searchCalls = 0;

  @override
  String get name => 'recording';

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async {
    searchCalls++;
    return [];
  }

  @override
  Future<String?> fetchLyric(String songId) async => null;
}

class _SlowProvider extends LyricProvider {
  _SlowProvider(this.completer);

  final Completer<LyricsPayload?> completer;

  @override
  String get name => 'slow';

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async => [];

  @override
  Future<String?> fetchLyric(String songId) async => null;

  @override
  Future<LyricsPayload?> getLyrics(String title, String artist) =>
      completer.future;
}

class _FastProvider extends LyricProvider {
  @override
  String get name => 'fast';

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async => [];

  @override
  Future<String?> fetchLyric(String songId) async => null;

  @override
  Future<LyricsPayload?> getLyrics(String title, String artist) async =>
      const LyricsPayload(lyric: '[00:00.00]快');
}

class _StubService extends LyricsService {
  _StubService(this.result);

  final LyricsResult? result;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async => result;
}
