import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../widgets/m3e_page_route.dart';
import '../widgets/page_modal.dart';

/// 响应式设计断点常量
/// 用于在整个应用中统一响应式行为
abstract class Breakpoints {
  /// 极窄设备 (小型手机，如 iPhone SE)
  static const double compact = 350;

  /// 标准手机宽度
  static const double mobile = 400;

  /// 平板/大屏幕手机
  static const double tablet = 600;

  /// 桌面/超宽屏幕
  static const double desktop = 900;
}

/// 桌面平台（Linux / Windows / macOS）：桌面骨架与桌面专属交互的统一判定。
///
/// 与壳层骨架分流（`MyApp.desktopShell`）互补：生产路径两者一致；测试里可用
/// 开关强制骨架，页面内的桌面增强（渠道栏 / 表格列 / 右键菜单）
/// 仍按平台判定——它们只在桌面骨架里渲染，无需再逐层传开关。
bool isDesktopPlatform() => switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS =>
        true,
      _ => false,
    };

/// 设备类型枚举
enum DeviceType {
  compact,
  mobile,
  tablet,
  desktop,
}

/// 页面布局分类
enum ResponsivePageType {
  shell,
  browse,
  detail,
  modal,
  preview,
}

/// 二级页面显示模式
enum SecondaryPageMode {
  fullScreen,
  sideSheet,
  centerDialog,
  bottomSheet,
}

enum AdaptiveModalContentLayout {
  wrapContent,
  fillHeight,
}

/// 统一的页面布局规格
class ResponsiveLayoutSpec {
  const ResponsiveLayoutSpec({
    required this.type,
    required this.maxWidth,
    required this.horizontalPadding,
    required this.preferTwoPane,
    required this.modalWidth,
    required this.modalMaxHeightFactor,
    required this.defaultMinTileWidth,
  });

  final ResponsivePageType type;
  final double maxWidth;
  final double horizontalPadding;
  final bool preferTwoPane;
  final double modalWidth;
  final double modalMaxHeightFactor;
  final double defaultMinTileWidth;

  EdgeInsets pagePadding({
    double vertical = 0,
  }) {
    return EdgeInsets.symmetric(
      horizontal: horizontalPadding,
      vertical: vertical,
    );
  }
}

