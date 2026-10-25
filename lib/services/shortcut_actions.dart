/// 快捷键命令 → 动作的共享执行器：软件内快捷键与系统级全局热键共用。
///
/// 「命令 → 动作」的语义只维护一份：播放类命令走 `PlaybackProvider`
/// （与底栏 / 顶栏按钮同一条链路），显示窗口走 `WindowChrome.show()`，
/// 壳层交互命令（聚焦搜索 / 切目的地 / 关队列面板）经注入回调转发——
/// 执行器不认识桌面布局。软件内挂载点（`desktop_shortcuts.dart`）可按需
/// 改用它；全局热键（`global_hotkeys.dart`）只用播放类与显示窗口命令。
library;

import 'package:flutter/foundation.dart' show ValueChanged, VoidCallback;

import '../providers/playback_provider.dart';
import 'shortcuts.dart';
import 'window/window_chrome.dart';

/// 相对 seek 步长（快退 / 快进各按一次的量）。
const Duration _seekStep = Duration(seconds: 5);

/// 音量步进（每次按键 ±5%）。
const double _volumeStep = 0.05;

/// 命令执行器：把 [ShortcutCommand] 翻译成对 provider / 窗口 / 壳层回调的调用。
class ShortcutActions {
  ShortcutActions({
    required this._playback,
    Future<void> Function()? showMainWindow,
    this.onFocusSearch,
    this.onSelectDestinationIndex,
    this.onCloseQueuePanel,
  })  : _showMainWindow = showMainWindow ?? WindowChrome.show;

  final PlaybackProvider _playback;

  /// 显示并聚焦主窗口（全局分组的 showMainWindow 命令）；缺省
  /// [WindowChrome.show]（非桌面平台是安全的空操作）。
  final Future<void> Function() _showMainWindow;

  /// 聚焦 / 打开全局搜索（软件内挂载点注入；未注入时命令静默忽略）。
  final VoidCallback? onFocusSearch;

  /// 切到第 index 个可见目的地（顺序 = 导航顺序）。
  final ValueChanged<int>? onSelectDestinationIndex;

  /// 关闭队列右面板（面板未打开时回调内部自行 no-op）。
  final VoidCallback? onCloseQueuePanel;

  /// 执行命令。
  ///
  /// 不在这里吞异常：调用方决定兜底口径——全局热键回调是即发即忘，
  /// 由 `GlobalHotkeys` 接住并记日志；软件内挂载点沿用 provider 自身的
  /// 失败语义（播放失败经快照错误提示）。
  Future<void> execute(ShortcutCommand command) async {
    switch (command) {
      case ShortcutCommand.togglePlayPause:
        await _playback.togglePlayPause();
      case ShortcutCommand.seekBackward:
        await _seekBy(-_seekStep);
      case ShortcutCommand.seekForward:
        await _seekBy(_seekStep);
      case ShortcutCommand.previousTrack:
        await _playback.skipToPrevious();
      case ShortcutCommand.nextTrack:
        await _playback.skipToNext();
      case ShortcutCommand.volumeUp:
        await _playback.adjustVolume(_volumeStep);
      case ShortcutCommand.volumeDown:
        await _playback.adjustVolume(-_volumeStep);
      case ShortcutCommand.toggleMute:
        await _playback.toggleMute();
      case ShortcutCommand.showMainWindow:
        await _showMainWindow();
      case ShortcutCommand.focusSearch:
        onFocusSearch?.call();
      case ShortcutCommand.selectDestination1:
        onSelectDestinationIndex?.call(0);
      case ShortcutCommand.selectDestination2:
        onSelectDestinationIndex?.call(1);
      case ShortcutCommand.selectDestination3:
        onSelectDestinationIndex?.call(2);
      case ShortcutCommand.closeQueuePanel:
        onCloseQueuePanel?.call();
    }
  }

  /// 相对 seek：当前进度 ± 步长，clamp 到 0..曲目时长（时长未知时只保底 0）。
  ///
  /// 无曲目时不动：seek 无处可去（恢复态有曲目，照常改保存进度）。
  Future<void> _seekBy(Duration delta) async {
    final snapshot = _playback.snapshot;
    if (snapshot.current == null) return;
    final durationMs = snapshot.duration.inMilliseconds;
    var targetMs =
        _playback.currentPosition.inMilliseconds + delta.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) targetMs = durationMs;
    await _playback.seekToPosition(targetMs);
  }
}
