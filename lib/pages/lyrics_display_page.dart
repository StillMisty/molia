import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/lyrics_display_provider.dart';
import '../services/lyrics_display/lyric_color_resolver.dart';
import '../services/lyrics_display/lyrics_display_settings.dart';
import '../services/lyrics_display/lyrics_output.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/app_color_picker.dart';

/// 歌词显示设置页：共享项 + 桌面歌词 / 通知·锁屏 / 蓝牙三组。
///
/// - 分组按输出能力显隐（不支持的平台直接隐藏，避免开关撒谎）；
/// - 桌面歌词分组对齐 LX 全套配置（样式 / 行为 / 控制条）；
/// - 媒体元数据两组共用同一输出（通知与蓝牙 profile 合成后写入 MediaItem）。
class LyricsDisplayPage extends StatefulWidget {
  const LyricsDisplayPage({super.key});

  @override
  State<LyricsDisplayPage> createState() => _LyricsDisplayPageState();
}

class _LyricsDisplayPageState extends State<LyricsDisplayPage>
    with WidgetsBindingObserver {
  /// 桌面歌词颜色预设（ARGB int）。
  ///
  /// 颜色契约禁止在业务页面写 `Color(0x...)` / `Color.fromARGB` 字面量，
  /// 预设以 int 定义、动态构造 Color(value)。
  static const List<int> _colorPresets = [
    0xFFFFFFFF,
    0xFF000000,
    0xFFFFEB3B,
    0xFF4CAF50,
    0xFF2196F3,
    0xFFE91E63,
    0xFFFF9800,
    0xFF9E9E9E,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<LyricsDisplayProvider>().refreshCapabilities();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // 从系统「显示在其他应用上层」授权页返回：复查能力。
      context.read<LyricsDisplayProvider>().refreshCapabilities();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    final display = context.watch<LyricsDisplayProvider>();
    final desktopCapability = display.capabilityOf(LyricsOutputIds.desktop);
    final mediaCapability = display.capabilityOf(LyricsOutputIds.media);
    final hasAnySupported =
        desktopCapability != LyricsOutputCapability.unsupported ||
            mediaCapability != LyricsOutputCapability.unsupported;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsLyricsDisplayTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            if (!hasAnySupported)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  l10n.lyricsDisplayUnsupported,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              )
            else ...[
              _sectionTitle(context, l10n.lyricsDisplaySharedTitle),
              _card(context, children: _sharedRows(context, l10n, settings)),
              if (desktopCapability != LyricsOutputCapability.unsupported) ...[
                _sectionTitle(context, l10n.lyricsDesktopTitle),
                _card(
                  context,
                  children: _desktopRows(
                    context,
                    l10n,
                    settings,
                    display,
                    desktopCapability,
                  ),
                ),
              ],
              if (mediaCapability != LyricsOutputCapability.unsupported) ...[
                _sectionTitle(context, l10n.lyricsNotificationTitle),
                _card(
                  context,
                  children: _notificationRows(context, l10n, settings),
                ),
                _sectionTitle(context, l10n.lyricsBluetoothTitle),
                _card(
                  context,
                  children: _bluetoothRows(
                    context,
                    l10n,
                    settings,
                    display,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _sharedRows(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
  ) {
    return [
      _switchRow(
        context,
        title: l10n.lyricsDisplayTranslation,
        subtitle: l10n.lyricsDisplayTranslationSubtitle,
        value: settings.translationEnabled,
        onChanged: settings.setTranslationEnabled,
      ),
      _switchRow(
        context,
        title: l10n.lyricsDisplayRoma,
        subtitle: l10n.lyricsDisplayRomaSubtitle,
        value: settings.romaEnabled,
        onChanged: settings.setRomaEnabled,
      ),
      _sliderRow(
        context,
        title: l10n.lyricsDisplayOffset,
        valueLabel: l10n.lyricsDisplayOffsetValue(settings.offsetMs),
        value: settings.offsetMs.toDouble(),
        min: -500,
        max: 500,
        divisions: 20,
        onChanged: (value) =>
            settings.setOffsetMs((value / 50).round() * 50),
      ),
      _dropdownRow<UnsyncedBehavior>(
        context,
        title: l10n.lyricsDisplayUnsynced,
        value: settings.unsyncedBehavior,
        options: [
          (UnsyncedBehavior.title, l10n.lyricsDisplayUnsyncedTitle),
          (UnsyncedBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
          (UnsyncedBehavior.firstLine, l10n.lyricsDisplayUnsyncedFirstLine),
        ],
        onChanged: settings.setUnsyncedBehavior,
      ),
    ];
  }

  List<Widget> _desktopRows(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
    LyricsDisplayProvider display,
    LyricsOutputCapability capability,
  ) {
    return [
      _switchRow(
        context,
        title: l10n.lyricsDesktopEnable,
        subtitle: l10n.lyricsDesktopEnableSubtitle,
        value: settings.desktopEnabled,
        onChanged: (value) async {
          if (value && capability == LyricsOutputCapability.needsPermission) {
            // 未授权：不假装开启，直接引导到系统授权页。
            await display.requestDesktopOverlayPermission();
            return;
          }
          await settings.setDesktopEnabled(value);
        },
      ),
      if (capability == LyricsOutputCapability.needsPermission)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: AppSemanticColors.of(context).warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.lyricsDesktopPermissionNeeded,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              M3EButton.text(
                onPressed: display.requestDesktopOverlayPermission,
                child: Text(l10n.lyricsDesktopPermissionGrant),
              ),
            ],
          ),
        ),
      _previewCard(context, l10n, settings),
      _sliderRow(
        context,
        title: l10n.lyricsDesktopFontSize,
        valueLabel: settings.desktopFontSize.round().toString(),
        value: settings.desktopFontSize,
        min: LyricsDisplaySettings.fontSizeRange.first,
        max: LyricsDisplaySettings.fontSizeRange.last,
        divisions: 36,
        onChanged: (value) => settings.setDesktopFontSize(value.roundToDouble()),
      ),
      _sliderRow(
        context,
        title: l10n.lyricsDesktopOpacity,
        valueLabel: '${(settings.desktopOpacity * 100).round()}%',
        value: settings.desktopOpacity * 100,
        min: LyricsDisplaySettings.opacityRange.first * 100,
        max: LyricsDisplaySettings.opacityRange.last * 100,
        divisions: 16,
        onChanged: (value) =>
            settings.setDesktopOpacity((value / 100).clamp(0.2, 1.0)),
      ),
      _sliderRow(
        context,
        title: l10n.lyricsDesktopWidth,
        valueLabel: '${settings.desktopWidthPercent.round()}%',
        value: settings.desktopWidthPercent,
        min: LyricsDisplaySettings.widthRange.first,
        max: LyricsDisplaySettings.widthRange.last,
        divisions: 12,
        onChanged: (value) => settings.setDesktopWidthPercent(value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsDesktopSingleLine,
        value: settings.desktopSingleLine,
        onChanged: settings.setDesktopSingleLine,
      ),
      if (!settings.desktopSingleLine)
        _dropdownRow<int>(
          context,
          title: l10n.lyricsDesktopMaxLines,
          value: settings.desktopMaxLines,
          options: [
            for (final value in const [1, 2, 3, 4, 5]) (value, '$value'),
          ],
          onChanged: settings.setDesktopMaxLines,
        ),
      _dropdownRow<DesktopTextAlignX>(
        context,
        title: l10n.lyricsDesktopAlign,
        value: settings.desktopTextAlignX,
        options: [
          (DesktopTextAlignX.left, l10n.lyricsDesktopAlignLeft),
          (DesktopTextAlignX.center, l10n.lyricsDesktopAlignCenter),
          (DesktopTextAlignX.right, l10n.lyricsDesktopAlignRight),
        ],
        onChanged: settings.setDesktopTextAlignX,
      ),
      _dropdownRow<DesktopTextAlignY>(
        context,
        title: '',
        value: settings.desktopTextAlignY,
        options: [
          (DesktopTextAlignY.top, l10n.lyricsDesktopAlignTop),
          (DesktopTextAlignY.center, l10n.lyricsDesktopAlignCenter),
          (DesktopTextAlignY.bottom, l10n.lyricsDesktopAlignBottom),
        ],
        onChanged: settings.setDesktopTextAlignY,
      ),
      _colorRow(
        context,
        title: l10n.lyricsDesktopColorPlayed,
        value: settings.desktopPlayedColor,
        source: settings.desktopPlayedColorSource,
        onSelected: settings.setDesktopPlayedColor,
        onSourceChanged: settings.setDesktopPlayedColorSource,
      ),
      _colorRow(
        context,
        title: l10n.lyricsDesktopColorUnplayed,
        value: settings.desktopUnplayedColor,
        source: settings.desktopUnplayedColorSource,
        onSelected: settings.setDesktopUnplayedColor,
        onSourceChanged: settings.setDesktopUnplayedColorSource,
      ),
      _colorRow(
        context,
        title: l10n.lyricsDesktopColorShadow,
        value: settings.desktopShadowColor,
        source: settings.desktopShadowColorSource,
        onSelected: settings.setDesktopShadowColor,
        onSourceChanged: settings.setDesktopShadowColorSource,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          l10n.lyricsDesktopColorThemeHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
      _switchRow(
        context,
        title: l10n.lyricsDesktopLock,
        value: settings.desktopLock,
        onChanged: settings.setDesktopLock,
      ),
      _switchRow(
        context,
        title: l10n.lyricsDesktopFreeze,
        value: settings.desktopFreezeOnScreenOff,
        onChanged: settings.setDesktopFreezeOnScreenOff,
      ),
      _switchRow(
        context,
        title: l10n.lyricsDesktopAnimation,
        value: settings.desktopShowToggleAnimation,
        onChanged: settings.setDesktopShowToggleAnimation,
      ),
      _dropdownRow<LyricsPauseBehavior>(
        context,
        title: l10n.lyricsDesktopPauseBehavior,
        value: settings.desktopPauseBehavior,
        options: [
          (LyricsPauseBehavior.keep, l10n.lyricsBehaviorKeep),
          (LyricsPauseBehavior.title, l10n.lyricsBehaviorTitle),
          (LyricsPauseBehavior.clear, l10n.lyricsBehaviorClear),
        ],
        onChanged: settings.setDesktopPauseBehavior,
      ),
      _dropdownRow<DesktopNoLyricsBehavior>(
        context,
        title: l10n.lyricsDesktopNoLyrics,
        value: settings.desktopNoLyricsBehavior,
        options: [
          (DesktopNoLyricsBehavior.title, l10n.lyricsBehaviorTitle),
          (DesktopNoLyricsBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
        ],
        onChanged: settings.setDesktopNoLyricsBehavior,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          l10n.lyricsDesktopControls,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlPlayPause,
        value: settings.desktopControls[DesktopControlKeys.playPause] ?? true,
        onChanged: (value) =>
            settings.setDesktopControlVisible(DesktopControlKeys.playPause, value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlPrevious,
        value: settings.desktopControls[DesktopControlKeys.previous] ?? true,
        onChanged: (value) =>
            settings.setDesktopControlVisible(DesktopControlKeys.previous, value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlNext,
        value: settings.desktopControls[DesktopControlKeys.next] ?? true,
        onChanged: (value) =>
            settings.setDesktopControlVisible(DesktopControlKeys.next, value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlTranslation,
        value: settings.desktopControls[DesktopControlKeys.translation] ?? true,
        onChanged: (value) => settings.setDesktopControlVisible(
            DesktopControlKeys.translation, value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlLock,
        value: settings.desktopControls[DesktopControlKeys.lock] ?? true,
        onChanged: (value) =>
            settings.setDesktopControlVisible(DesktopControlKeys.lock, value),
      ),
      _switchRow(
        context,
        title: l10n.lyricsControlClose,
        value: settings.desktopControls[DesktopControlKeys.close] ?? true,
        onChanged: (value) =>
            settings.setDesktopControlVisible(DesktopControlKeys.close, value),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: M3EButton.icon(
          style: M3EButtonStyle.tonal,
          onPressed: display.resetDesktopPosition,
          icon: const Icon(Icons.center_focus_strong_rounded),
          label: Text(l10n.lyricsDesktopResetPosition),
        ),
      ),
    ];
  }

  List<Widget> _notificationRows(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
  ) {
    return [
      _switchRow(
        context,
        title: l10n.lyricsNotificationEnable,
        subtitle: l10n.lyricsNotificationEnableSubtitle,
        value: settings.notificationEnabled,
        onChanged: settings.setNotificationEnabled,
      ),
      _dropdownRow<LyricsMetadataTarget>(
        context,
        title: l10n.lyricsMetadataTarget,
        value: settings.notificationTarget,
        options: _targetOptions(l10n),
        onChanged: settings.setNotificationTarget,
      ),
      _dropdownRow<LyricsMetadataFormat>(
        context,
        title: l10n.lyricsMetadataFormat,
        value: settings.notificationFormat,
        options: _formatOptions(l10n),
        onChanged: settings.setNotificationFormat,
      ),
      _switchRow(
        context,
        title: l10n.lyricsMetadataIncludeTranslation,
        value: settings.notificationIncludeTranslation,
        onChanged: settings.setNotificationIncludeTranslation,
      ),
      _dropdownRow<LyricsPauseBehavior>(
        context,
        title: l10n.lyricsMetadataPauseBehavior,
        value: settings.notificationPauseBehavior,
        options: _pauseOptions(l10n),
        onChanged: settings.setNotificationPauseBehavior,
      ),
    ];
  }

  List<Widget> _bluetoothRows(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
    LyricsDisplayProvider display,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return [
      Row(
        children: [
          Icon(
            display.a2dpConnected
                ? Icons.bluetooth_connected_rounded
                : Icons.bluetooth_disabled_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            display.a2dpConnected
                ? l10n.lyricsBluetoothStatusConnected
                : l10n.lyricsBluetoothStatusDisconnected,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      const SizedBox(height: 4),
      _switchRow(
        context,
        title: l10n.lyricsBluetoothEnable,
        subtitle: l10n.lyricsBluetoothEnableSubtitle,
        value: settings.bluetoothEnabled,
        onChanged: settings.setBluetoothEnabled,
      ),
      _switchRow(
        context,
        title: l10n.lyricsBluetoothOnlyA2dp,
        value: settings.bluetoothOnlyWhenA2dp,
        onChanged: settings.setBluetoothOnlyWhenA2dp,
      ),
      _dropdownRow<LyricsMetadataTarget>(
        context,
        title: l10n.lyricsMetadataTarget,
        value: settings.bluetoothTarget,
        options: _targetOptions(l10n),
        onChanged: settings.setBluetoothTarget,
      ),
      _dropdownRow<LyricsMetadataFormat>(
        context,
        title: l10n.lyricsMetadataFormat,
        value: settings.bluetoothFormat,
        options: _formatOptions(l10n),
        onChanged: settings.setBluetoothFormat,
      ),
      _switchRow(
        context,
        title: l10n.lyricsMetadataIncludeTranslation,
        value: settings.bluetoothIncludeTranslation,
        onChanged: settings.setBluetoothIncludeTranslation,
      ),
      _dropdownRow<int>(
        context,
        title: l10n.lyricsBluetoothUpdateInterval,
        value: settings.bluetoothUpdateIntervalMs,
        options: [
          (0, l10n.lyricsBluetoothIntervalLine),
          (1000, l10n.lyricsBluetoothInterval1s),
          (2000, l10n.lyricsBluetoothInterval2s),
        ],
        onChanged: settings.setBluetoothUpdateIntervalMs,
      ),
      _dropdownRow<LyricsPauseBehavior>(
        context,
        title: l10n.lyricsMetadataPauseBehavior,
        value: settings.bluetoothPauseBehavior,
        options: _pauseOptions(l10n),
        onChanged: settings.setBluetoothPauseBehavior,
      ),
    ];
  }

  List<(LyricsMetadataTarget, String)> _targetOptions(AppLocalizations l10n) => [
        (LyricsMetadataTarget.subtitle, l10n.lyricsMetadataTargetSubtitle),
        (LyricsMetadataTarget.artist, l10n.lyricsMetadataTargetArtist),
        (LyricsMetadataTarget.title, l10n.lyricsMetadataTargetTitle),
        (LyricsMetadataTarget.album, l10n.lyricsMetadataTargetAlbum),
      ];

  List<(LyricsMetadataFormat, String)> _formatOptions(AppLocalizations l10n) => [
        (LyricsMetadataFormat.lyric, l10n.lyricsMetadataFormatLyric),
        (LyricsMetadataFormat.lyricTitle, l10n.lyricsMetadataFormatLyricTitle),
        (LyricsMetadataFormat.titleLyric, l10n.lyricsMetadataFormatTitleLyric),
      ];

  List<(LyricsPauseBehavior, String)> _pauseOptions(AppLocalizations l10n) => [
        (LyricsPauseBehavior.keep, l10n.lyricsBehaviorKeep),
        (LyricsPauseBehavior.title, l10n.lyricsBehaviorTitle),
        (LyricsPauseBehavior.clear, l10n.lyricsBehaviorClear),
      ];

  // --- 通用行组件 ---

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
        ),
      );

  Widget _card(BuildContext context, {required List<Widget> children}) =>
      M3ECard(
        variant: M3ECardVariant.filled,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );

  Widget _switchRow(
    BuildContext context, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          M3ESwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required String title,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title)),
              Text(
                valueLabel,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          M3ESlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            size: M3ESliderSize.xs,
            trackThickness: 6,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _dropdownRow<T>(
    BuildContext context, {
    required String title,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          SizedBox(
            width: 170,
            child: M3EDropdownMenu<T>(
              items: [
                for (final (optionValue, label) in options)
                  M3EDropdownItem<T>(
                    label: label,
                    value: optionValue,
                    selected: optionValue == value,
                  ),
              ],
              singleSelect: true,
              showChipAnimation: false,
              onSelectionChanged: (items) {
                if (items.isNotEmpty) onChanged(items.first.value);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 颜色行：取色方式（自定义 / 跟随主题角色）+ 自定义时的任意取色。
  ///
  /// - 预设色板提供快捷选择；「调色」按钮打开 HSV + Hex 任意调色器；
  /// - 跟随主题时颜色来自当前 ColorScheme（莫奈 / 封面取色统一出口），
  ///   主题变化会经调度自动重新下发，无需手动改色。
  Widget _colorRow(
    BuildContext context, {
    required String title,
    required int value,
    required LyricColorSource source,
    required ValueChanged<int> onSelected,
    required ValueChanged<LyricColorSource> onSourceChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title)),
              SizedBox(
                width: 170,
                child: M3EDropdownMenu<LyricColorSource>(
                  items: [
                    for (final (option, label) in _colorSourceOptions(l10n))
                      M3EDropdownItem<LyricColorSource>(
                        label: label,
                        value: option,
                        selected: option == source,
                      ),
                  ],
                  singleSelect: true,
                  showChipAnimation: false,
                  onSelectionChanged: (items) {
                    if (items.isNotEmpty) onSourceChanged(items.first.value);
                  },
                ),
              ),
            ],
          ),
          if (source == LyricColorSource.custom) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final preset in _colorPresets)
                  InkWell(
                    onTap: () => onSelected(preset),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(preset),
                        border: Border.all(
                          color: preset == value
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: preset == value ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                // 任意颜色：HSV + Hex，不受预设限制。
                InkWell(
                  onTap: () async {
                    final picked = await showAppColorPicker(
                      context,
                      initialColor: value,
                      withAlpha: true,
                    );
                    if (picked != null) onSelected(picked);
                  },
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Icon(
                      Icons.colorize_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<(LyricColorSource, String)> _colorSourceOptions(
    AppLocalizations l10n,
  ) =>
      [
        (LyricColorSource.custom, l10n.lyricsColorSourceCustom),
        (LyricColorSource.primary, l10n.lyricsColorSourcePrimary),
        (LyricColorSource.secondary, l10n.lyricsColorSourceSecondary),
        (LyricColorSource.tertiary, l10n.lyricsColorSourceTertiary),
        (LyricColorSource.onSurface, l10n.lyricsColorSourceOnSurface),
        (
          LyricColorSource.onSurfaceVariant,
          l10n.lyricsColorSourceOnSurfaceVariant
        ),
      ];

  /// 样式预览：用与悬浮窗相同的配置渲染一行示例，调完即所见。
  Widget _previewCard(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final fontSize = math.min(settings.desktopFontSize, 28.0);
    final played = Color(resolveLyricColor(
      settings.desktopPlayedColorSource,
      settings.desktopPlayedColor,
      scheme,
    ));
    final unplayed = Color(resolveLyricColor(
      settings.desktopUnplayedColorSource,
      settings.desktopUnplayedColor,
      scheme,
    ));
    final shadow = Color(resolveLyricColor(
      settings.desktopShadowColorSource,
      settings.desktopShadowColor,
      scheme,
    ));
    final previewLines = <Widget>[
      Text(
        l10n.lyricsDesktopPreviewLine,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: played.withValues(alpha: settings.desktopOpacity),
          fontSize: fontSize,
          shadows: [
            Shadow(color: shadow, blurRadius: 2, offset: const Offset(0, 1)),
          ],
        ),
      ),
    ];
    if (settings.translationEnabled && !settings.desktopSingleLine) {
      previewLines.add(
        Text(
          l10n.lyricsDesktopPreviewTranslation,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: unplayed.withValues(alpha: settings.desktopOpacity),
            fontSize: fontSize * 0.8,
            shadows: [
              Shadow(color: shadow, blurRadius: 2, offset: const Offset(0, 1)),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.lyricsDesktopPreview),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: previewLines,
            ),
          ),
        ],
      ),
    );
  }
}
