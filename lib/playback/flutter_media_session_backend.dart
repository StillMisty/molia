import 'package:flutter_media_session/flutter_media_session.dart';

import 'media_session_backend.dart';

/// [MediaSessionBackend] 的 `flutter_media_session` 实现
/// （Android / iOS / macOS / Windows / Web）。
///
/// 只包装 [FlutterMediaSessionPlatform]：不经过 `FlutterMediaSession`
/// 单例，因为它的 `activate()` 会在 Android 自动请求通知权限——本应用的
/// 权限时机由 `services/notification_permission.dart` 在首次真正播放 /
/// 首次开启歌词输出时决定。
class FlutterMediaSessionBackend implements MediaSessionBackend {
  FlutterMediaSessionBackend({FlutterMediaSessionPlatform? platform})
      : _platform = platform ?? FlutterMediaSessionPlatform.instance;

  final FlutterMediaSessionPlatform _platform;

  @override
  Future<void> activate() => _platform.activate();

  @override
  Future<void> deactivate() => _platform.deactivate();

  @override
  Future<void> updateMetadata(MediaMetadata metadata) =>
      _platform.updateMetadata(metadata);

  @override
  Future<void> updatePlaybackState(PlaybackState state) =>
      _platform.updatePlaybackState(state);

  @override
  Future<void> updateAvailableActions(Set<MediaAction> actions) =>
      _platform.updateAvailableActions(actions);

  @override
  Stream<MediaAction> get actions => _platform.onMediaAction;
}
