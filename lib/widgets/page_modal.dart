/// 页面型弹窗的卡片容器。
///
/// 与 [M3EDialog] 本体的小弹窗不同，页面型弹窗承载的是**整页内容**：页面自带
/// Scaffold / M3EAppBar / 内部 Navigator 或长列表。`M3EDialog` 会把内容塞进
/// `SingleChildScrollView` 并叠加标题栏，整页放进去会被拉成一条长滚动，内层
/// 路由与列表也会失去自己的滚动宿主。所以这里只提供卡片外壳，标题栏、返回与
/// 滚动都交给页面自己——外壳复用的仍是 `M3EDialogTheme` 的圆角 / 阴影 token，
/// 视觉上与 `M3EDialog` 同一套语言。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

class PageModalCard extends StatelessWidget {
  const PageModalCard({
    super.key,
    required this.child,
    this.maxWidth,
    this.heightFactor = 0.86,
  });

  /// 页面内容；自带 Scaffold / AppBar 的整页，不再是弹窗正文。
  final Widget child;

  /// 卡片最大宽度；缺省取 [M3EDialogTheme.maxWidth]（560）。
  final double? maxWidth;

  /// 卡片最高占屏比例，对应 `ResponsiveLayoutSpec.modalMaxHeightFactor`。
  final double heightFactor;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final M3EDialogTheme dialogTheme = theme.dialogTheme;
    final M3EColorScheme scheme = theme.colorScheme;

    return ConstrainedBox(
      // 用 ConstrainedBox 而非固定 SizedBox：键盘弹出时外层 `M3EDialogInset`
      // 已经把可用高度收紧（padding 叠加 viewInsets），这里的 maxHeight 只做
      // 上限，卡片会跟着外层约束回缩，不会把内容顶出屏幕。
      constraints: BoxConstraints(
        maxWidth: maxWidth ?? dialogTheme.maxWidth,
        maxHeight: MediaQuery.sizeOf(context).height * heightFactor,
      ),
      child: M3ECard(
        // 底色必须是 surface，不能沿用 M3EDialog 默认的 surfaceContainerHigh：
        // 页面自带 Scaffold 时正文是 surface（AI DJ / 设置子页），设置首屏
        // 没有 Scaffold 却直接铺在卡片上，两档会呈现两种底色。
        color: scheme.surface,
        elevation: dialogTheme.elevation,
        borderRadius: BorderRadius.circular(dialogTheme.cornerRadius),
        clipBehavior: Clip.antiAlias,
        padding: EdgeInsets.zero,
        // 卡片只是容器，整页内容的焦点顺序由页面自己决定。
        focusable: false,
        child: child,
      ),
    );
  }
}
