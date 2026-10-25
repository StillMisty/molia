import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics_service.dart';

/// 歌词会话模块：加载/解析/去重/过期守卫/预取/手动选择。
Track _track(String id) => Track(
  id: TrackId('fake', id),
  title: 'Title $id',
  artists: [Artist(name: 'Artist $id')],
  origin: TrackOrigin.lx,
  payload: {'id': id},
);

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService({Map<String, LyricsResult?>? results})
    : _results = results ?? const {};

  final Map<String, LyricsResult?> _results;
  final Map<String, Duration> delays = {};
  final List<String> requested = [];
  final List<bool> ignoreCacheCalls = [];
  final List<({String trackId, String provider})> saved = [];
  bool manual = false;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async {
    requested.add(trackId);
    ignoreCacheCalls.add(ignoreCache);
    final delay = delays[trackId];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    return _results[trackId];
  }

  @override
  Future<bool> hasManualLyrics(String trackId) async => manual;

  @override
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName, {
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    saved.add((trackId: trackId, provider: providerName));
  }
}

/// 按调用顺序返回结果的取词服务（空 → 空 → 有词，覆盖重试路径）。
class _FlakyLyricsService extends LyricsService {
  _FlakyLyricsService(this.results);

  final List<LyricsResult?> results;
  final List<String> requested = [];
  int _call = 0;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async {
    requested.add(trackId);
    if (_call >= results.length) return null;
    return results[_call++];
  }
}

