/// 桌面壳层的软件内快捷键挂载点（仅桌面骨架使用）。
///
/// 顶层 [HardwareKeyboard] 处理器把物理按键按可配置的软件内绑定表
/// （[ShortcutSettings.inAppBindings]，默认表见 `shortcut_bindings.dart`）
/// 翻译成命令后执行：播放相关命令直接走 [PlaybackProvider]（与底栏 / 顶栏
/// 按钮同一条链路），聚焦搜索 / 切目的地 / 关队列面板交给壳层回调——本组件
/// 不认识桌面布局，只管「按键 → 动作」。
///
/// **为什么用 [HardwareKeyboard] 处理器而不是顶层 `Focus.onKeyEvent`**：
/// 焦点事件只沿「当前焦点 → 祖先链」分发；一旦焦点落到壳层 Focus 的**祖先**
/// （route 的 FocusScope：列表点空白处 / 搜索回车后 `unfocus()` / 收藏页退出
/// 搜索），壳层 Focus 就再也收不到按键，Space、←→、Ctrl+F 会整体失效。
/// `HardwareKeyboard` 处理器在焦点分发之前统一收取按键，与焦点位置无关；
/// 代价是「更近的控件优先」不再自动成立，因此这里显式让位：
/// - 软件内快捷键总开关关闭：不注册处理器，所有按键放行；
/// - 文本输入框聚焦时全部放行（Space / 方向键 / Esc 归文本编辑与输入法）；
/// - 设置页正在录制新组合键时全部放行（否则录制 Space / ←→ 会先触发播放）；
/// - 处理器返回 false 时不消费事件，继续走正常焦点分发（聚焦的按钮 / 滑杆
///   仍能先响应自己的键）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import '../../providers/playback_provider.dart';
import '../../services/shortcut_settings.dart';
import '../../services/shortcut_actions.dart';
import '../../services/shortcuts.dart';

final _logger = Logger('molia.desktop_shortcuts');

/// 软件内快捷键挂载点：包住桌面骨架整棵树，在顶层拦截按键。
class DesktopShortcuts extends StatefulWidget {
  const DesktopShortcuts({
    super.key,
    required this.onFocusSearch,
    required this.onSelectDestinationIndex,
    required this.onCloseQueuePanel,
    required this.child,
  });

  /// 聚焦搜索（默认 Ctrl+F）：聚焦 / 打开全局搜索（宽窄窗分流由壳层回调决定）。
  final VoidCallback onFocusSearch;

  /// 切目的地（默认 Ctrl+1/2/3）：切到第 index 个可见目的地（顺序 = 导航顺序）。
  final ValueChanged<int> onSelectDestinationIndex;

  /// 关闭队列面板（默认 Esc）：面板未打开时回调内部自行 no-op。
  final VoidCallback onCloseQueuePanel;

  final Widget child;

  @override
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  /// 处理器当前是否已挂到 [HardwareKeyboard]（跟随软件内总开关）。
  bool _registered = false;

  @override
  void initState() {
    super.initState();
    // 用 addListener 而不是 context.watch：本组件不含 UI，watch 会让整棵桌面壳
    // 在每次绑定 / 开关变更时重建；这里只有「总开关翻转」需要动作——关闭时
    // 摘掉处理器（字面意义的完全不拦截），打开时挂回。
    ShortcutSettings.instance.addListener(_syncEnabled);
    _syncEnabled();
  }

  @override
  void dispose() {
    ShortcutSettings.instance.removeListener(_syncEnabled);
    // 幂等：未注册时移除是无操作。
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  /// 总开关 → 处理器注册状态（幂等）。
  void _syncEnabled() {
    final enabled = ShortcutSettings.instance.inAppEnabled;
    if (enabled == _registered) return;
    _registered = enabled;
    if (enabled) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    } else {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    // 只认首次按下：KeyRepeatEvent 会让开关类命令（播放 / 静音 / 切页）连发，
    // 长按一个键变成反复开关。
    if (event is! KeyDownEvent) return false;
    // 设置页正在录制组合键：整体让位（录制行不是 EditableText，只能靠共享的
    // 录制态判定），否则录制 Space / ←→ 会先触发播放命令。
    if (ShortcutSettings.instance.isRecordingCombo) return false;
    // 输入框聚焦时不拦截任何键（硬约定）：Space / ←→ / Esc 都要留给文本编辑
    // 与输入法。
    if (_isTextInputFocused()) return false;
    final keyboard = HardwareKeyboard.instance;
    // 命中判定查当前生效绑定（覆盖优先、其次默认）：每次按键现取，设置页
    // 改绑 / 恢复默认立即生效，无需重建壳层。
    for (final entry
        in ShortcutSettings.instance.inAppBindings.effective.entries) {
      if (entry.value.matches(
        event.logicalKey,
        ctrl: keyboard.isControlPressed,
        shift: keyboard.isShiftPressed,
        alt: keyboard.isAltPressed,
        meta: keyboard.isMetaPressed,
      )) {
        _execute(entry.key);
        return true;
      }
    }
    return false;
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

  /// 执行命令：走共享执行器（`ShortcutActions`），与全局热键同一套语义。
  ///
  /// 回调在 `HardwareKeyboard` 处理器里同步触发（不能 await），执行异常由
  /// provider / 执行器自身兜底，这里只保证不把 Future 丢成未处理错误。
  void _execute(ShortcutCommand command) {
    final actions = ShortcutActions(
      playback: context.read<PlaybackProvider>(),
      onFocusSearch: widget.onFocusSearch,
      onSelectDestinationIndex: widget.onSelectDestinationIndex,
      onCloseQueuePanel: widget.onCloseQueuePanel,
    );
    unawaited(actions.execute(command).catchError((Object error) {
      _logger.warning('快捷键命令执行失败（${command.name}）：$error');
    }));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
