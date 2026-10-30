import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/lyrics_display_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/sources_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/update_provider.dart';
import '../services/audio_focus_settings.dart';
import '../services/data_saver_service.dart';
import '../services/library/library_add_settings.dart';
import '../services/lyrics_display/lyrics_output.dart';
import '../services/source_swap/source_swap_settings.dart';
import '../theme/m3e_context.dart';
import '../theme/scheme_builder.dart';
import '../utils/color_hex.dart';
import '../utils/data_saver_subtitle.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../widgets/app_color_picker.dart';
import '../widgets/cover_picker_sheet.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/settings/settings_section_grid.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/track_artwork.dart';
import 'ai_dj_page.dart';
import 'data_settings_page.dart';
import 'general_settings_page.dart';
import 'lyrics_display/desktop_lyrics_settings_page.dart';
import 'lyrics_display/lyrics_content_settings_page.dart';
import 'lyrics_display/system_media_lyrics_settings_page.dart';
import 'play_statistics_page.dart';
import 'shortcut_settings_page.dart';
import 'sources_page.dart';
import 'sync_settings_page.dart';
import 'update_settings_page.dart';

/// 宽屏设置弹层宽度（首屏两列画布上限）。
///
/// 弹层宿主在 `widgets/settings/settings_sheet.dart` 用同一常量封顶弹层宽度；
/// 两列启用判据由壳层解析的 `DesktopLayout.masterDetail` 给出
/// （见 desktop_layout.dart）；列宽不随窗口继续变宽，子页是长表单保持单列。
const double kSettingsSheetDesktopWidth = 880;

