/// 封面槽位的可复用包装：飞行 reveal 与按压反馈。
///
/// 两者都只做「包装层」：卡片作为稳定 child 传入，逐帧重建只发生在窄包装器
/// 内部（opacity / IgnorePointer / 缩放），不重建图片与动画状态。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';

/// 单个侧槽的 reveal 包装：直接监听飞行控制器，把卡片作为稳定 child。
///
/// 逐帧只重建 opacity / IgnorePointer；位置与倾角始终是稳态，reveal<1 时
/// 只做原位淡入/淡出。卡片在 reveal=0 也保持布局与图片状态（opacity 0），
/// 避免尾段淡入时重建闪占位。
class SideRevealSlot extends StatelessWidget {
  const SideRevealSlot({
    super.key,
    required this.reveal,
    required this.x,
    required this.rotation,
    required this.opacity,
    required this.onTap,
    required this.child,
  });

  final ValueListenable<double> reveal;
  final double x;
  final double rotation;
  final double opacity;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Center(
        child: ValueListenableBuilder<double>(
          valueListenable: reveal,
          child: child,
          builder: (context, value, child) {
            final Widget content = child ?? const SizedBox.shrink();
            final double progress = value.clamp(0.0, 1.0);
            if (progress >= 1.0) {
              return Transform.translate(
                offset: Offset(x, 0),
                child: Transform.rotate(
                  angle: rotation,
                  child: Opacity(
                    opacity: opacity,
                    child: IgnorePointer(
                      ignoring: onTap == null,
                      child: content,
                    ),
                  ),
                ),
              );
            }
            final double eased = Curves.easeOutCubic.transform(progress);
            // 侧槽只做原位淡入/淡出：位置与倾角保持稳态，不再从中心
            // 平移/缩放。否则飞行动画里侧图会先沿水平方向滑出，随后才
            // 显出倾角（用户反馈的「先水平平移再倾斜」）。
            return Transform.translate(
              offset: Offset(x, 0),
              child: Transform.rotate(
                angle: rotation,
                child: Opacity(
                  opacity: opacity * eased,
                  child: IgnorePointer(ignoring: true, child: content),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 槽位按压反馈：按下缩放 + 点击。
///
/// 按压走原始指针事件（TapGestureRecognizer 的 onTapDown 与横滑识别器竞争时
/// 要等 100ms 判定或抬手才触发，给不了「按下即反馈」）；点击语义由调用方
/// 传入（已包含触感），本包装器不依赖 Haptics / Playback。
class DeckSlotPressScale extends StatelessWidget {
  const DeckSlotPressScale({
    super.key,
    required this.scale,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onPointerCancel,
    required this.onTap,
    required this.child,
  });

  final double scale;
  final VoidCallback onPointerDown;
  final VoidCallback onPointerUp;
  final VoidCallback onPointerCancel;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: Listener(
        onPointerDown: (_) => onPointerDown(),
        onPointerUp: (_) => onPointerUp(),
        onPointerCancel: (_) => onPointerCancel(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

/// 可点击侧邻封面的读屏语义与桌面手型光标。
///
/// 侧邻封面是「上一首 / 下一首」按钮，不是一张可看的图：只标方向标签，
/// 并接管子树的语义（点击动作由本节点提供）——否则读屏会把它读成无声的
/// 图片 + 一个匿名可点区域。不可点时（拖动 / 飞行 / 无曲目）不包这层。
class DeckSideCoverSemantics extends StatelessWidget {
  const DeckSideCoverSemantics({
    super.key,
    required this.left,
    required this.onTap,
    required this.child,
  });

  /// true = 左槽（上一首），false = 右槽（下一首）。
  final bool left;

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n =
        AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('zh'));
    return Semantics(
      button: true,
      label: left ? l10n.previousTrackTooltip : l10n.nextTrackTooltip,
      onTap: onTap,
      excludeSemantics: true,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: child),
    );
  }
}