extension ResponsiveExtension on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;

  double get screenHeight => MediaQuery.sizeOf(this).height;

  Size get screenSize => MediaQuery.sizeOf(this);

  bool get isCompact => screenWidth < Breakpoints.compact;

  bool get isNarrow => screenWidth < Breakpoints.mobile;

  bool get isLargeScreen => screenWidth >= Breakpoints.tablet;

  bool get isDesktop => screenWidth >= Breakpoints.desktop;

  bool get isMobile => screenWidth < Breakpoints.tablet;

  DeviceType get deviceType {
    if (screenWidth < Breakpoints.compact) return DeviceType.compact;
    if (screenWidth < Breakpoints.tablet) return DeviceType.mobile;
    if (screenWidth < Breakpoints.desktop) return DeviceType.tablet;
    return DeviceType.desktop;
  }

  int get gridCrossAxisCount {
    return adaptiveColumns(
      minTileWidth: layoutType(ResponsivePageType.browse).defaultMinTileWidth,
      min: 3,
      // 超宽屏（桌面骨架内容区最宽 1600）网格多留列：窗口越宽卡片列数越
      // 接近可用宽度，避免两侧大片留白。
      max: 8,
    );
  }

  double get horizontalPadding {
    return layoutType(ResponsivePageType.browse).horizontalPadding;
  }

  T responsive<T>({
    required T mobile,
    T? compact,
    T? tablet,
    T? desktop,
  }) {
    return switch (deviceType) {
      DeviceType.compact => compact ?? mobile,
      DeviceType.mobile => mobile,
      DeviceType.tablet => tablet ?? mobile,
      DeviceType.desktop => desktop ?? tablet ?? mobile,
    };
  }

  ResponsiveLayoutSpec layoutType(ResponsivePageType type) {
    // 桌面档与平板档同宽：桌面骨架的内容区已经由侧栏（96）与「窗口宽 −
    // 栏宽」的表格判据拉开层次，页边距再叠一层更宽的留白只会压缩表格档
    // 的可用宽（`DesktopLayout.tableColumns` 的阈值按 24 留）。
    final padding = responsive<double>(
      compact: 12,
      mobile: 16,
      tablet: 24,
      desktop: 24,
    );

    switch (type) {
      case ResponsivePageType.shell:
        return ResponsiveLayoutSpec(
          type: type,
          maxWidth: double.infinity,
          horizontalPadding: padding,
          preferTwoPane: isLargeScreen,
          modalWidth: responsive(
            mobile: 420,
            tablet: 520,
            desktop: 560,
          ),
          modalMaxHeightFactor: isLargeScreen ? 0.88 : 0.92,
          defaultMinTileWidth: 220,
        );
      case ResponsivePageType.browse:
        return ResponsiveLayoutSpec(
          type: type,
          maxWidth: responsive(
            mobile: double.infinity,
            tablet: 1040,
            // 桌面骨架内容区更宽（侧栏 + 播放器列 + 队列面板并行），
            // 网格页放宽上限；平板档与移动档不变。
            desktop: 1600,
          ),
          horizontalPadding: padding,
          preferTwoPane: isLargeScreen,
          modalWidth: responsive(
            mobile: 420,
            tablet: 520,
            desktop: 560,
          ),
          modalMaxHeightFactor: isLargeScreen ? 0.88 : 0.92,
          defaultMinTileWidth: responsive(
            compact: 112,
            mobile: 132,
            tablet: 164,
            desktop: 176,
          ),
        );
      case ResponsivePageType.detail:
        return ResponsiveLayoutSpec(
          type: type,
          maxWidth: responsive(
            mobile: double.infinity,
            tablet: 960,
            desktop: 1080,
          ),
          horizontalPadding: padding,
          preferTwoPane: isLargeScreen,
          modalWidth: responsive(
            mobile: 420,
            tablet: 520,
            // 桌面档二级页（专辑 / 歌手 / 评论等侧滑）加宽：行内信息更长，
            // 宽一档减少横向拥挤；M3E 侧边弹层会按主题 maxWidth 与本屏
            // 可用宽度夹取（见 `ResponsiveNavigation._showM3ESideSheet`）。
            desktop: 720,
          ),
          modalMaxHeightFactor: isLargeScreen ? 0.9 : 0.94,
          defaultMinTileWidth: 260,
        );
      case ResponsivePageType.modal:
        return ResponsiveLayoutSpec(
          type: type,
          maxWidth: responsive(
            mobile: 560,
            tablet: 560,
            desktop: 620,
          ),
          horizontalPadding: responsive(
            compact: 12,
            mobile: 16,
            tablet: 20,
            desktop: 24,
          ),
          preferTwoPane: false,
          modalWidth: responsive(
            mobile: 420,
            tablet: 500,
            // 桌面档保持 560：本档被设置弹层、定时关闭、来源分享、AI 推歌
            // 共用，设置页的宽弹层用显式 `maxWidth` 单独指定（见
            // `settings_page.dart::kSettingsSheetDesktopWidth`），不要在这里
            // 一刀切加宽——窄弹层跟着变宽会在桌面上摊出大片空白。
            desktop: 560,
          ),
          modalMaxHeightFactor: isLargeScreen ? 0.86 : 0.92,
          defaultMinTileWidth: 220,
        );
      case ResponsivePageType.preview:
        return ResponsiveLayoutSpec(
          type: type,
          maxWidth: responsive(
            mobile: double.infinity,
            tablet: 980,
            desktop: 1120,
          ),
          horizontalPadding: padding,
          preferTwoPane: false,
          modalWidth: responsive(
            mobile: 420,
            tablet: 560,
            desktop: 620,
          ),
          modalMaxHeightFactor: isLargeScreen ? 0.9 : 0.94,
          defaultMinTileWidth: 180,
        );
    }
  }

  int adaptiveColumns({
    required double minTileWidth,
    int min = 1,
    int max = 6,
  }) {
    final availableWidth = math.max(
      0,
      screenWidth -
          (layoutType(ResponsivePageType.browse).horizontalPadding * 2),
    );
    if (availableWidth <= 0) {
      return min;
    }
    final columns = (availableWidth / minTileWidth).floor();
    return columns.clamp(min, max);
  }
}

