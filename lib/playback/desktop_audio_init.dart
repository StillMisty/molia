/// 桌面端音频后端初始化（Windows/Linux 使用 media_kit；其余平台为空操作）。
library;

export 'desktop_audio_init_stub.dart'
    if (dart.library.io) 'desktop_audio_init_io.dart';
