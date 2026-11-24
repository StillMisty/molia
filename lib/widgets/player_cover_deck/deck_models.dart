/// 封面堆叠渲染共享的槽位、语义 key 与一帧视觉快照。
///
/// 这里只放「不含 provider / 不含控制器」的纯数据与小工具：入口组件、控制器
/// 与渲染层都从这里取同一份 key / 侧槽外观 / 帧字段，避免各自手抄。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../cover_appearance.dart';
import '../cover_handoff.dart';
import '../player_cover_session.dart';

/// 侧槽卡片相对主封面的缩放；中心换场起手/落点也使用同一缩放。
const double deckSideSlotScale = coverHandoffSideSlotScale;

/// 接管后上一段滑出卡的离场窗口（占剩余行程的比例）。
///
/// 它已经不在新会话的邻位窗口里，必须在接管开头快速淡出，否则会与新的
/// oldNeighbor 身份在同一槽位叠影。
const double deckTakeoverTailFadeSpan = 0.45;

/// 侧槽卡外观：把 [CoverAppearance.page] 的圆角 / 描边 / 阴影按
/// [deckSideSlotScale] 一起缩放。
///
/// 换场结束时，滑出卡是「主封面尺寸 × scale 0.78」，而稳态侧槽卡是
/// 「侧槽尺寸 × scale 1」。若侧槽仍用页面端 r18/1px/24px 阴影，落位帧
/// 圆角会从 18×0.78 跳到 18、描边从 0.78 跳到 1、阴影也突然变重；
/// 缩放过外观后两段视觉完全一致，交接无跳变。
final CoverAppearance deckSideSlotAppearance = CoverAppearance(
  radius: CoverAppearance.page.radius * deckSideSlotScale,
  stroke: CoverAppearance.page.stroke * deckSideSlotScale,
  shadow: CoverAppearance.page.shadow * deckSideSlotScale,
  iconRatio: CoverAppearance.page.iconRatio,
  iconSize: CoverAppearance.page.iconSize,
);

/// 移动卡在 Stack 中的稳定 key：回拖时绘制顺序翻转，靠它保持卡片
/// element（图片 / 动画状态）不被按位置重建。
const Key deckCenterLayerKey = ValueKey('coverLayerCenter');
const Key deckOutgoingLayerKey = ValueKey('coverLayerOutgoing');
const Key deckOutgoingArtworkLayerKey = ValueKey('coverLayerOutgoingArtwork');

/// 中心槽位（进场）封面的语义 key：切歌中间帧从哪一侧入场是可观察行为。
const Key deckCenterCoverCardKey = ValueKey('coverSlotCenter');

/// 滑出（旧中心）封面的语义 key：滑出卡是否参与切歌动画是可观察行为。
/// 对账校正期间它也是淡出中的旧预览卡。
const Key deckOutgoingCoverCardKey = ValueKey('coverSlotOutgoing');

/// 中心封面换图（同 id、URL 更新）时旧图卡片的语义 key。
const Key deckOutgoingArtworkCardKey = ValueKey('coverArtworkOutgoing');

/// 左右槽位卡按身份（track id）的语义 key。
///
/// 空闲期身份交叉淡化时同一槽位会并存新旧两张卡（旧淡出、新淡入），测试
/// 按身份分别定位并采样透明度（不读私有字段）。
Key deckSideCoverCardKey({required bool left, required TrackId id}) =>
    ValueKey('coverSlot${left ? 'Left' : 'Right'}:${id.uri}');

/// 中心封面按身份（track id）的语义 key。
///
/// 稳态中心、拖动/提交/回退的预览目标与对账校正后的实际曲目都可观察。
Key deckCenterCoverTrackKey(TrackId id) =>
    ValueKey('coverSlotCenter:${id.uri}');

/// 封面堆叠的槽位标识（按压反馈按槽位定位）。
enum DeckSlot { left, center, right }

/// 一帧封面堆叠的渲染输入。
///
/// 控制器把会话、动画控制器与空闲视觉折算成这一份不可变快照；渲染层只读
/// 它，不再回头摸控制器或 provider。逐帧构造，字段全部是值 / 身份引用。
class DeckArtworkFrame {
  const DeckArtworkFrame({
    required this.displayTrack,
    required this.snapshot,
    required this.session,
    required this.artDimension,
    required this.progress,
    required this.correcting,
    required this.animating,
    required this.showingPreview,
    required this.outgoingOnTop,
    required this.handoff,
    required this.handoffActive,
    required this.handoffTails,
    required this.leftOutgoing,
    required this.rightOutgoing,
    required this.sourceFade,
    required this.identityFade,
    required this.artworkFade,
    required this.correctionFade,
    required this.sideTransitioning,
    required this.centerArtworkRefreshing,
    required this.outgoingCenterArtworkUrl,
    required this.currentImageUrl,
    required this.sideReveal,
    required this.pageCoverHidden,
    required this.morphCoverKey,
  });

  final Track? displayTrack;
  final PlaybackSnapshot snapshot;

  /// 拍下这一帧时的切歌会话快照（渲染层不再回头摸会话）。
  final CoverSwapSnapshot session;

  /// 当前布局的封面边长（侧槽尺寸 / 位移由它派生）。
  final double artDimension;

  /// 切歌弹簧原始进度（可能过冲；透明度在渲染侧截断）。
  final double progress;

  final bool correcting;
  final bool animating;
  final bool showingPreview;
  final bool outgoingOnTop;
  final CoverHandoff? handoff;
  final bool handoffActive;
  final List<CoverHandoffTail> handoffTails;
  final Track? leftOutgoing;
  final Track? rightOutgoing;

  /// 对账落位后源侧身份的纯淡入进度（已 easeOut）。
  final double sourceFade;

  /// 空闲槽位身份交叉淡化进度（已 easeOut）。
  final double identityFade;

  /// 中心同 id 换图淡化进度（已 easeOut）。
  final double artworkFade;

  /// 对账校正交叉淡化进度（已 easeOut）。
  final double correctionFade;

  /// 邻位是否正在借用当前封面作过渡占位。
  final bool sideTransitioning;

  final bool centerArtworkRefreshing;
  final String? outgoingCenterArtworkUrl;

  /// 当前展示曲目的真实封面 URL（邻位过渡占位 / 拖动源侧缺图兜底）。
  final String? currentImageUrl;

  /// 进入/离开播放页时侧槽原位淡入淡出；null = 减弱动效，直接落位。
  final ValueListenable<double>? sideReveal;

  final bool pageCoverHidden;
  final Key? morphCoverKey;
}
