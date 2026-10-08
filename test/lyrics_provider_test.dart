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
  final List<({String trackId, String provider})> saved = [];

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId,
  ) async {
    requested.add(trackId);
    final delay = delays[trackId];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    return _results[trackId];
  }

  @override
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName,
  ) async {
    saved.add((trackId: trackId, provider: providerName));
  }
}

void main() {
  test('同步歌词：ready + isSynced；未同步歌词：伪时间戳 + isSynced=false', () async {
    final service = _FakeLyricsService(results: {
      'fake:synced': const LyricsResult(
          lyric: '[00:01.00]hello\n[00:02.00]world', provider: 'fake'),
      'fake:plain': const LyricsResult(lyric: 'hello\nworld', provider: 'fake'),
      'fake:empty': null,
    });
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

  test('同一曲目重复加载复用结果；过期响应被丢弃', () async {
    final service = _FakeLyricsService(results: {
      'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
      'fake:b': const LyricsResult(lyric: '[00:01.00]b', provider: 'fake'),
    });
    service.delays['fake:a'] = const Duration(milliseconds: 50);
    final provider = LyricsProvider(service: service);

    final slowA = provider.load(_track('a'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await provider.load(_track('b'));
    expect(provider.state.trackId, 'fake:b');

    // 慢响应回来时已被守卫丢弃，仍是 b。
    await slowA;
    expect(provider.state.trackId, 'fake:b');
    expect(provider.state.lines.single.text, 'b');

    // 同一曲目已有结果：不重复取词。
    await provider.load(_track('b'));
    expect(service.requested.where((id) => id == 'fake:b').length, 1);
  });

  test('预取：写缓存不改展示状态，且不重复请求', () async {
    final service = _FakeLyricsService(results: {
      'fake:current': const LyricsResult(lyric: '[00:01.00]c', provider: 'fake'),
      'fake:next': const LyricsResult(lyric: '[00:01.00]n', provider: 'fake'),
    });
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
    final service = _FakeLyricsService(results: {
      'fake:a': const LyricsResult(lyric: '[00:01.00]a', provider: 'fake'),
    });
    final provider = LyricsProvider(service: service);
    await provider.load(_track('a'));
    expect(provider.state.status, LyricsStatus.ready);

    provider.reset();
    expect(provider.state.status, LyricsStatus.idle);
    expect(provider.state.trackId, isNull);
  });
}
