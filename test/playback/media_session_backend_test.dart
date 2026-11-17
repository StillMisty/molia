import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/flutter_media_session_backend.dart';
import 'package:molia/playback/media_artwork_uri.dart';
import 'package:molia/playback/media_session_backend.dart';
import 'package:molia/playback/media_session_backend_factory.dart';

/// `flutter_media_session` 的平台替身：记录调用与转发动作流。
class _FakeFlutterMediaSessionPlatform extends FlutterMediaSessionPlatform {
  final List<String> calls = [];
  final StreamController<MediaAction> actions =
      StreamController<MediaAction>.broadcast();

  MediaMetadata? metadata;
  PlaybackState? playbackState;
  Set<MediaAction>? availableActions;
  String? appId;
  String? displayName;

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
  Future<void> setAppId(
    String id, {
    String? displayName,
    String? iconPath,
  }) async {
    calls.add('setAppId');
    appId = id;
    this.displayName = displayName;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterMediaSessionBackend', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('activate 直接调用 platform（不请求通知权限）', () async {
      final platform = _FakeFlutterMediaSessionPlatform();
      addTearDown(platform.dispose);
      final backend = FlutterMediaSessionBackend(platform: platform);

      await backend.activate();

      expect(platform.calls, ['activate']);
      expect(platform.calls, isNot(contains('requestNotificationPermission')));
      // 非 Linux 平台不写 MPRIS 身份，也不碰 Windows 的 AUMID。
      expect(platform.calls, isNot(contains('setAppId')));
    });

    test('Linux 在 activate 前写入 MPRIS 身份（DesktopEntry / Identity）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final platform = _FakeFlutterMediaSessionPlatform();
      addTearDown(platform.dispose);
      final backend = FlutterMediaSessionBackend(platform: platform);

      await backend.activate();

      expect(platform.calls, ['setAppId', 'activate']);
      expect(platform.appId, linuxMediaSessionAppId);
      expect(platform.displayName, linuxMediaSessionDisplayName);
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

  group('createSystemMediaSessionBackend', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('按平台选择后端：Linux 与其他端共用 FlutterMediaSessionBackend', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
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
      expect(mediaArtworkUriForPath(r'C:\covers\a.jpg'), r'C:\covers\a.jpg');

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(
        mediaArtworkUriForPath('/tmp/covers/a.jpg'),
        'file:///tmp/covers/a.jpg',
      );
      expect(mediaArtworkUriForPath(''), isNull);
    });
  });
}
