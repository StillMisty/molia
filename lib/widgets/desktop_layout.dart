import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'responsive.dart';
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
    this.visible = true,
    required super.child,
  });

  /// 收藏 / 曲库两栏布局的固定栏宽（左合集列表 / 左专辑歌手分组）。
  static const double browseGroupPaneWidth = 320;

  /// 当前平台是否桌面（linux / windows / macOS）：桌面增强的总开关。
  ///
  /// 与壳层骨架分流同源（`defaultTargetPlatform`），测试里可经
  /// `MyApp(desktopShell:)` 强制骨架，但页面内的桌面增强仍按平台判定——
  /// 它们只在桌面骨架里渲染，无需再逐层传开关。
  final bool isDesktopPlatform;

  /// 解析时的窗口宽（屏幕宽语义）。
  ///
  /// 原始像素，**不作为通知判据**（见 [updateShouldNotify]）：桌面拖拽窗口
  /// 时它每个像素都在变，消费它做连续布局的叶子应改用 `LayoutBuilder`。
  final double windowWidth;

  /// 解析时的实际栏宽（= M3E 导航轨折叠宽，默认 96）。
  ///
  /// 不变量：桌面壳层侧栏恒为折叠档（`alwaysCollapse`）—— 侧栏是这个壳层里
  /// 唯一常驻吃宽度的栏，[contentWidth] 因此就是内容区可用宽。侧栏若将来支持
  /// 展开，宽度来源要跟着换（而不是在这里加一个「估算值」）。
  final double railWidth;

  /// 本作用域对应的页面是否可见（壳层页面层用）。
  ///
  /// 默认 true：壳层全局作用域 / 独立挂载不变。页面层隐藏时用最后的解析值
  /// 再包一层并置 false，窗口宽变化不再通知隐藏页；重新可见时靠这次翻转
  /// 通知一次并拿到最新值。
  final bool visible;

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
      contentWidth >= spec.minContentWidth;

  /// 壳层入口（不随逐像素尺寸重建的宿主）。
  ///
  /// `scope` 在调用方 build 里读 `MediaQuery.sizeOf`，会把原始像素注册成
  /// 调用方的依赖（壳层每 1px 重建）。宿主把这次读取收在自己这一层，
  /// [updateShouldNotify] 只看派生判据，向下只在真正影响版式时通知。
  static Widget host({required Widget child}) =>
      _DesktopLayoutHost(child: child);

  /// 消费入口：取壳层解析结果；无壳层时按当前 context 回退解析。
  static DesktopLayout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopLayout>() ??
      _resolveLayout(context);

  /// 通知判据：只比「会改变版式」的派生量。
  ///
  /// [windowWidth] 原始像素不作为判据：桌面拖拽窗口时它每 1px 都变，算进来
  /// 会让所有消费方（收藏正文 / 搜索结果整棵滚动视图 / 曲库详情）每次尺寸
  /// 变化都整页重建。需要连续宽度的叶子用 `LayoutBuilder` 读约束；
  /// [contentWidth] 只在判据翻转的那一帧被读到，不能当连续值用。
  @override
  bool updateShouldNotify(DesktopLayout oldWidget) =>
      visible != oldWidget.visible ||
      (visible &&
          (isDesktopPlatform != oldWidget.isDesktopPlatform ||
              railWidth != oldWidget.railWidth ||
              tableColumns != oldWidget.tableColumns ||
              tableColumnsFor(TrackRowColumnSpec.history) !=
                  oldWidget.tableColumnsFor(TrackRowColumnSpec.history)));
}

/// [DesktopLayout.host] 的实现：读取窗口宽与侧栏宽并解析一次。
///
/// 自身每个像素都会重建，但向下只在 [DesktopLayout.updateShouldNotify] 的
/// 判据翻转时通知；子树的逐像素自适应交给局部 `LayoutBuilder`。
class _DesktopLayoutHost extends StatelessWidget {
  const _DesktopLayoutHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return DesktopLayout(
      isDesktopPlatform: isDesktopPlatform(),
      windowWidth: width,
      railWidth: M3ETheme.of(context).navigationRailTheme.collapsedWidth,
      child: child,
    );
  }
}
