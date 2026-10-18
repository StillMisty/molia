import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptics.dart';
import '../../services/shortcut_bindings.dart';
import '../../services/shortcut_settings.dart';
import '../card_list_surface.dart';
import 'settings_tiles.dart';

/// 快捷键绑定行：动作名 + 当前组合；点击进入录制态，抓下一次按键组合。
///
/// 录制交互：点击行 → 行内文案换成「按下新按键…」并请求焦点；此后
/// - 无修饰键的 Esc = 取消（录制态的标准退出键，与点别处失焦取消同义）；
/// - 可绑定的键 = 提交（修饰键状态取 [HardwareKeyboard] 的实时值）；
/// - 不可绑定的键（修饰键本身 / 媒体键等）= 忽略，保持录制态等下一个键。
///
/// 录制期间经 [ShortcutSettings.beginRecordingCombo] 置全局录制标志：
/// 软件内快捷键处理器（`HardwareKeyboard` 处理器先于焦点分发收到按键）据此
/// 整体让位，否则录制 Space / ←→ 会先触发播放命令。
class ShortcutRecorderTile extends StatefulWidget {
  const ShortcutRecorderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.combo,
    required this.overridden,
    required this.onRecorded,
    this.resetKey,
    this.onReset,
  });

  final IconData icon;

  /// 动作名（设置页按冻结的 `shortcutAction*` 文案传入）。
  final String title;

  /// 当前生效的组合（覆盖优先，其次默认）。
  final ShortcutCombo combo;

  /// 是否被用户改过（决定「回默认」按钮是否出现）。
  final bool overridden;

  /// 录制提交回调；是否接受由调用方校验（非法 / 冲突时由调用方提示）。
  final ValueChanged<ShortcutCombo> onRecorded;

  /// 「回默认」按钮的稳定 key（测试定位）。
  final Key? resetKey;

  /// 「回默认」动作；null = 不显示按钮。
  final VoidCallback? onReset;

  @override
  State<ShortcutRecorderTile> createState() => _ShortcutRecorderTileState();
}

class _ShortcutRecorderTileState extends State<ShortcutRecorderTile> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'shortcutRecorder');
  bool _recording = false;

  @override
  void dispose() {
    // 行被移除（返回上一页）时若仍在录制，必须释放全局录制标志，
    // 否则软件内快捷键会一直让位。
    ShortcutSettings.instance.endRecordingCombo(this);
    _focusNode.dispose();
    super.dispose();
  }

  void _toggleRecording() {
    if (_recording) {
      _stopRecording();
      return;
    }
    HapticsService.lightImpact();
    ShortcutSettings.instance.beginRecordingCombo(this);
    setState(() => _recording = true);
    _focusNode.requestFocus();
  }

  void _stopRecording() {
    ShortcutSettings.instance.endRecordingCombo(this);
    if (!_recording) return;
    setState(() => _recording = false);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_recording || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    // 无修饰键的 Esc 取消；带修饰键的 Esc 是普通可绑定组合（全局热键本就
    // 要求带修饰键），照常提交。
    if (event.logicalKey == LogicalKeyboardKey.escape && !_hasModifier()) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    // 不可绑定的键（修饰键本身、F13、媒体键等）不写进组合：忽略并保持录制。
    if (!isBindableKey(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final combo = ShortcutCombo(
      key: event.logicalKey,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    // 先退出录制态再提交：校验失败的提示由页面给出，用户可再点行重录。
    _stopRecording();
    widget.onRecorded(combo);
    return KeyEventResult.handled;
  }

  bool _hasModifier() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final item = m3e.listTheme.item;
    final valueText =
        _recording ? l10n.shortcutsRecording : widget.combo.label();
    // 录制态用强调色：与「当前值」的信息文本区分开，提示正在等按键。
    final valueColor = _recording
        ? m3e.colorScheme.primary
        : m3e.colorScheme.onSurfaceVariant;

    return Focus(
      focusNode: _focusNode,
      // 焦点移走（点其它行 / 关闭弹层）：取消录制，不留下「半录制」的行。
      onFocusChange: (hasFocus) {
        if (!hasFocus && _recording) _stopRecording();
      },
      onKeyEvent: _handleKeyEvent,
      child: CardListSurface(
        position: SettingsRowPosition.of(context),
        padding: kSettingsRowPadding,
        semanticLabel: '${widget.title}, $valueText',
        onPressed: _toggleRecording,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: item.minHeight - kSettingsRowPadding.vertical,
          ),
          child: Row(
            children: [
              SettingsTileIcon(icon: widget.icon, isDestructive: false),
              const SizedBox(width: 12),
              Expanded(
                child: SettingsTileLabel(title: widget.title, subtitle: ''),
              ),
              const SizedBox(width: kSettingsSmallSpacing),
              Flexible(
                child: Text(
                  valueText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: m3e.typeScale.bodyMedium.copyWith(color: valueColor),
                ),
              ),
              if (widget.overridden && widget.onReset != null) ...[
                const SizedBox(width: kSettingsSmallSpacing),
                M3EIconButton(
                  key: widget.resetKey,
                  variant: M3EIconButtonVariant.standard,
                  semanticLabel: l10n.shortcutsResetAll,
                  icon: const Icon(Icons.restart_alt_rounded),
                  onPressed: widget.onReset,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
