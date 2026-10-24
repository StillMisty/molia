/// 壳层导航 / 顶栏的一份 spec：mobile 与 desktop 两套骨架各自适配渲染。
///
/// 骨架不合并（顶栏标题、侧栏类型、底栏形态各自适配），但共享同一份 chrome：
/// 目的地 → 图标 / 标签映射、索引 → 目的地回调、设置按钮 / 窗口控件 /
/// 左侧留白。这些只此一份，避免改一处漏一处。顶栏本体（M3E 工具行 / 底部槽 /
/// 拖动区 / 状态栏）统一由 `ShellAppBar` 装配，本文件只负责往里塞内容。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/nav_provider.dart';
import '../services/window/window_chrome.dart';
import '../widgets/nav_destination_style.dart';
import 'desktop/window_controls.dart';
import 'shell_app_bar.dart';

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

  /// 顶栏槽：工具行（M3E compact，56dp）+ 骨架自己的前置动作 / 底部槽。
  ///
  /// [actions] 是骨架自己的前置动作（移动骨架的迷你播放 / 下一首）；
  /// [bottom] 是骨架自己的底部槽（移动骨架的波浪进度条）。标题留白 / 拖动区 /
  /// 状态栏明暗由 [ShellAppBar] 统一处理，两套骨架不再各配自己的一份。
  PreferredSizeWidget appBar({
    required Widget title,
    List<Widget> actions = const [],
    PreferredSizeWidget? bottom,
  }) =>
      ShellAppBar(
        title: title,
        actions: [...actions, ..._trailingActions()],
        bottom: bottom,
      );

  /// 顶栏尾部动作：设置 + 窗口控件 + 右侧留白（两套骨架同一份）。
  List<Widget> _trailingActions() => [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          onPressed: onOpenSettings,
          // 图标按钮统一不做悬浮提示（口径见 docs/architecture.md §6
          // 「按钮选型」）；这一排紧挨窗口控件，提示只会更吵，无障碍名保留。
          semanticLabel: l10n.settingsTitle,
          icon: const Icon(Icons.settings_rounded),
        ),
        if (WindowChrome.isSupported) const WindowControls(),
        const SizedBox(width: 8),
      ];

  /// 顶栏标题区左缘（= `M3EAppBarTheme.titleInset`，品牌区左缘对齐它）。
  ///
  /// M3E 的标题槽从 titleInset 起排，这里跟随包内默认值而不是自定一个数：
  /// 一旦包内对齐调整，壳层与二级页顶栏一起移动。
  static const double appBarTitleSpacing = 16;
}
