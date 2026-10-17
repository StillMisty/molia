import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/shortcut_bindings.dart';
import '../services/shortcut_settings.dart';
import '../services/shortcuts.dart';
import '../services/window/app_tray.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/settings/shortcut_recorder_tile.dart';

/// 快捷键设置子页：软件内 / 全局两组的总开关与绑定自定义。
///
/// 从设置 › 通用进入，在设置弹层内部导航（见 `settings_page.dart`）。
/// 绑定校验（全局必须带修饰键、同组不重复）由 [ShortcutSettings.setBinding]
/// 兜底；本页在拒绝时给出具体原因（缺修饰键 / 被哪个动作占用）。
class ShortcutSettingsPage extends StatefulWidget {
  const ShortcutSettingsPage({super.key});

  @override
  State<ShortcutSettingsPage> createState() => _ShortcutSettingsPageState();
}

class _ShortcutSettingsPageState extends State<ShortcutSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // provider 缺省（独立挂载的测试）时回退单例：生产里两者是同一实例。
    final settings =
        context.watch<ShortcutSettings?>() ?? ShortcutSettings.instance;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsShortcutsTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          _buildScopeCard(context, l10n, settings, ShortcutScope.inApp),
          const SizedBox(height: kSettingsSectionSpacing),
          _buildScopeCard(context, l10n, settings, ShortcutScope.global),
        ],
      ),
    );
  }

  /// 一个分组的卡片：总开关 + 全部绑定行 + 组级恢复默认。
  Widget _buildScopeCard(
    BuildContext context,
    AppLocalizations l10n,
    ShortcutSettings settings,
    ShortcutScope scope,
  ) {
    final inApp = scope == ShortcutScope.inApp;
    final bindings = inApp ? settings.inAppBindings : settings.globalBindings;
    final enabled = inApp ? settings.inAppEnabled : settings.globalEnabled;
    final hasOverrides =
        ShortcutBindings.commandsOf(scope).any(bindings.isOverridden);
    return SettingsSectionCard(
      title: inApp ? l10n.shortcutsInAppSection : l10n.shortcutsGlobalSection,
      footer: _scopeFooter(l10n, scope),
      children: [
        SettingsSwitchTile(
          switchKey: inApp
              ? const Key('shortcutsEnabledSwitch')
              : const Key('shortcutsGlobalEnabledSwitch'),
          icon: inApp ? Icons.keyboard_rounded : Icons.public_rounded,
          title: inApp
              ? l10n.shortcutsEnabledSwitch
              : l10n.shortcutsGlobalEnabledSwitch,
          // 组说明放卡片 footer（开关行本身只留标题，避免同页重复文案）。
          subtitle: '',
          value: enabled,
          onChanged: (value) => unawaited(
            inApp
                ? settings.setInAppEnabled(value)
                : settings.setGlobalEnabled(value),
          ),
        ),
        for (final command in ShortcutBindings.commandsOf(scope))
          ShortcutRecorderTile(
            key: Key('shortcutRow_${scope.name}_${command.name}'),
            icon: _actionIcon(command),
            title: _actionLabel(l10n, command),
            combo: bindings.comboFor(command)!,
            overridden: bindings.isOverridden(command),
            resetKey: Key('shortcutReset_${scope.name}_${command.name}'),
            onReset: () => unawaited(settings.setBinding(scope, command, null)),
            onRecorded: (combo) =>
                unawaited(_applyRecorded(settings, scope, command, combo)),
          ),
        _ResetScopeTile(
          key: Key('shortcutResetAll_${scope.name}'),
          enabled: hasOverrides,
          onPressed: () => unawaited(settings.resetScope(scope)),
        ),
      ],
    );
  }

  /// 分组说明：软件内 / 全局各自的生效口径；全局在 Linux 上额外提示
  /// Wayland 无法注册系统级热键（口径同通用页的托盘 hint：仅 Linux 提醒）。
  Widget _scopeFooter(AppLocalizations l10n, ShortcutScope scope) {
    if (scope == ShortcutScope.inApp) {
      return SettingsSectionHint(text: l10n.shortcutsInAppHint);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHint(text: l10n.shortcutsGlobalHint),
        if (AppTray.isLinuxDesktop)
          SettingsSectionHint(text: l10n.shortcutsGlobalLinuxHint),
      ],
    );
  }

  /// 提交一次录制结果：校验失败时给出具体原因（组合已被哪个动作占用 /
  /// 全局缺修饰键），成功则静默（行内文案即反馈）。
  Future<void> _applyRecorded(
    ShortcutSettings settings,
    ShortcutScope scope,
    ShortcutCommand command,
    ShortcutCombo combo,
  ) async {
    final bindings = scope == ShortcutScope.inApp
        ? settings.inAppBindings
        : settings.globalBindings;
    final accepted = await settings.setBinding(scope, command, combo);
    if (accepted || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    // 与 setBinding 同一判定源：拒绝后状态未变，这里的快照仍然有效。
    final conflict = combo.isValidForScope(scope)
        ? bindings.conflictWith(combo, exclude: command)
        : null;
    final message = conflict != null
        ? l10n.shortcutsConflict(_actionLabel(l10n, conflict))
        : l10n.shortcutsGlobalNeedsModifier;
    context.read<NotificationService?>()?.showSnackBar(message);
  }
}

