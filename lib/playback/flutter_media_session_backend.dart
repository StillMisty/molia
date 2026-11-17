import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';

import 'media_session_backend.dart';

/// Linux MPRIS 的 `DesktopEntry`：与已安装的
/// `linux/packaging/share/applications/top.stillmisty.molia.desktop` 同名
/// （也是 `linux/CMakeLists.txt` 的 `APPLICATION_ID`），Wayland 门户与
/// GNOME / KDE 媒体浮层靠它认领应用身份。
const String linuxMediaSessionAppId = 'top.stillmisty.molia';

/// Linux MPRIS 的 `Identity`（媒体浮层显示名）。
///
/// 不设置时插件回落到进程名（`molia`），与安装后的应用名不一致。
const String linuxMediaSessionDisplayName = 'Molia';

/// [MediaSessionBackend] 的 `flutter_media_session` 实现
/// （Android / iOS / macOS / Windows / Linux）。
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
  Future<void> activate() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      // MPRIS 的 Identity / DesktopEntry 由插件缓存；必须在 activate 前写入，
      // 否则插件会用 prgname 初始化总线名与身份，之后再改要等一次
      // PropertiesChanged。Windows 的 AUMID 仍由 runner 设置（ADR-0010），
      // 这里不碰。
      await _platform.setAppId(
        linuxMediaSessionAppId,
        displayName: linuxMediaSessionDisplayName,
      );
    }
    await _platform.activate();
  }

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
