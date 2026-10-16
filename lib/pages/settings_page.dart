import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/lyrics_display_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/sources_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/update_provider.dart';
import '../services/data_saver_service.dart';
import '../services/haptics.dart';
import '../services/lyrics_display/lyrics_output.dart';
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
import 'data_settings_page.dart';
import 'general_settings_page.dart';
import 'lyrics_display/desktop_lyrics_settings_page.dart';
import 'lyrics_display/lyrics_content_settings_page.dart';
import 'lyrics_display/system_media_lyrics_settings_page.dart';
import 'sources_page.dart';
import 'sync_settings_page.dart';
import 'update_settings_page.dart';

/// 打开设置弹层（顶栏入口与测试共用）。
///
/// 小屏（底部弹层）：dismiss guard 是返回的唯一入口——先在弹层内部退子页
/// （立即返回 false、不等待退栈动画，对齐官方 Compose `settleToDismiss` 的
/// 「收起一级」语义），子页退完后再允许关闭。guard 非空时弹层宿主照样接管
/// 预测返回手势（material_3_expressive ≥ 1.1.7）：手势全程有跟手预览，提交后
/// 由 guard 裁决——退掉子页（返回 false）则预览回弹、弹层留在原位；子页已退完
/// 则放行关闭。内层子页本身不参与预测返回（见
/// [SettingsPage._innerTransitionTheme]）。
/// 大屏（居中对话框）忽略 guard，返回由 [SettingsPage] 页内处理。
Future<void> showSettingsSheet(BuildContext context) {
  final navigatorKey = GlobalKey<NavigatorState>();
  return ResponsiveNavigation.showAdaptiveModalPage<void>(
    context: context,
    showCloseButton: false,
    onDismissRequest: () async {
      final navigator = navigatorKey.currentState;
      if (navigator != null && navigator.canPop()) {
        unawaited(navigator.maybePop());
        return false;
      }
      return true;
    },
    child: SettingsPage(navigatorKey: navigatorKey),
  );
}

/// 设置弹层：内部 Navigator 承载首屏与子页（避免弹层叠弹层）。
///
/// 首屏按语义分区：外观 / 播放 / 歌词与展示 / 内容与来源 / 通用与数据；
/// 子页经 [openSettingsSubPage] 推入本 Navigator。
///
/// 返回处理按宿主形态分叉：
/// - 小屏（M3E 底部弹层）：弹层宿主的 dismiss guard（见 `showSettingsSheet`）
///   负责「先在弹层内退子页、再关弹层」（对齐 Compose `settleToDismiss` 的
///   「收起一级」语义）；弹层宿主自己接管预测返回手势（跟手预览 + guard 拒绝
///   后回弹），内层路由被排除在外（见 [SettingsPage._innerTransitionTheme]）；
///   本页不再挂 PopScope，避免同一次返回被两处处理。
/// - 大屏（居中对话框）：没有宿主 guard，由 [NavigatorPopHandler] 转发系统
///   返回——先退子页，回到首屏后对话框正常关闭。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.navigatorKey});

  /// 弹层宿主与 dismiss guard 共享的内部导航 key。
  ///
  /// 小屏时宿主的 guard 需要读取内部 Navigator 的栈状态并退子页；缺省
  /// （如测试直接挂载）时内部自建 key。
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final GlobalKey<NavigatorState> _fallbackNavigatorKey =
      GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState> get _navigatorKey =>
      widget.navigatorKey ?? _fallbackNavigatorKey;

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

  /// 内层 Navigator 的过渡主题：Android 换成不参与预测返回的 fade-forwards。
  ///
  /// 为什么内层路由不能走预测返回：框架把同一次手势派发给**所有**返回 true 的
  /// 观察者，而 `Route.isCurrent` 只看自己那个 Navigator——根导航器上开着弹层
  /// （对话框 / 底部弹层）时，内层子页依旧是自己导航器的「current」，于是会和
  /// 最上层表面各自接管：实测（`test/settings_page_test.dart` 的「根导航器上方
  /// dialog」用例）是手势退掉内层子页、最上层对话框反而留下，两条路由都退时还会
  /// 一次手势退两级。弹层的跟手预览由 M3E 弹层宿主自己实现
  /// （`m3e_bottom_sheet_modal_host.dart`），不依赖内层路由过渡，所以把内层
  /// 排除掉不会丢预览。内层页面继续走「普通返回 → 弹层 guard → 先退子页」这条
  /// 既有链路；fade-forwards 与预测返回 builder 的非手势过渡视觉一致，观感不变。
  ThemeData _innerTransitionTheme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          ...base.pageTransitionsTheme.builders,
          TargetPlatform.android: const FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final navigator = Navigator(
      key: _navigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => _SettingsHomeView(
          scrollController: _sheetScrollController,
        ),
      ),
    );
    final themed = Theme(
      data: _innerTransitionTheme(context),
      child: navigator,
    );
    if (!context.isLargeScreen) {
      return themed;
    }
    return NavigatorPopHandler(
      onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
      child: themed,
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

class _SettingsHomeViewState extends State<_SettingsHomeView>
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
    final sources = context.read<SourcesProvider?>();
    final lyricsDisplay = context.watch<LyricsDisplayProvider?>();
    final m3e = M3ETheme.of(context);

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
                      // 页面标题走 M3E typeScale（与行内排版同一套 token；
                      // 不再用 material 的 textTheme.headlineSmall）。
                      style: m3e.typeScale.headlineSmall,
                    ),
                  ),
                  Row(
                    children: [
                      M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        // 关闭的是承载设置的弹层/对话框本体：用 pop 绕过
                        // dismiss guard，子页打开时也整个关闭。
                        onPressed: () => Navigator.of(context, rootNavigator: true)
                            .pop(),
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
              _lyricsSection(context, l10n, lyricsDisplay),
              const SizedBox(height: kSettingsSectionSpacing),
              _contentSection(context, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _generalAndDataSection(
                context,
                l10n,
                syncProvider: syncProvider,
                updateProvider: updateProvider,
              ),
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

  /// 播放：默认播放模式 / 启动恢复 / 默认音质 / 自动换源 / 省流（开关与生效子项）。
  ///
  /// 省流不单开子页：开关行排在分区末位，开启时才展开音质上限与封面省流
  /// （三行共用同一套设置行，行为与独立子页一致）。
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
              // 音质标签都是短词（无损 / 320K / Hi-Res）：字段收窄，
              // 把行内宽度让给标题与说明。
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
        // 全部输出都不支持（Web / 桌面等）：给一句解释，而不是静默只剩一条入口。
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
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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

  /// 通用与数据：通用子页 / 数据子页 / 同步子页 / 关于与更新。
  Widget _generalAndDataSection(
    BuildContext context,
    AppLocalizations l10n, {
    required SyncProvider? syncProvider,
    required UpdateProvider? updateProvider,
  }) {
    final showSync = syncProvider != null && !kIsWeb;
    return SettingsSectionCard(
      title: l10n.settingsGeneralAndDataTitle,
      children: [
        // 震动反馈（设备本地键，不随同步）：关掉后全应用触感一起静音，
        // 就地开关排在入口行之前。
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

  /// 更新入口副标题：优先「可更新至 x.y.z」，否则显示当前版本。
  String _updateSubtitle(AppLocalizations l10n, UpdateProvider provider) {
    final version = provider.release?.version;
    if (provider.updateAvailable && version != null && version.isNotEmpty) {
      return l10n.settingsUpdateAvailable(version);
    }
    return l10n.settingsUpdateSubtitle(provider.currentVersionLabel);
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
