/// Windows 任务栏缩略图工具栏入口：鼠标悬浮任务栏按钮时的预览浮层里显示
/// 「收藏 / 上一首 / 播放暂停 / 下一首」四个按钮。
///
/// 与 `app_tray.dart` 同构：UI / 组合根只经这里访问，通道与平台守卫收在实现
/// 文件（`taskbar_thumb_bar_io.dart`）；非 Windows 平台全部方法是空操作。
///
/// 原生侧见 `windows/runner/taskbar_thumb_bar.cpp`（ITaskbarList3）。
library;

export 'taskbar_thumb_bar_io.dart';
