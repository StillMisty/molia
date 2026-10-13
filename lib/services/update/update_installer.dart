/// 更新安装策略入口（按平台条件导入，模式同 `services/window/window_chrome.dart`）。
///
/// - 原生（Android / Linux / Windows）：`update_installer_io.dart`；
/// - Web：`update_installer_stub.dart`（不支持应用内安装，只提供刷新页面）。
library;

export 'update_installer_stub.dart'
    if (dart.library.io) 'update_installer_io.dart';
export 'update_installer_types.dart';
