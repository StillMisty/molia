import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/notification_service.dart';
import '../widgets/nav_destination_style.dart';
import '../widgets/settings/settings_reorderable_rows.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 设置 › 通用 › 底部导航：拖拽排序 + 显示/隐藏（至少保留 1 个）。
///
/// 三条拖拽列表不占设置首屏：低频、手势重（拖拽与开关互不抢），单独一页
/// 能给出足够行距与提示。行为与首屏内联版本一致：启动首页锁定、即时生效
/// 并持久化。
class BottomNavSettingsPage extends StatelessWidget {
  const BottomNavSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nav = context.watch<NavProvider>();
    final order = nav.order;

    return SettingsSubPage(
      title: l10n.settingsBottomNavTitle,
      children: [
        SettingsSectionCard(
          children: [
            SettingsReorderableRows(
              itemCount: order.length,
              itemKey: (index) => ValueKey(order[index]),
              itemBuilder: (context, index) =>
                  _buildRow(context, l10n, nav, order[index], index),
              onReorder: (oldIndex, newIndex) =>
                  nav.reorder(oldIndex, newIndex),
            ),
            const SizedBox(height: kSettingsSmallSpacing),
            SettingsSectionHint(text: l10n.settingsBottomNavHint),
          ],
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
    final label = destination.label(l10n);
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
        child: Icon(Icons.drag_handle_rounded, color: scheme.onSurfaceVariant),
      ),
      onChanged: (bool value) async {
        // 置灰后正常不可达；留作并发/同步改变状态时的兜底拒绝提示。
        final accepted = await nav.setVisible(destination, value);
        if (!accepted && context.mounted) {
          Provider.of<NotificationService>(
            context,
            listen: false,
          ).showSnackBar(l10n.settingsBottomNavKeepOne);
        }
      },
    );
  }
}
