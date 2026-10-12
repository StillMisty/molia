import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/app_branding_service.dart';
import '../services/language_service.dart';
import '../services/notification_service.dart';
import '../widgets/nav_destination_icons.dart';
import '../widgets/settings/settings_tiles.dart';

/// 通用设置子页：语言、应用名称与底部导航定制。
///
/// 从设置首屏「通用」进入，在设置弹层内部导航（见 `settings_page.dart`）。
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  /// 语言切换后强制 FutureBuilder 重新读取保存值。
  Key _languageKey = UniqueKey();

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
          SettingsSectionCard(
            children: [
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
                  return SettingsNavTile(
                    key: const Key('settingsLanguageItem'),
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
          if (nav != null) ...[
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.settingsBottomNavTitle,
              children: [_BottomNavSettings(provider: nav)],
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

  String _currentLanguageValue(Locale? locale) {
    if (locale == null) return 'system';
    return locale.languageCode;
  }

  Future<void> _showLanguageDialog(BuildContext context, AppLocalizations l10n,
      VoidCallback onSuccess) async {
    final notificationService = context.read<NotificationService>();
    final navigator = Navigator.of(context, rootNavigator: true);
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
            // 语言切换后界面立即生效，即反馈，无需再弹成功提示。
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
            width: settingsDialogWidth(context),
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
              onPressed: () => navigator.pop(),
              child: Text(l10n.cancelButton),
            ),
          ],
        );
      }),
    );
  }
}

/// 底部导航定制：拖拽排序 + 显示/隐藏（至少保留 1 个），即时生效并持久化。
class _BottomNavSettings extends StatelessWidget {
  const _BottomNavSettings({required this.provider});

  final NavProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nav = provider;
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
        const SizedBox(height: kSettingsSmallSpacing),
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
          const SizedBox(width: kSettingsElementSpacing),
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
