/// 桌面窗口 chrome 入口：隐藏原生标题栏 + 顶栏拖动区 + 窗口按钮
/// （最小化 / 最大化-还原 / 关闭）+ 窗口几何的记忆与恢复。
///
/// 平台范围：仅 Linux / Windows 桌面生效；其余平台（Android / iOS / macOS）
/// 没有 `window_manager` 的插件实现，`WindowChrome` 的初始化与窗口监听都是
/// 空操作。
///
/// UI 只依赖本入口：`window_manager` 是桌面专属插件，import 与平台守卫统一
/// 收在实现文件里，其它平台不会误调插件 API（见 docs/pitfalls.md #30）。
library;

export 'window_chrome_io.dart';
