/// 歌词页滚动 / 跟随策略：纯函数（输入测量值，输出对齐比例 / 留白 / 目标偏移）。
///
/// 从 `lib/widgets/lyrics.dart` 抽出：这些数学原先埋在 State 里，只能靠
/// widget pump 验证；现在脱离渲染树，可单测（`test/lyrics_core_test.dart`）。
/// 组件仍负责测量（ScrollController / RenderAbstractViewport / MediaQuery）与
/// 执行（jumpTo / animateTo），本文件只决定「滚到哪、要不要动」。
library;

/// 顶栏渐隐带高度（未计系统状态栏）。
const double kTopFadeBandHeight = 40.0;

/// 激活行锚点比例：可见区域（去掉顶栏与底栏遮挡）的纵向中线，再整体上移
/// [upwardBias] 个视口高度（顶栏比底栏高，居中会视觉偏下）。
///
/// 返回「视口高度的比例」（0 = 顶，1 = 底）：主行文本块的顶边就放在这里
/// （见 [anchoredLineOffset]）。
double effectiveAlignment({
  required double viewport,
  required double topOverlay,
  required double bottomOverlay,
  required double upwardBias,
}) {
  if (viewport <= 0) return (0.5 - upwardBias).clamp(0.0, 1.0);
  final visibleCenter = (topOverlay + (viewport - bottomOverlay)) / 2.0;
  final anchor = visibleCenter - viewport * upwardBias;
  return (anchor / viewport).clamp(0.0, 1.0);
}

/// 列表尾部留白：按激活行锚点反推，保证最后一行（主行文本顶边）也能滚到
/// 锚点位置（等价于 `视口高 × (1 − 锚点比例) + 余量`）。
double tailSpace({
  required double viewport,
  required double topOverlay,
  required double bottomOverlay,
  required double upwardBias,
}) {
  if (viewport <= 0) return 400.0;
  final visibleHeight = (viewport - topOverlay - bottomOverlay).clamp(0.0, viewport);
  return (visibleHeight / 2.0) +
      bottomOverlay +
      viewport * upwardBias +
      8.0;
}

/// 目标偏移夹取到可滚动范围。
double clampScrollOffset({
  required double target,
  required double minScrollExtent,
  required double maxScrollExtent,
}) =>
    target.clamp(minScrollExtent, maxScrollExtent);

/// 激活行锚定：把目标（主行文本块）的顶边放到视口 [anchorFraction] 处的
/// 滚动偏移。
///
/// [leadingOffset] 取 `RenderAbstractViewport.getOffsetToReveal(target, 0.0).offset`
/// —— 目标的顶边对齐视口顶边时的偏移。注意与 `getOffsetToReveal` 的
/// alignment 参数语义不同：那里是 `alignment × (视口高 − 目标高)`，目标越高
/// 顶边越靠上；本函数不按目标高度缩放，长行换行 / 带扩展行的项越高，落点
/// 不会越偏（锚的始终是主行顶边）。
double anchoredLineOffset({
  required double leadingOffset,
  required double viewport,
  required double anchorFraction,
}) =>
    leadingOffset - anchorFraction * viewport;

/// 是否需要跳转：位移在 [deadband]（像素）以内不动，避免抖动。
bool shouldScrollTo({
  required double current,
  required double target,
  double deadband = 1.0,
}) =>
    (current - target).abs() > deadband;
