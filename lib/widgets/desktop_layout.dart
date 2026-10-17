import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/responsive.dart';
import 'track_row.dart';

/// 按当前 context 解析桌面布局（[DesktopLayout.of] 的回退与壳层提供共用）。
///
/// 为什么放在类外：类里有一个同名的 `isDesktopPlatform` 字段，类作用域会
/// 遮蔽 `responsive.dart` 的同名判定函数，类内静态方法调不到它。
DesktopLayout _resolveLayout(BuildContext context, {Widget? child}) =>
    DesktopLayout(
      isDesktopPlatform: isDesktopPlatform(),
      windowWidth: MediaQuery.sizeOf(context).width,
      // 实际栏宽 = M3E 导航轨的折叠宽（壳层侧栏恒为折叠档；主题改值这里
      // 跟着变，不写死数值）。
      railWidth: M3ETheme.of(context).navigationRailTheme.collapsedWidth,
      child: child ?? const SizedBox.shrink(),
    );

/// 桌面布局解析结果：壳层一次解析，页面 / 骨架只消费。
///
/// 为什么集中：同一句「是不是桌面宽布局」若分散在收藏页 / 设置页 / 资料库 /
/// 表格列 / 桌面骨架里各自推导，阈值与宽度来源（屏幕宽 / 内容宽 / 窗口宽）
/// 的漂移没有任何机制能发现。本类把两类语义分开表达：
///
/// - 窗口宽语义是字段与派生 getter（[masterDetail] / [searchCompact] /
///   [railForceCollapsed] / [queuePanelAvailable] / [contentWidth] /
///   [tableColumns] / [tableColumnsFor]）：壳层在 `build` 里解析一次并向下
///   提供；
/// - 内容宽语义是 `*At(contentWidth)` 方法：内容区宽度由消费方量出后传入，
///   但「用哪个阈值 + 平台判据」只此一处。
///
/// 无壳层（独立挂载页面 / 弹层路由 / 测试）时 [of] 按当前 context 回退解析，
/// 与壳层生产路径同一公式。
class DesktopLayout extends InheritedWidget {
  const DesktopLayout({
    super.key,
    required this.isDesktopPlatform,
    required this.windowWidth,
    required this.railWidth,
    required super.child,
  });

  /// 当前平台是否桌面（linux / windows / macOS）：桌面增强的总开关。
  ///
  /// 与壳层骨架分流同源（`defaultTargetPlatform`），测试里可经
  /// `MyApp(desktopShell:)` 强制骨架，但页面内的桌面增强仍按平台判定——
  /// 它们只在桌面骨架里渲染，无需再逐层传开关。
  final bool isDesktopPlatform;

  /// 解析时的窗口宽（屏幕宽语义）。
  final double windowWidth;

  /// 解析时的实际栏宽（= M3E 导航轨折叠宽，默认 96）：桌面壳层里唯一
  /// 常驻吃宽度的栏；批量瘦身后队列面板与页内合集栏都不再占宽。
  final double railWidth;

  /// 页面级桌面增强（窗口宽语义）：桌面平台 + 窗口宽 ≥ [Breakpoints.desktop]。
  ///
  /// 消费方：收藏页 master-detail 合集栏与设置首屏两列——同一判据合并为一处，
  /// 两页观感不会再各自漂移。
  bool get masterDetail =>
      isDesktopPlatform && windowWidth >= Breakpoints.desktop;

  /// 顶栏搜索形态：窗口宽 < [Breakpoints.desktop]（900）退化为图标按钮。
  ///
  /// 消费方：桌面骨架顶栏与壳层 Ctrl+F 快捷键分流（两者必须同一判据，
  /// 否则快捷键会落到不可见的入口上）。
  bool get searchCompact => windowWidth < Breakpoints.desktop;

  /// 桌面侧栏是否强制折叠（窗口宽 < [railForceCollapseWidth]）。
  ///
  /// 只影响渲染，不改布局记忆值：变宽后按用户设定恢复。
  bool get railForceCollapsed => windowWidth < railForceCollapseWidth;

  /// 队列面板是否可渲染（窗口宽 ≥ [queueForceCloseWidth]）。
  bool get queuePanelAvailable => windowWidth >= queueForceCloseWidth;

  /// 内容宽（窗口宽语义）：窗口宽 − 实际栏宽。
  double get contentWidth => windowWidth - railWidth;

  /// 宽屏表格列（窗口宽语义）：桌面平台 + [contentWidth] ≥
  /// [TrackRowColumnSpec.minContentWidth]（默认一档规范 = 搜索 / 发现）。
  ///
  /// 为什么按窗口宽 − 栏宽而不是量出的内容宽：判据只随窗口与栏宽变，不随
  /// 页面结构变 —— 量出的内容宽在带页内栏 / 面板的页面里会被二次扣减，
  /// 同一窗口宽在不同页面得出不同结论。
  bool get tableColumns => tableColumnsFor(TrackRowColumnSpec.standard);

  /// 宽屏表格列（窗口宽语义，按规范）：列多的一套（播放历史）需要更宽的
  /// 内容区才不溢出，阈值跟着 [spec] 走。
  bool tableColumnsFor(TrackRowColumnSpec spec) =>
      tableColumnsAt(contentWidth, minContentWidth: spec.minContentWidth);

  /// 宽屏表格列（内容宽语义）：桌面平台 + 内容宽 ≥ [minContentWidth]。
  ///
  /// 输入 = 内容宽，由调用方量出。页面自带常驻栏 / 面板时量出的内容宽会被
  /// 二次扣减、判据随页面结构漂移，此时应改用 [tableColumns] /
  /// [tableColumnsFor]（窗口宽 − 实际栏宽）。
  bool tableColumnsAt(double contentWidth, {double? minContentWidth}) =>
      isDesktopPlatform &&
      contentWidth >= (minContentWidth ?? TrackRowColumns.minWidth);

  /// 资料库渠道竖栏（内容宽语义）：桌面平台 + 内容宽 ≥ [Breakpoints.desktop]。
  ///
  /// 与 [tableColumnsAt] 同一宽度来源：渠道入口与搜索结果表格列共处同一内容
  /// 区，口径必须同源；渠道数量等页面自身条件由调用方 AND。
  bool channelRailAt(double contentWidth) =>
      isDesktopPlatform && contentWidth >= Breakpoints.desktop;

  /// 侧栏强制折叠阈值（桌面骨架专用）。
  static const double railForceCollapseWidth = 1000;

  /// 队列面板可渲染阈值（桌面骨架专用；<1200 时面板不渲染、入口置灰）。
  static const double queueForceCloseWidth = 1200;

  /// 壳层提供入口：解析当前 context 的窗口宽 / 平台位，并用结果包住 [child]。
  static Widget scope(BuildContext context, {required Widget child}) =>
      _resolveLayout(context, child: child);

  /// 解析当前 context 的桌面布局（壳层非 build 时读取：快捷键分流等）。
  static DesktopLayout resolve(BuildContext context) => _resolveLayout(context);

  /// 消费入口：取壳层解析结果；无壳层时按当前 context 回退解析。
  static DesktopLayout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopLayout>() ??
      _resolveLayout(context);

  @override
  bool updateShouldNotify(DesktopLayout oldWidget) =>
      isDesktopPlatform != oldWidget.isDesktopPlatform ||
      windowWidth != oldWidget.windowWidth ||
      railWidth != oldWidget.railWidth;
}
