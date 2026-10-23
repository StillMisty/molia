/// 播放链路封面的统一解码边长。
///
/// 播放页大封面最大 600 逻辑像素（`player.dart` 的大屏列宽上限），顶栏 /
/// 迷你条 / 飞行副本为了共享同一 ImageCache 键也走这个尺寸。若不设上限，
/// 一张 2000×2000 封面会以原图解码占 15MB，三张邻位封面就把缓存推到
/// 45MB 以上（见 `docs/performance-audit-2026-10.md` §3.3）。
///
/// 取屏幕短边而不是固定 600：手机竖屏的播放页封面受屏宽约束，按 600 解码
/// 会白白放大到超出屏幕物理像素；桌面窗口则仍以 600 逻辑像素封顶。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show BuildContext, MediaQuery;

/// 播放页封面允许的最大逻辑边长（`player.dart` 的大屏列宽上限与解码上限
/// 共用本常量：布局变宽时解码会同步变大，不会出现「图比显示尺寸小」）。
const double playbackCoverMaxLogicalEdge = 600;

/// 当前设备上播放封面应解码到的物理像素边长。
///
/// 播放页三封面堆叠里中心封面只占可用宽的 1/1.5（两侧留给邻位封面），
/// 所以 600 逻辑像素已经是实际显示尺寸的约 1.5 倍采样；取这个上限而不是
/// 精确布局宽，是为了让顶栏 / 迷你条 / 飞行副本共享同一个键时仍有足够像素，
/// 飞行到最大也只会 1:1，不会放大糊图。
int playbackCoverDecodeEdge(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  final dpr = media?.devicePixelRatio ?? 1.0;
  final screenEdge = media?.size.shortestSide ?? playbackCoverMaxLogicalEdge;
  final logical = math.min(playbackCoverMaxLogicalEdge, screenEdge);
  return math.max(1, (logical * dpr).round());
}
