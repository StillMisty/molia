/// Linux MPRIS 后端（条件导出）：IO 平台用 `audio_service_mpris` 的 Dart
/// 平台实现；Web 等非 IO 平台只有 stub（工厂返回 null），保证 Web 构建不
/// 引入 D-Bus。
library;

export 'mpris_media_session_backend_stub.dart'
    if (dart.library.io) 'mpris_media_session_backend_io.dart';
