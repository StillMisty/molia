/// 播放链路封面的统一解码边长。
///
/// 播放页大封面最大 600 逻辑像素（`player.dart` 的大屏列宽上限），顶栏 /
/// 迷你条 / 飞行副本为了共享同一 ImageCache 键也走这个尺寸。若不设上限，
/// 一张 2000×2000 封面会以原图解码占 15MB，三张邻位封面就把缓存推到
/// 45MB 以上（见 `docs/performance-audit.md` §3.3，2026-10-22 首轮）。
///
/// 取屏幕短边而不是固定 600：手机竖屏的播放页封面受屏宽约束，按 600 解码
/// 会白白放大到超出屏幕物理像素；桌面窗口则仍以 600 逻辑像素封顶。
///
/// 短边按 256 / 384 / 512 / 600 四档向上取整，不直接当解码边长：桌面拖动
/// 窗口时短边每个像素都在变，直接取值等于每帧换一个 ResizeImage 键，顶栏 /
/// 底栏 / 播放页三张封面会跟着反复重解码。向上取档保证解码边长不小于当前
/// 窗口所需（不糊图），同一档内拖动则复用已解码的图；DPR 仍乘在档位之外，
/// 跨屏拖动导致 DPR 变化时照常换键（物理像素需求确实变了）。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show BuildContext, MediaQuery;

/// 播放页封面允许的最大逻辑边长（`player.dart` 的大屏列宽上限与解码上限
/// 共用本常量：布局变宽时解码会同步变大，不会出现「图比显示尺寸小」）。
const double playbackCoverMaxLogicalEdge = 600;

/// 逻辑解码边长的固定档位（向上取档）。
///
/// 档位只由逻辑短边决定，不掺 DPR：DPR 是乘在档位之后的独立因子，跨屏拖动
/// 时物理像素需求变了就必须换键，不能把两种变化混进同一组档位里。
const List<double> _logicalEdgeBuckets = [256, 384, 512, 600];

/// 按逻辑短边与 DPR 计算播放封面应解码到的物理像素边长。
///
/// 纯函数：不读 context，档位边界可直接单测。逻辑短边先夹到 256 –
/// [playbackCoverMaxLogicalEdge]，再向上取到档位表的最近一档——向上而不是
/// 就近，是为了让解码边长始终覆盖实际显示需求，否则小窗口会拿到比布局还
/// 小的图，播放页封面被放大后发糊。
int playbackCoverDecodeEdgeFor({
  required double dpr,
  required double shortestSide,
}) {
  final double requested = shortestSide.isFinite
      ? shortestSide
      : playbackCoverMaxLogicalEdge;
  final double clamped = math.min(
    playbackCoverMaxLogicalEdge,
    math.max(_logicalEdgeBuckets.first, requested),
  );
  final double logical = _logicalEdgeBuckets.firstWhere(
    (edge) => edge >= clamped,
    orElse: () => playbackCoverMaxLogicalEdge,
  );
  // 非法 DPR（0 / NaN）按 1 兜底，避免 round 抛错或得到无意义的 0。
  final double ratio = dpr.isFinite && dpr > 0 ? dpr : 1.0;
  return math.max(1, (logical * ratio).round());
}

/// 当前设备上播放封面应解码到的物理像素边长。
///
/// 播放页三封面堆叠里中心封面只占可用宽的 1/1.5（两侧留给邻位封面），
/// 所以 600 逻辑像素已经是实际显示尺寸的约 1.5 倍采样；取这个上限而不是
/// 精确布局宽，是为了让顶栏 / 迷你条 / 飞行副本共享同一个键时仍有足够像素，
/// 飞行到最大也只会 1:1，不会放大糊图。
int playbackCoverDecodeEdge(BuildContext context) {
  // 按 aspect 订阅：播放封面在滚动 / 键盘弹收时不该跟着整份 MediaQueryData
  // 一起重建。
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final shortestSide =
      MediaQuery.maybeSizeOf(context)?.shortestSide ??
      playbackCoverMaxLogicalEdge;
  return playbackCoverDecodeEdgeFor(dpr: dpr, shortestSide: shortestSide);
}
