import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 把 M3E 主题挂到路由内容**之下**的包装器。
///
/// 为什么需要在路由里再挂一层：`M3EMaterialApp` 的 M3ETheme 位于 Navigator
/// 之上，页面内 `Text` 依赖的是 App 级 `DefaultTextStyle`。Android 预测返回
/// 退场与主题重建（取色 / 亮度切换）交错时，正在出栈的页面元素还挂在 App 级
/// `DefaultTextStyle` 的依赖表里，随后被卸载就会触发「不是我们的后代」断言。
/// 页面内容在路由内、Navigator 之下再挂一层 M3ETheme 后，页面文本只依赖这层
/// 随路由生灭的 `DefaultTextStyle`，与 App 级 chrome 主题解耦。
///
/// [builder] 必须在内层 M3ETheme 的 context 下执行，因此这里用 [Builder]
/// 而不是直接 `builder(context)`；否则页面拿到的仍是 App 级主题。
class M3ERouteTheme extends StatelessWidget {
  /// 创建路由级主题包装；[builder] 在包装后的主题下构建页面内容。
  const M3ERouteTheme({super.key, required this.builder});

  /// 页面内容构建器（在路由级 M3ETheme 之下执行）。
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    // 读取当前主题数据而不是让调用方传入：路由推入后主题仍可能变化
    // （封面取色 / 系统亮度 / 字体），这里跟随最近一层 M3ETheme 同步重建。
    final data = M3ETheme.of(context);
    return M3ETheme(
      data: data,
      child: Builder(builder: builder),
    );
  }
}

/// 页面路由的统一入口：内容经 [M3ERouteTheme] 在 Navigator 之下再挂一层
/// M3E 主题。
///
/// 直接使用 `MaterialPageRoute` 会让页面文本依赖 App 级 `DefaultTextStyle`，
/// 预测返回退场 + 主题重建时可能触发框架断言；页面路由一律走本类
/// （`test/architecture/layering_test.dart` 会扫描 `lib/**` 防止回退）。
class M3EPageRoute<T> extends MaterialPageRoute<T> {
  /// 构造参数与 material_ui 的 [MaterialPageRoute] 保持一致（含
  /// `includeRouteSemantics`），返回类型仍是 [T]。
  M3EPageRoute({
    required super.builder,
    super.settings,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.requestFocus,
    super.includeRouteSemantics,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  });

  @override
  Widget buildContent(BuildContext context) => M3ERouteTheme(builder: builder);
}
