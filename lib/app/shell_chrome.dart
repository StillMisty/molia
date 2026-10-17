/// 壳层导航 / 顶栏的一份 spec：mobile 与 desktop 两套骨架各自适配渲染。
///
/// 骨架不合并（顶栏标题、侧栏类型、底栏形态各自适配），但共享同一份 chrome：
/// 目的地 → 图标 / 标签映射、索引 → 目的地回调、设置按钮 / 窗口控件 /
/// titleSpacing / 拖动区。这些只此一份，避免改一处漏一处。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/window/window_chrome.dart';
import '../widgets/nav_destination_style.dart';
import 'desktop/window_controls.dart';

/// 壳层导航 / 顶栏 spec：目的地 + 标签 + 选择 + 顶栏槽位。
class ShellChrome {
  const ShellChrome({
    required this.destinations,
    required this.selectedDestination,
    required this.selectedIndex,
    required this.l10n,
    required this.onDestinationSelected,
    required this.onOpenSettings,
  });

  /// 实际渲染的目的地（NavProvider 过滤隐藏项后的顺序）。
  final List<ShellDestination> destinations;

  /// 当前选中的目的地（顶栏标题）；与 [selectedIndex] 分开持有，保留
  /// 「选中项不在可见列表」时壳层的兜底标题。
  final ShellDestination selectedDestination;

  /// [selectedDestination] 在 [destinations] 中的下标（不在列表时为 -1）。
  final int selectedIndex;

  /// 目的地标签与顶栏无障碍文案的唯一来源（en/zh）。
  final AppLocalizations l10n;

  /// 目的地被点击 / 重复点击（两套骨架共用同一壳层回调）。
  final ValueChanged<ShellDestination> onDestinationSelected;

  /// 打开设置弹层。
  final VoidCallback onOpenSettings;

  /// 目的地 → 本地化标签（唯一映射，见 `nav_destination_style.dart`）。
  String labelFor(ShellDestination destination) => destination.label(l10n);

  /// 导航轨 / 底栏的索引回调：索引 → 目的地 → 壳层回调（唯一映射）。
  void selectDestinationAt(int index) =>
      onDestinationSelected(destinations[index]);

  /// 目的地 → 导航轨条目（唯一映射循环）。
  List<M3ENavigationRailDestination> railDestinations() => [
        for (final destination in destinations)
          M3ENavigationRailDestination(
            icon: destination.outlinedIcon,
            selectedIcon: destination.filledIcon,
            label: labelFor(destination),
          ),
      ];

  /// 目的地 → 底栏条目（唯一映射循环）。
  List<M3ENavigationBarDestination> barDestinations() => [
        for (final destination in destinations)
          M3ENavigationBarDestination(
            icon: destination.outlinedIcon,
            selectedIcon: destination.filledIcon,
            label: labelFor(destination),
          ),
      ];

  /// 顶栏槽：titleSpacing / 无返回键 / 拖动区包装（两套骨架同一份）。
  ///
  /// [actions] 是骨架自己的前置动作（移动骨架的迷你播放 / 下一首）；
  /// [bottom] 是骨架自己的底部槽（移动骨架的波浪进度条）。
  PreferredSizeWidget appBar({
    required BuildContext context,
    required Widget title,
    List<Widget> actions = const [],
    PreferredSizeWidget? bottom,
  }) {
    final bar = AppBar(
      titleSpacing: appBarTitleSpacing,
      // 壳层是根页面，永远不需要返回键；且路由内的局部历史条目（如 M3E 下拉
      // 菜单打开时）会让 ModalRoute.canPop 变真，默认的
      // automaticallyImplyLeading 会在此刻冒出返回箭头。
      automaticallyImplyLeading: false,
      title: title,
      actions: [...actions, ..._trailingActions()],
      bottom: bottom,
    );
    // 顶栏整体是窗口拖动区（隐藏标题栏后唯一的拖动入口）：外层用 AppBar
    // 自报高度；非桌面平台 WindowDragArea 是纯透传。
    return PreferredSize(
      preferredSize: Size.fromHeight(
          AppBar.preferredHeightFor(context, bar.preferredSize)),
      child: WindowDragArea(child: bar),
    );
  }

  /// 顶栏尾部动作：设置 + 窗口控件 + 右侧留白（两套骨架同一份）。
  List<Widget> _trailingActions() => [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          onPressed: onOpenSettings,
          // 顶栏不做悬浮提示（窗口控件区一排按钮，tooltip 反而吵）；
          // 无障碍语义仍保留（icon-only 按钮的可访问名）。
          semanticLabel: l10n.settingsTitle,
          icon: const Icon(Icons.settings_rounded),
        ),
        if (WindowChrome.isSupported) const WindowControls(),
        const SizedBox(width: 8),
      ];

  /// 顶栏统一左右留白。
  static const double appBarTitleSpacing = 12;
}
