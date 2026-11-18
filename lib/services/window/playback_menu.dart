/// macOS 顶层「播放」菜单：入口与 `app_tray.dart` / `taskbar_thumb_bar.dart`
/// 同构，实现与平台守卫收在 `playback_menu_io.dart`。
///
/// 菜单动作必须落到托盘 / 任务栏同一批闭包（provider 命令面），不能成为第二
/// 套播放策略；文案由组合根按当前语言解析后下发（原生没有本地化表）。
library;

export 'playback_menu_io.dart';
