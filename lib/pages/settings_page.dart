import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/playback_provider.dart';
import '../providers/sources_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/theme_provider.dart';
import '../services/data_saver_service.dart';
import '../services/settings_service.dart';
import '../services/source_swap/source_swap_settings.dart';
import '../theme/scheme_builder.dart';
import '../utils/color_hex.dart';
import '../utils/data_saver_subtitle.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../widgets/app_color_picker.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/settings/settings_tiles.dart';
import 'ai_dj_page.dart';
import 'data_saver_settings_page.dart';
import 'data_settings_page.dart';
import 'general_settings_page.dart';
import 'lyrics_display_page.dart';
import 'sources_page.dart';
import 'sync_settings_page.dart';

/// 设置弹层：内部 Navigator 承载首屏与子页（避免弹层叠弹层）。
///
/// 首屏按语义分区：外观 / 播放 / 歌词与展示 / 内容与来源 / 通用与数据；
/// 子页经 [openSettingsSubPage] 推入本 Navigator，系统返回先退子页，
/// 回到首屏后再由弹层自身关闭（[NavigatorPopHandler] 转发）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.subPageOpen});

  /// 子页栈状态出口（true = 内部有子页可退）。
  ///
  /// M3E 底部弹层在系统返回时会给弹层内所有 PopScope 回调发
  /// didPop=false，并据此请求关闭；调用方把本通知器接到弹层
  /// `onDismissRequest` guard（false 保持弹层打开），系统返回才能
  /// 先退子页、再关弹层。中心对话框（large 宽）无需此出口。
  final ValueNotifier<bool>? subPageOpen;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 弹层宿主下发的滚动控制器：首屏滚动视图必须显式挂它，才能保留
  /// 「列表滚到顶继续下滑 = 收缩/关闭弹层」的联动。
  ///
  /// 为什么不能靠 PrimaryScrollController 自动继承：本页内部还有一层
  /// Navigator，Flutter 的 ModalRoute 会给每条路由装一个自己的
  /// PrimaryScrollController，会把弹层的控制器遮蔽掉（弹层拖拽随之失效）。
  M3EBottomSheetScrollController? _sheetScrollController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheetScrollController = M3EBottomSheet.scrollControllerOf(context);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<NavigationNotification>(
      onNotification: (notification) {
        // 嵌套 Navigator 的可弹栈状态：同步给弹层 dismiss guard。
        widget.subPageOpen?.value = notification.canHandlePop;
        return false;
      },
      child: NavigatorPopHandler(
        onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
        child: Navigator(
          key: _navigatorKey,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => _SettingsHomeView(
              scrollController: _sheetScrollController,
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置首屏：分区卡片 + 弹层内部子页入口。
class _SettingsHomeView extends StatefulWidget {
  const _SettingsHomeView({this.scrollController});

  /// 弹层滚动控制器（独立挂载时为 null，走默认行为）。
  final ScrollController? scrollController;

  @override
  State<_SettingsHomeView> createState() => _SettingsHomeViewState();
}

class _SettingsHomeViewState extends State<_SettingsHomeView> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 以下 provider 在测试等场景可能缺省：缺省时隐藏对应行，不报错。
    final dataSaver = context.watch<DataSaverService?>();
    final syncProvider = context.watch<SyncProvider?>();
    final sourceSwapSettings = context.watch<SourceSwapSettings?>();
    final sources = context.read<SourcesProvider?>();
    final theme = Theme.of(context);

    return Container(
      padding: ResponsivePadding.horizontal(
        context,
        pageType: ResponsivePageType.modal,
      ),
      width: double.infinity,
      child: SingleChildScrollView(
        // 挂弹层的滚动控制器：拖动列表到顶后继续下滑可收缩/关闭弹层。
        controller: widget.scrollController,
        // 设置页只作为底部弹层/对话框内容出现，状态栏 padding 由弹层承担，
        // 这里再加会造成顶部大片空白。
        padding: const EdgeInsets.symmetric(vertical: kSettingsPadding),
        child: ResponsivePageContainer(
          pageType: ResponsivePageType.modal,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: kSettingsSmallSpacing),
                    child: Text(
                      l10n.settingsTitle,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  Row(
                    children: [
                      M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        // 关闭的是承载设置的弹层（内部 Navigator 之上）。
                        onPressed: () => Navigator.of(context, rootNavigator: true)
                            .maybePop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: kSettingsSectionSpacing),
              _appearanceSection(context, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _playbackSection(
                context,
                l10n,
                dataSaver: dataSaver,
                sourceSwapSettings: sourceSwapSettings,
                sources: sources,
              ),
              const SizedBox(height: kSettingsSectionSpacing),
              _lyricsSection(context, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _contentSection(context, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _generalAndDataSection(context, l10n, syncProvider: syncProvider),
            ],
          ),
        ),
      ),
    );
  }

  /// 外观：主题模式 / 基础配色 / 自定义色（仅自定义时） / 封面覆盖 / 纯黑 / 字体。
  Widget _appearanceSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsAppearanceTitle,
      children: [
        Selector<
            ThemeProvider,
            ({
              ThemeMode mode,
              ColorBaseSource base,
              bool followArtwork,
              bool monetAvailable,
              bool pureBlack,
              Color seed,
              String? appFont,
            })>(
          selector: (context, provider) => (
            mode: provider.themeMode,
            base: provider.baseColorSource,
            followArtwork: provider.followArtworkEnabled,
            monetAvailable: provider.monetAvailable,
            pureBlack: provider.pureBlackEnabled,
            seed: provider.seedColor,
            appFont: provider.appFontFamily,
          ),
          builder: (context, appearance, _) {
            final (
              mode: themeMode,
              base: baseColorSource,
              followArtwork: followArtworkEnabled,
              monetAvailable: monetAvailable,
              pureBlack: pureBlackEnabled,
              seed: seedColor,
              appFont: appFontFamily,
            ) = appearance;
            // 同一个 Selector 产出的多行：行距由 SettingsRows 统一给。
            return SettingsRows(
              children: [
                SettingsChoiceRow<ThemeMode>(
                  key: const Key('settingsThemeModeItem'),
                  icon: Icons.brightness_6_rounded,
                  title: l10n.settingsThemeMode,
                  value: themeMode,
                  options: [
                    (ThemeMode.system, l10n.themeModeSystem),
                    (ThemeMode.light, l10n.themeModeLight),
                    (ThemeMode.dark, l10n.themeModeDark),
                  ],
                  onChanged: (mode) {
                    // 传平台亮度：system 模式下立即按当前系统亮度生效。
                    context.read<ThemeProvider>().setThemeMode(
                          mode,
                          platformBrightness:
                              MediaQuery.platformBrightnessOf(context),
                        );
                  },
                ),
                // 基础配色（单选）：壁纸 / 自定义；封面覆盖见下一项。
                SettingsChoiceRow<ColorBaseSource>(
                  key: const Key('settingsBaseColorItem'),
                  icon: Icons.palette_rounded,
                  title: l10n.settingsBaseColor,
                  subtitle: _baseColorSubtitle(
                    l10n,
                    baseColorSource,
                    monetAvailable: monetAvailable,
                    seedColor: seedColor,
                  ),
                  value: baseColorSource,
                  options: [
                    (ColorBaseSource.wallpaper, l10n.settingsBaseColorWallpaper),
                    (ColorBaseSource.custom, l10n.settingsBaseColorCustom),
                  ],
                  // 平台无莫奈时壁纸项禁用（仍可显示为选中态，配色回退种子色）。
                  optionEnabled: (source) =>
                      source != ColorBaseSource.wallpaper || monetAvailable,
                  onChanged: (source) =>
                      context.read<ThemeProvider>().setBaseColorSource(source),
                ),
                // 自定义色仅作基础配色时显示，避免与「壁纸」并存产生歧义。
                if (baseColorSource == ColorBaseSource.custom)
                  SettingsColorValueTile(
                    key: const Key('settingsSeedColorItem'),
                    icon: Icons.color_lens_rounded,
                    title: l10n.settingsSeedColor,
                    colorArgb: seedColor.toARGB32(),
                    onTap: () => _pickSeedColor(context),
                  ),
                // 封面覆盖层：盖过基础配色（含壁纸）；无封面回退。
                SettingsSwitchTile(
                  switchKey: const Key('settingsFollowArtworkSwitch'),
                  icon: Icons.album_rounded,
                  title: l10n.settingsFollowArtwork,
                  subtitle: l10n.settingsFollowArtworkSubtitle,
                  value: followArtworkEnabled,
                  onChanged: (value) => context
                      .read<ThemeProvider>()
                      .setFollowArtworkEnabled(value),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsPureBlackSwitch'),
                  icon: Icons.dark_mode_rounded,
                  title: l10n.settingsPureBlack,
                  subtitle: l10n.settingsPureBlackSubtitle,
                  value: pureBlackEnabled,
                  onChanged: (value) => context
                      .read<ThemeProvider>()
                      .setPureBlackEnabled(value),
                ),
                // 全局应用字体：来自设备已装字体，null = 系统默认。
                SettingsNavTile(
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
      ],
    );
  }

  /// 播放：默认播放模式 / 启动恢复 / 默认音质 / 当前音质 / 自动换源 / 省流入口。
  Widget _playbackSection(
    BuildContext context,
    AppLocalizations l10n, {
    required DataSaverService? dataSaver,
    required SourceSwapSettings? sourceSwapSettings,
    required SourcesProvider? sources,
  }) {
    return SettingsSectionCard(
      title: l10n.settingsPlaybackTitle,
      children: [
        Selector<PlaybackProvider, PlayMode>(
          selector: (context, provider) => provider.defaultPlayMode,
          builder: (context, defaultPlayMode, _) => SettingsChoiceRow<PlayMode>(
            key: const Key('settingsDefaultPlayModeItem'),
            icon: Icons.play_circle_outline_rounded,
            title: l10n.settingsDefaultPlayMode,
            // 「默认」= 新播放会话的初始模式，不打断当前播放。
            subtitle: l10n.settingsDefaultPlayModeSubtitle,
            value: defaultPlayMode,
            options: [
              (PlayMode.sequential, l10n.playModeSequential),
              (PlayMode.shuffle, l10n.playModeShuffle),
              (PlayMode.singleRepeat, l10n.playModeSingleRepeat),
            ],
            onChanged: (mode) =>
                context.read<PlaybackProvider>().setDefaultPlayMode(mode),
          ),
        ),
        Selector<PlaybackProvider, bool>(
          selector: (context, provider) => provider.restoreSessionEnabled,
          builder: (context, restoreSession, _) => SettingsSwitchTile(
            switchKey: const Key('settingsRestoreSessionSwitch'),
            icon: Icons.restore_rounded,
            title: l10n.settingsRestoreSessionTitle,
            subtitle: l10n.settingsRestoreSessionSubtitle,
            value: restoreSession,
            onChanged: (value) =>
                context.read<PlaybackProvider>().setRestoreSessionEnabled(value),
          ),
        ),
        // 音源默认音质：设置页唯一入口。
        if (sources != null)
          Selector<SourcesProvider, String>(
            selector: (context, provider) => provider.preferredQuality,
            builder: (context, quality, _) => SettingsDropdownRow<String>(
              key: const Key('settingsDefaultQualityItem'),
              icon: Icons.high_quality_rounded,
              title: l10n.sourcesDefaultQuality,
              subtitle: l10n.sourcesQualityHint,
              value: quality,
              options: [
                for (final option in sources.qualityOptions)
                  (option.value, sourceQualityLabel(l10n, option.value)),
              ],
              onChanged: sources.setPreferredQuality,
            ),
          ),
        Selector<PlaybackProvider, String>(
          selector: (context, provider) => provider.currentQualityLabel,
          builder: (context, qualityLabel, _) => SettingsInfoTile(
            key: const Key('settingsCurrentQualityItem'),
            icon: Icons.graphic_eq_rounded,
            title: l10n.settingsCurrentQuality,
            subtitle: qualityLabel,
          ),
        ),
        // 自动换源：播放失败后的跨源找回（手动换源不受此开关控制）。
        if (sourceSwapSettings != null)
          Selector<SourceSwapSettings, bool>(
            selector: (context, settings) => settings.autoEnabled,
            builder: (context, autoEnabled, _) => SettingsSwitchTile(
              switchKey: const Key('settingsAutoSourceSwapSwitch'),
              icon: Icons.swap_horiz_rounded,
              title: l10n.settingsAutoSourceSwap,
              subtitle: l10n.settingsAutoSourceSwapSubtitle,
              value: autoEnabled,
              onChanged: (value) => sourceSwapSettings.setAutoEnabled(value),
            ),
          ),
        // 省流模式：子页承载开关与子项，入口副标题保留网络状态。
        if (dataSaver != null)
          SettingsNavTile(
            key: const Key('settingsDataSaverItem'),
            icon: Icons.data_saver_on_rounded,
            title: l10n.settingsDataSaverTitle,
            subtitle: dataSaverSubtitle(
              l10n,
              enabled: dataSaver.enabled,
              detectionAvailable: dataSaver.detectionAvailable,
              onCellular: dataSaver.onCellular,
            ),
            onTap: () => openSettingsSubPage(
              context,
              const DataSaverSettingsPage(),
            ),
          ),
      ],
    );
  }

  /// 歌词与展示：歌词显示子页入口 + 复制单行开关。
  Widget _lyricsSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsLyricsSection,
      children: [
        // 歌词显示：歌词页 / 歌词输出 / 桌面歌词 / 通知·锁屏 / 蓝牙（二级子页）。
        SettingsNavTile(
          key: const Key('settingsLyricsDisplayItem'),
          icon: Icons.lyrics_rounded,
          title: l10n.settingsLyricsDisplayTitle,
          subtitle: l10n.settingsLyricsDisplaySubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const LyricsDisplayPage(),
          ),
        ),
        _buildCopyLyricsTile(context, l10n),
      ],
    );
  }

  /// 内容与来源：音源管理 / AI 推歌。
  Widget _contentSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsContentSection,
      children: [
        SettingsNavTile(
          icon: Icons.library_music_rounded,
          title: l10n.sourcesTitle,
          subtitle: l10n.settingsSourcesItemSubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const SourcesPage(),
          ),
        ),
        // AI 推歌：配置与开启入口（模式生效后推荐流出在发现页）。
        if (!kIsWeb)
          SettingsNavTile(
            key: const Key('settingsAiDjItem'),
            icon: Icons.auto_awesome_rounded,
            title: l10n.aiDjTitle,
            subtitle: l10n.aiDjSettingsSubtitle,
            onTap: () => openSettingsSubPage(
              context,
              const AiDjPage(),
            ),
          ),
      ],
    );
  }

  /// 通用与数据：通用子页 / 数据子页 / 同步子页。
  Widget _generalAndDataSection(
    BuildContext context,
    AppLocalizations l10n, {
    required SyncProvider? syncProvider,
  }) {
    final showSync = syncProvider != null && !kIsWeb;
    return SettingsSectionCard(
      title: l10n.settingsGeneralAndDataTitle,
      children: [
        SettingsNavTile(
          key: const Key('settingsGeneralItem'),
          icon: Icons.tune_rounded,
          title: l10n.generalTitle,
          subtitle: l10n.settingsGeneralSubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const GeneralSettingsPage(),
          ),
        ),
        SettingsNavTile(
          key: const Key('settingsDataItem'),
          icon: Icons.sd_storage_rounded,
          title: l10n.dataManagementTitle,
          subtitle: l10n.settingsDataSubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const DataSettingsPage(),
          ),
        ),
        if (showSync)
          SettingsNavTile(
            key: const Key('settingsSyncItem'),
            icon: Icons.sync_rounded,
            title: l10n.settingsSyncTitle,
            subtitle: l10n.settingsSyncItemSubtitle,
            onTap: () => openSettingsSubPage(
              context,
              const SyncSettingsPage(),
            ),
          ),
      ],
    );
  }

  /// 基础配色副标题：壁纸（平台不支持时说明）或当前自定义色 hex。
  String _baseColorSubtitle(
    AppLocalizations l10n,
    ColorBaseSource source, {
    required bool monetAvailable,
    required Color seedColor,
  }) {
    if (source != ColorBaseSource.wallpaper) {
      return colorHexLabel(seedColor.toARGB32());
    }
    return monetAvailable
        ? l10n.settingsBaseColorWallpaper
        : l10n.settingsMonetUnavailable;
  }

  /// 「将歌词复制为单行」开关（SettingsService 持久化，与歌词页共用）。
  Widget _buildCopyLyricsTile(BuildContext context, AppLocalizations l10n) {
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

            return SettingsSwitchTile(
              icon: Icons.text_format_rounded,
              title: l10n.copyLyricsAsSingleLineTitle,
              subtitle: l10n.copyLyricsAsSingleLineSubtitle,
              value: copyAsSingleLine,
              enabled: snapshot.hasData,
              onChanged: (value) {
                settingsService.saveCopyLyricsAsSingleLine(value);
                setState(() {});
              },
            );
          });
    });
  }

  /// 主题色：直接打开任意取色器（HSV + Hex）。
  ///
  /// 自定义色是「基础配色」的一种；封面覆盖开启时，播放有封面的歌曲
  /// 期间会被封面取色盖过（设置项文案已说明）。
  Future<void> _pickSeedColor(BuildContext context) async {
    final themeProvider = context.read<ThemeProvider>();
    final picked = await showAppColorPicker(
      context,
      initialColor: themeProvider.seedColor.toARGB32(),
    );
    if (picked == null) return;
    await themeProvider.setSeedColor(Color(picked));
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
}