void main() {
  test('同步歌词：ready + isSynced；未同步歌词：伪时间戳 + isSynced=false', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:synced': const LyricsResult(
          lyric: '[00:01.00]hello\n[00:02.00]world',
          provider: 'fake',
        ),
        'fake:plain': const LyricsResult(
          lyric: 'hello\nworld',
          provider: 'fake',
        ),
        'fake:empty': null,
      },
    );
    final provider = LyricsProvider(service: service);

    await provider.load(_track('synced'));
    expect(provider.state.status, LyricsStatus.ready);
    expect(provider.state.isSynced, isTrue);
    expect(provider.state.lines.map((line) => line.text), ['hello', 'world']);

    await provider.load(_track('plain'));
    expect(provider.state.status, LyricsStatus.ready);
    expect(provider.state.isSynced, isFalse);
    expect(provider.state.lines, hasLength(2));

    await provider.load(_track('empty'));
    expect(provider.state.status, LyricsStatus.empty);
    expect(provider.state.lines, isEmpty);
  });

  test('B 站登录刷新：非 B 源且非手动时强制绕过缓存，手动 / B 源跳过', () async {
    final service = _FakeLyricsService(
      results: {
        'bili:1': const LyricsResult(lyric: '[00:01.00]云', provider: 'netease'),
      },
    );
    final provider = LyricsProvider(service: service);
    final track = Track(
      id: const TrackId('bili', '1'),
      title: 'B 站歌',
      artists: const [Artist(name: 'UP')],
      origin: TrackOrigin.builtin,
    );
    await provider.load(track);
    expect(service.ignoreCacheCalls, [false]);

    await provider.refreshAfterBiliLogin();
    expect(service.requested, ['bili:1', 'bili:1']);
    expect(service.ignoreCacheCalls.last, isTrue);

    service.manual = true;
    final before = service.requested.length;
    await provider.refreshAfterBiliLogin();
    expect(service.requested.length, before, reason: '手动歌词不覆盖');
  });

  test('同一曲目重复 ensure 复用结果；过期响应被丢弃', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
        'fake:b': const LyricsResult(lyric: '[00:01.00]b', provider: 'fake'),
      },
    );
    service.delays['fake:a'] = const Duration(milliseconds: 50);
    final provider = LyricsProvider(service: service);

    final slowA = provider.ensureForTrack(_track('a'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await provider.ensureForTrack(_track('b'));
    expect(provider.state.trackId, 'fake:b');

    // 慢响应回来时已被守卫丢弃，仍是 b。
    await slowA;
    expect(provider.state.trackId, 'fake:b');
    expect(provider.state.lines.single.text, 'b');

    // 同一曲目已有结果：不重复取词。
    await provider.ensureForTrack(_track('b'));
    expect(service.requested.where((id) => id == 'fake:b').length, 1);
  });

  test('ensure：曲目变化加载、同曲目 ready / loading 不重复取词', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
      },
    );
    final provider = LyricsProvider(service: service);

    await provider.ensureForTrack(_track('a'));
    await provider.ensureForTrack(_track('a'));
    expect(service.requested.where((id) => id == 'fake:a').length, 1);
    expect(provider.state.status, LyricsStatus.ready);

    // 换曲：状态先归 loading（旧行立即清空），完成后切换。
    final next = provider.ensureForTrack(_track('b'));
    expect(provider.state.trackId, 'fake:b');
    expect(provider.state.status, LyricsStatus.loading);
    expect(provider.state.lines, isEmpty);
    await next;
    expect(provider.state.status, LyricsStatus.empty);
  });

  test('ensure：空结果允许一次自动重试，之后不再打网络', () async {
    final service = _FakeLyricsService();
    final provider = LyricsProvider(service: service);
    final track = _track('flaky');

    await provider.ensureForTrack(track);
    expect(provider.state.status, LyricsStatus.empty);
    expect(service.requested.length, 1);

    // 播放快照抖动再次 ensure：同一曲目空结果自动重试一次。
    await provider.ensureForTrack(track);
    expect(service.requested.length, 2);
    expect(provider.state.status, LyricsStatus.empty);

    // 已用掉自动重试：后续重复 ensure 不再取词（避免快照抖动打网络）。
    await provider.ensureForTrack(track);
    await provider.ensureForTrack(track);
    expect(service.requested.length, 2);
  });

  test('retry：同曲目空结果后仍可显式重取', () async {
    final service = _FlakyLyricsService([
      null,
      null,
      const LyricsResult(lyric: '[00:01.00]ok', provider: 'fake'),
    ]);
    final provider = LyricsProvider(service: service);
    final track = _track('retry');

    await provider.ensureForTrack(track);
    await provider.ensureForTrack(track); // 自动重试仍空
    expect(provider.state.status, LyricsStatus.empty);

    await provider.retry();
    expect(provider.state.status, LyricsStatus.ready);
    expect(provider.state.lines.single.text, 'ok');
    expect(service.requested.where((id) => id == 'fake:retry').length, 3);
  });

  test('ensure(null) 清空会话；无曲目重复通知不重置', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
      },
    );
    final provider = LyricsProvider(service: service);
    await provider.ensureForTrack(_track('a'));
    expect(provider.state.status, LyricsStatus.ready);

    await provider.ensureForTrack(null);
    expect(provider.state.status, LyricsStatus.idle);
    expect(provider.state.trackId, isNull);

    final requestsBefore = service.requested.length;
    await provider.ensureForTrack(null);
    expect(provider.state.status, LyricsStatus.idle);
    expect(service.requested.length, requestsBefore);
  });

  test('预取：写缓存不改展示状态，且不重复请求', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:current': const LyricsResult(
          lyric: '[00:01.00]c',
          provider: 'fake',
        ),
        'fake:next': const LyricsResult(lyric: '[00:01.00]n', provider: 'fake'),
      },
    );
    final provider = LyricsProvider(service: service);

    await provider.load(_track('current'));
    await provider.preload(_track('next'));
    await provider.preload(_track('next'));

    expect(provider.state.trackId, 'fake:current');
    expect(service.requested.where((id) => id == 'fake:next').length, 1);
  });

  test('手动选择：写缓存并在仍是当前曲目时更新状态', () async {
    final service = _FakeLyricsService();
    final provider = LyricsProvider(service: service);

    await provider.load(_track('a'));
    await provider.saveManual(
      trackId: 'fake:a',
      lyric: '[00:03.00]手动歌词',
      providerName: 'qq',
    );

    expect(service.saved.single.trackId, 'fake:a');
    expect(provider.state.status, LyricsStatus.ready);
    expect(provider.state.providerName, 'qq');
    expect(provider.state.lines.single.text, '手动歌词');

    // 非当前曲目：只写缓存，不动展示状态。
    await provider.saveManual(
      trackId: 'fake:other',
      lyric: '[00:03.00]别的歌词',
      providerName: 'qq',
    );
    expect(provider.state.trackId, 'fake:a');
  });

  test('reset 清空状态', () async {
    final service = _FakeLyricsService(
      results: {
        'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
      },
    );
    final provider = LyricsProvider(service: service);
    await provider.load(_track('a'));
    expect(provider.state.status, LyricsStatus.ready);

    provider.reset();
    expect(provider.state.status, LyricsStatus.idle);
    expect(provider.state.trackId, isNull);
  });
}
