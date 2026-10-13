import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_audio_handler.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/sources/source_track.dart';

SourceTrack _track({String? coverUrl}) => SourceTrack(
      sourceKey: 'wy',
      origin: 'builtin',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      coverUrl: coverUrl,
      duration: const Duration(seconds: 269),
      raw: const {'songmid': 186016},
    );

/// 只覆写状态的假服务：不触碰 just_audio 平台通道（同
/// local_playback_backend_test 的模式）。
class _FakeService extends LocalPlaybackService {
  _FakeService()
      : super(
          resolver: (track, {String? quality}) async => 'http://127.0.0.1/a.wav',
        );

  bool hasTrackValue = false;
  int skipToNextCalls = 0;
  int skipToPreviousCalls = 0;

  @override
  bool get hasTrack => hasTrackValue;

  @override
  bool get isPlaying => false;

  @override
  bool get isLoading => false;

  @override
  PlayMode get mode => PlayMode.sequential;

  @override
  SourceTrack? get currentSourceTrack => null;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  List<SourceTrack> get queueTracks => const [];

  @override
  int get currentIndex => -1;

  @override
  Future<void> skipToNext() async {
    skipToNextCalls++;
  }

  @override
  Future<void> skipToPrevious() async {
    skipToPreviousCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mediaItemForTrack：系统媒体会话封面', () {
    test('封面 URL 带统一请求头（修复通知封面 403）', () {
      final item = mediaItemForTrack(
        _track(
          coverUrl:
              'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        ),
        duration: const Duration(seconds: 269),
        artworkBlocked: false,
      );

      expect(
        item.artUri,
        Uri.parse(
          'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        ),
      );
      // audio_service 在 Dart 侧用默认 UA（Dart/x）下载封面会被网易 CDN
      // 403，必须带上与 App 内封面一致的浏览器 UA + 平台 Referer。
      expect(item.artHeaders?['User-Agent'], ArtworkCache.browserUserAgent);
      expect(item.artHeaders?['Referer'], 'https://music.163.com/');
      expect(item.duration, const Duration(seconds: 269));
      expect(item.id, 'lx:wy:186016');
    });

    test('协议相对封面地址补全为 https', () {
      final item = mediaItemForTrack(
        _track(coverUrl: '//p2.music.126.net/cover.jpg'),
        duration: null,
        artworkBlocked: false,
      );

      expect(item.artUri, Uri.parse('https://p2.music.126.net/cover.jpg'));
      expect(item.artHeaders?['Referer'], 'https://music.163.com/');
    });

    test('省流模式整体置空封面（不触发通知封面下载）', () {
      final item = mediaItemForTrack(
        _track(coverUrl: 'https://p1.music.126.net/cover.jpg'),
        duration: null,
        artworkBlocked: true,
      );

      expect(item.artUri, isNull);
      expect(item.artHeaders, isNull);
    });

    test('无封面 / 非法地址不带 artUri 与 artHeaders', () {
      for (final cover in <String?>[null, '', 'not a url']) {
        final item = mediaItemForTrack(
          _track(coverUrl: cover),
          duration: null,
          artworkBlocked: false,
        );
        expect(item.artUri, isNull, reason: 'cover=$cover');
        expect(item.artHeaders, isNull, reason: 'cover=$cover');
      }
    });

    test('空歌手回退「未知歌手」、空专辑为 null', () {
      final item = mediaItemForTrack(
        SourceTrack(
          sourceKey: 'kw',
          origin: 'builtin',
          title: '歌名',
          artist: '',
          album: '',
          raw: const {'id': 1},
        ),
        duration: null,
        artworkBlocked: false,
      );

      expect(item.artist, '未知歌手');
      expect(item.album, isNull);
    });
  });

  group('parseArtUri', () {
    test('保留绝对地址、补全协议相对地址、拒绝无 scheme', () {
      expect(
        parseArtUri('https://a.com/x.jpg'),
        Uri.parse('https://a.com/x.jpg'),
      );
      expect(
        parseArtUri('//a.com/x.jpg'),
        Uri.parse('https://a.com/x.jpg'),
      );
      expect(parseArtUri('a.com/x.jpg'), isNull);
      expect(parseArtUri(null), isNull);
    });
  });

  group('恢复态切歌键回落', () {
    test('服务无曲目（冷启动恢复态）：回落给注入的 provider 回调', () async {
      final service = _FakeService();
      addTearDown(service.dispose);
      var restoredNext = 0;
      var restoredPrevious = 0;
      final handler = LocalAudioHandler(
        service,
        onRestoredSkipToNext: () async => restoredNext++,
        onRestoredSkipToPrevious: () async => restoredPrevious++,
      );

      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(restoredNext, 1);
      expect(restoredPrevious, 1);
      expect(service.skipToNextCalls, 0);
      expect(service.skipToPreviousCalls, 0);
    });

    test('服务已有真实曲目：走正常切歌，不触发回落', () async {
      final service = _FakeService()..hasTrackValue = true;
      addTearDown(service.dispose);
      var restoredCalls = 0;
      final handler = LocalAudioHandler(
        service,
        onRestoredSkipToNext: () async => restoredCalls++,
      );

      await handler.skipToNext();

      expect(service.skipToNextCalls, 1);
      expect(restoredCalls, 0);
    });
  });
}
