/// 桌面壳层的全局快捷键挂载点（仅桌面骨架使用）。
///
/// 顶层 [Focus] 监听按键事件，经纯映射表（`lib/services/shortcuts.dart`）
/// 翻译成命令后执行：播放相关命令直接走 [PlaybackProvider]（与底栏 / 顶栏
/// 按钮同一条链路），聚焦搜索 / 切目的地 / 关队列面板交给壳层回调——本组件
/// 不认识桌面布局，只管「按键 → 动作」。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/playback_provider.dart';
import '../../services/shortcuts.dart';

/// 快退 / 快进步长。
const Duration _seekStep = Duration(seconds: 5);

/// 音量步进（每次按键 ±5%）。
const double _volumeStep = 0.05;

/// 全局快捷键挂载点：包住桌面骨架整棵树，在顶层拦截按键。
///
/// 挂在壳层顶层而非各控件：事件从当前焦点沿焦点树冒泡，任何获得焦点的
/// 壳内控件（按钮 / 列表 / 进度条）都是本节点的后代，未被子控件消费的按键
/// 都会到达这里；更近的控件（聚焦的滑杆方向键、M3E 搜索锚点的 Space）先于
/// 本节点处理，天然不冲突。
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.onFocusSearch,
    required this.onSelectDestinationIndex,
    required this.onCloseQueuePanel,
    required this.child,
  });

  /// Ctrl+F：聚焦 / 打开全局搜索（宽窄窗分流由壳层回调决定）。
  final VoidCallback onFocusSearch;

  /// Ctrl+1/2/3：切到第 index 个可见目的地（顺序 = 导航顺序）。
  final ValueChanged<int> onSelectDestinationIndex;

  /// Esc：关闭队列右面板（面板未打开时回调内部自行 no-op）。
  final VoidCallback onCloseQueuePanel;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // 壳层挂载即持有焦点：启动后（无其它焦点时）快捷键直接生效；
      // 控件取得焦点后事件仍沿焦点树冒泡到本节点。
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(context, event),
      child: child,
    );
  }

  KeyEventResult _handleKeyEvent(BuildContext context, KeyEvent event) {
    // 只认首次按下：KeyRepeatEvent 会让开关类命令（播放 / 静音 / 切页）连发，
    // 长按一个键变成反复开关。
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 输入框聚焦时不拦截任何键（硬约定）：Space / ←→ / Esc 都要留给文本编辑
    // 与输入法；事件虽会从输入框冒泡到这里，本节点必须让位。
    if (_isTextInputFocused()) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final command = shortcutFor(
      event.logicalKey,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    if (command == null) return KeyEventResult.ignored;
    _execute(context, command);
    return KeyEventResult.handled;
  }

  /// 当前焦点是否落在文本输入框内（搜索框 / 设置页输入框 / 重命名弹层等）。
  ///
  /// [EditableText] 用内部 Focus 持有焦点，且不消费大多数按键（Space 是
  /// 文本输入、方向键走文本编辑动作），事件会继续冒泡到本节点；从焦点
  /// 上下文向上找 EditableText 祖先即可覆盖输入框内部所有子焦点节点。
  bool _isTextInputFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _execute(BuildContext context, ShortcutCommand command) {
    final playback = context.read<PlaybackProvider>();
    switch (command) {
      case ShortcutCommand.togglePlayPause:
        unawaited(playback.togglePlayPause());
      case ShortcutCommand.seekBackward:
        unawaited(_seekBy(playback, -_seekStep));
      case ShortcutCommand.seekForward:
        unawaited(_seekBy(playback, _seekStep));
      case ShortcutCommand.previousTrack:
        unawaited(playback.skipToPrevious());
      case ShortcutCommand.nextTrack:
        unawaited(playback.skipToNext());
      case ShortcutCommand.volumeUp:
        unawaited(playback.adjustVolume(_volumeStep));
      case ShortcutCommand.volumeDown:
        unawaited(playback.adjustVolume(-_volumeStep));
      case ShortcutCommand.toggleMute:
        unawaited(playback.toggleMute());
      case ShortcutCommand.focusSearch:
        onFocusSearch();
      case ShortcutCommand.selectDestination1:
        onSelectDestinationIndex(0);
      case ShortcutCommand.selectDestination2:
        onSelectDestinationIndex(1);
      case ShortcutCommand.selectDestination3:
        onSelectDestinationIndex(2);
      case ShortcutCommand.closeQueuePanel:
        onCloseQueuePanel();
    }
  }

  /// 相对 seek：当前进度 ± 步长，clamp 到 0..曲目时长（时长未知时只保底 0）。
  ///
  /// 无曲目时不动：seek 无处可去（恢复态有曲目，照常改保存进度）。
  Future<void> _seekBy(PlaybackProvider playback, Duration delta) async {
    final snapshot = playback.snapshot;
    if (snapshot.current == null) return;
    final durationMs = snapshot.duration.inMilliseconds;
    var targetMs =
        playback.currentPosition.inMilliseconds + delta.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) targetMs = durationMs;
    await playback.seekToPosition(targetMs);
  }
}