class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({
    super.key,
    required this.mobile,
    this.compact,
    this.tablet,
    this.desktop,
  });

  final Widget mobile;
  final Widget? compact;
  final Widget? tablet;
  final Widget? desktop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= Breakpoints.desktop && desktop != null) {
          return desktop!;
        }
        if (width >= Breakpoints.tablet && tablet != null) {
          return tablet!;
        }
        if (width < Breakpoints.compact && compact != null) {
          return compact!;
        }
        return mobile;
      },
    );
  }
}

class ResponsiveValue<T> extends StatelessWidget {
  const ResponsiveValue({
    super.key,
    required this.mobile,
    this.compact,
    this.tablet,
    this.desktop,
    required this.builder,
  });

  final T mobile;
  final T? compact;
  final T? tablet;
  final T? desktop;
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    final value = context.responsive<T>(
      mobile: mobile,
      compact: compact,
      tablet: tablet,
      desktop: desktop,
    );
    return builder(context, value);
  }
}

class ResponsiveGap extends StatelessWidget {
  const ResponsiveGap({
    super.key,
    this.compact = 8,
    this.mobile = 12,
    this.tablet = 16,
    this.desktop = 24,
    this.axis = Axis.horizontal,
  });

  final double compact;
  final double mobile;
  final double tablet;
  final double desktop;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final size = context.responsive<double>(
      compact: compact,
      mobile: mobile,
      tablet: tablet,
      desktop: desktop,
    );

    return axis == Axis.horizontal
        ? SizedBox(width: size)
        : SizedBox(height: size);
  }
}

class ResponsivePadding {
  static EdgeInsets horizontal(
    BuildContext context, {
    ResponsivePageType pageType = ResponsivePageType.browse,
  }) {
    final padding = context.layoutType(pageType).horizontalPadding;
    return EdgeInsets.symmetric(horizontal: padding);
  }

  static EdgeInsets all(
    BuildContext context, {
    ResponsivePageType pageType = ResponsivePageType.browse,
  }) {
    final padding = context.layoutType(pageType).horizontalPadding;
    return EdgeInsets.all(padding);
  }

  static EdgeInsets symmetric(
    BuildContext context, {
    ResponsivePageType pageType = ResponsivePageType.browse,
    double? horizontalCompact,
    double? horizontalMobile,
    double? horizontalTablet,
    double? verticalCompact,
    double? verticalMobile,
    double? verticalTablet,
  }) {
    final horizontal = context.responsive<double>(
      compact: horizontalCompact ?? 8,
      mobile:
          horizontalMobile ?? context.layoutType(pageType).horizontalPadding,
      tablet:
          horizontalTablet ?? context.layoutType(pageType).horizontalPadding,
      desktop:
          horizontalTablet ?? context.layoutType(pageType).horizontalPadding,
    );
    final vertical = context.responsive<double>(
      compact: verticalCompact ?? 8,
      mobile: verticalMobile ?? 12,
      tablet: verticalTablet ?? 16,
      desktop: verticalTablet ?? 20,
    );
    return EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical);
  }
}

