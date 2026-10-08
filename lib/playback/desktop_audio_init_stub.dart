/// Web 平台：本地播放使用 just_audio 的 Web 实现，无需桌面音频后端。
bool desktopAudioAvailable = true;

/// 初始化失败原因（Web 上恒为 null）。
String? desktopAudioInitError;

void initDesktopAudioIfNeeded() {}
