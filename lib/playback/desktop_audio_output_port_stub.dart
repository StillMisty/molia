/// Web / 无 `dart:io` 平台的桌面输出端口：不产生事件。
library;

import 'platform_audio_port.dart';

/// 创建 no-op 桌面输出端口（Web 构建只需要这个符号存在）。
PlatformAudioPort createDesktopAudioOutputPort() =>
    const NoopPlatformAudioPort();
