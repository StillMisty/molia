/// 封面换场接管代数（cover handoff）。
///
/// 收拢「弹簧途中再次切歌」时用到的全部视觉公式：常规中心/滑出卡随进度
/// 的位置、旋转、缩放与透明度，接管快照（continuous / restart），以及被
/// 替换下来的更早滑出卡（tail）的离场插值。deck 只负责身份与图层编排，
/// 本模块只做纯数值求值，可脱离 widget 树单测。
///
/// 这些公式直接决定落位帧是否与稳态侧槽卡逐像素重合，常量与窗口边界
/// 因此集中在这里：deck 的布局（侧槽边长/偏移）也引用同一组常量，禁止在
/// 渲染侧再手抄一份。
library;

import 'package:flutter/animation.dart' show Curves;

import '../domain/models/track.dart';

/// 邻位稳态透明度；窗口淡出/淡入的端点值（p=0 / p=1 与稳态卡一致）。
const double coverHandoffNeighborOpacity = 0.85;

/// 侧槽卡片相对主封面的缩放；中心换场起手/落点也使用同一缩放。
const double coverHandoffSideSlotScale = 0.78;

/// 侧槽相对中心的横向偏移（占主封面边长的比例）。
const double coverHandoffSideOffsetFactor = 0.30;

/// 侧槽卡的倾角（弧度）。
const double coverHandoffSideRotation = 0.05;

/// 目标槽位旧身份淡出窗口终点：p ∈ [0, 0.4] 内 0.85 → 0。
const double coverHandoffOldNeighborFadeEnd = 0.4;

/// 源槽位新身份淡入窗口起点：p ∈ [0.6, 1] 内 0 → 0.85。
const double coverHandoffNewNeighborFadeStart = 0.6;

/// 一帧可复用的封面视觉状态（接管插值的输入/输出）。
class CoverHandoffVisual {
  const CoverHandoffVisual({
    required this.x,
    required this.rotation,
    required this.scale,
    required this.opacity,
  });

  final double x;
  final double rotation;
  final double scale;
  final double opacity;

  /// 线性插值：几何（位置/旋转/缩放）按 [t] 原样插值，透明度同式。
  static CoverHandoffVisual lerp(
    CoverHandoffVisual a,
    CoverHandoffVisual b,
    double t,
  ) => CoverHandoffVisual(
    x: a.x + (b.x - a.x) * t,
    rotation: a.rotation + (b.rotation - a.rotation) * t,
    scale: a.scale + (b.scale - a.scale) * t,
    opacity: a.opacity + (b.opacity - a.opacity) * t,
  );

  @override
  bool operator ==(Object other) =>
      other is CoverHandoffVisual &&
      other.x == x &&
      other.rotation == rotation &&
      other.scale == scale &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(x, rotation, scale, opacity);

  @override
  String toString() =>
      'CoverHandoffVisual(x: $x, rotation: $rotation, scale: $scale, '
      'opacity: $opacity)';
}

/// 接管方式。
///
/// - [continuous]：同一方向、未接近落位，沿用旧弹簧进度，q 走剩余行程；
/// - [restart]：方向反转 / 接近落位 / 新中心是旧滑出卡，新弹簧 p=0→1，
///   起点视觉来自接管瞬间。
enum CoverHandoffKind { continuous, restart }

/// 接管会话捕获的起点。
///
/// [previousCenterTrack] 是上一段的旧中心卡（也就是新会话的滑出卡），
/// 不是本段新中心。continuous 用 `(p - p0) / (1 - p0)` 走剩余行程；
/// restart 保留接管瞬间的旧中心/旧滑出视觉，作为新弹簧 p=0 的起点。
class CoverHandoff {
  const CoverHandoff({
    required this.kind,
    required this.p0,
    required this.direction,
    required this.previousCenterTrack,
    this.outgoingFrom,
    this.centerFrom,
    this.centerFromTrack,
  });

  final CoverHandoffKind kind;
  final double p0;
  final int direction;
  final Track previousCenterTrack;

  /// 旧中心卡（新会话滑出卡）在接管瞬间的实际视觉；链式接管时不再按公式
  /// 重算（上一段可能已被 restart 中心 override）。
  final CoverHandoffVisual? outgoingFrom;

  /// 新中心在接管瞬间的捕获视觉：restart 的 C==A，或 continuous 中 C 已
  /// 作为 source neighbor 出现；否则为 null（用公式入场）。
  final CoverHandoffVisual? centerFrom;

  /// [centerFrom] 对应的新中心 track（链式接管时用于识别上一段中心身份）。
  final Track? centerFromTrack;

  bool get isContinuous => kind == CoverHandoffKind.continuous;

  /// 接管插值进度：continuous 把 [p0] 映射到剩余行程起点，restart 用新弹簧
  /// 自身进度。
  double qAt(double progress) => isContinuous
      ? ((progress - p0) / (1 - p0)).clamp(0.0, 1.0)
      : progress.clamp(0.0, 1.0);
}

