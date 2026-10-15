import 'package:flutter/widgets.dart';

/// 列表「回到顶部」的统一动作（底栏重复点击资料库 / 收藏等入口）。
///
/// 距离不定 → 固定时长 + 曲线：弹簧采样要求固定距离（`MotionCurve` 的时长是
/// 采样窗口，长列表会被窗口截断成硬停），而 `ScrollController.animateTo` 走
/// `DrivenScrollActivity`，自带用户触摸打断（拖动即接管），不用自己起 ticker。
///
/// 无客户端（列表未挂载）或已在顶部时不动作：省掉一次零位移的无意义动画。
void animateScrollToTop(ScrollController controller) {
  if (!controller.hasClients || controller.offset <= 0) return;
  controller.animateTo(
    0,
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );
}