class ResponsiveNavigation {
  /// 打开二级页：窄屏全屏（标题进 [M3EAppBar]），宽屏 [M3ESideSheet] 侧滑。
  ///
  /// [body] 必须是**已 embedded** 的页面正文（不带 Scaffold / AppBar）：两种
  /// chrome 都由本方法提供，页面再叠一层就会出现双层标题栏。
  static Future<T?> showSecondaryPage<T>({
    required BuildContext context,
    required String title,
    required Widget body,
    SecondaryPageMode preferredMode = SecondaryPageMode.sideSheet,
    double? maxWidth,
    bool barrierDismissible = true,
  }) {
    final spec = context.layoutType(ResponsivePageType.detail);
    final resolvedMaxWidth = maxWidth ?? spec.modalWidth;

    if (!spec.preferTwoPane || preferredMode == SecondaryPageMode.fullScreen) {
      return _showFullScreen<T>(
        context: context,
        child: body,
        title: title,
      );
    }

    return _showM3ESideSheet<T>(
      context: context,
      title: title,
      child: body,
      maxWidth: resolvedMaxWidth,
      barrierDismissible: barrierDismissible,
    );
  }

  /// 全屏页面（页面自带 Scaffold / AppBar，不属于二级页）：如海报预览。
  static Future<T?> showFullScreenPage<T>({
    required BuildContext context,
    required Widget child,
  }) =>
      _showFullScreen<T>(context: context, child: child);

  /// 页面型弹层：窄屏 M3E 底部弹层，宽屏 M3EDialog 路由 + [PageModalCard]。
  ///
  /// 页面自带 Scaffold / AppBar（与 [showSecondaryPage] 的 embedded 正文
  /// 不同），所以卡片只提供容器，不再叠标题栏；标题、返回与滚动都由页面
  /// 自己负责。
  ///
  /// [onDismissRequest] 只在窄屏底部弹层分支生效。宽屏居中弹窗没有宿主
  /// guard，设置页由页面自己的 `NavigatorPopHandler` 先退子页、回到首屏后
  /// 再关闭弹层。
  static Future<T?> showPageModal<T>({
    required BuildContext context,
    required Widget child,
    double? maxWidth,
    double heightFactor = 0.86,
    bool barrierDismissible = true,
    bool showDragHandle = true,
    Future<bool> Function()? onDismissRequest,
    M3EBottomSheetTheme Function(M3EBottomSheetTheme)? sheetThemeBuilder,
  }) {
    if (!context.isLargeScreen) {
      return _showBottomSheet<T>(
        context: context,
        child: child,
        showCloseButton: false,
        showDragHandle: showDragHandle,
        onDismissRequest: onDismissRequest,
        sheetThemeBuilder: sheetThemeBuilder,
        pageType: ResponsivePageType.modal,
      );
    }
    return M3EDialog.show<T>(
      context,
      dialog: Builder(
        builder: (context) => PageModalCard(
          maxWidth: maxWidth,
          heightFactor: heightFactor,
          child: child,
        ),
      ),
      barrierDismissible: barrierDismissible,
      // 页面型弹窗不抢焦点：设置首页 / AI DJ 列表不该一打开就出现焦点环。
      autofocusFirst: false,
    );
  }

  /// 简单弹层（定时关闭 / 来源分享）：窄屏 M3E 底部弹层，宽屏 M3EDialog。
  ///
  /// [child] 是弹窗正文（自带内边距与滚动内容）；宽屏由 M3EDialog 负责
  /// 标题栏与滚动、窄屏由 [_buildSheetContent] 提供标题栏。
  ///
  /// [titleTrailing] 是标题右侧的附属控件（如定时关闭的「同时退出应用」
  /// 勾选项）。M3EDialog 的标题是字符串、没有右侧插槽，因此带
  /// [titleTrailing] 时必须同时传 [forceSheet]（宽屏也走底部抽屉）。
  ///
  /// [forceSheet] 为 true 时宽屏也使用底部弹层，而不是 M3EDialog。
  static Future<T?> showSimpleModal<T>({
    required BuildContext context,
    required String title,
    required Widget child,
    Widget? titleTrailing,
    bool forceSheet = false,
    bool barrierDismissible = true,
  }) {
    assert(
      titleTrailing == null || forceSheet,
      'titleTrailing 需要 forceSheet：M3EDialog 标题没有右侧插槽。',
    );
    if (!forceSheet && context.isLargeScreen) {
      return M3EDialog.show<T>(
        context,
        dialog: Builder(
          builder: (context) => M3EDialog(
            title: title,
            content: child,
            // 正文自己带左右内边距（与底部弹层共用），避免再叠 24。
            contentPadding: const EdgeInsets.only(bottom: 8),
          ),
        ),
        barrierDismissible: barrierDismissible,
      );
    }
    return _showBottomSheet<T>(
      context: context,
      child: child,
      title: title,
      titleTrailing: titleTrailing,
      // 正文自带滚动：按内容展开（页面型弹层才用 fillHeight），不要撑满整屏。
      contentLayout: AdaptiveModalContentLayout.wrapContent,
      pageType: ResponsivePageType.modal,
    );
  }

