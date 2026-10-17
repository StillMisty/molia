/// 桌面全局快捷键的纯映射表（键 + 修饰键 → 命令）。
///
/// 只做判定、不碰 UI 与 provider：桌面壳层的挂载组件
/// （`lib/app/desktop/desktop_shortcuts.dart`）把物理按键翻译成入参、再执行
/// 命令。判定与执行分离后，按键口径（哪些组合生效、哪些让位）可脱离
/// widget 树单测，也只在映射表这一处维护。
library;

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
/// （Shift+方向键选文本、Alt+← 后退等），全局快捷键不与其争抢；Ctrl 之外
/// 的修饰键参与即视为「不是这条快捷键」。
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
