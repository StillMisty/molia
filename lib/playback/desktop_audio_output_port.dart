/// 桌面输出监听端口（仅 Windows / macOS / Linux；Web 走 stub no-op）。
///
/// P0 的 [PlatformAudioPort] 是唯一 seam：桌面适配器只扩展它的 `outputLost`
/// 事件，不新增第二个播放层构造参数（ADR-0036）。
library;

export 'desktop_audio_output_port_stub.dart'
    if (dart.library.io) 'desktop_audio_output_port_io.dart';
