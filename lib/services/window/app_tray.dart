/// 桌面托盘（Linux / Windows）：出口与 `window_chrome.dart` 同构。
///
/// UI 组合根只经这里访问托盘：实现文件（`app_tray_io.dart`）是全仓唯一 import
/// `tray_manager` / `nativeapi` 的地方——这些包是桌面专属插件（其 Dart 代码
/// import `dart:io` 与 `dart:ffi`），import 与平台守卫都收在实现文件里，
/// 移动端 / macOS 上 `AppTray` 的全部方法都是空操作
/// （见 docs/pitfalls.md #30 的同类约束）。
library;

export 'app_tray_io.dart';
export 'tray_menu_labels.dart';
