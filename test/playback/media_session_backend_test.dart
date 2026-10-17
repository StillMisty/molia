import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/flutter_media_session_backend.dart';
import 'package:molia/playback/media_artwork_uri.dart';
import 'package:molia/playback/media_session_backend.dart';
import 'package:molia/playback/media_session_backend_factory.dart';
import 'package:molia/playback/mpris_media_session_backend_io.dart';

/// `flutter_media_session` 的平台替身：记录调用与转发动作流。
class _FakeFlutterMediaSessionPlatform extends FlutterMediaSessionPlatform {
  final List<String> calls = [];
  final StreamController<MediaAction> actions =
      StreamController<MediaAction>.broadcast();

  MediaMetadata? metadata;
  PlaybackState? playbackState;
  Set<MediaAction>? availableActions;

  @override
  Future<void> activate() async {
    calls.add('activate');
  }

  @override
  Future<void> deactivate() async {
    calls.add('deactivate');
  }

  @override
  Future<bool> requestNotificationPermission() async {
    calls.add('requestNotificationPermission');
    return true;
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    calls.add('updateMetadata');
    this.metadata = metadata;
  }

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {
    calls.add('updatePlaybackState');
    playbackState = state;
  }

  @override
  Future<void> updateAvailableActions(Set<MediaAction>? actions) async {
    calls.add('updateAvailableActions');
    availableActions = actions;
  }

  @override
  Stream<MediaAction> get onMediaAction => actions.stream;

  Future<void> dispose() => actions.close();
}

/// `audio_service_mpris` 所实现的平台接口替身：不触碰 D-Bus。
class _FakeAudioServicePlatform extends AudioServicePlatform {
  ConfigureRequest? configureRequest;
  MediaItemMessage? mediaItem;
  PlaybackStateMessage? playbackState;
  AudioHandlerCallbacks? handlerCallbacks;
  Object? configureError;