/// 接管后被替换下来的更早滑出卡：从捕获视觉继续向远离中心的方向离场并
/// 短淡出，不回到新会话的侧槽窗口。
class CoverHandoffTail {
  const CoverHandoffTail({
    required this.track,
    required this.p0,
    required this.direction,
    required this.from,
  });

  final Track track;
  final double p0;
  final int direction;
  final CoverHandoffVisual from;

  /// 当前全局进度 [progress] 下的视觉：前 [fadeSpan] 段剩余行程内淡出，
  /// 同时继续向远离中心的方向滑出（不回到新会话的侧槽窗口）。
  CoverHandoffVisual visualAt(
    double progress, {
    required double sideOffset,
    required double fadeSpan,
  }) {
    final double q = ((progress - p0) / (1 - p0)).clamp(0.0, 1.0);
    final double slide = Curves.easeOut.transform(q);
    final double fade = Curves.easeOut.transform(
      (q / fadeSpan).clamp(0.0, 1.0),
    );
    return CoverHandoffVisual(
      x: from.x + (-sideOffset * direction * 1.15 - from.x) * slide,
      rotation:
          from.rotation +
          (-coverHandoffSideRotation * direction * 1.15 - from.rotation) *
              slide,
      scale: from.scale + (0.70 - from.scale) * slide,
      opacity: from.opacity * (1 - fade),
    );
  }

  /// 进度基准重挂（restart 把 controller 归零后，旧 tail 以当前渲染值为
  /// 新起点，不能冻结在旧进度上）。
  CoverHandoffTail rebased({
    required double p0,
    required CoverHandoffVisual visual,
  }) => CoverHandoffTail(
    track: track,
    p0: p0,
    direction: direction,
    from: visual,
  );
}

/// 中心卡从侧槽入场 / 退到侧槽时的缩放。
double coverCenterScaleAt(
  double progress, {
  double sideScale = coverHandoffSideSlotScale,
}) => sideScale + (1 - sideScale) * progress;

/// 常规会话在 [progress] 的中心卡视觉（无接管 override 时的全局公式）。
///
/// 位移/旋转/缩放用原始进度（弹簧过冲保留）；透明度截断 0..1（M3E 规范：
/// effects 不过冲）。
CoverHandoffVisual coverRegularCenterVisual(
  double progress, {
  required int direction,
  required double sideOffset,
  double sideScale = coverHandoffSideSlotScale,
  double neighborOpacity = coverHandoffNeighborOpacity,
}) {
  final double opacityProgress = progress.clamp(0.0, 1.0);
  return CoverHandoffVisual(
    x: direction * sideOffset * (1 - progress),
    rotation: coverHandoffSideRotation * direction * (1 - progress),
    scale: coverCenterScaleAt(progress, sideScale: sideScale),
    opacity: neighborOpacity + (1 - neighborOpacity) * opacityProgress,
  );
}

/// 常规会话在 [progress] 的滑出卡视觉（旧中心 → 目标侧槽）。
CoverHandoffVisual coverRegularOutgoingVisual(
  double progress, {
  required int direction,
  required double sideOffset,
}) {
  final double opacityProgress = progress.clamp(0.0, 1.0);
  return CoverHandoffVisual(
    x: -sideOffset * direction * progress,
    rotation: -coverHandoffSideRotation * direction * progress,
    scale: 1.0 - 0.22 * progress,
    opacity: 1.0 - 0.15 * opacityProgress,
  );
}

/// 侧槽上的身份卡视觉（source neighbor 捕获起点；位置/倾角/缩放固定）。
CoverHandoffVisual coverSourceNeighborVisual({
  required int direction,
  required double sideOffset,
  required double opacity,
  double sideScale = coverHandoffSideSlotScale,
}) => CoverHandoffVisual(
  x: direction * sideOffset,
  rotation: coverHandoffSideRotation * direction,
  scale: sideScale,
  opacity: opacity,
);

/// 接管会话中滑出卡（旧中心）在 [progress] 的视觉。
///
/// [CoverHandoff.outgoingFrom] 为空时退回常规中心公式在 [CoverHandoff.p0]
/// 的值；随后按 q 插值到目标侧槽。
CoverHandoffVisual coverHandoffOutgoingVisual(
  CoverHandoff handoff,
  double progress, {
  required double sideOffset,
}) {
  final CoverHandoffVisual from =
      handoff.outgoingFrom ??
      coverRegularCenterVisual(
        handoff.p0,
        direction: handoff.direction,
        sideOffset: sideOffset,
      );
  final double t = handoff.qAt(progress);
  return CoverHandoffVisual.lerp(
    from,
    CoverHandoffVisual(
      x: -sideOffset * handoff.direction,
      rotation: -coverHandoffSideRotation * handoff.direction,
      scale: coverHandoffSideSlotScale,
      opacity: coverHandoffNeighborOpacity,
    ),
    t,
  );
}

