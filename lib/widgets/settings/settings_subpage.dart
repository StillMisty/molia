import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_tiles.dart';

/// 设置子页的统一 chrome：M3E 顶栏 + 统一内边距的滚动正文。
///
/// 设置子页活在 `SettingsPage` 的内层 Navigator 里（见 `settings_page.dart`），
/// 不能像根导航器上的二级页那样交给 `ResponsiveNavigation.showSecondaryPage`：
/// 预测返回要按「子页 / 弹层首屏」分派手势归属（子页手势只退子页，首屏手势才
/// 让弹层收缩），普通返回也必须先退子页、再关弹层。这套所有权在设置弹层，
/// 所以设置域的 chrome 收在本模块；`showSecondaryPage` 继续负责设置域之外的
/// 窄屏全屏 / 宽屏侧滑二级页。
class SettingsSubPage extends StatelessWidget {
  /// 常规设置页：正文按顺序排进统一 padding 的 [ListView]。
  const SettingsSubPage({
    super.key,
    required this.title,
    this.actions,
    required this.children,
    this.safeArea = false,
  }) : body = null;

  /// 自定义正文：加载 / 错误状态等由调用方决定，[body] 原样作为 Scaffold body。
  ///
  /// 仍需要标准滚动正文时用 [SettingsSubPageList] 复用同一份 padding / ListView。
  const SettingsSubPage.body({
    super.key,
    required this.title,
    this.actions,
    required this.body,
    this.safeArea = false,
  }) : children = null;

  final String title;
  final List<Widget>? actions;
  final List<Widget>? children;
  final Widget? body;

  /// 正文外再包一层 [SafeArea]（缓存管理页需要底部系统 inset 留白）。
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final content = body ?? SettingsSubPageList(children: children!);
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(title),
        automaticallyImplyLeading: true,
        actions: actions,
      ),
      body: safeArea ? SafeArea(child: content) : content,
    );
  }
}

/// 设置子页的标准滚动正文：`ListView` + [kSettingsPadding]。
///
/// [SettingsSubPage.body] 的调用方（FutureBuilder / Consumer / 条件加载态）
/// 用它在分支里保留与常规子页完全一致的滚动与内边距。
class SettingsSubPageList extends StatelessWidget {
  const SettingsSubPageList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(kSettingsPadding),
      children: children,
    );
  }
}