/// 组级「恢复默认」行：全默认时置灰（没有可恢复的覆盖）。
///
/// 独立成组件是因为 [SettingsRowPosition] 由 [SettingsSectionCard] 下发给
/// 子项；在页面方法里直接取位置会拿到卡片外的作用域。
class _ResetScopeTile extends StatelessWidget {
  const _ResetScopeTile({
    super.key,
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final item = M3ETheme.of(context).listTheme.item;
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: l10n.shortcutsResetAll,
      onPressed: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: item.minHeight - kSettingsRowPadding.vertical,
          ),
          child: Row(
            children: [
              SettingsTileIcon(
                icon: Icons.restart_alt_rounded,
                isDestructive: false,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SettingsTileLabel(
                  title: l10n.shortcutsResetAll,
                  subtitle: '',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 动作的展示名（冻结的 `shortcutAction*` 文案键）。
String _actionLabel(AppLocalizations l10n, ShortcutCommand command) =>
    switch (command) {
      ShortcutCommand.togglePlayPause => l10n.shortcutActionPlayPause,
      ShortcutCommand.seekBackward => l10n.shortcutActionSeekBackward,
      ShortcutCommand.seekForward => l10n.shortcutActionSeekForward,
      ShortcutCommand.previousTrack => l10n.shortcutActionPrevious,
      ShortcutCommand.nextTrack => l10n.shortcutActionNext,
      ShortcutCommand.volumeUp => l10n.shortcutActionVolumeUp,
      ShortcutCommand.volumeDown => l10n.shortcutActionVolumeDown,
      ShortcutCommand.toggleMute => l10n.shortcutActionMute,
      ShortcutCommand.focusSearch => l10n.shortcutActionSearch,
      ShortcutCommand.selectDestination1 => l10n.shortcutActionDestination1,
      ShortcutCommand.selectDestination2 => l10n.shortcutActionDestination2,
      ShortcutCommand.selectDestination3 => l10n.shortcutActionDestination3,
      ShortcutCommand.closeQueuePanel => l10n.shortcutActionCloseQueue,
      ShortcutCommand.showMainWindow => l10n.shortcutActionShowWindow,
    };

/// 动作行的图标（按动作语义选型；与执行端命令一一对应）。
IconData _actionIcon(ShortcutCommand command) => switch (command) {
      ShortcutCommand.togglePlayPause => Icons.play_arrow_rounded,
      ShortcutCommand.seekBackward => Icons.fast_rewind_rounded,
      ShortcutCommand.seekForward => Icons.fast_forward_rounded,
      ShortcutCommand.previousTrack => Icons.skip_previous_rounded,
      ShortcutCommand.nextTrack => Icons.skip_next_rounded,
      ShortcutCommand.volumeUp => Icons.volume_up_rounded,
      ShortcutCommand.volumeDown => Icons.volume_down_rounded,
      ShortcutCommand.toggleMute => Icons.volume_off_rounded,
      ShortcutCommand.focusSearch => Icons.search_rounded,
      ShortcutCommand.selectDestination1 => Icons.filter_1_rounded,
      ShortcutCommand.selectDestination2 => Icons.filter_2_rounded,
      ShortcutCommand.selectDestination3 => Icons.filter_3_rounded,
      ShortcutCommand.closeQueuePanel => Icons.playlist_remove_rounded,
      ShortcutCommand.showMainWindow => Icons.desktop_windows_rounded,
    };
