/// 高级设置页：首屏收起的低频与细节旋钮。
///
/// 原则：这里放「还在、但很少改」的选项（字体、默认封面、淡入淡出、加入
/// 位置、震动、应用名称、窗口记忆、省流音质、更新清单与镜像）。日常设置
/// 不再为它们付出首屏行数；底层设置键与默认值保持不变。
///
/// 分组标题按**内容**命名，不复用首屏一级卡名（外观 / 曲库与存储 / 通用 /
/// 桌面 / 音源与在线服务）：同一句话在两处出现会让用户以为是同一组设置。
/// 下载模板 / 标签 / 通知与缓存保留策略已并回「下载与缓存」页（同一域只在
/// 一个入口出现）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/theme_provider.dart';
import '../providers/update_provider.dart';
import '../services/app_branding_service.dart';
import '../services/data_saver_service.dart';
import '../services/haptics.dart';
import '../services/library/library_add_settings.dart';
import '../services/window/window_settings.dart';
import '../widgets/responsive.dart';
import '../widgets/labels/source_quality_label.dart';
import '../widgets/cover_picker_sheet.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/settings/playback_details_section.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/track_artwork.dart';

class SettingsAdvancedPage extends ConsumerWidget {
  const SettingsAdvancedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSubPage(
      title: l10n.settingsAdvancedTitle,
      safeArea: true,
      children: [
        _appearanceSection(context, ref, l10n),
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
        _updateSection(context, l10n),
      ],
    );
  }

  /// 字体与封面：两者都保留自定义能力，只是不再占首屏。
  Widget _appearanceSection(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final m3e = M3ETheme.of(context);
    final appFontFamily = ref.watch(
      themeProvider.select((theme) => theme.appFontFamily),
    );
    return SettingsSectionCard(
      title: l10n.settingsAdvancedAppearanceTitle,
      children: [
        SettingsNavTile(
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
          onTap: () => _showAppFontPicker(context, ref, l10n, appFontFamily),
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
              memCacheWidth: (40 * MediaQuery.devicePixelRatioOf(context))
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
      title: l10n.settingsAdvancedLibraryAddTitle,
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
      title: l10n.settingsAdvancedGeneralTitle,
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
      title: l10n.settingsAdvancedDesktopTitle,
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
      title: l10n.settingsAdvancedDataSaverTitle,
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

  Widget _updateSection(BuildContext context, AppLocalizations l10n) {
    final provider = context.watch<UpdateProvider?>();
    if (provider == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: l10n.settingsAdvancedUpdateSourceTitle,
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
    WidgetRef ref,
    AppLocalizations l10n,
    String? current,
  ) async {
    final theme = ref.read(themeProvider.notifier);
    final choice = await showFontPickerSheet(
      context,
      title: l10n.settingsAppFont,
      selected: current == null
          ? const FontChoice.system()
          : FontChoice.family(current),
    );
    if (choice == null || choice.inherit) return;
    await theme.setAppFontFamily(choice.family);
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
