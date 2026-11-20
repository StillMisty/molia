part of 'app_shell.dart';

/// 单个 tab 页分层在过渡进度 [progress]（`_tabTransition` 原始值 0..1）
/// 下的透明度与缩放。
///
/// 不变量：**除「过渡进行中的出场层」外，任何状态的缩放都必须是 1.0**。
/// 顶栏⇄播放页飞行在点击那一刻同步抓取锚点（`localToGlobal` 含祖先变换），
/// 隐藏页残留的非 1 缩放会让飞行副本落在错误的位置/尺寸上，交接瞬间真身
/// 跳变（「飞过头再复位」）。出场微缩只在过渡进行中有意义——过渡走完时
/// opacity 已是 0，此后按 1.0 参与布局与后续锚点抓取。
///
/// 入场同理不做微缩（缩放会让飞行副本落在缩放后的位置）。
@visibleForTesting
({double opacity, double scale}) shellPageLayerPresentation({
  required bool selected,
  required bool outgoing,
  required double progress,
}) {
  final t = Curves.easeInOutCubic.transform(progress);
  if (selected) {
    final inT = Curves.easeOutCubic.transform(
      ((t - 0.15) / 0.85).clamp(0.0, 1.0),
    );
    return (opacity: inT, scale: 1.0);
  }
  if (outgoing && progress < 1.0) {
    final outT = (t / 0.35).clamp(0.0, 1.0);
    return (
      opacity: 1.0 - Curves.easeInCubic.transform(outT),
      scale: 1.0 + (0.97 - 1.0) * outT,
    );
  }
  return (opacity: 0.0, scale: 1.0);
}

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
        // 既非「当前页」也非「上一页」（切换过渡的另一端）时，页面整体
        // Offstage：省掉整页 layout（Opacity(0) 只省 paint）。
        //
        // 出场层只在「还没淡完」时放行 ticker：淡出首帧若已静音，出场页
        // 会冻在上一帧再硬切；但上一目的地会长期保留 outgoing 标记，淡完
        // 后必须恢复静音，不能让隐藏页的常驻 ticker 一直空转。
        final bool fadingOut = outgoing && presentation.opacity > 0;
        return ShellPageVisibility(
          visible: selected,
          child: Offstage(
            offstage: !selected && !outgoing,
            child: IgnorePointer(
              ignoring: !selected,
              child: TickerMode(
                enabled: selected || fadingOut,
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
        );
      },
    );
  }
}
