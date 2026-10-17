/// 快捷键命令枚举，以及固定映射（键 + 修饰键 → 命令）的参考实现。
///
/// [ShortcutCommand] 是绑定模型与各执行端共享的枚举；运行时的按键判定走
/// 可配置绑定表（`shortcut_settings.dart` 读 `shortcut_bindings.dart` 的
/// 默认表 + 用户覆盖）。[shortcutFor] 是固定映射的参考实现（Shift / Alt /
/// Meta 一律不命中），由 `test/services/shortcuts_test.dart` 锁定。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// 快捷键命令：映射表与执行端共享的枚举（执行端 switch 穷尽覆盖）。
enum ShortcutCommand {
  /// Space：播放 / 暂停。
  togglePlayPause,

  /// ←：快退 5s。
  seekBackward,

  /// →：快进 5s。
  seekForward,

  /// Ctrl+←：上一首。
  previousTrack,

  /// Ctrl+→：下一首。
  nextTrack,

  /// ↑：音量 +5%。
  volumeUp,

  /// ↓：音量 -5%。
  volumeDown,

  /// M：静音开关。
  toggleMute,

  /// Ctrl+F：聚焦 / 打开全局搜索。
  focusSearch,

  /// Ctrl+1：第 1 个可见目的地（顺序 = 导航顺序）。
  selectDestination1,

  /// Ctrl+2：第 2 个可见目的地。
  selectDestination2,

  /// Ctrl+3：第 3 个可见目的地。
  selectDestination3,

  /// Esc：关闭队列右面板。
  closeQueuePanel,

  /// 全局分组专用：显示主窗口（窗口失焦时把应用拉到前台）。
  showMainWindow,
}

/// 键 + 修饰键 → 命令；未命中返回 null。
///
/// Shift / Alt / Meta 一律不命中：这些组合被系统、输入法与文本编辑占用
/// （Shift+方向键选文本、Alt+← 后退等），固定映射不与其争抢；Ctrl 之外
/// 的修饰键参与即视为「不是这条快捷键」。
///
/// 标注 [visibleForTesting]：生产路径已不再调用（见文件头），保留为固定口径
/// 的测试目标（`test/services/shortcuts_test.dart`）。
@visibleForTesting
ShortcutCommand? shortcutFor(
  LogicalKeyboardKey key, {
  bool ctrl = false,
  bool shift = false,
  bool alt = false,
  bool meta = false,
}) {
  if (shift || alt || meta) return null;
  if (ctrl) {
    return switch (key) {
      LogicalKeyboardKey.arrowLeft => ShortcutCommand.previousTrack,
      LogicalKeyboardKey.arrowRight => ShortcutCommand.nextTrack,
      LogicalKeyboardKey.keyF => ShortcutCommand.focusSearch,
      LogicalKeyboardKey.digit1 => ShortcutCommand.selectDestination1,
      LogicalKeyboardKey.digit2 => ShortcutCommand.selectDestination2,
      LogicalKeyboardKey.digit3 => ShortcutCommand.selectDestination3,
      _ => null,
    };
  }
  return switch (key) {
    LogicalKeyboardKey.space => ShortcutCommand.togglePlayPause,
    LogicalKeyboardKey.arrowLeft => ShortcutCommand.seekBackward,
    LogicalKeyboardKey.arrowRight => ShortcutCommand.seekForward,
    LogicalKeyboardKey.arrowUp => ShortcutCommand.volumeUp,
    LogicalKeyboardKey.arrowDown => ShortcutCommand.volumeDown,
    LogicalKeyboardKey.keyM => ShortcutCommand.toggleMute,
    LogicalKeyboardKey.escape => ShortcutCommand.closeQueuePanel,
    _ => null,
  };
}
