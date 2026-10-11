import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 取词链路：曲目原生优先、首个非空即返回、扩展行透传与落缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(String id) => Track(
        id: TrackId('kw', id),
        title: '歌',
        artists: const [Artist(name: '手')],
        origin: TrackOrigin.builtin,
        payload: {'songmid': id},
      );

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
    final again =
        await service.getLyrics('歌', '手', 'kw:1', track: track('1'));
    expect(again?.lyric, '[00:00.00]原生');
    expect(loaderCalls, 1);
  });

  test('原生失败回退名字搜索：首个非空即返回，不等最慢提供者', () async {
    final slow = Completer<LyricsPayload?>();
    final service = LyricsService(
      providers: [_SlowProvider(slow), _FastProvider()],
      trackLyricLoader: (t) async => null,
    );

    final result =
        await service.getLyrics('歌', '手', 'kw:2', track: track('2'));
    expect(result?.provider, 'fast');
    // 慢提供者仍在飞行：完成它不影响已返回的结果。
    slow.complete(null);
  });

  test('无 loader 时保持名字搜索行为', () async {
    final service = LyricsService(providers: [_FastProvider()]);
    final result = await service.getLyrics('歌', '手', 'kw:3');
    expect(result?.provider, 'fast');
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
      service: _StubService(const LyricsResult(
        lyric: '[00:01.00]你好',
        lxlyric: '[00:01.00]<0,200>你<200,300>好',
        provider: 'kw',
      )),
    );
    await provider.load(track('10'));
    expect(provider.state.lines.single.words, hasLength(2));
    expect(provider.state.lines.single.words!.first.text, '你');
  });
}

class _RecordingProvider extends LyricProvider {
  int searchCalls = 0;

  @override
  String get name => 'recording';

  @override
  Future<SongMatch?> search(String title, String artist) async => null;

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
      {int limit = 3}) async {
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
  Future<List<SongMatch>> searchMultiple(String title, String artist,
          {int limit = 3}) async =>
      [];

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
  Future<List<SongMatch>> searchMultiple(String title, String artist,
          {int limit = 3}) async =>
      [];

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
  }) async =>
      result;
}
