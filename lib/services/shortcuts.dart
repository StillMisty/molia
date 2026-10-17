/// 快捷键命令枚举（动作名）。
///
/// 绑定表（动作 ↔ 按键组合，含默认值）在 `shortcut_bindings.dart`；
/// 执行语义在 `shortcut_actions.dart`；两个挂载点分别见
/// `lib/app/desktop/desktop_shortcuts.dart`（软件内）与
/// `lib/services/global_hotkeys.dart`（全局）。
library;


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
