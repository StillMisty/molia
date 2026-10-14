import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/lyrics/qq_provider.dart';
import 'package:molia/services/lyrics/netease_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/mock_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('LyricsService Tests', () {
    test('QQ Provider can search and fetch lyrics', () async {
      final mockClient = mockDio((request) async {
        final path = request.uri.path;
        if (path.contains('musicu.fcg')) {
          final response = {
            'req': {
              'data': {
                'body': {
                  'song': {
                    'list': [
                      {
                        'mid': 'mock-song-id',
                        'title': '你瞒我瞒',
                        'singer': [
                          {'name': '陈柏宇'}
                        ],
                      }
                    ],
                  },
                },
              },
            },
          };
          // 先编码为 UTF-8 字节，避免 QQProvider 内 utf8.decode 遇到非法字符。
          final bodyBytes = utf8.encode(jsonEncode(response));
          return bytesResponse(bodyBytes, statusCode: 200,
              headers: {
                'content-type': ['application/json; charset=utf-8']
              });
        }

        if (path.contains('fcg_query_lyric_new')) {
          final response = {'lyric': '[00:00]你瞒我瞒'};
          final bodyBytes = utf8.encode(jsonEncode(response));
          return bytesResponse(bodyBytes,
              statusCode: 200,
              headers: {
                'content-type': ['application/json']
              });
        }

        return textResponse('Not Found', statusCode: 404);
      });

      final provider = QQProvider(dio: mockClient);
      final songMatch = await provider.search('Bohemian Rhapsody', 'Queen');

      expect(songMatch, isNotNull);
      if (songMatch != null) {
        expect(songMatch.title, '你瞒我瞒');
        expect(songMatch.artist, '陈柏宇');
        final lyrics = await provider.fetchLyric(songMatch.songId);
        expect(lyrics, isNotNull);

        if (lyrics != null) {
          expect(lyrics.contains('['), isTrue);
          expect(lyrics.contains(']'), isTrue);
          expect(lyrics.contains('你瞒我瞒'), isTrue);
        }
      }
    });

    // 网易云API需要登录，所以这个测试可能会失败
    // 我们将其标记为skip
    test('NetEase Provider can search and fetch lyrics', () async {
      final provider = NetEaseProvider();
      final songMatch = await provider.search('Bohemian Rhapsody', 'Queen');

      // 如果API需要登录，这里可能返回null
      if (songMatch != null) {
        final lyrics = await provider.fetchLyric(songMatch.songId);
        if (lyrics != null) {
          expect(lyrics.contains('['), isTrue);
          expect(lyrics.contains(']'), isTrue);
        }
      } else {
        debugPrint('网易云API需要登录，跳过测试');
      }
    }, skip: '网易云API可能需要登录');

    test('LyricsService can get lyrics from multiple providers', () async {
      final service = LyricsService(providers: [_FakeLyricProvider()]);
      final result = await service.getLyrics(
          'Bohemian Rhapsody', 'Queen', 'test_track_id');

      expect(result, isNotNull);
      if (result != null) {
        expect(result.lyric.contains('['), isTrue);
        expect(result.lyric.contains(']'), isTrue);
        expect(result.provider, equals('fake'));
      }
    });

    test('提供者全部失败时只请求一轮（不重复取词）', () async {
      final first = _CountingProvider(name: 'first', result: null);
      final second = _CountingProvider(name: 'second', result: null);
      final service = LyricsService(providers: [first, second]);

      final result =
          await service.getLyrics('Bohemian Rhapsody', 'Queen', 'no_result');

      expect(result, isNull);
      expect(first.calls, 1);
      expect(second.calls, 1);
    });

    test('网络回退开关：本地下载曲目无离线歌词时跳过网络提供者', () async {
      final counting = _CountingProvider(name: 'counting', result: 'lyric');
      final service = LyricsService(
        providers: [counting],
        networkFallbackAllowed: (track) => track.id.sourceKey != 'local',
      );

      const localTrack = Track(
        id: TrackId('local', 'wy:1'),
        title: '本地歌曲',
        origin: TrackOrigin.localFile,
        payload: {'path': '/downloads/a.mp3', 'songId': 'wy:1'},
      );
      final local = await service.getLyrics(
        '本地歌曲',
        '歌手',
        'local:wy:1',
        track: localTrack,
      );
      expect(local, isNull);
      expect(counting.calls, 0, reason: '离线曲目不发起网络歌词请求');

      // 在线曲目行为不变：仍走网络提供者。
      const onlineTrack = Track(
        id: TrackId('wy', '1'),
        title: '在线歌曲',
        origin: TrackOrigin.builtin,
      );
      final online = await service.getLyrics(
        '在线歌曲',
        '歌手',
        'wy:1',
        track: onlineTrack,
      );
      expect(online, isNotNull);
      expect(counting.calls, 1);
    });
  });
}

class _CountingProvider extends LyricProvider {
  _CountingProvider({required this.name, required this.result});

  @override
  final String name;

  final String? result;
  int calls = 0;

  @override
  Future<String?> fetchLyric(String songId) async => result;

  @override
  Future<SongMatch?> search(String title, String artist) async =>
      SongMatch(songId: 'counting-$name', title: title, artist: artist);

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
      {int limit = 3}) async {
    calls++;
    return [
      SongMatch(songId: 'counting-$name', title: title, artist: artist),
    ];
  }
}

class _FakeLyricProvider extends LyricProvider {
  @override
  String get name => 'fake';

  @override
  Future<String?> fetchLyric(String songId) async {
    return '[00:00]Mock Lyric Line';
  }

  @override
  Future<SongMatch?> search(String title, String artist) async {
    return SongMatch(songId: 'fake-id', title: title, artist: artist);
  }

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
      {int limit = 3}) async {
    return [SongMatch(songId: 'fake-id', title: title, artist: artist)];
  }
}
