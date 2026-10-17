import 'package:flutter_media_session/flutter_media_session.dart';

/// 系统媒体会话后端：跨端统一模型（`flutter_media_session` 的
/// [MediaMetadata] / [PlaybackState] / [MediaAction]）+ 可注入实现。
///
/// Android / iOS / macOS / Windows 走 [FlutterMediaSessionBackend]；
/// Linux 走 `audio_service_mpris` 的 MPRIS 实现（见
/// `mpris_media_session_backend.dart`）。`LocalAudioHandler` 只依赖本接口，
/// 单测用记录型 fake 即可断言全部映射，不触碰平台通道。
abstract class MediaSessionBackend {
  /// 启动媒体会话（Android 前台服务 / Windows SMTC / MPRIS 注册）。
  ///
  /// 注意：不要经由 `FlutterMediaSession().activate()`——它会在 Android
  /// 启动时自动请求通知权限，改变本应用「首次真正播放才请求」的时机。
  Future<void> activate();

  /// 释放平台资源（停止前台服务 / SMTC / MPRIS 对象）。
  Future<void> deactivate();

  Future<void> updateMetadata(MediaMetadata metadata);

  Future<void> updatePlaybackState(PlaybackState state);

  /// 更新系统控件可用的动作集合。播放模式（顺序 / 单曲 / 随机）作为
  /// Android 通知的自定义动作随集合一起下发。
  Future<void> updateAvailableActions(Set<MediaAction> actions);

  /// 系统控制（通知 / 锁屏 / 耳机键 / 媒体浮层）发来的动作。
  Stream<MediaAction> get actions;
}

/// 空后端：平台不支持时的兜底，所有调用都是 no-op。
///
/// 保留非空实现（而不是让 `LocalAudioHandler` 到处判空），让播放链路
/// 与平台支持情况解耦。
class NoopMediaSessionBackend implements MediaSessionBackend {
  const NoopMediaSessionBackend();

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {}

  @override
  Future<void> updateAvailableActions(Set<MediaAction> actions) async {}

  @override
  Stream<MediaAction> get actions => const Stream.empty();
}
