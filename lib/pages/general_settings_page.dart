import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/app_branding_service.dart';
import '../services/language_service.dart';
import '../services/notification_service.dart';
import '../widgets/nav_destination_icons.dart';
import '../widgets/settings/settings_reorderable_rows.dart';
import '../widgets/settings/settings_tiles.dart';

/// 通用设置子页：底部导航、语言与应用名称（按改动频率排序）。
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

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.generalTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          // 行序按改动频率：底部导航（常改）→ 语言 → 应用名称。
          if (nav != null) ...[
            SettingsSectionCard(
              title: l10n.settingsBottomNavTitle,
              footer: SettingsSectionHint(text: l10n.settingsBottomNavHint),
              children: [_BottomNavSettings(provider: nav)],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
          ],
          SettingsSectionCard(
            children: [
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
    final label = switch (destination) {
      ShellDestination.nowPlaying => l10n.nowPlayingLabel,
      ShellDestination.favorites => l10n.favoritesLabel,
      ShellDestination.library => l10n.libraryLabel,
    };

    return SettingsSwitchTile(
      // 图标用实心变体（与底栏/侧栏选中态一致，识别度更好）。
      icon: destination.settingsIcon,
      title: label,
      subtitle: '',
      value: nav.isVisible(destination),
      trailing: ReorderableDragStartListener(
        index: index,
        child: Icon(
          Icons.drag_handle_rounded,
          color: scheme.onSurfaceVariant,
        ),
      ),
      onChanged: (bool value) async {
        final accepted = await nav.setVisible(destination, value);
        if (!accepted && context.mounted) {
          Provider.of<NotificationService>(context, listen: false)
              .showSnackBar(l10n.settingsBottomNavKeepOne);
        }
      },
    );
  }
}
