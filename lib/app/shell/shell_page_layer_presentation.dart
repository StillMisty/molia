/// 单个 tab 页在过渡进度下的透明度与缩放（纯函数，独立于页面包装层）。
///
/// 单独成文件：形状配方是壳层淡入淡出的唯一来源，接口测试直接 import 本文件
/// 即可验证，不需要挂载 `MyApp`；文件只依赖动画曲线，不进纯判定模块
/// （`shell_presentation.dart`）。
library;

import 'package:material_ui/material_ui.dart';

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
