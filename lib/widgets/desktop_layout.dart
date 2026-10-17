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
/// 的漂移没有任何机制能发现。全部判据都只有窗口宽一种来源：壳层在 `build`
/// 里解析一次并向下提供，页面不再自己量宽（量出的内容宽会被页内常驻栏二次
/// 扣减，同一窗口宽在不同页面得出不同结论）。
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

  /// 解析时的实际栏宽（= M3E 导航轨折叠宽，默认 96）。
  ///
  /// 不变量：桌面壳层侧栏恒为折叠档（`alwaysCollapse`），且队列面板已并入
  /// 播放页右栏 —— 侧栏是这个壳层里唯一常驻吃宽度的栏，[contentWidth] 因此
  /// 就是内容区可用宽。侧栏若将来支持展开，宽度来源要跟着换（而不是在这里
  /// 加一个「估算值」）。
  final double railWidth;

  /// 页面级桌面增强（窗口宽语义）：桌面平台 + 窗口宽 ≥ [Breakpoints.desktop]。
  ///
  /// 消费方：设置首屏两列（窄窗回单列）。阈值只维护在这里，页面不自推。
  bool get masterDetail =>
      isDesktopPlatform && windowWidth >= Breakpoints.desktop;

  /// 顶栏搜索形态：窗口宽 < [Breakpoints.desktop]（900）退化为图标按钮。
  ///
  /// 消费方：桌面骨架顶栏与壳层 Ctrl+F 快捷键分流（两者必须同一判据，
  /// 否则快捷键会落到不可见的入口上）。
  bool get searchCompact => windowWidth < Breakpoints.desktop;

  /// 内容宽（窗口宽语义）：窗口宽 − 实际栏宽（[railWidth] 的不变量：
  /// 壳层只有侧栏一条常驻栏，这里就是内容区可用宽）。
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
      isDesktopPlatform && contentWidth >= spec.minContentWidth;

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