  @override
  Future<void> configure(ConfigureRequest request) async {
    final error = configureError;
    if (error != null) throw error;
    configureRequest = request;
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    mediaItem = request.mediaItem;
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    playbackState = request.state;
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    handlerCallbacks = callbacks;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterMediaSessionBackend', () {
    test('activate 直接调用 platform（不请求通知权限）', () async {
      final platform = _FakeFlutterMediaSessionPlatform();
      addTearDown(platform.dispose);
      final backend = FlutterMediaSessionBackend(platform: platform);

      await backend.activate();

      expect(platform.calls, ['activate']);
      expect(platform.calls, isNot(contains('requestNotificationPermission')));
    });

    test('元数据 / 状态 / 动作转发，动作流透传', () async {
      final platform = _FakeFlutterMediaSessionPlatform();
      addTearDown(platform.dispose);
      final backend = FlutterMediaSessionBackend(platform: platform);

      await backend.updateMetadata(const MediaMetadata(title: '晴天'));
      await backend.updatePlaybackState(
        const PlaybackState(status: PlaybackStatus.playing),
      );
      await backend.updateAvailableActions({MediaAction.play});

      expect(platform.metadata?.title, '晴天');
      expect(platform.playbackState?.status, PlaybackStatus.playing);
      expect(platform.availableActions, {MediaAction.play});

      final received = <MediaAction>[];
      final subscription = backend.actions.listen(received.add);
      addTearDown(subscription.cancel);
      platform.actions.add(MediaAction.pause);
      await pumpEventQueue();
      expect(received, [MediaAction.pause]);
    });
  });

  group('MprisMediaSessionBackend', () {
    test('configure 使用 Molia 的 MPRIS 身份', () async {
      final platform = _FakeAudioServicePlatform();
      final backend = MprisMediaSessionBackend(platform: platform);

      await backend.activate();

      expect(backend.isAvailable, isTrue);
      expect(
        platform.configureRequest?.config.androidNotificationChannelId,
        'top.stillmisty.molia.media',
      );
      expect(
        platform.configureRequest?.config.androidNotificationChannelName,
        'Molia',
      );
    });

    test('MediaMetadata → MediaItemMessage，PlaybackState → PlaybackStateMessage',
        () async {
      final platform = _FakeAudioServicePlatform();
      final backend = MprisMediaSessionBackend(platform: platform);
      await backend.activate();

      await backend.updateMetadata(
        const MediaMetadata(
          title: '晴天',
          artist: '周杰伦',
          album: '叶惠美',
          duration: Duration(seconds: 269),
          artworkUri: 'https://p1.music.126.net/cover.jpg',
        ),
      );
      await backend.updatePlaybackState(
        const PlaybackState(
          status: PlaybackStatus.playing,
          position: Duration(seconds: 42),
          bufferedPosition: Duration(seconds: 60),
          repeatMode: MediaRepeatMode.one,
          shuffleModeEnabled: true,
        ),
      );

      expect(platform.mediaItem?.title, '晴天');
      expect(platform.mediaItem?.artist, '周杰伦');
      expect(platform.mediaItem?.album, '叶惠美');
      expect(platform.mediaItem?.duration, const Duration(seconds: 269));
      expect(
        platform.mediaItem?.artUri,
        Uri.parse('https://p1.music.126.net/cover.jpg'),
      );

      expect(platform.playbackState?.playing, isTrue);
      expect(platform.playbackState?.updatePosition, const Duration(seconds: 42));
      expect(platform.playbackState?.bufferedPosition,
          const Duration(seconds: 60));
      expect(
        platform.playbackState?.repeatMode,
        AudioServiceRepeatModeMessage.one,
      );
      expect(
        platform.playbackState?.shuffleMode,
        AudioServiceShuffleModeMessage.all,
      );
    });

    test('平台回调映射为 MediaAction 流（play/pause/stop/next/previous/seek）',
        () async {
      final platform = _FakeAudioServicePlatform();
      final backend = MprisMediaSessionBackend(platform: platform);
      await backend.activate();

      final received = <MediaAction>[];
      final subscription = backend.actions.listen(received.add);
      addTearDown(subscription.cancel);
      final callbacks = platform.handlerCallbacks!;

      await callbacks.play(const PlayRequest());
      await callbacks.pause(const PauseRequest());
      await callbacks.stop(const StopRequest());
      await callbacks.skipToNext(const SkipToNextRequest());
      await callbacks.skipToPrevious(const SkipToPreviousRequest());
      await callbacks.seek(const SeekRequest(position: Duration(seconds: 9)));
      await pumpEventQueue();

      expect(
        received.map((action) => action.name),
        ['play', 'pause', 'stop', 'skipToNext', 'skipToPrevious', 'seekTo'],
      );
      expect(received.last.seekPosition, const Duration(seconds: 9));
    });

    test('D-Bus 不可用：吞错标记不可用，后续更新静默', () async {
      final platform = _FakeAudioServicePlatform()
        ..configureError = Exception('no session bus');
      final backend = MprisMediaSessionBackend(platform: platform);

      await backend.activate();

      expect(backend.isAvailable, isFalse);
      await backend.updateMetadata(const MediaMetadata(title: '晴天'));
      await backend.updatePlaybackState(
        const PlaybackState(status: PlaybackStatus.playing),
      );
      expect(platform.mediaItem, isNull);
      expect(platform.playbackState, isNull);
    });
  });

  group('createSystemMediaSessionBackend', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('按平台选择后端', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(createSystemMediaSessionBackend(), isA<MprisMediaSessionBackend>());

      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          createSystemMediaSessionBackend(),
          isA<FlutterMediaSessionBackend>(),
          reason: '$platform',
        );
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(createSystemMediaSessionBackend(), isNull);
    });
  });

  test('NoopMediaSessionBackend：全空操作且无动作', () async {
    const backend = NoopMediaSessionBackend();
    await backend.activate();
    await backend.updateMetadata(const MediaMetadata(title: 'x'));
    await backend.updatePlaybackState(
      const PlaybackState(status: PlaybackStatus.idle),
    );
    await backend.updateAvailableActions({MediaAction.play});
    await backend.deactivate();
    expect(await backend.actions.isEmpty, isTrue);
  });

  group('mediaArtworkUriForPath', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Windows 传裸路径、其余平台传 file URI、空路径为 null', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        mediaArtworkUriForPath(r'C:\covers\a.jpg'),
        r'C:\covers\a.jpg',
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(mediaArtworkUriForPath('/tmp/covers/a.jpg'), 'file:///tmp/covers/a.jpg');
      expect(mediaArtworkUriForPath(''), isNull);
    });
  });
}
