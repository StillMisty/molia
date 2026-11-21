part of 'app_shell.dart';

/// 单个 tab 页的分层包装：fade-through（出场快速淡出微缩，入场淡入回落）。
///
/// `child` 为稳定实例：动画每帧只重建包装层，页面子树不重建（状态保持）。
/// 透明度/缩放由 [shellPageLayerPresentation] 唯一计算（含「隐藏页必须
/// scale==1」约束）。
class _ShellPageLayer extends StatelessWidget {
  const _ShellPageLayer({
    super.key,
    required this.selected,
    required this.outgoing,
    required this.animation,
    required this.child,
  });

  final bool selected;
  final bool outgoing;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final presentation = shellPageLayerPresentation(
          selected: selected,
          outgoing: outgoing,
          // expressive spatial 弹簧阻尼 0.8 会轻微过冲（bounded 只夹显式设值，
          // 模拟器逐帧输出不夹）；Curves 断言输入在 0..1，且过冲对透明度 /
          // 缩放没有意义，先夹住再交给形状函数。
          progress: animation.value.clamp(0.0, 1.0),
        );
        // 可见性门控：隐藏页面的组件放弃 provider 订阅（见 ShellPageVisibility），
        // TickerMode 只静音动画，挡不住 ChangeNotifier 触发的整页重建。
        //
        // 淡出进行中（opacity 仍在变）页面必须继续布局；淡完之后才是真正的
        // 隐藏页。注意 `outgoing` 是上一目的地的长期标记（切页后一直保留到
        // 下一次切页），不能单独用它判可见：否则上一页淡完后仍会每帧参与
        // layout，窗口 resize 时这笔开销就是每像素一次整页重排。
        //
        // 隐藏用 LayoutSkippingOffstage 而不是 Offstage：后者隐藏时仍会
        // 布局子级（见该文件注释）。隐藏子树也不接收尺寸 / DPR / padding /
        // 布局档位的变化，重新可见时在同一次 build 里换回当前值。
        final bool fadingOut = outgoing && presentation.opacity > 0;
        final bool active = selected || fadingOut;
        // 恒撑满 Stack：给页面层一个 tight 约束，让内部
        // LayoutSkippingOffstage 成为 relayout boundary。隐藏页里的
        // LayoutBuilder / Focus 依赖变化会 scheduleLayoutCallback，若祖先链
        // 已被隐藏标脏、又没有边界可停，框架会触发
        // `_debugRelayoutBoundaryAlreadyMarkedNeedsLayout` 断言。
        return SizedBox.expand(
          child: ShellPageVisibility(
            visible: selected,
            child: _PageSizeInputs(
              active: active,
              child: LayoutSkippingOffstage(
                hidden: !active,
                child: IgnorePointer(
                  ignoring: !selected,
                  child: TickerMode(
                    enabled: active,
                    child: Opacity(
                      opacity: presentation.opacity,
                      child: Transform.scale(
                        scale: presentation.scale,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 页面级尺寸输入缓存：页面的 build 只依赖这一层，而不是窗口级的
/// [MediaQuery] / [AdaptiveLayoutScope] / [DesktopLayout]。
///
/// 隐藏页（`active == false`）继续收到最后一次可见时的尺寸输入，窗口 resize
/// 不会让它的 MediaQuery / 布局档位通知页面重建；重新可见时在本次 build 里
/// 换回当前值，并靠 `visible` 翻转通知一次。`active` 与 TickerMode 同源
/// （选中或淡出中），淡出期间仍需按当前尺寸布局。
class _PageSizeInputs extends StatefulWidget {
  const _PageSizeInputs({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_PageSizeInputs> createState() => _PageSizeInputsState();
}

class _PageSizeInputsState extends State<_PageSizeInputs> {
  MediaQueryData? _media;
  AdaptiveLayout? _adaptive;

  /// 只留解析结果，不留 [DesktopLayout] 本身：InheritedWidget 持有整棵
  /// 外层子树，缓存它会让旧帧的 widget 树跟着页面一起常驻。
  ({bool isDesktopPlatform, double windowWidth, double railWidth})? _desktop;

  @override
  Widget build(BuildContext context) {
    // 这里刻意整份取 MediaQueryData：本层要把「当前值」或「隐藏时的旧快照」
    // 原样重新提供给页面，分面读取拼不回一个完整的 MediaQueryData。订阅由
    // 本层承担，页面只依赖内层缓存，窗口变化不会重建隐藏页；整树订阅是这
    // 一层的必要成本，已登记到 media_query_usage_test 白名单。
    final media = MediaQuery.of(context);
    final adaptive = AdaptiveLayoutScope.of(context);
    final desktop = DesktopLayout.of(context);
    // 重新可见时直接在本帧取当前值（不 setState）；隐藏期间只保留旧值。
    if (widget.active || _media == null) {
      _media = media;
      _adaptive = adaptive;
      _desktop = (
        isDesktopPlatform: desktop.isDesktopPlatform,
        windowWidth: desktop.windowWidth,
        railWidth: desktop.railWidth,
      );
    }
    final desktopValues = _desktop!;
    return MediaQuery(
      data: _media!,
      child: AdaptiveLayoutScope(
        layout: _adaptive!,
        visible: widget.active,
        child: DesktopLayout(
          isDesktopPlatform: desktopValues.isDesktopPlatform,
          windowWidth: desktopValues.windowWidth,
          railWidth: desktopValues.railWidth,
          visible: widget.active,
          child: widget.child,
        ),
      ),
    );
  }
}
