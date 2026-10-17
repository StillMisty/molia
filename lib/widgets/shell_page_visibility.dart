import 'package:flutter/widgets.dart';

/// 壳层页面可见性：常驻挂载的页面（播放 / 收藏 / 资料库）据此放弃 provider
/// 订阅——隐藏页的消息订阅会让整页 build（含过滤 / 排序 / 列表），
/// `TickerMode` 只静音动画，挡不住 `ChangeNotifier` 触发的重建。
///
/// 使用约定（页面 / 常驻 tab 内部）：
///
/// ```dart
/// final provider = ShellPageVisibility.maybeVisibleOf(context) ?? true
///     ? context.watch<LibraryProvider>()
///     : context.read<LibraryProvider>();
/// ```
///
/// - 可见：正常 `watch`（依赖随重建重新登记）；
/// - 隐藏：`read` 不建立依赖，通知不再触发本页重建；重新可见时
///   [ShellPageVisibility.updateShouldNotify] 触发一次重建并重新订阅；
/// - 脱离壳层挂载（单测直接挂页面）时 [maybeVisibleOf] 返回 null，
///   调用方按可见处理，行为与门控引入前一致。
class ShellPageVisibility extends InheritedWidget {
  const ShellPageVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  /// 当前页面是否可见（被选中）。
  final bool visible;

  /// 读取可见性并登记依赖；无壳层（未挂载 [ShellPageVisibility]）返回 null。
  static bool? maybeVisibleOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ShellPageVisibility>()
      ?.visible;

  @override
  bool updateShouldNotify(ShellPageVisibility oldWidget) =>
      visible != oldWidget.visible;
}