  static Future<T?> _showFullScreen<T>({
    required BuildContext context,
    required Widget child,
    String? title,
  }) {
    return Navigator.of(context).push<T>(
      M3EPageRoute(
        builder: (context) => title != null
            ? Scaffold(
                appBar: M3EAppBar.top(
                  title: Text(title),
                  automaticallyImplyLeading: true,
                ),
                body: child,
              )
            : child,
      ),
    );
  }

  /// 用 M3E 侧边弹层承载页面正文。
  ///
  /// M3E 的侧边弹层自带 header（标题 + 关闭）与 `Expanded` body，因此
  /// [child] 只能是正文；页面自己的 Scaffold / AppBar 由调用方在窄屏分支提供。
  /// 主题宽度覆盖到调用方解析出的档位（详情页平板 520 / 桌面 720）：包内
  /// 默认 maxWidth 只有 400，会把列表行挤窄。
  static Future<T?> _showM3ESideSheet<T>({
    required BuildContext context,
    required String title,
    required Widget child,
    required double maxWidth,
    bool barrierDismissible = true,
    AdaptiveModalContentLayout contentLayout =
        AdaptiveModalContentLayout.fillHeight,
  }) {
    final baseTheme = M3ETheme.of(context).sideSheetTheme;
    return M3ESideSheet.show<T>(
      context,
      title: title,
      // M3E 弹层不提供 Material 祖先，InkWell 等水波组件会直接崩溃；
      // 透明 Material 只补齐 ink 绘制层，不改变观感。
      body: Material(
        type: MaterialType.transparency,
        child: Builder(
          builder: (sheetContext) => MediaQuery.removePadding(
            context: sheetContext,
            // 包内已按系统栏 inset 给整个弹层留过底部（M3ESafeArea），正文
            // 再按 MediaQuery 补一次会双重留白。
            removeBottom: true,
            child: Padding(
              // 包内 M3ESafeArea 在键盘弹出时把 bottom 归零（只处理系统栏
              // inset），这里补键盘高度，输入区不会被键盘压住。
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              // 侧边弹层 body 是 Expanded：wrapContent 内容顶部对齐，避免
              // 拉伸成整屏高。
              child: contentLayout == AdaptiveModalContentLayout.wrapContent
                  ? Align(alignment: Alignment.topCenter, child: child)
                  : child,
            ),
          ),
        ),
      ),
      theme: baseTheme.copyWith(width: maxWidth, maxWidth: maxWidth),
      // 遮罩点击 / 返回 / Esc 的关闭开关（对应旧 barrierDismissible）。
      isDismissible: barrierDismissible,
    );
  }

