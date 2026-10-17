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
/// **为什么用 [HardwareKeyboard] 处理器而不是顶层 `Focus.onKeyEvent`**：
/// 焦点事件只沿「当前焦点 → 祖先链」分发；一旦焦点落到壳层 Focus 的**祖先**
/// （route 的 FocusScope：列表点空白处 / 搜索回车后 `unfocus()` / 收藏页退出
/// 搜索），壳层 Focus 就再也收不到按键，Space、←→、Ctrl+F 会整体失效。
/// `HardwareKeyboard` 处理器在焦点分发之前统一收取按键，与焦点位置无关；
/// 代价是「更近的控件优先」不再自动成立，因此这里显式让位：
/// - 文本输入框聚焦时全部放行（Space / 方向键 / Esc 归文本编辑与输入法）；
/// - 处理器返回 false 时不消费事件，继续走正常焦点分发（聚焦的按钮 / 滑杆
///   仍能先响应自己的键）。
class DesktopShortcuts extends StatefulWidget {
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
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    // 只认首次按下：KeyRepeatEvent 会让开关类命令（播放 / 静音 / 切页）连发，
    // 长按一个键变成反复开关。
    if (event is! KeyDownEvent) return false;
    // 输入框聚焦时不拦截任何键（硬约定）：Space / ←→ / Esc 都要留给文本编辑
    // 与输入法。
    if (_isTextInputFocused()) return false;
    final keyboard = HardwareKeyboard.instance;
    final command = shortcutFor(
      event.logicalKey,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    if (command == null) return false;
    _execute(command);
    return true;
  }

  /// 当前焦点是否落在文本输入框内（搜索框 / 设置页输入框 / 重命名弹层等）。
  ///
  /// [EditableText] 用内部 Focus 持有焦点；从焦点上下文向上找 EditableText
  /// 祖先即可覆盖输入框内部所有子焦点节点。
  bool _isTextInputFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _execute(ShortcutCommand command) {
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
        widget.onFocusSearch();
      case ShortcutCommand.selectDestination1:
        widget.onSelectDestinationIndex(0);
      case ShortcutCommand.selectDestination2:
        widget.onSelectDestinationIndex(1);
      case ShortcutCommand.selectDestination3:
        widget.onSelectDestinationIndex(2);
      case ShortcutCommand.closeQueuePanel:
        widget.onCloseQueuePanel();
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

  @override
  Widget build(BuildContext context) => widget.child;
}
