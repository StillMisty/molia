import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/app_branding_service.dart';
import '../services/haptics.dart';
import '../services/language_service.dart';
import '../services/notification_service.dart';
import '../services/window/app_tray.dart';
import '../services/window/tray_settings.dart';
import '../services/window/window_settings.dart';
import '../widgets/nav_destination_icons.dart';
import '../widgets/settings/settings_reorderable_rows.dart';
import '../widgets/settings/settings_tiles.dart';

/// 通用设置子页：底部导航、语言、应用名称与震动反馈（按改动频率排序）。
///
/// 从设置首屏「通用与数据」进入，在设置弹层内部导航（见 `settings_page.dart`）。
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  /// 当前语言偏好（null = 跟随系统）；异步装载一次，切换后本地更新。
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLanguage());
  }

  Future<void> _loadLanguage() async {
    final locale = await LanguageService.getSavedLocale();
    if (!mounted) return;
    setState(() => _locale = locale);
  }

  /// 行内切换语言：localeNotifier 驱动界面立即生效，即反馈，无需成功提示。
  ///
  /// [LanguageService.setAppLocale] 自身吞掉平台通道与持久化错误（失败只记
  /// 日志、偏好仍尽力保存），因此这里没有可展示的失败路径。
  Future<void> _setLanguage(String value) async {
    final locale = switch (value) {
      'en' => const Locale('en'),
      'zh' => const Locale('zh'),
      _ => null, // system
    };
    await LanguageService.setAppLocale(locale);
    if (!mounted) return;
    setState(() => _locale = locale);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 测试等场景可能不提供 NavProvider：缺省时隐藏底部导航分组。
    final nav = context.watch<NavProvider?>();
    // 托盘设置同理：缺省（或非桌面平台）时隐藏「桌面」分组。
    final tray = context.watch<TraySettings?>();

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.generalTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          // 行序按改动频率：底部导航（常改）→ 震动反馈 → 语言 → 应用名称
          // → 桌面行为。
          if (nav != null) ...[
            SettingsSectionCard(
              title: l10n.settingsBottomNavTitle,
              footer: SettingsSectionHint(text: l10n.settingsBottomNavHint),
              children: [
                _StartupPageSettings(provider: nav),
                _BottomNavSettings(provider: nav),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
          ],
          SettingsSectionCard(
            children: [
              // 震动反馈（设备本地键，不随同步）：关掉后全应用触感一起静音。
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
              SettingsChoiceRow<String>(
                key: const Key('settingsLanguageItem'),
                icon: Icons.language_rounded,
                title: l10n.languageSettingTitle,
                value: _locale?.languageCode ?? 'system',
                options: [
                  ('system', l10n.languageSystem),
                  ('en', l10n.languageEnglish),
                  ('zh', l10n.languageSimplifiedChinese),
                ],
                onChanged: _setLanguage,
              ),
              // 应用名称：顶栏无歌曲时显示的自定义文案。
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
          ),
          // 桌面托盘：仅 Linux/Windows 显示（其余平台 AppTray.isSupported
          // 为 false，开关没有意义）。
          if (AppTray.isSupported && tray != null) ...[
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.settingsDesktopSection,
              // Linux 托盘图标依赖桌面面板：GNOME 需 AppIndicator 扩展，
              // 否则图标不显示（只在 Linux 提醒，避免 Windows 用户困惑）。
              footer: AppTray.isLinuxDesktop
                  ? SettingsSectionHint(text: l10n.settingsTrayLinuxHint)
                  : null,
              children: [
                SettingsSwitchTile(
                  switchKey: const Key('settingsCloseToTraySwitch'),
                  icon: Icons.desktop_windows_rounded,
                  title: l10n.settingsCloseToTray,
                  subtitle: l10n.settingsCloseToTraySubtitle,
                  value: tray.closeToTray,
                  onChanged: tray.setCloseToTray,
                ),
                // 记住窗口位置与大小（设备本地键，不随同步）：重启后窗口回到
                // 上次的位置/尺寸（最大化状态一并恢复）。
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
            ),
          ],
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
}

/// 目的地的本地化名称（启动首页行与底部导航行共用）。
String _destinationLabel(AppLocalizations l10n, ShellDestination destination) =>
    switch (destination) {
      ShellDestination.nowPlaying => l10n.nowPlayingLabel,
      ShellDestination.favorites => l10n.favoritesLabel,
      ShellDestination.library => l10n.libraryLabel,
    };

/// 启动首页：行内分段选择「打开应用时进入的页面」。
///
/// 不可见的目的地不筛掉、只禁用：分段布局不随显隐变化（否则改一次显隐
/// 选项就会跳位）。存储值可能因同步推来的隐藏当前不可见——此时副标题改用
/// [AppLocalizations.settingsStartupPageHidden] 说明实际进入的兜底页。
class _StartupPageSettings extends StatelessWidget {
  const _StartupPageSettings({required this.provider});

  final NavProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nav = provider;
    final home = nav.homeDestination;
    final homeVisible = nav.isVisible(home);

    return SettingsChoiceRow<ShellDestination>(
      key: const Key('settingsStartupPageItem'),
      icon: Icons.rocket_launch_rounded,
      title: l10n.settingsStartupPageTitle,
      subtitle: homeVisible
          ? l10n.settingsStartupPageSubtitle
          : l10n.settingsStartupPageHidden(
              _destinationLabel(l10n, home),
              _destinationLabel(l10n, nav.effectiveHomeDestination),
            ),
      value: home,
      options: [
        for (final destination in nav.order)
          (destination, _destinationLabel(l10n, destination)),
      ],
      // 隐藏项禁用（想选先显示）：禁用保持分段布局稳定。
      optionEnabled: nav.isVisible,
      onChanged: nav.setHomeDestination,
      icons: {
        for (final destination in ShellDestination.values)
          destination: destination.settingsIcon,
      },
    );
  }
}

/// 底部导航定制：拖拽排序 + 显示/隐藏（至少保留 1 个），即时生效并持久化。
///
/// 行是标准设置开关行（[SettingsSwitchTile]）；拖拽手柄挂在行尾
/// （[ReorderableDragStartListener] 只包手柄，整行点击仍是显隐开关，
/// 两种手势互不抢），排序容器与音源渠道共用 [SettingsReorderableRows]。
class _BottomNavSettings extends StatelessWidget {
  const _BottomNavSettings({required this.provider});

  final NavProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nav = provider;
    final order = nav.order;

    return SettingsReorderableRows(
      itemCount: order.length,
      itemKey: (index) => ValueKey(order[index]),
      itemBuilder: (context, index) =>
          _buildRow(context, l10n, nav, order[index], index),
      onReorder: (oldIndex, newIndex) => nav.reorder(oldIndex, newIndex),
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
    final label = _destinationLabel(l10n, destination);
    // 启动首页锁定：置灰并要求先改首页；已是不可见的不一致态不禁用，
    // 否则用户无法把它重新打开（想关先改首页只在可见时成立）。
    final locked =
        destination == nav.homeDestination && nav.isVisible(destination);

    return SettingsSwitchTile(
      // 图标用实心变体（与底栏/侧栏选中态一致，识别度更好）。
      icon: destination.settingsIcon,
      title: label,
      subtitle: locked ? l10n.settingsBottomNavKeepHome : '',
      value: nav.isVisible(destination),
      enabled: !locked,
      trailing: ReorderableDragStartListener(
        index: index,
        child: Icon(
          Icons.drag_handle_rounded,
          color: scheme.onSurfaceVariant,
        ),
      ),
      onChanged: (bool value) async {
        // 置灰后正常不可达；留作并发/同步改变状态时的兜底拒绝提示。
        final accepted = await nav.setVisible(destination, value);
        if (!accepted && context.mounted) {
          Provider.of<NotificationService>(context, listen: false)
              .showSnackBar(l10n.settingsBottomNavKeepOne);
        }
      },
    );
  }
}