  static Future<T?> _showBottomSheet<T>({
    required BuildContext context,
    required Widget child,
    required ResponsivePageType pageType,
    String? title,
    Widget? titleTrailing,
    bool showCloseButton = true,
    bool showDragHandle = true,
    Future<bool> Function()? onDismissRequest,
    M3EBottomSheetTheme Function(M3EBottomSheetTheme)? sheetThemeBuilder,
    AdaptiveModalContentLayout contentLayout =
        AdaptiveModalContentLayout.fillHeight,
  }) {
    final spec = context.layoutType(pageType);
    final screenHeight = MediaQuery.sizeOf(context).height;
    // modalMaxHeightFactor 是内容最高占屏比例；换算成 M3E 的顶部留白，
    // 保持该比例不变。
    final topMargin = screenHeight * (1 - spec.modalMaxHeightFactor);
    final baseTheme = M3ETheme.of(context).bottomSheetTheme.copyWith(
          compactTopMargin: topMargin,
          wideTopMargin: topMargin,
        );
    final theme = sheetThemeBuilder?.call(baseTheme) ?? baseTheme;
    return M3EBottomSheet.show<T>(
      context,
      theme: theme,
      // 初始展开到内容高度（上限为屏幕高度减顶部留白），向下可回落到
      // 半屏 collapsed。
      initialValue: M3EBottomSheetValue.expanded,
      showDragHandle: showDragHandle,
      onDismissRequest: onDismissRequest,
      // M3E 弹层不提供 Material 祖先，InkWell 等水波组件会直接崩溃；
      // 透明 Material 只补齐 ink 绘制层，不改变观感。
      builder: (context) => Material(
        type: MaterialType.transparency,
        child: _buildSheetContent(
          context: context,
          child: child,
          title: title,
          titleTrailing: titleTrailing,
          showCloseButton: showCloseButton,
          showDragHandle: showDragHandle,
          drawDragHandle: false, // M3E 弹层自带拖拽把手，避免双层
          contentLayout: contentLayout,
        ),
      ),
    );
  }

  static Widget _buildSheetContent({
    required BuildContext context,
    required Widget child,
    String? title,
    Widget? titleTrailing,
    bool showCloseButton = true,
    bool showDragHandle = false,
    bool drawDragHandle = true,
    AdaptiveModalContentLayout contentLayout =
        AdaptiveModalContentLayout.fillHeight,
  }) {
    if (title == null &&
        titleTrailing == null &&
        !showCloseButton &&
        !showDragHandle) {
      return child;
    }

    final body = switch (contentLayout) {
      AdaptiveModalContentLayout.wrapContent =>
        Flexible(fit: FlexFit.loose, child: child),
      AdaptiveModalContentLayout.fillHeight => Expanded(child: child),
    };
    final theme = M3ETheme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDragHandle && drawDragHandle)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        if (title != null || titleTrailing != null || showCloseButton) ...[
          // M3EBottomSheetHeader 在 material_3_expressive 1.2.0 未公开导出，
          // 这里按同一套 token 自绘：高度取 bottomSheetTheme 的
          // fullScreenHeaderHeight（默认 64）、标题用 typeScale.titleLarge，
          // 换包版本时跟着主题一起变，不再依赖写死的 48 高标题行。
          SizedBox(
            height: theme.bottomSheetTheme.fullScreenHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  if (showCloseButton)
                    M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      icon: const Icon(Icons.close_rounded),
                      // 弹层头部是通用件，l10n 可能未注册（测试 / 独立挂载）。
                      semanticLabel: (AppLocalizations.of(context) ??
                              lookupAppLocalizations(const Locale('zh')))
                          .close,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  if (title != null)
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typeScale.titleLarge.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  if (title == null) const Spacer(),
                  if (titleTrailing != null) ...[
                    const SizedBox(width: 8),
                    titleTrailing,
                  ],
                ],
              ),
            ),
          ),
          // 分隔线单独一条：header 高度固定后不再用 Container 的 bottom
          // border（border 会算进盒高，把标题行压窄）。
          const M3EDivider(),
        ],
        body,
      ],
    );
  }
}

class ResponsivePageContainer extends StatelessWidget {
  const ResponsivePageContainer({
    super.key,
    required this.child,
    this.pageType = ResponsivePageType.browse,
    this.maxWidth,
    this.padding,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final ResponsivePageType pageType;
  final double? maxWidth;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final spec = context.layoutType(pageType);
    final resolvedMaxWidth = maxWidth ?? spec.maxWidth;
    final effectiveChild = padding != null
        ? Padding(
            padding: padding!,
            child: child,
          )
        : child;

    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: resolvedMaxWidth),
        child: effectiveChild,
      ),
    );
  }
}
