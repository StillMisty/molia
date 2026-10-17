import 'media_session_backend.dart';

/// 非 IO 平台没有 MPRIS：返回 null，由调用方跳过系统媒体会话。
MediaSessionBackend? createMprisMediaSessionBackend() => null;
