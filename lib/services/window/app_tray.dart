/// 桌面托盘（Linux / Windows）：条件导出 stub / io，出口与 `window_chrome.dart` 同构。
///
/// UI 组合根只经这里访问托盘：实现文件（`app_tray_io.dart`）是全仓唯一 import
/// `tray_manager` / `nativeapi` 的地方——这些包的 Dart 代码 import `dart:io`
/// 与 `dart:ffi`，被 Web 编译路径引用会直接构建失败（见 docs/pitfalls.md #30
/// 的同类约束），因此移动端 / Web / macOS 一律走空实现。
library;

export 'app_tray_stub.dart' if (dart.library.io) 'app_tray_io.dart';
export 'tray_menu_labels.dart';