/// 设置首屏内容：分区卡片 + 子页入口。
///
/// 只负责内容；弹层宿主、内层 Navigator 与预测返回归属在
/// `widgets/settings/settings_sheet.dart`。独立挂载（测试等）时照常渲染，
/// 子页经 `openSettingsSubPage` push 到最近的 Navigator。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.scrollController});

  /// 弹层滚动控制器（独立挂载时为 null，走默认行为）。
  final ScrollController? scrollController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // 首屏直达的桌面歌词入口按能力显隐：打开设置时先复查一次。
        context.read<LyricsDisplayProvider?>()?.refreshCapabilities();
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
      // 从系统「显示在其他应用上层」授权页返回：复查桌面歌词能力。
      context.read<LyricsDisplayProvider?>()?.refreshCapabilities();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 以下 provider 在测试等场景可能缺省：缺省时隐藏对应行，不报错。
    final dataSaver = context.watch<DataSaverService?>();
    final syncProvider = context.watch<SyncProvider?>();
    final updateProvider = context.watch<UpdateProvider?>();
    final sourceSwapSettings = context.watch<SourceSwapSettings?>();
    final libraryAddSettings = context.watch<LibraryAddSettings?>();
    final audioFocusSettings = context.watch<AudioFocusSettings?>();
    final sources = context.read<SourcesProvider?>();
    final lyricsDisplay = context.watch<LyricsDisplayProvider?>();
    // 两列流式需要比单列舒适行宽（`maxWidth`）更宽的画布：上限取设置弹层
    // 宽度，两列各占约半宽；单列沿用 `maxWidth` 不变。判据由壳层解析的
    // DesktopLayout 给出（`masterDetail` 的当前消费方只此一处）。
    final twoColumn = DesktopLayout.of(context).masterDetail;

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
          maxWidth: twoColumn ? kSettingsSheetDesktopWidth : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSectionGrid(
                twoColumn: twoColumn,
                // 宽屏按内容量分列：外观 / 封面 / 歌词 / 通用在左，
                // 播放 / 内容 / 数据在右；左列约 13 行、右列约 13 行。
                startColumn: const {0, 1, 3, 5},
                children: [
                  _appearanceSection(context, l10n),
                  _coversSection(context, l10n),
                  _playbackSection(
                    context,
                    l10n,
                    dataSaver: dataSaver,
                    sourceSwapSettings: sourceSwapSettings,
                    libraryAddSettings: libraryAddSettings,
                    audioFocusSettings: audioFocusSettings,
                    sources: sources,
                  ),
                  _lyricsSection(context, l10n, lyricsDisplay),
                  _contentSection(context, l10n),
                  _generalSection(
                    context,
                    l10n,
                    updateProvider: updateProvider,
                  ),
                  _dataSection(
                    context,
                    l10n,
                    syncProvider: syncProvider,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 外观：主题模式 / 基础配色 / 自定义色（仅自定义时） / 纯黑 / 字体。
  Widget _appearanceSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsAppearanceTitle,
      children: [
        Selector<
            ThemeProvider,
            ({
              ThemeMode mode,
              ColorBaseSource base,
              SystemBaseColorSource systemColorSource,
              bool pureBlack,
              Color seed,
              String? appFont,
            })>(
          selector: (context, provider) => (
            mode: provider.themeMode,
            base: provider.baseColorSource,
            systemColorSource: provider.systemBaseColorSource,
            pureBlack: provider.pureBlackEnabled,
            seed: provider.seedColor,
            appFont: provider.appFontFamily,
          ),
          builder: (context, appearance, _) {
            final (
              mode: themeMode,
              base: baseColorSource,
              systemColorSource: systemColorSource,
              pureBlack: pureBlackEnabled,
              seed: seedColor,
              appFont: appFontFamily,
            ) = appearance;
            final m3e = M3ETheme.of(context);
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
                // 基础配色（单选）：壁纸 / 自定义；封面取色见「封面」分区。
                SettingsChoiceRow<ColorBaseSource>(
                  key: const Key('settingsBaseColorItem'),
                  icon: Icons.palette_rounded,
                  title: l10n.settingsBaseColor,
                  subtitle: _baseColorSubtitle(
                    l10n,
                    baseColorSource,
                    systemColorSource: systemColorSource,
                    seedColor: seedColor,
                  ),
                  value: baseColorSource,
                  options: [
                    (
                      ColorBaseSource.wallpaper,
                      l10n.settingsBaseColorWallpaper
                    ),
                    (ColorBaseSource.custom, l10n.settingsBaseColorCustom),
                  ],
                  // 壁纸图 / 强调色都不可用时壁纸项禁用
                  //（仍可显示为选中态，配色回退种子色）。
                  optionEnabled: (source) =>
                      source != ColorBaseSource.wallpaper ||
                      systemColorSource != SystemBaseColorSource.unavailable,
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
                SettingsSwitchTile(
                  switchKey: const Key('settingsPureBlackSwitch'),
                  icon: Icons.dark_mode_rounded,
                  title: l10n.settingsPureBlack,
                  subtitle: l10n.settingsPureBlackSubtitle,
                  value: pureBlackEnabled,
                  onChanged: (value) =>
                      context.read<ThemeProvider>().setPureBlackEnabled(value),
                ),
                // 全局应用字体：来自设备已装字体，null = 系统默认；
                // 行尾 "Aa" 用所选字体渲染，名称只作副标题。
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
                  onTap: () => _showAppFontPicker(context, l10n, appFontFamily),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 封面：播放时跟随封面取色 / 默认封面。
  ///
  /// 「同步自定义封面」不在这里：同步类别状态只有「跨设备同步 › 同步内容」
  /// 一处入口，外观页不再放第二份快捷开关。
  Widget _coversSection(BuildContext context, AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsCoversSection,
      children: [
        Selector<ThemeProvider, bool>(
          selector: (context, provider) => provider.followArtworkEnabled,
          builder: (context, followArtworkEnabled, _) => SettingsSwitchTile(
            switchKey: const Key('settingsFollowArtworkSwitch'),
            icon: Icons.album_rounded,
            title: l10n.settingsFollowArtwork,
            subtitle: l10n.settingsFollowArtworkSubtitle,
            value: followArtworkEnabled,
            onChanged: (value) => context
                .read<ThemeProvider>()
                .setFollowArtworkEnabled(value),
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
              borderRadius: BorderRadius.circular(10),
              memCacheWidth:
                  (40 * MediaQuery.of(context).devicePixelRatio).round(),
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

  /// 播放：默认播放模式 / 启动恢复 / 加入位置 / 默认音质 / 自动换源 /
  /// 省流（开关与生效子项）。
  ///
  /// 省流不单开子页：开关行排在分区末位，开启时才展开音质上限与封面省流
  /// （三行共用同一套设置行，行为与独立子页一致）。
  Widget _playbackSection(
    BuildContext context,
    AppLocalizations l10n, {
    required DataSaverService? dataSaver,
    required SourceSwapSettings? sourceSwapSettings,
    required LibraryAddSettings? libraryAddSettings,
    required AudioFocusSettings? audioFocusSettings,
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
              (PlayMode.listLoop, l10n.playModeListLoop),
              (PlayMode.sequential, l10n.playModeSequential),
              (PlayMode.singleRepeat, l10n.playModeSingleRepeat),
              (PlayMode.shuffle, l10n.playModeShuffle),
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
            onChanged: (value) => context
                .read<PlaybackProvider>()
                .setRestoreSessionEnabled(value),
          ),
        ),
        // 其他应用播放声音时是否继续播放：桌面没有音频焦点实现，不显示。
        if (audioFocusSettings != null && !isDesktopPlatform())
          Selector<AudioFocusSettings, bool>(
            selector: (context, settings) => settings.playWithOtherApps,
            builder: (context, playWithOtherApps, _) => SettingsSwitchTile(
              switchKey: const Key('settingsPlayWithOtherAppsSwitch'),
              icon: Icons.multitrack_audio_rounded,
              title: l10n.settingsPlayWithOtherApps,
              subtitle: l10n.settingsPlayWithOtherAppsSubtitle,
              value: playWithOtherApps,
              onChanged: audioFocusSettings.setPlayWithOtherApps,
            ),
          ),
        // 加入收藏 / 列表的位置：新曲目放开头还是末尾（默认开头）。
        if (libraryAddSettings != null)
          Selector<LibraryAddSettings, LibraryAddPosition>(
            selector: (context, settings) => settings.position,
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
              onChanged: libraryAddSettings.setPosition,
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
              // 音质标签都是短词（无损 / 320K / Hi-Res）：字段从 112 起按最长
              // 选项自适应加宽（「Hi-Res」不被折行），把其余宽度让给标题与说明。
              fieldWidth: 112,
              value: quality,
              options: [
                for (final option in sources.qualityOptions)
                  (option.value, sourceQualityLabel(l10n, option.value)),
              ],
              onChanged: sources.setPreferredQuality,
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
        // 省流模式：开关行在分区末位，开启时才展开跟随子项（音质上限 / 封面省流）；
        // 副标题保留当前网络状态，让「仅移动数据生效」对用户透明。
        if (dataSaver != null) ...[
          SettingsSwitchTile(
            switchKey: const Key('settingsDataSaverSwitch'),
            icon: Icons.data_saver_on_rounded,
            title: l10n.settingsDataSaverTitle,
            subtitle: dataSaverSubtitle(
              l10n,
              enabled: dataSaver.enabled,
              detectionAvailable: dataSaver.detectionAvailable,
              onCellular: dataSaver.onCellular,
            ),
            value: dataSaver.enabled,
            onChanged: (value) => dataSaver.setEnabled(value),
          ),
          if (dataSaver.enabled) ...[
            SettingsChoiceRow<String>(
              key: const Key('settingsDataSaverQualityItem'),
              icon: Icons.graphic_eq_rounded,
              title: l10n.settingsDataSaverQuality,
              value: dataSaver.qualityCap,
              options: [
                for (final option in DataSaverService.qualityOptions)
                  (option, sourceQualityLabel(l10n, option)),
              ],
              onChanged: (value) => dataSaver.setQualityCap(value),
            ),
            SettingsSwitchTile(
              switchKey: const Key('settingsDataSaverCoversSwitch'),
              icon: Icons.image_rounded,
              title: l10n.settingsDataSaverCovers,
              subtitle: l10n.settingsDataSaverCoversSubtitle,
              value: dataSaver.coversSaverEnabled,
              onChanged: (value) => dataSaver.setCoversSaverEnabled(value),
            ),
          ],
        ],
      ],
    );
  }

  /// 歌词与展示：桌面歌词 / 歌词与输出 / 系统媒体歌词（三条叶子入口）。
  ///
  /// 输出入口按平台能力显隐（桌面歌词＝悬浮窗能力、系统媒体＝媒体会话能力；
  /// 不支持的平台隐藏入口，避免开关撒谎）；「歌词与输出」与应用内歌词页
  /// 及共享项相关，与输出能力无关，始终可见。
  Widget _lyricsSection(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplayProvider? lyricsDisplay,
  ) {
    final LyricsOutputCapability desktopCapability = lyricsDisplay == null
        ? LyricsOutputCapability.unsupported
        : lyricsDisplay.capabilityOf(LyricsOutputIds.desktop);
    final LyricsOutputCapability mediaCapability = lyricsDisplay == null
        ? LyricsOutputCapability.unsupported
        : lyricsDisplay.capabilityOf(LyricsOutputIds.media);
    final bool desktopSupported =
        desktopCapability != LyricsOutputCapability.unsupported;
    final bool mediaSupported =
        mediaCapability != LyricsOutputCapability.unsupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: l10n.settingsLyricsSection,
          children: [
            if (desktopSupported)
              SettingsNavTile(
                key: const Key('settingsDesktopLyricsItem'),
                icon: Icons.picture_in_picture_alt_rounded,
                title: l10n.lyricsDesktopTitle,
                subtitle: l10n.lyricsDesktopEntrySubtitle,
                onTap: () => openSettingsSubPage(
                  context,
                  const DesktopLyricsSettingsPage(),
                ),
              ),
            SettingsNavTile(
              key: const Key('settingsLyricsContentItem'),
              icon: Icons.lyrics_rounded,
              title: l10n.lyricsContentTitle,
              subtitle: l10n.lyricsContentSubtitle,
              onTap: () => openSettingsSubPage(
                context,
                const LyricsContentSettingsPage(),
              ),
            ),
            if (mediaSupported)
              SettingsNavTile(
                key: const Key('settingsSystemMediaLyricsItem'),
                icon: Icons.notifications_active_rounded,
                title: l10n.lyricsSystemMediaTitle,
                subtitle: l10n.lyricsSystemMediaSubtitle,
                onTap: () => openSettingsSubPage(
                  context,
                  const SystemMediaLyricsSettingsPage(),
                ),
              ),
          ],
        ),
        // 桌面歌词与系统媒体两路输出都不可用：给一句解释，而不是静默只剩一条
        // 入口。
        if (!desktopSupported && !mediaSupported)
          _lyricsSectionHint(context, l10n.lyricsDisplayUnsupported),
        // 平台支持但媒体会话初始化失败（音频服务 init 返回 null）：
        // 给出可见提示——否则系统媒体入口消失、只剩日志，用户无法自查。
        if (mediaSupported && lyricsDisplay?.mediaSessionInitFailed == true)
          _lyricsSectionHint(context, l10n.lyricsMediaSessionUnavailable),
      ],
    );
  }

  Widget _lyricsSectionHint(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: kSettingsSectionSpacing),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.typeScale.bodyMedium.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
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

  /// 通用与数据：通用子页 / 快捷键 / 听歌统计 / 数据子页 / 同步 / 更新。
  ///
  /// 两部分各自成卡（原来的「通用与数据」一张卡内容太长）：快捷键（桌面）与
  /// 听歌统计从通用 / 数据子页提到首屏——两者是高频入口，原先要找两步。
  Widget _generalSection(
    BuildContext context,
    AppLocalizations l10n, {
    required UpdateProvider? updateProvider,
  }) {
    return SettingsSectionCard(
      title: l10n.generalTitle,
      children: [
        SettingsNavTile(
          key: const Key('settingsGeneralItem'),
          icon: Icons.tune_rounded,
          title: l10n.settingsGeneralTitle,
          subtitle: l10n.settingsGeneralSubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const GeneralSettingsPage(),
          ),
        ),
        // 快捷键：软件内 / 全局两组的总开关与绑定自定义。只在桌面平台显示
        // （移动端软件内快捷键与全局热键都不注册）。
        if (isDesktopPlatform())
          SettingsNavTile(
            key: const Key('settingsShortcutsItem'),
            icon: Icons.keyboard_rounded,
            title: l10n.settingsShortcutsTitle,
            subtitle: l10n.settingsShortcutsSubtitle,
            onTap: () => openSettingsSubPage(
              context,
              const ShortcutSettingsPage(),
            ),
          ),
        // 关于与更新：版本 / 渠道 / 自动检查 / 下载安装。
        if (updateProvider != null)
          SettingsNavTile(
            key: const Key('settingsUpdateItem'),
            icon: Icons.system_update_alt_rounded,
            title: l10n.settingsUpdateTitle,
            subtitle: _updateSubtitle(l10n, updateProvider),
            onTap: () => openSettingsSubPage(
              context,
              const UpdateSettingsPage(),
            ),
          ),
      ],
    );
  }

  /// 数据：数据子页 / 听歌统计 / 跨设备同步。
  Widget _dataSection(
    BuildContext context,
    AppLocalizations l10n, {
    required SyncProvider? syncProvider,
  }) {
    return SettingsSectionCard(
      title: l10n.settingsDataSection,
      children: [
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
        // 听歌统计：事件级采集（本机），播放次数 / 热力图 / 导出。
        // 采集开关留在数据子页（与缓存 / 导入导出同一处）。
        SettingsNavTile(
          key: const Key('settingsPlayStatisticsItem'),
          icon: Icons.insights_rounded,
          title: l10n.statsTitle,
          subtitle: l10n.statsSettingsSubtitle,
          onTap: () => openSettingsSubPage(
            context,
            const PlayStatisticsPage(),
          ),
        ),
        if (syncProvider != null)
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

  /// 更新入口副标题：优先「可更新至 x.y.z」，否则显示当前版本。
  String _updateSubtitle(AppLocalizations l10n, UpdateProvider provider) {
    final version = provider.release?.version;
    if (provider.updateAvailable && version != null && version.isNotEmpty) {
      return l10n.settingsUpdateAvailable(version);
    }
    return l10n.settingsUpdateSubtitle(provider.currentVersionLabel);
  }

  /// 基础配色副标题：壁纸档三态（壁纸 / 强调色 / 都不可用）或当前自定义色 hex。
  String _baseColorSubtitle(
    AppLocalizations l10n,
    ColorBaseSource source, {
    required SystemBaseColorSource systemColorSource,
    required Color seedColor,
  }) {
    if (source != ColorBaseSource.wallpaper) {
      return colorHexLabel(seedColor.toARGB32());
    }
    return switch (systemColorSource) {
      SystemBaseColorSource.wallpaper => l10n.settingsBaseColorWallpaperActive,
      SystemBaseColorSource.accent => l10n.settingsBaseColorAccentActive,
      SystemBaseColorSource.unavailable => l10n.settingsMonetUnavailable,
    };
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
