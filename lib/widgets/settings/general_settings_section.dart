import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/bottom_nav_settings_page.dart';
import '../../providers/nav_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/haptics.dart';
import '../../services/language_service.dart';
import '../nav_destination_style.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「通用」卡：启动页 / 底部导航 / 语言 / 震动 / 应用名称。
///
/// 桌面托盘、窗口与快捷键在「桌面」卡（仅桌面出现），更新与问题排查在
/// 「关于与更新」卡；本卡只放平台无关的通用偏好。震动是设备本地键，卡底
/// 给一句说明。
class GeneralSettingsSection extends StatefulWidget {
  const GeneralSettingsSection({super.key, required this.availability});

  final SettingsSectionAvailability availability;

  @override
  State<GeneralSettingsSection> createState() => _GeneralSettingsSectionState();
}

class _GeneralSettingsSectionState extends State<GeneralSettingsSection> {
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
    // 测试等场景可能不提供 NavProvider：缺省时隐藏导航相关行。
    final nav = widget.availability.nav;

    return SettingsSectionCard(
      title: l10n.settingsGeneralTitle,
      footer: SettingsSectionHint(text: l10n.settingsGeneralDeviceLocalHint),
      children: [
        // 行序按改动频率：启动页（常改）→ 底栏 → 震动 → 语言 → 应用名称。
        if (nav != null) ...[
          _StartupPageSettings(provider: nav),
          SettingsNavTile(
            key: const Key('settingsBottomNavItem'),
            icon: Icons.dashboard_customize_rounded,
            title: l10n.settingsBottomNavTitle,
            subtitle: l10n.settingsBottomNavSubtitle,
            onTap: () =>
                openSettingsSubPage(context, const BottomNavSettingsPage()),
          ),
        ],
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
    );
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
}

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
              home.label(l10n),
              nav.effectiveHomeDestination.label(l10n),
            ),
      value: home,
      options: [
        for (final destination in nav.order)
          (destination, destination.label(l10n)),
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