/// 接管会话中滑出卡的链式查询：有接管快照时优先用捕获视觉，否则用常规
/// 公式。
CoverHandoffVisual coverOutgoingVisualAt({
  required CoverHandoff? handoff,
  required double progress,
  required int direction,
  required double sideOffset,
}) => handoff != null
    ? coverHandoffOutgoingVisual(handoff, progress, sideOffset: sideOffset)
    : coverRegularOutgoingVisual(
        progress,
        direction: direction,
        sideOffset: sideOffset,
      );

/// 接管会话中新中心在 [progress] 的捕获视觉；未捕获时返回 null（渲染侧
/// 继续用全局公式）。
CoverHandoffVisual? coverHandoffCenterVisual(
  CoverHandoff handoff,
  double progress,
) {
  final CoverHandoffVisual? from = handoff.centerFrom;
  if (from == null) return null;
  return CoverHandoffVisual.lerp(
    from,
    const CoverHandoffVisual(x: 0, rotation: 0, scale: 1, opacity: 1),
    handoff.qAt(progress),
  );
}

/// 上一段中心卡的链式查询：若接管快照捕获过同一身份的新中心起点
/// （restart 的 C==A，或 continuous 的 source neighbor），按捕获视觉求值；
/// 否则退回常规全局公式。
CoverHandoffVisual coverCenterVisualAt({
  required CoverHandoff? handoff,
  required Track? centerTrack,
  required double progress,
  required int direction,
  required double sideOffset,
}) {
  final CoverHandoff? current = handoff;
  if (current != null &&
      current.centerFromTrack != null &&
      current.centerFromTrack!.id.uri == centerTrack?.id.uri) {
    final CoverHandoffVisual? visual = coverHandoffCenterVisual(
      current,
      progress,
    );
    if (visual != null) return visual;
  }
  return coverRegularCenterVisual(
    progress,
    direction: direction,
    sideOffset: sideOffset,
  );
}

/// 常规旧中心卡捕获成 tail：中心运动公式在 [p0] 的值就是它此刻的视觉。
CoverHandoffTail coverHandoffTailFromRegularOutgoing({
  required Track track,
  required double p0,
  required int direction,
  required double sideOffset,
}) => CoverHandoffTail(
  track: track,
  p0: p0,
  direction: direction,
  from: coverRegularOutgoingVisual(
    p0,
    direction: direction,
    sideOffset: sideOffset,
  ),
);

/// 接管会话的滑出卡捕获成 tail；已淡出（≤ 0.01）时返回 null。
CoverHandoffTail? coverHandoffTailFromOutgoingHandoff(
  CoverHandoff handoff,
  double progress, {
  required double sideOffset,
}) {
  final CoverHandoffVisual visual = coverHandoffOutgoingVisual(
    handoff,
    progress,
    sideOffset: sideOffset,
  );
  if (visual.opacity <= 0.01) return null;
  return CoverHandoffTail(
    track: handoff.previousCenterTrack,
    p0: progress,
    direction: handoff.direction,
    from: visual,
  );
}

/// 目标槽位旧身份透明度：窗口 p∈[0, 0.4] 内 0.85→0（窗口内 easeOut），
/// 之后保持 0。窗口化交叉让旧身份先退场、新身份后进场。
double coverOldNeighborOpacityAt(double progress) {
  final double window = (progress / coverHandoffOldNeighborFadeEnd).clamp(
    0.0,
    1.0,
  );
  return coverHandoffNeighborOpacity * (1 - Curves.easeOut.transform(window));
}

/// 源槽位新身份透明度：窗口 p∈[0.6, 1] 内 0→0.85（窗口内 easeInOut）。
double coverSourceNewNeighborOpacityAt(double progress) {
  final double window =
      ((progress - coverHandoffNewNeighborFadeStart) /
              (1 - coverHandoffNewNeighborFadeStart))
          .clamp(0.0, 1.0);
  return coverHandoffNeighborOpacity * Curves.easeInOut.transform(window);
}

/// 把预览阶段的源侧透明度换算成稳态源侧淡入的起点。
///
/// 稳态淡入渲染的是 `neighborOpacity × easeOut(fade)`；预览窗口用的是
/// easeInOut。求 easeOut 的反函数，保证对账切换的那一帧透明度不跳。
double coverSourceFadeStartFor(
  double previewOpacity, {
  double neighborOpacity = coverHandoffNeighborOpacity,
}) {
  final double target = (previewOpacity / neighborOpacity).clamp(0.0, 1.0);
  if (target <= 0) return 0;
  if (target >= 1) return 1;
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 12; i++) {
    final mid = (low + high) / 2;
    if (Curves.easeOut.transform(mid) < target) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2;
}
