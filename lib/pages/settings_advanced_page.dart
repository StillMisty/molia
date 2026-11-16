/// 高级设置页：首屏收起的低频与细节旋钮。
///
/// 原则：这里放「还在、但很少改」的选项（字体、默认封面、淡入淡出、加入
/// 位置、震动、应用名称、窗口记忆、省流音质、下载模板/标签/通知、缓存保留
/// 策略、更新清单与镜像）。日常设置不再为它们付出首屏行数；底层设置键与
/// 默认值保持不变。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/theme_provider.dart';
import '../providers/update_provider.dart';
import '../services/app_branding_service.dart';
import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_manager.dart';
import '../services/download/download_settings.dart';
import '../services/haptics.dart';
import '../services/library/library_add_settings.dart';
import '../services/window/window_settings.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../widgets/cover_picker_sheet.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/settings/cache_policy_dialog.dart';
import '../widgets/settings/playback_details_section.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/track_artwork.dart';

class SettingsAdvancedPage extends StatelessWidget {
  const SettingsAdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSubPage(
      title: l10n.settingsAdvancedTitle,
      safeArea: true,
      children: [
        _appearanceSection(context, l10n),
        const SizedBox(height: kSettingsSectionSpacing),
        const PlaybackDetailsSection(),
        const SizedBox(height: kSettingsSectionSpacing),
        _librarySection(context, l10n),
        const SizedBox(height: kSettingsSectionSpacing),
        _generalSection(context, l10n),
        if (isDesktopPlatform()) ...[
          const SizedBox(height: kSettingsSectionSpacing),
          _desktopSection(l10n),
        ],
        const SizedBox(height: kSettingsSectionSpacing),
        _onlineSection(context, l10n),
        const SizedBox(height: kSettingsSectionSpacing),
        _downloadSection(context, l10n),
        const SizedBox(height: kSettingsSectionSpacing),
        const _CacheAdvancedSection(),
        const SizedBox(height: kSettingsSectionSpacing),
        _updateSection(context, l10n),
      ],
    );
  }

  /// 外观：应用字体与默认封面。两者都保留自定义能力，只是不再占首屏。
  Widget _appearanceSection(BuildContext context, AppLocalizations l10n) {
    final m3e = M3ETheme.of(context);
    return SettingsSectionCard(
      title: l10n.settingsAppearanceTitle,
      children: [
        Selector<ThemeProvider, String?>(
          selector: (context, provider) => provider.appFontFamily,
          builder: (context, appFontFamily, _) => SettingsNavTile(
            key: const Key('settingsAppFontItem'),
            icon: Icons.text_fields_rounded,
            title: l10n.settingsAppFont,
            subtitle: appFontFamily ?? l10n.fontSystemDefault,
            trailing: Text(
              'Aa',
              style: m3e.typeScale.titleMedium.copyWith(
                fontFamily: appFontFamily,
                color: m3e.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => _showAppFontPicker(context, l10n, appFontFamily),
          ),
        ),
        // 默认封面：只作用于没有封面 / 远端加载失败的歌曲封面，
        // 不参与取色、下载与标签。
        CoverChangeBuilder(
          builder: (context, _) => SettingsNavTile(
            key: const Key('settingsDefaultCoverItem'),
            icon: Icons.image_rounded,
            title: l10n.coverDefaultTitle,
            subtitle: l10n.coverDefaultSubtitle,
            trailing: TrackArtwork(
              // 只显示全局默认封面（没有曲目身份）；外层已订阅。
              listenForChanges: false,
              size: 40,
              borderRadius: M3EShapes.radiusMedium,
              memCacheWidth: (40 * MediaQuery.of(context).devicePixelRatio)
                  .round(),
              fallbackIconSize: 20,
            ),
            onTap: () => unawaited(
              showCoverPickerSheet(
                context,
                fileNameBase: l10n.coverDefaultTitle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _librarySection(BuildContext context, AppLocalizations l10n) {
    final settings = context.watch<LibraryAddSettings?>();
    if (settings == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: l10n.settingsLibraryStorageTitle,
      children: [
        Selector<LibraryAddSettings, LibraryAddPosition>(
          selector: (context, value) => value.position,
          builder: (context, position, _) =>
              SettingsChoiceRow<LibraryAddPosition>(
                key: const Key('settingsLibraryAddPositionItem'),
                icon: Icons.playlist_add_rounded,
                title: l10n.settingsLibraryAddPosition,
                subtitle: l10n.settingsLibraryAddPositionSubtitle,
                value: position,
                options: [
                  (LibraryAddPosition.top, l10n.settingsLibraryAddPositionTop),
                  (
                    LibraryAddPosition.bottom,
                    l10n.settingsLibraryAddPositionBottom,
                  ),
                ],
                onChanged: settings.setPosition,
              ),
        ),
      ],
    );
  }

  Widget _generalSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsGeneralTitle,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: HapticsService.enabledNotifier,
          builder: (context, hapticsEnabled, _) => SettingsSwitchTile(
            switchKey: const Key('settingsHapticsSwitch'),
            icon: Icons.vibration_rounded,
            title: l10n.settingsHapticsTitle,
            subtitle: l10n.settingsHapticsSubtitle,
            value: hapticsEnabled,
            onChanged: HapticsService.setEnabled,
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: AppBrandingService.titleNotifier,
          builder: (context, appTitle, _) => SettingsNavTile(
            key: const Key('settingsAppTitleItem'),
            icon: Icons.badge_rounded,
            title: l10n.settingsAppTitle,
            subtitle: appTitle,
            onTap: () => _showAppTitleDialog(context, l10n),
          ),
        ),
      ],
    );
  }

  Widget _desktopSection(AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsDesktopSection,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: WindowSettings.rememberBoundsNotifier,
          builder: (context, rememberBounds, _) => SettingsSwitchTile(
            switchKey: const Key('settingsRememberWindowBoundsSwitch'),
            icon: Icons.window_rounded,
            title: l10n.settingsRememberWindowBounds,
            subtitle: l10n.settingsRememberWindowBoundsSubtitle,
            value: rememberBounds,
            onChanged: WindowSettings.setRememberBounds,
          ),
        ),
      ],
    );
  }

  Widget _onlineSection(BuildContext context, AppLocalizations l10n) {
    final dataSaver = context.watch<DataSaverService?>();
    if (dataSaver == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: l10n.settingsNetworkSourcesTitle,
      children: [
        SettingsChoiceRow<String>(
          key: const Key('settingsDataSaverQualityItem'),
          icon: Icons.graphic_eq_rounded,
          title: l10n.settingsDataSaverQuality,
          subtitle: l10n.settingsDataSaverQualitySubtitle,
          value: dataSaver.qualityCap,
          options: [
            for (final option in DataSaverService.qualityOptions)
              (option, sourceQualityLabel(l10n, option)),
          ],
          onChanged: (value) => dataSaver.setQualityCap(value),
        ),
      ],
    );
  }

  Widget _downloadSection(BuildContext context, AppLocalizations l10n) {
    final settings = context.watch<DownloadSettings?>();
    if (settings == null) return const SizedBox.shrink();
    final downloads = context.watch<DownloadManager?>();
    return SettingsSectionCard(
      title: l10n.downloadSettingsTitle,
      children: [
        SettingsValueTile(
          key: const Key('downloadFilenameTemplateItem'),
          icon: Icons.edit_note_rounded,
          title: l10n.downloadFilenameTemplate,
          subtitle: l10n.downloadFilenameTemplateHint,
          value: settings.filenameTemplate,
          onTap: () => unawaited(_editTemplate(context, settings)),
        ),
        SettingsSwitchTile(
          switchKey: const Key('downloadEmbedTagsSwitch'),
          icon: Icons.music_note_rounded,
          title: l10n.downloadEmbedTags,
          subtitle: l10n.downloadEmbedTagsSubtitle,
          value: settings.embedTags,
          onChanged: (value) => unawaited(settings.setEmbedTags(value)),
        ),
        // 下载通知只在 Android 有语义（前台服务 + 通知栏进度）。
        if (downloads?.notificationsSupported ?? false)
          SettingsSwitchTile(
            switchKey: const Key('downloadNotificationsSwitch'),
            icon: Icons.notifications_active_rounded,
            title: l10n.downloadNotifications,
            subtitle: l10n.downloadNotificationsSubtitle,
            value: settings.notifications,
            onChanged: (value) => unawaited(settings.setNotifications(value)),
          ),
      ],
    );
  }

  Widget _updateSection(BuildContext context, AppLocalizations l10n) {
    final provider = context.watch<UpdateProvider?>();
    if (provider == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: l10n.updateAdvancedSection,
      children: [
        SettingsNavTile(
          key: const Key('settingsUpdateManifestItem'),
          icon: Icons.link_rounded,
          title: l10n.updateManifestOverrideTitle,
          subtitle: provider.manifestUrlOverride.isEmpty
              ? l10n.updateManifestOverrideDefault
              : provider.manifestUrlOverride,
          onTap: () => _editText(
            context,
            title: l10n.updateManifestOverrideTitle,
            hint: l10n.updateManifestOverrideHint,
            initial: provider.manifestUrlOverride,
            onSave: provider.setManifestUrlOverride,
          ),
        ),
        SettingsNavTile(
          key: const Key('settingsUpdateMirrorItem'),
          icon: Icons.cloud_download_rounded,
          title: l10n.updateDownloadPrefixTitle,
          subtitle: provider.downloadPrefix.isEmpty
              ? l10n.updateDownloadPrefixDefault
              : provider.downloadPrefix,
          onTap: () => _editText(
            context,
            title: l10n.updateDownloadPrefixTitle,
            hint: l10n.updateDownloadPrefixHint,
            initial: provider.downloadPrefix,
            onSave: provider.setDownloadPrefix,
          ),
        ),
      ],
    );
  }

  /// 全局应用字体选择：来自设备已装字体（枚举见 SystemFontsService），
  /// null 表示系统默认；选择后经 ThemeProvider 立即重建全局主题。
  Future<void> _showAppFontPicker(
    BuildContext context,
    AppLocalizations l10n,
    String? current,
  ) async {
    final themeProvider = context.read<ThemeProvider>();
    final choice = await showFontPickerSheet(
      context,
      title: l10n.settingsAppFont,
      selected: current == null
          ? const FontChoice.system()
          : FontChoice.family(current),
    );
    if (choice == null || choice.inherit) return;
    await themeProvider.setAppFontFamily(choice.family);
  }

  /// 自定义应用名称：文本输入弹层（空白回退默认名称 Molia）。
  Future<void> _showAppTitleDialog(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final controller = TextEditingController(
      text: AppBrandingService.titleNotifier.value,
    );
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义），关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsAppTitleDialogTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ETextField(
            controller: controller,
            placeholder: l10n.settingsAppTitleHint,
            leading: const Icon(Icons.badge_rounded),
            maxLength: AppBrandingService.maxLength,
            autofocus: true,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () async {
              await AppBrandingService.setTitle(controller.text);
              navigator.pop();
            },
            child: Text(l10n.saveChanges),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  /// 编辑文件名模板：实时预览 + 恢复默认。
  Future<void> _editTemplate(
    BuildContext context,
    DownloadSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: settings.filenameTemplate);
    final navigator = Navigator.of(context, rootNavigator: true);
    final result = await M3EDialog.show<String>(
      context,
      dialog: StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = DownloadSettings.applyTemplate(
            controller.text,
            const {'artist': '歌手', 'title': '歌名', 'album': '专辑'},
          );
          return M3EDialog(
            title: l10n.downloadFilenameTemplate,
            content: SizedBox(
              width: settingsDialogWidth(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  M3ETextField(
                    controller: controller,
                    autofocus: true,
                    placeholder: l10n.downloadFilenameTemplate,
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (_) => navigator.pop(controller.text),
                  ),
                  const SizedBox(height: kSettingsSmallSpacing),
                  Text(
                    l10n.downloadFilenameTemplateHint,
                    style: context.typeScale.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.downloadFilenamePreview}: $preview',
                    style: context.typeScale.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              M3EButton.text(
                onPressed: () {
                  controller.text = kDefaultFilenameTemplate;
                  setDialogState(() {});
                },
                child: Text(l10n.downloadReset),
              ),
              M3EButton.text(
                onPressed: () => navigator.pop(),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed: () => navigator.pop(controller.text),
                child: Text(l10n.save),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null) return;
    await settings.setFilenameTemplate(result);
  }

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required Future<void> Function(String value) onSave,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: initial);
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: title,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ETextField(
            controller: controller,
            placeholder: hint,
            leading: const Icon(Icons.link_rounded),
            autofocus: true,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () async {
              await onSave(controller.text);
              navigator.pop();
            },
            child: Text(l10n.saveChanges),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}

/// 缓存保留策略（歌词 TTL / 封面数量与过期）：低频数值，只在高级页出现。
class _CacheAdvancedSection extends StatefulWidget {
  const _CacheAdvancedSection();

  static const int _daysMin = 1;
  static const int _daysMax = 3650; // 10 年
  static const int _artworkMaxMin = 10;
  static const int _artworkMaxMax = 100000;

  @override
  State<_CacheAdvancedSection> createState() => _CacheAdvancedSectionState();
}

class _CacheAdvancedSectionState extends State<_CacheAdvancedSection> {
  int _lyricsTtlDays = CacheService.defaultLyricsTtlDays;
  int _artworkMaxObjects = CacheService.defaultArtworkMaxObjects;
  int _artworkStaleDays = CacheService.defaultArtworkStaleDays;

  CacheService? get _service => context.read<CacheService?>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final service = _service;
    if (service == null) return;
    unawaited(
      Future.wait([
        service.lyricsTtlDays(),
        service.artworkMaxObjects(),
        service.artworkStaleDays(),
      ]).then((values) {
        if (!mounted) return;
        setState(() {
          _lyricsTtlDays = values[0];
          _artworkMaxObjects = values[1];
          _artworkStaleDays = values[2];
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_service == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: l10n.settingsCacheTitle,
      children: [
        SettingsValueTile(
          icon: Icons.schedule_rounded,
          title: l10n.cachePolicyLyricsTtl,
          value: _lyricsTtlDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_lyricsTtlDays),
          onTap: () => _edit(
            context,
            title: l10n.cachePolicyLyricsTtl,
            current: _lyricsTtlDays,
            min: _CacheAdvancedSection._daysMin,
            max: _CacheAdvancedSection._daysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheNeverExpire : l10n.cacheValueDays(value),
            onSelected: (value) async {
              setState(() => _lyricsTtlDays = value);
              await _service?.setLyricsTtlDays(value);
            },
          ),
        ),
        SettingsValueTile(
          icon: Icons.image_rounded,
          title: l10n.cachePolicyArtworkMax,
          value: _artworkMaxObjects <= 0
              ? l10n.cacheUnlimited
              : l10n.cacheValueItems(_artworkMaxObjects),
          onTap: () => _edit(
            context,
            title: l10n.cachePolicyArtworkMax,
            current: _artworkMaxObjects,
            min: _CacheAdvancedSection._artworkMaxMin,
            max: _CacheAdvancedSection._artworkMaxMax,
            unitLabel: l10n.cacheUnitItems,
            zeroLabel: l10n.cacheUnlimited,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheUnlimited : l10n.cacheValueItems(value),
            onSelected: (value) async {
              setState(() => _artworkMaxObjects = value);
              await _service?.setArtworkMaxObjects(value);
            },
          ),
        ),
        SettingsValueTile(
          icon: Icons.update_rounded,
          title: l10n.cachePolicyArtworkStale,
          value: _artworkStaleDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_artworkStaleDays),
          onTap: () => _edit(
            context,
            title: l10n.cachePolicyArtworkStale,
            current: _artworkStaleDays,
            min: _CacheAdvancedSection._daysMin,
            max: _CacheAdvancedSection._daysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheNeverExpire : l10n.cacheValueDays(value),
            onSelected: (value) async {
              setState(() => _artworkStaleDays = value);
              await _service?.setArtworkStaleDays(value);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context, {
    required String title,
    required int current,
    required int min,
    required int max,
    required String unitLabel,
    required String zeroLabel,
    required String Function(int value) labelOf,
    required ValueChanged<int> onSelected,
  }) async {
    final value = await showCachePolicyValueDialog(
      context,
      title: title,
      current: current,
      min: min,
      max: max,
      unitLabel: unitLabel,
      zeroLabel: zeroLabel,
      labelOf: labelOf,
    );
    if (value == null || !mounted) return;
    onSelected(value);
  }
}
