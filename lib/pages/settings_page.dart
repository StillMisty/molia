import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/local_database_provider.dart';
import '../providers/nav_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/app_color_picker.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/nav_destination_icons.dart';
import '../services/app_branding_service.dart';
import '../services/language_service.dart';
import '../services/settings_service.dart';
import '../services/data_saver_service.dart';
import '../services/notification_service.dart';
import 'cache_management_page.dart';
import 'lyrics_display_page.dart';
import 'sources_page.dart';
import '../utils/responsive.dart';
import 'dart:math' as math;

// 设置页统一间距常量。
const double kDefaultPadding = 16.0;
const double kSectionSpacing = 24.0;
const double kElementSpacing = 16.0;
const double kSmallSpacing = 8.0;

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Container(
      padding: ResponsivePadding.horizontal(
        context,
        pageType: ResponsivePageType.modal,
      ),
      width: double.infinity,
      child: SingleChildScrollView(
        // 设置页只作为底部弹层/对话框内容出现，状态栏 padding 由弹层承担，
        // 这里再加会造成顶部大片空白。
        padding: const EdgeInsets.symmetric(vertical: kDefaultPadding),
        child: ResponsivePageContainer(
          pageType: ResponsivePageType.modal,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: kSmallSpacing),
                    child: Text(
                      l10n.settingsTitle,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  Row(
                    children: [
                      M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: kSectionSpacing),
              const SettingsMenuSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsMenuSection extends StatefulWidget {
  const SettingsMenuSection({super.key});

  @override
  State<SettingsMenuSection> createState() => _SettingsMenuSectionState();
}

class _SettingsMenuSectionState extends State<SettingsMenuSection> {
  /// 语言切换后强制 FutureBuilder 重新读取保存值。
  Key _languageKey = UniqueKey();

  double _dialogWidth(BuildContext context) {
    return math.min(
      MediaQuery.of(context).size.width * 0.9,
      context.layoutType(ResponsivePageType.modal).modalWidth,
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            // 小节标题是结构标签，不用强调色（强调色只给交互/选中）。
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!; // Get AppLocalizations instance
    // 省流模式：测试等场景可能不提供 provider，缺省时隐藏该区块。
    final dataSaver = context.watch<DataSaverService?>();

    return M3ECard(
      variant: M3ECardVariant.filled,
      borderRadius: BorderRadius.circular(kDefaultPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, l10n.settingsAppearanceTitle),
          const SizedBox(height: kElementSpacing),
          Selector<
              ThemeProvider,
              ({
                ThemeMode mode,
                bool dynamicColor,
                bool monet,
                bool monetAvailable,
                bool pureBlack,
                Color seed,
                String? appFont,
              })>(
            selector: (context, provider) => (
              mode: provider.themeMode,
              dynamicColor: provider.dynamicColorEnabled,
              monet: provider.monetColorEnabled,
              monetAvailable: provider.monetAvailable,
              pureBlack: provider.pureBlackEnabled,
              seed: provider.seedColor,
              appFont: provider.appFontFamily,
            ),
            builder: (context, appearance, _) {
              final (
                mode: themeMode,
                dynamicColor: dynamicColorEnabled,
                monet: monetColorEnabled,
                monetAvailable: monetAvailable,
                pureBlack: pureBlackEnabled,
                seed: seedColor,
                appFont: appFontFamily,
              ) = appearance;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSettingMenuItem(
                    context,
                    key: const Key('settingsThemeModeItem'),
                    icon: Icons.brightness_6_rounded,
                    title: l10n.settingsThemeMode,
                    subtitle: switch (themeMode) {
                      ThemeMode.system => l10n.themeModeSystem,
                      ThemeMode.light => l10n.themeModeLight,
                      ThemeMode.dark => l10n.themeModeDark,
                    },
                    onTap: () => _showThemeModeDialog(context, l10n),
                  ),
                  const SizedBox(height: kElementSpacing),
                  _buildValueSwitchMenuItem(
                    context,
                    switchKey: const Key('settingsDynamicColorSwitch'),
                    icon: Icons.palette_rounded,
                    title: l10n.settingsDynamicColor,
                    subtitle: l10n.settingsDynamicColorSubtitle,
                    value: dynamicColorEnabled,
                    onChanged: (value) => context
                        .read<ThemeProvider>()
                        .setDynamicColorEnabled(value),
                  ),
                  const SizedBox(height: kElementSpacing),
                  // 莫奈取色：平台（Android 12+）不支持时禁用并提示。
                  _buildValueSwitchMenuItem(
                    context,
                    switchKey: const Key('settingsMonetColorSwitch'),
                    icon: Icons.wallpaper_rounded,
                    title: l10n.settingsMonetColor,
                    subtitle: monetAvailable
                        ? l10n.settingsMonetColorSubtitle
                        : l10n.settingsMonetUnavailable,
                    value: monetColorEnabled,
                    enabled: monetAvailable,
                    onChanged: (value) => context
                        .read<ThemeProvider>()
                        .setMonetColorEnabled(value),
                  ),
                  const SizedBox(height: kElementSpacing),
                  _buildValueSwitchMenuItem(
                    context,
                    switchKey: const Key('settingsPureBlackSwitch'),
                    icon: Icons.dark_mode_rounded,
                    title: l10n.settingsPureBlack,
                    subtitle: l10n.settingsPureBlackSubtitle,
                    value: pureBlackEnabled,
                    onChanged: (value) => context
                        .read<ThemeProvider>()
                        .setPureBlackEnabled(value),
                  ),
                  const SizedBox(height: kElementSpacing),
                  _buildSettingMenuItem(
                    context,
                    key: const Key('settingsSeedColorItem'),
                    icon: Icons.color_lens_rounded,
                    title: l10n.settingsSeedColor,
                    subtitle: _seedColorLabel(l10n, seedColor),
                    onTap: () => _showSeedColorDialog(context, l10n),
                  ),
                  const SizedBox(height: kElementSpacing),
                  // 全局应用字体：来自设备已装字体，null = 系统默认。
                  _buildSettingMenuItem(
                    context,
                    key: const Key('settingsAppFontItem'),
                    icon: Icons.text_fields_rounded,
                    title: l10n.settingsAppFont,
                    subtitle: appFontFamily ?? l10n.fontSystemDefault,
                    onTap: () =>
                        _showAppFontPicker(context, l10n, appFontFamily),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: kSectionSpacing),

          _sectionTitle(context, l10n.settingsBottomNavTitle),
          const SizedBox(height: kElementSpacing),
          const _BottomNavSettings(),
          const SizedBox(height: kSectionSpacing),

          _sectionTitle(context, l10n.settingsPlaybackTitle),
          const SizedBox(height: kElementSpacing),
          Selector<PlaybackProvider, PlayMode>(
            selector: (context, provider) => provider.defaultPlayMode,
            builder: (context, defaultPlayMode, _) => _buildSettingMenuItem(
              context,
              key: const Key('settingsDefaultPlayModeItem'),
              icon: Icons.play_circle_outline_rounded,
              title: l10n.settingsDefaultPlayMode,
              subtitle: _playModeLabel(l10n, defaultPlayMode),
              onTap: () => _showDefaultPlayModeDialog(context, l10n),
            ),
          ),
          const SizedBox(height: kElementSpacing),
          Selector<PlaybackProvider, String>(
            selector: (context, provider) => provider.currentQualityLabel,
            builder: (context, qualityLabel, _) => _buildInfoMenuItem(
              context,
              key: const Key('settingsCurrentQualityItem'),
              icon: Icons.graphic_eq_rounded,
              title: l10n.settingsCurrentQuality,
              subtitle: qualityLabel,
            ),
          ),
          const SizedBox(height: kSectionSpacing),

          // 省流模式：默认关闭，开启后仅移动数据生效。
          if (dataSaver != null) ...[
            _sectionTitle(context, l10n.settingsDataSaverTitle),
            const SizedBox(height: kElementSpacing),
            _buildDataSaverSection(context, l10n, dataSaver),
            const SizedBox(height: kSectionSpacing),
          ],

          _sectionTitle(context, l10n.settingsSourcesSection),
          const SizedBox(height: kElementSpacing),
          _buildSettingMenuItem(
            context,
            icon: Icons.library_music_rounded,
            title: l10n.sourcesTitle,
            subtitle: l10n.settingsSourcesItemSubtitle,
            onTap: () {
              ResponsiveNavigation.showAdaptiveModalPage(
                context: context,
                child: const SourcesPage(),
              );
            },
          ),
          const SizedBox(height: kSectionSpacing),

          _sectionTitle(context, l10n.generalTitle),
          const SizedBox(height: kElementSpacing),
          FutureBuilder<Locale?>(
            future: LanguageService.getSavedLocale(),
            key: _languageKey,
            builder: (context, snapshot) {
              String languageDisplay = l10n.languageSystem;
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData) {
                final locale = snapshot.data!;
                switch (locale.languageCode) {
                  case 'en':
                    languageDisplay = l10n.languageEnglish;
                    break;
                  case 'zh':
                    languageDisplay = l10n.languageSimplifiedChinese;
                    break;
                  default:
                    languageDisplay = locale.toString();
                }
              }
              return _buildSettingMenuItem(
                context,
                icon: Icons.language_rounded,
                title: l10n.languageSettingTitle,
                subtitle: languageDisplay.isNotEmpty
                    ? languageDisplay
                    : l10n.languageSettingSubtitle,
                onTap: () => _showLanguageDialog(context, l10n, () {
                  setState(() {
                    _languageKey = UniqueKey();
                  });
                }),
              );
            },
          ),
          const SizedBox(height: kElementSpacing),
          // 应用名称：顶栏无歌曲时显示的自定义文案。
          ValueListenableBuilder<String>(
            valueListenable: AppBrandingService.titleNotifier,
            builder: (context, appTitle, _) => _buildSettingMenuItem(
              context,
              key: const Key('settingsAppTitleItem'),
              icon: Icons.badge_rounded,
              title: l10n.settingsAppTitle,
              subtitle: appTitle,
              onTap: () => _showAppTitleDialog(context, l10n),
            ),
          ),
          const SizedBox(height: kElementSpacing),
          _buildSwitchMenuItem(
            context,
            icon: Icons.text_format_rounded,
            title: l10n.copyLyricsAsSingleLineTitle,
            subtitle: l10n.copyLyricsAsSingleLineSubtitle,
          ),
          const SizedBox(height: kElementSpacing),
          // 歌词显示：桌面歌词 / 通知·锁屏 / 蓝牙（平台能力不足时页内隐藏分组）。
          _buildSettingMenuItem(
            context,
            key: const Key('settingsLyricsDisplayItem'),
            icon: Icons.lyrics_rounded,
            title: l10n.settingsLyricsDisplayTitle,
            subtitle: l10n.settingsLyricsDisplaySubtitle,
            onTap: () {
              ResponsiveNavigation.showAdaptiveModalPage(
                context: context,
                child: const LyricsDisplayPage(),
              );
            },
          ),
          const SizedBox(height: kSectionSpacing),

          _sectionTitle(context, l10n.dataManagementTitle),
          const SizedBox(height: kElementSpacing),
          _buildSettingMenuItem(
            context,
            icon: Icons.upload_file_rounded,
            title: l10n.exportDataTitle,
            subtitle: l10n.exportDataSubtitle,
            onTap: () => _exportData(context, l10n),
          ),
          const SizedBox(height: kElementSpacing),
          _buildSettingMenuItem(
            context,
            icon: Icons.download_rounded,
            title: l10n.importDataTitle,
            subtitle: l10n.importDataSubtitle,
            onTap: () => _showImportDialog(context, l10n),
          ),
          // LX Music 收藏夹（.lxmc）导入：Web 无 gzip/文件系统，隐藏入口。
          if (!kIsWeb) ...[
            const SizedBox(height: kElementSpacing),
            _buildSettingMenuItem(
              context,
              icon: Icons.favorite_border_rounded,
              title: l10n.libraryImportFavorites,
              subtitle: l10n.libraryImportFavoritesSubtitle,
              onTap: () => importLxmcFavoritesFlow(context),
            ),
          ],
          const SizedBox(height: kElementSpacing),
          // 缓存管理：音频/歌词/封面占用 + 策略 + 单清/全清。
          _buildSettingMenuItem(
            context,
            key: const Key('settingsCacheManagementItem'),
            icon: Icons.storage_rounded,
            title: l10n.settingsCacheTitle,
            subtitle: l10n.settingsCacheSubtitle,
            onTap: () {
              ResponsiveNavigation.showAdaptiveModalPage(
                context: context,
                child: const CacheManagementPage(),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 自定义应用名称：文本输入弹层（空白回退默认名称，随语言为 Molia/茉咏）。
  Future<void> _showAppTitleDialog(
      BuildContext context, AppLocalizations l10n) async {
    final controller = TextEditingController(
      text: AppBrandingService.titleNotifier.value,
    );
    final navigator = Navigator.of(context);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsAppTitleDialogTitle,
        content: SizedBox(
          width: _dialogWidth(context),
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
            onPressed: () => Navigator.pop(context),
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

  Widget _buildSettingMenuItem(
    BuildContext context, {
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return InkWell(
      key: key,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(kSmallSpacing),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // 危险操作图标底：error 容器成对色（不用 10% 透明红）。
                color: isDestructive
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: isDestructive
                    ? Theme.of(context).colorScheme.onErrorContainer
                    : Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: kElementSpacing),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: isDestructive
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final settingsService =
        Provider.of<SettingsService>(context, listen: false);
    return StatefulBuilder(builder: (context, setState) {
      return FutureBuilder<bool>(
          future: settingsService.getCopyLyricsAsSingleLine(),
          builder: (context, snapshot) {
            bool copyAsSingleLine = false;
            if (snapshot.hasData) {
              copyAsSingleLine = snapshot.data!;
            }

            return InkWell(
              onTap: () {
                if (snapshot.hasData) {
                  HapticFeedback.lightImpact();
                  final newValue = !copyAsSingleLine;
                  settingsService.saveCopyLyricsAsSingleLine(newValue);
                  setState(() {});
                }
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(kSmallSpacing),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        icon,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: kElementSpacing),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    M3ESwitch(
                      value: copyAsSingleLine,
                      onChanged: (bool value) {
                        HapticFeedback.lightImpact();
                        settingsService.saveCopyLyricsAsSingleLine(value);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            );
          });
    });
  }

  /// 只读信息项（无点击、无 chevron）：如「当前播放音质」。
  Widget _buildInfoMenuItem(
    BuildContext context, {
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(kSmallSpacing),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: kElementSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 省流模式区块：总开关 + 生效时的音质上限与封面省流子项。
  ///
  /// 副标题在开启后附带当前网络状态（移动数据已生效 / Wi-Fi 未生效 /
  /// 无法检测），让「仅移动数据生效」的行为对用户透明。
  Widget _buildDataSaverSection(
    BuildContext context,
    AppLocalizations l10n,
    DataSaverService dataSaver,
  ) {
    final status = !dataSaver.detectionAvailable
        ? l10n.settingsDataSaverNetworkUnknown
        : (dataSaver.onCellular
            ? l10n.settingsDataSaverNetworkCellular
            : l10n.settingsDataSaverNetworkWifi);
    final subtitle = dataSaver.enabled
        ? '${l10n.settingsDataSaverSubtitle} · $status'
        : l10n.settingsDataSaverSubtitle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildValueSwitchMenuItem(
          context,
          switchKey: const Key('settingsDataSaverSwitch'),
          icon: Icons.data_saver_on_rounded,
          title: l10n.settingsDataSaverTitle,
          subtitle: subtitle,
          value: dataSaver.enabled,
          onChanged: (value) => dataSaver.setEnabled(value),
        ),
        if (dataSaver.enabled) ...[
          const SizedBox(height: kElementSpacing),
          _buildSettingMenuItem(
            context,
            key: const Key('settingsDataSaverQualityItem'),
            icon: Icons.graphic_eq_rounded,
            title: l10n.settingsDataSaverQuality,
            subtitle: _dataSaverQualityLabel(l10n, dataSaver.qualityCap),
            onTap: () => _showDataSaverQualityDialog(context, l10n, dataSaver),
          ),
          const SizedBox(height: kElementSpacing),
          _buildValueSwitchMenuItem(
            context,
            switchKey: const Key('settingsDataSaverCoversSwitch'),
            icon: Icons.image_rounded,
            title: l10n.settingsDataSaverCovers,
            subtitle: l10n.settingsDataSaverCoversSubtitle,
            value: dataSaver.coversSaverEnabled,
            onChanged: (value) => dataSaver.setCoversSaverEnabled(value),
          ),
        ],
      ],
    );
  }

  /// 通用「图标 + 标题/副标题 + M3ESwitch」设置项（动态取色等 provider 状态）。
  /// [enabled] 为 false 时整项禁用（平台不支持的能力）。
  Widget _buildValueSwitchMenuItem(
    BuildContext context, {
    Key? switchKey,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              onChanged(!value);
            }
          : null,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Container(
          padding: const EdgeInsets.all(kSmallSpacing),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: kElementSpacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              M3ESwitch(
                key: switchKey,
                value: value,
                onChanged: enabled
                    ? (bool newValue) {
                        HapticFeedback.lightImpact();
                        onChanged(newValue);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 预设色名：按 [ThemeProvider.presetSeedColors] 的顺序取标签，
  /// 避免在设置页重复维护一份颜色字面量；自定义色回退为十六进制。
  String _seedColorLabel(AppLocalizations l10n, Color color) {
    final argb = color.toARGB32();
    final index = ThemeProvider.presetSeedColors
        .indexWhere((preset) => preset.toARGB32() == argb);
    return switch (index) {
      0 => l10n.colorBlue,
      1 => l10n.colorPurple,
      2 => l10n.colorGreen,
      3 => l10n.colorOrange,
      4 => l10n.colorPink,
      5 => l10n.colorTeal,
      _ =>
        '#${argb.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    };
  }

  String _playModeLabel(AppLocalizations l10n, PlayMode mode) {
    return switch (mode) {
      PlayMode.sequential => l10n.playModeSequential,
      PlayMode.shuffle => l10n.playModeShuffle,
      PlayMode.singleRepeat => l10n.playModeSingleRepeat,
    };
  }

  /// 省流音质上限显示名（复用音源页的音质文案）。
  String _dataSaverQualityLabel(AppLocalizations l10n, String quality) {
    return switch (quality) {
      '320k' => l10n.sourcesQuality320k,
      '192k' => l10n.sourcesQuality192k,
      '128k' => l10n.sourcesQuality128k,
      _ => quality,
    };
  }

  Future<void> _showDataSaverQualityDialog(BuildContext context,
      AppLocalizations l10n, DataSaverService dataSaver) async {
    final navigator = Navigator.of(context);

    Future<void> select(String quality) async {
      await dataSaver.setQualityCap(quality);
      navigator.pop();
    }

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsDataSaverQuality,
        content: SizedBox(
          width: _dialogWidth(context),
          child: M3ERadioGroup<String>(
            groupValue: dataSaver.qualityCap,
            onChanged: select,
            groupLabel: l10n.settingsDataSaverQuality,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final option in DataSaverService.qualityOptions)
                  M3ERadio<String>(
                    value: option,
                    groupValue: dataSaver.qualityCap,
                    label: Text(_dataSaverQualityLabel(l10n, option)),
                    onChanged: select,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  Future<void> _showThemeModeDialog(
      BuildContext context, AppLocalizations l10n) async {
    final themeProvider = context.read<ThemeProvider>();
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final navigator = Navigator.of(context);

    Future<void> select(ThemeMode mode) async {
      await themeProvider.setThemeMode(
        mode,
        platformBrightness: platformBrightness,
      );
      navigator.pop();
    }

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsThemeMode,
        content: SizedBox(
          width: _dialogWidth(context),
          child: M3ERadioGroup<ThemeMode>(
            groupValue: themeProvider.themeMode,
            onChanged: select,
            groupLabel: l10n.settingsThemeMode,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                M3ERadio<ThemeMode>(
                  value: ThemeMode.system,
                  groupValue: themeProvider.themeMode,
                  label: Text(l10n.themeModeSystem),
                  onChanged: select,
                ),
                M3ERadio<ThemeMode>(
                  value: ThemeMode.light,
                  groupValue: themeProvider.themeMode,
                  label: Text(l10n.themeModeLight),
                  onChanged: select,
                ),
                M3ERadio<ThemeMode>(
                  value: ThemeMode.dark,
                  groupValue: themeProvider.themeMode,
                  label: Text(l10n.themeModeDark),
                  onChanged: select,
                ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  Future<void> _showSeedColorDialog(
      BuildContext context, AppLocalizations l10n) async {
    final themeProvider = context.read<ThemeProvider>();
    final navigator = Navigator.of(context);

    Future<void> select(int argb) async {
      await themeProvider.setSeedColor(Color(argb));
      navigator.pop();
    }

    // 任意自定义色：HSV 滑杆 + Hex 输入（不限预设）。
    Future<void> pickCustom() async {
      final initial = themeProvider.seedColor.toARGB32();
      navigator.pop();
      final picked = await showAppColorPicker(context, initialColor: initial);
      if (picked == null) return;
      await themeProvider.setSeedColor(Color(picked));
    }

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsSeedColor,
        content: SizedBox(
          width: _dialogWidth(context),
          child: M3ERadioGroup<int>(
            groupValue: themeProvider.seedColor.toARGB32(),
            onChanged: select,
            groupLabel: l10n.settingsSeedColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final color in ThemeProvider.presetSeedColors)
                  M3ERadio<int>(
                    value: color.toARGB32(),
                    groupValue: themeProvider.seedColor.toARGB32(),
                    onChanged: select,
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: kSmallSpacing),
                        Text(_seedColorLabel(l10n, color)),
                      ],
                    ),
                  ),
                const SizedBox(height: kSmallSpacing),
                // M3EDialog 内容没有 Material 祖先：透明 Material 包一层 InkWell。
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: const Key('settingsSeedColorCustom'),
                    onTap: pickCustom,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.colorize_rounded,
                            size: 20,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: kSmallSpacing),
                          Text(l10n.colorPickerCustom),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  /// 全局应用字体选择：来自设备已装字体（枚举见 SystemFontsService），
  /// null 表示系统默认；选择后经 ThemeProvider 立即重建全局主题。
  Future<void> _showAppFontPicker(
      BuildContext context, AppLocalizations l10n, String? current) async {
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

  Future<void> _showDefaultPlayModeDialog(
      BuildContext context, AppLocalizations l10n) async {
    final playbackProvider = context.read<PlaybackProvider>();
    final navigator = Navigator.of(context);

    Future<void> select(PlayMode mode) async {
      await playbackProvider.setDefaultPlayMode(mode);
      navigator.pop();
    }

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.settingsDefaultPlayMode,
        content: SizedBox(
          width: _dialogWidth(context),
          child: M3ERadioGroup<PlayMode>(
            groupValue: playbackProvider.defaultPlayMode,
            onChanged: select,
            groupLabel: l10n.settingsDefaultPlayMode,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                M3ERadio<PlayMode>(
                  value: PlayMode.sequential,
                  groupValue: playbackProvider.defaultPlayMode,
                  label: Text(l10n.playModeSequential),
                  onChanged: select,
                ),
                M3ERadio<PlayMode>(
                  value: PlayMode.shuffle,
                  groupValue: playbackProvider.defaultPlayMode,
                  label: Text(l10n.playModeShuffle),
                  onChanged: select,
                ),
                M3ERadio<PlayMode>(
                  value: PlayMode.singleRepeat,
                  groupValue: playbackProvider.defaultPlayMode,
                  label: Text(l10n.playModeSingleRepeat),
                  onChanged: select,
                ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  Future<void> _exportData(BuildContext context, AppLocalizations l10n) async {
    final localDbProvider =
        Provider.of<LocalDatabaseProvider>(context, listen: false);
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final currentContext = context;

    try {
      bool success = await localDbProvider.exportDataToJson();
      if (!currentContext.mounted) return;
      // 成功时系统文件选择器本身即反馈，不再弹 toast；失败仍需提示。
      if (!success) {
        notificationService.showErrorSnackBar(l10n.exportFailed);
      }
    } catch (e) {
      if (currentContext.mounted) {
        notificationService.showErrorSnackBar(l10n.exportFailed);
      }
    }
  }

  String _currentLanguageValue(Locale? locale) {
    if (locale == null) return 'system';
    return locale.languageCode;
  }

  Future<void> _showLanguageDialog(BuildContext context, AppLocalizations l10n,
      VoidCallback onSuccess) async {
    final notificationService = context.read<NotificationService>();
    final navigator = Navigator.of(context);
    final currentContext = context;

    final currentLocale = await LanguageService.getSavedLocale();
    if (!currentContext.mounted) return;
    final currentValue = _currentLanguageValue(currentLocale);

    M3EDialog.show<void>(
      currentContext,
      dialog: StatefulBuilder(builder: (context, setState) {
        Future<void> selectLanguage(String value) async {
          try {
            final Locale? locale = switch (value) {
              'en' => const Locale('en'),
              'zh' => const Locale('zh'),
              _ => null, // system
            };
            await LanguageService.setAppLocale(locale);
            navigator.pop();
            // 语言切换后界面立即生效，即反馈；不再弹成功 toast。
            onSuccess();
          } catch (e) {
            if (currentContext.mounted) {
              notificationService
                  .showErrorSnackBar(l10n.failedToChangeLanguage(e.toString()));
            }
          }
        }

        return M3EDialog(
          title: l10n.languageDialogTitle,
          content: SizedBox(
            width: _dialogWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                M3ERadioGroup<String>(
                  groupValue: currentValue,
                  onChanged: selectLanguage,
                  groupLabel: l10n.languageDialogTitle,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      M3ERadio<String>(
                        value: 'system',
                        groupValue: currentValue,
                        label: Text(l10n.languageSystem),
                        onChanged: selectLanguage,
                      ),
                      M3ERadio<String>(
                        value: 'en',
                        groupValue: currentValue,
                        label: Text(l10n.languageEnglish),
                        onChanged: selectLanguage,
                      ),
                      M3ERadio<String>(
                        value: 'zh',
                        groupValue: currentValue,
                        label: Text(l10n.languageSimplifiedChinese),
                        onChanged: selectLanguage,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            M3EButton.text(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancelButton),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _showImportDialog(
      BuildContext context, AppLocalizations l10n) async {
    final localDbProvider =
        Provider.of<LocalDatabaseProvider>(context, listen: false);
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final navigator = Navigator.of(context);
    final currentContext = context;

    M3EDialog.show<void>(
      currentContext,
      dialog: M3EDialog(
        title: l10n.importDialogTitle,
        content: SizedBox(
          width: _dialogWidth(context),
          child: Text(
            l10n.importDialogMessage,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              try {
                bool success = await localDbProvider.importDataFromJson();
                if (!currentContext.mounted) return;
                if (success) {
                  notificationService.showSuccessSnackBar(l10n.importSuccess);
                } else {
                  notificationService.showErrorSnackBar(l10n.importFailed);
                }
              } catch (e) {
                if (currentContext.mounted) {
                  notificationService.showErrorSnackBar(l10n.importFailed);
                }
              }
            },
            child: Text(l10n.importButton),
          ),
        ],
      ),
    );
  }
}

/// 底部导航定制：拖拽排序 + 显示/隐藏（至少保留 1 个），即时生效并持久化。
class _BottomNavSettings extends StatelessWidget {
  const _BottomNavSettings();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 测试等场景可能不提供 NavProvider：缺省时隐藏该区块。
    final nav = context.watch<NavProvider?>();
    if (nav == null) return const SizedBox.shrink();
    final order = nav.order;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (oldIndex, newIndex) =>
              nav.reorder(oldIndex, newIndex),
          children: [
            for (var index = 0; index < order.length; index++)
              _buildRow(context, l10n, nav, order[index], index),
          ],
        ),
        const SizedBox(height: kSmallSpacing),
        Text(
          l10n.settingsBottomNavHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    NavProvider nav,
    ShellDestination destination,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 预览统一用实心变体（与底栏/侧栏选中态一致，识别度更好）。
    final icon = destination.filledIcon;
    final label = switch (destination) {
      ShellDestination.nowPlaying => l10n.nowPlayingLabel,
      ShellDestination.favorites => l10n.favoritesLabel,
      ShellDestination.library => l10n.libraryLabel,
    };

    return Padding(
      key: ValueKey(destination),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: IconTheme.merge(
              data: IconThemeData(
                color: scheme.onSecondaryContainer,
                size: 24,
              ),
              child: icon,
            ),
          ),
          const SizedBox(width: kElementSpacing),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          M3ESwitch(
            value: nav.isVisible(destination),
            onChanged: (bool value) async {
              HapticFeedback.lightImpact();
              final accepted = await nav.setVisible(destination, value);
              if (!accepted && context.mounted) {
                Provider.of<NotificationService>(context, listen: false)
                    .showSnackBar(l10n.settingsBottomNavKeepOne);
              }
            },
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle_rounded,
                  color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
