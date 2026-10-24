/// 壳层顶栏：M3EAppBar.top（compact 档）+ 可选底部槽（移动骨架的波浪进度）。
///
/// 为什么不是裸 `AppBar`：壳层顶栏也要吃 M3E 的形状 / 状态层 / 动效口径，
/// 并把「工具行 56dp + 底部槽 + 状态栏明暗 + 窗口拖动」收在一个组件里，
/// 两套骨架的 `ShellChrome.appBar` 只负责给标题与动作。
library;

import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../services/window/window_chrome.dart';

/// 壳层顶栏：M3E 工具行（56dp）+ 可选底部槽。
///
/// 整条工具条（标题 + 按钮）放进 M3E 的 title 槽：桌面窗口控件是一整块可变
/// 宽的 Row（约 180dp），而 M3E 的 actions 只按 48dp/个预留标题宽度，直接
/// 放会与标题重叠。title 槽拿到的是「左 16dp / 右 4dp」的整宽，按钮由这一行
/// 自己排，宽度不再依赖 M3E 的预留规则。
class ShellAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ShellAppBar({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.bottom,
  });

  /// 顶栏标题（桌面 = 品牌区 + 空白拖动区；移动 = 曲目信息区）。
  final Widget title;

  /// 标题右侧的动作（骨架自己的按钮 + 共享的设置 / 窗口控件，见
  /// `ShellChrome._trailingActions`）。
  final List<Widget> actions;

  /// 底部槽（移动骨架的波浪进度条）；桌面骨架不传。
  final PreferredSizeWidget? bottom;

  /// M3E compact 档内容高度（`M3EAppBarTheme.defaults` 的 64 − 8）。
  ///
  /// 与旧 `kToolbarHeight`（56）一致：工具行高度是壳层对外承诺，测试按它
  /// 校验，改 M3E 档位时这里先红。
  static const double toolbarHeight = 56;

  @override
  Size get preferredSize => Size.fromHeight(
        toolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    // M3EAppBar 自己不设置系统栏明暗（旧 AppBar 由 AppBarTheme 全局注入），
    // 这里补上本地声明：状态栏画在顶栏这一层之上，缺省时会回退到系统配色
    // （深色壁纸下图标可能看不见）。
    final overlay = Theme.of(context).appBarTheme.systemOverlayStyle;
    final Widget bar = M3EAppBar.top(
      density: M3EAppBarDensity.compact,
      // 壳层是根页面，永远不需要返回键；路由内的局部历史条目（如 M3E 下拉
      // 菜单打开时）会让 ModalRoute.canPop 变真，默认的 imply 会冒出返回箭头。
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          Expanded(child: title),
          ...actions,
        ],
      ),
    );
    final Widget stack = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        bar,
        if (bottom != null)
          SizedBox(
            // 高度由底部槽自己声明，这里同样钉住：平直进度条（4dp）与波浪态
            // （10dp）必须同槽心，play/pause 切换时整条不跳。
            height: bottom!.preferredSize.height,
            child: bottom,
          ),
      ],
    );
    // 顶栏整体是窗口拖动区（隐藏标题栏后唯一的拖动入口）：非桌面平台
    // WindowDragArea 是纯透传。
    return WindowDragArea(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlay ?? const SystemUiOverlayStyle(),
        child: stack,
      ),
    );
  }
}
