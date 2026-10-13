/// 桌面窗口 chrome 入口：隐藏原生标题栏 + 顶栏拖动区 + 窗口按钮
/// （最小化 / 最大化-还原 / 关闭）。
///
/// 平台范围：仅 Linux / Windows 桌面生效（[window_chrome_io.dart]），
/// 其余平台（Web / 移动端 / macOS）走空实现 [window_chrome_stub.dart]，
/// 行为与改动前一致。
///
/// UI 只依赖本入口：`package:window_manager` 的 Dart 代码 import `dart:io`，
/// 被 UI 直接引用会毁掉 Web 构建（见 docs/pitfalls.md #30），
/// 因此一律经条件导入。
library;

export 'window_chrome_stub.dart'
    if (dart.library.io) 'window_chrome_io.dart';
