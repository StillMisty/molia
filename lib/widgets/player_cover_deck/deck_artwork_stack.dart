/// 封面堆叠的渲染层：三槽位、移动卡、换场接管 tail 与稳态淡化。
///
/// 只消费 [DeckArtworkFrame]（控制器折好的一帧视觉）与显式传入的播放 / 封面
/// 查询能力；不读 provider、不持有控制器。手势宿主、会话时机与动画编排都在
/// 外层（入口组件 / `DeckController`）。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../domain/models/track.dart';
import '../../providers/playback_provider.dart';
import '../playback_cover_decode.dart';
import '../app_network_image.dart';
import '../cover_appearance.dart';
import '../cover_fallback.dart';
import '../cover_handoff.dart';
import 'deck_models.dart';
import 'deck_slots.dart';

/// 三封面堆叠：左=上一首、中=当前、右=下一首（左右压住露出边缘）。
///
/// 切歌动画与「拖动跟手」共用同一条进度：横向拖动时中心位由预览目标封面
/// 顶上、按滑动距离过渡；松手后从同一进度续播或回弹。无上一首/下一首时
/// 对应槽位为空（不闪、不空跳）。
class DeckArtworkStack extends StatelessWidget {
  const DeckArtworkStack({
    super.key,
    required this.frame,
    required this.playback,
    required this.realCoverUrlOf,
    required this.defaultCoverUrl,
    required this.centerScaleAnimation,
    required this.playStateScaleAnimation,
    required this.pressScaleFor,
    required this.onPressStart,
    required this.onPressEnd,
    required this.onTapCenter,
    required this.onTapPrevious,
    required this.onTapNext,
  });

  final DeckArtworkFrame frame;
  final PlaybackProvider playback;

  /// 真实封面 URL（自定义 / 原始；默认封面只做展示兜底）。
  final String? Function(Track?) realCoverUrlOf;

  /// 全局默认封面（展示兜底；真实封面缺失 / 加载失败时使用）。
  final String? defaultCoverUrl;

  /// 播放态缩放 × 按压反馈的重绘源（中心卡专用）。
  final Listenable centerScaleAnimation;
  final Animation<double> playStateScaleAnimation;

  final double Function(DeckSlot slot) pressScaleFor;
  final void Function(DeckSlot slot) onPressStart;
  final VoidCallback onPressEnd;
  final VoidCallback onTapCenter;
  final VoidCallback? onTapPrevious;
  final VoidCallback? onTapNext;

  @override
  Widget build(BuildContext context) {
    final session = frame.session;
    final double p = frame.progress;
    final double pClamped = p.clamp(0.0, 1.0);
    final int dir = session.direction;
    final double sideSize = frame.artDimension * deckSideSlotScale;
    final double offset = frame.artDimension * coverHandoffSideOffsetFactor;
    const double sideRotation = coverHandoffSideRotation;
    final ValueListenable<double>? sideReveal = frame.sideReveal;
    final CoverHandoff? handoff = frame.handoff;
    final children = <Widget>[];

    // 接管后更早的滑出卡：从捕获位置继续向左离场并快速淡出，
    // 不参与新会话的邻位窗口（否则会与 oldNeighbor 同身份叠影）。
    for (final tail in frame.handoffTails) {
      final CoverHandoffVisual visual = tail.visualAt(
        p,
        sideOffset: offset,
        fadeSpan: deckTakeoverTailFadeSpan,
      );
      if (visual.opacity <= 0.005) continue;
      children.add(
        _mainCoverLayer(
          context,
          tail.track,
          artDimension: frame.artDimension,
          // 尾卡列表只在接管时变动：按身份给稳定 key（restart
          // 会 rebase p0，不能把会变的进度放进 key，否则 Element
          // 被重建、图片闪）。去重后同曲最多一张 tail。
          layerKey: ValueKey('coverHandoffTail:${tail.track.id.uri}'),
          x: visual.x,
          rotation: visual.rotation,
          scale: visual.scale,
          opacity: visual.opacity,
          interactive: false,
        ),
      );
    }

    // 回拖/回弹时当前封面压在中心目标之上；正向拖动/落位时
    // 目标在上（与稳态一致）。
    final bool outgoingOnTop = frame.showingPreview && frame.outgoingOnTop;
    Widget? outgoingLayer;
    // 目标槽位旧身份：窗口 p∈[0, 0.4] 内 0.85→0 原位淡出（无位移），
    // 与源槽位新身份的淡入窗口（p∈[0.6, 1]）错开——同一槽位不出现
    // 两张半透明封面叠加的「叠影」。接管会话中这个旧身份正是被
    // 替换下来的上一段滑出卡，由 tail 层接管，不能重复渲染。
    if (frame.animating &&
        session.oldNeighbor != null &&
        !frame.handoffActive) {
      children.add(
        _sideCoverLayer(
          context,
          session.oldNeighbor,
          sideSize: sideSize,
          x: -offset * dir,
          rotation: -sideRotation * dir,
          opacity: coverOldNeighborOpacityAt(pClamped),
          reveal: sideReveal,
          cardKey: deckSideCoverCardKey(
            left: dir > 0,
            id: session.oldNeighbor!.id,
          ),
        ),
      );
    }

    if (frame.animating) {
      // 源槽位新身份：窗口 p∈[0.6, 1] 内 0→0.85 原位淡入（无位移）。
      // 拖动预览时目标尚未成为快照 current，源侧身份取会话提前
      // 解析的「再下一首 / 再上一首」，让三槽窗口随拖动连续滑动；
      // 即时切歌时快照已经翻页，取新 current 的邻位即可。
      final Track? sourceTrack = frame.showingPreview
          ? session.previewSourceNeighbor
          : (dir == 1 ? frame.snapshot.next : session.previous);
      // 预览中目标封面仍在场，作为源侧缺图占位最连续；即时切歌
      // 时当前封面就是新曲目。
      final String? sourcePlaceholderUrl = frame.showingPreview
          ? (realCoverUrlOf(session.to) ?? frame.currentImageUrl)
          : frame.currentImageUrl;
      children.add(
        _sideCoverLayer(
          context,
          sourceTrack,
          sideSize: sideSize,
          x: offset * dir,
          rotation: sideRotation * dir,
          opacity: coverSourceNewNeighborOpacityAt(pClamped),
          reveal: sideReveal,
          cardKey: sourceTrack == null
              ? null
              : deckSideCoverCardKey(left: dir < 0, id: sourceTrack.id),
          placeholderUrl: sourcePlaceholderUrl,
        ),
      );
      // 滑出的旧当前 → 目标槽位：全程插值（终点与稳态槽位卡
      // 完全重合：位置/旋转/缩放/透明度一致，动画结束无 pop）。
      // 连切接管时以捕获的中心卡视觉为起点、按剩余行程
      // `q = (p - p0) / (1 - p0)` 插值（见 cover_handoff.dart）；
      // 否则沿用本轮全局进度公式。
      // 入栈时机由 outgoingOnTop 决定（见中心卡渲染）。
      if (session.from != null) {
        final CoverHandoffVisual outgoing = coverOutgoingVisualAt(
          handoff: frame.handoffActive ? handoff : null,
          progress: p,
          direction: dir,
          sideOffset: offset,
        );
        outgoingLayer = _mainCoverLayer(
          context,
          session.from,
          artDimension: frame.artDimension,
          slotKey: deckOutgoingCoverCardKey,
          layerKey: deckOutgoingLayerKey,
          x: outgoing.x,
          rotation: outgoing.rotation,
          scale: outgoing.scale,
          opacity: outgoing.opacity,
          interactive: false,
        );
      }
    } else {
      // 稳态邻位：可点击切歌（左=上一首，右=下一首）。
      // - 拖动对账落位后的源侧新身份以纯透明度淡入（无位移/缩放/旋转）；
      // - 空闲期身份变化（加歌/删歌/开关随机/next 变空）以约
      //   180ms 原位交叉淡化表达（旧身份淡出、新身份淡入）。
      // 两个淡化控制器稳态都停在 1，倍率不产生任何影响。
      final double sourceFade = frame.sourceFade;
      final double identityFade = frame.identityFade;
      // 邻位占位只在槽位身份过渡期间借用当前封面：冷启动首帧
      // 左右图还没解码完时若也用当前封面，会短暂出现「三张
      // 同一封面」的错位闪动；稳态交给各自的中性占位。
      final String? sidePlaceholderUrl = frame.sideTransitioning
          ? frame.currentImageUrl
          : null;
      children.addAll(
        _idleSideLayers(
          context,
          left: true,
          shown: session.previous,
          outgoing: frame.leftOutgoing,
          sideSize: sideSize,
          x: -offset,
          rotation: -sideRotation,
          sourceFade: dir == -1 ? sourceFade : 1.0,
          identityFade: identityFade,
          reveal: sideReveal,
          placeholderUrl: sidePlaceholderUrl,
          // 左槽点击 = 上一首：只要展示了身份（快照 previous 或
          // 队列前一位，与后端 skipToPrevious 的回退、拖动预览
          // 同源）就可点；左槽为空时不渲染卡片，自然不可点。
          // 飞行期间禁用点击（副本/锚点交接期间不接受切歌）。
          onTap: onTapPrevious,
        ),
      );
      children.addAll(
        _idleSideLayers(
          context,
          left: false,
          shown: frame.snapshot.next,
          outgoing: frame.rightOutgoing,
          sideSize: sideSize,
          x: offset,
          rotation: sideRotation,
          sourceFade: dir == 1 ? sourceFade : 1.0,
          identityFade: identityFade,
          reveal: sideReveal,
          placeholderUrl: sidePlaceholderUrl,
          onTap: onTapNext,
        ),
      );
    }

    // 中心位：拖动/提交/回退时由预览目标封面顶上（真正的切歌在松手后
    // 才发生）；动画/稳态下就是当前曲目。顶栏⇄播放页飞行时只隐藏
    // 这一张。预览目标在拖动开始时固定，不重读快照（否则提交后
    // 快照先推新邻位，中心封面会闪成再下一首）。
    //
    // 透明度随进度 0.85→1.0 连续插值：p=0 时与稳态的源槽位卡
    // 完全一致（0.85），消除「动画首帧硬跳 1.0」的起手闪跳；
    // p=1 时与稳态中心封面一致（1.0）。
    if (frame.correcting) {
      // 对账校正：旧预览卡（原位）淡出、实际曲目卡淡入，全程
      // 无位移/缩放——到位曲目与预览目标不同时只换图不搬位。
      final double correctionFade = frame.correctionFade;
      if (session.to != null) {
        children.add(
          _mainCoverLayer(
            context,
            session.to,
            artDimension: frame.artDimension,
            slotKey: deckOutgoingCoverCardKey,
            layerKey: deckOutgoingLayerKey,
            x: 0,
            rotation: 0,
            scale: 1.0,
            opacity: 1.0 - correctionFade,
            interactive: false,
            hidden: frame.pageCoverHidden,
          ),
        );
      }
      children.addAll(_steadyCenterLayers(context, opacity: correctionFade));
    } else if (frame.animating) {
      final Track? centerTrack = frame.showingPreview
          ? (session.to ?? frame.displayTrack)
          : frame.displayTrack;
      if (!outgoingOnTop && outgoingLayer != null) {
        children.add(outgoingLayer);
      }
      // 接管捕获了新中心起点时（restart 的 C==A / continuous 的
      // source neighbor）按捕获视觉插值；否则用公式入场。
      final CoverHandoffVisual? handoffCenter = frame.handoffActive
          ? coverHandoffCenterVisual(handoff!, p)
          : null;
      final CoverHandoffVisual regularCenter = coverRegularCenterVisual(
        p,
        direction: dir,
        sideOffset: offset,
      );
      children.add(
        _mainCoverLayer(
          context,
          centerTrack,
          artDimension: frame.artDimension,
          slotKey: deckCenterCoverCardKey,
          layerKey: deckCenterLayerKey,
          trackKey: centerTrack == null
              ? null
              : deckCenterCoverTrackKey(centerTrack.id),
          x: handoffCenter?.x ?? regularCenter.x,
          rotation: handoffCenter?.rotation ?? regularCenter.rotation,
          scale: handoffCenter?.scale ?? regularCenter.scale,
          opacity: handoffCenter?.opacity ?? regularCenter.opacity,
          interactive: !frame.showingPreview,
          coverKey: frame.morphCoverKey,
          hidden: frame.pageCoverHidden,
          // 中心卡不借上一首封面当占位：目标图未预热时用曲目自己的
          // 默认封面 / 中性回退，避免旧封面从下面透出。
        ),
      );
      if (outgoingOnTop && outgoingLayer != null) {
        children.add(outgoingLayer);
      }
    } else {
      // 稳态中心：同 id、URL 更新（音源补图）时以约 250ms 交叉
      // 淡化换图（旧图淡出、新图淡入），不播切歌动画。
      children.addAll(_steadyCenterLayers(context, opacity: 1.0));
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  /// 稳态邻位槽位的渲染层：身份交叉淡化期间同槽位并存旧（淡出）与新
  /// （淡入）两张卡，全程稳态几何（无位移/缩放/旋转）；身份变空则只渲染
  /// 淡出中的旧卡（淡出为空）。[sourceFade] 是对账落位后的源侧纯淡入倍率。
  List<Widget> _idleSideLayers(
    BuildContext context, {
    required bool left,
    required Track? shown,
    required Track? outgoing,
    required double sideSize,
    required double x,
    required double rotation,
    required double sourceFade,
    required double identityFade,
    required ValueListenable<double>? reveal,
    required String? placeholderUrl,
    required VoidCallback? onTap,
  }) {
    final double base = coverHandoffNeighborOpacity * sourceFade;
    final layers = <Widget>[];
    if (outgoing != null) {
      layers.add(
        _sideCoverLayer(
          context,
          outgoing,
          sideSize: sideSize,
          x: x,
          rotation: rotation,
          opacity: base * (1 - identityFade),
          reveal: reveal,
          cardKey: deckSideCoverCardKey(left: left, id: outgoing.id),
          placeholderUrl: placeholderUrl,
        ),
      );
    }
    if (shown != null) {
      layers.add(
        _sideCoverLayer(
          context,
          shown,
          sideSize: sideSize,
          x: x,
          rotation: rotation,
          opacity: base * identityFade,
          reveal: reveal,
          cardKey: deckSideCoverCardKey(left: left, id: shown.id),
          placeholderUrl: placeholderUrl,
          onTap: onTap,
          pressSlot: left ? DeckSlot.left : DeckSlot.right,
        ),
      );
    }
    return layers;
  }

  /// 稳态中心封面层：实际曲目卡（交互 + 共享飞行锚点），同 id 换图淡化
  /// 期间追加旧 URL 卡（原位淡出、不可交互）。
  List<Widget> _steadyCenterLayers(
    BuildContext context, {
    required double opacity,
  }) {
    final layers = <Widget>[];
    if (frame.centerArtworkRefreshing && frame.artworkFade < 1) {
      layers.add(
        _mainCoverLayer(
          context,
          frame.displayTrack,
          artDimension: frame.artDimension,
          slotKey: deckOutgoingArtworkCardKey,
          layerKey: deckOutgoingArtworkLayerKey,
          x: 0,
          rotation: 0,
          scale: 1.0,
          opacity: opacity * (1 - frame.artworkFade),
          interactive: false,
          hidden: frame.pageCoverHidden,
          // 空串表达「明确无封面」（音源补图前的起点）：传 null 会被当作
          // 「未提供覆盖」而回退到曲目当前（新）URL，旧图卡就变成新图了。
          artworkUrlOverride: frame.outgoingCenterArtworkUrl ?? '',
          fallback: buildFallbackArtwork(context),
        ),
      );
    }
    layers.add(
      _mainCoverLayer(
        context,
        frame.displayTrack,
        artDimension: frame.artDimension,
        slotKey: deckCenterCoverCardKey,
        layerKey: deckCenterLayerKey,
        trackKey: frame.displayTrack == null
            ? null
            : deckCenterCoverTrackKey(frame.displayTrack!.id),
        x: 0,
        rotation: 0,
        scale: 1.0,
        opacity: opacity * frame.artworkFade,
        interactive: true,
        coverKey: frame.morphCoverKey,
        hidden: frame.pageCoverHidden,
      ),
    );
    return layers;
  }

  /// 邻位封面（压在当前封面之下；[onTap] 非空时可点击切歌）。
  ///
  /// 稳态几何固定（位置/旋转/尺寸），透明度由调用方按窗口/淡入计算。
  /// [reveal] 是进入/离开播放页时侧槽原位淡入/淡出的进度监听：只有本层
  /// 包装器逐帧重建，卡片作为稳定 child 保留（reveal=0 也保持布局与解码，
  /// 只把 opacity 调到 0，避免飞行尾段淡入时重建图片闪占位）。
  /// 中心卡不在这里，所以 reveal 不会改变封面锚点。
  /// 不参与 hit test 时（[onTap] 为空）忽略指针。[cardKey] 是身份语义 key
  /// （空闲淡换时同一槽位并存新旧两张卡，测试按身份定位）。
  Widget _sideCoverLayer(
    BuildContext context,
    Track? track, {
    required double sideSize,
    required double x,
    required double rotation,
    required double opacity,
    required ValueListenable<double>? reveal,
    Key? cardKey,
    String? placeholderUrl,
    VoidCallback? onTap,
    DeckSlot? pressSlot,
  }) {
    if (track == null) return const SizedBox.shrink();
    Widget card = _buildCoverCard(
      context,
      track,
      sideSize,
      key: cardKey,
      appearance: deckSideSlotAppearance,
      placeholderUrl: placeholderUrl,
    );
    if (onTap != null) {
      final slot = pressSlot!;
      card = DeckSideCoverSemantics(
        left: slot == DeckSlot.left,
        onTap: onTap,
        child: DeckSlotPressScale(
          scale: pressScaleFor(slot),
          onPointerDown: () => onPressStart(slot),
          onPointerUp: onPressEnd,
          onPointerCancel: onPressEnd,
          onTap: onTap,
          child: card,
        ),
      );
    }
    final ValueListenable<double>? revealListenable = reveal;
    if (revealListenable == null) {
      return Positioned.fill(
        child: Center(
          child: Transform.translate(
            offset: Offset(x, 0),
            child: Transform.rotate(
              angle: rotation,
              child: Opacity(
                opacity: opacity,
                child: IgnorePointer(ignoring: onTap == null, child: card),
              ),
            ),
          ),
        ),
      );
    }
    return SideRevealSlot(
      reveal: revealListenable,
      x: x,
      rotation: rotation,
      opacity: opacity,
      onTap: onTap,
      child: card,
    );
  }

  /// 当前/滑出封面（可交互时保留滑动手势与点击播放/暂停）。
  ///
  /// [artworkUrlOverride] 用于换图淡化的旧 URL 卡：曲目身份相同、只换图片
  /// 地址（[fallback] 与稳态中心卡一致，避免缺图时占位不一致）。
  /// [trackKey] 是中心封面的身份语义 key（校正后展示的是哪一首）。
  Widget _mainCoverLayer(
    BuildContext context,
    Track? track, {
    required double artDimension,
    required double x,
    required double rotation,
    required double scale,
    required double opacity,
    required bool interactive,
    Key? slotKey,
    Key? trackKey,
    Key? layerKey,
    Key? coverKey,
    bool hidden = false,
    String? artworkUrlOverride,
    Widget? fallback,
  }) {
    Widget card = interactive
        ? _buildConfigurableMainContent(
            context,
            track,
            artDimension: artDimension,
            coverKey: coverKey,
          )
        : _buildCoverCard(
            context,
            track,
            artDimension,
            artworkUrlOverride: artworkUrlOverride,
            fallback: fallback,
          );
    if (slotKey != null) {
      card = KeyedSubtree(key: slotKey, child: card);
    }
    if (trackKey != null) {
      card = KeyedSubtree(key: trackKey, child: card);
    }
    return Positioned.fill(
      key: layerKey,
      child: Center(
        child: Transform.translate(
          offset: Offset(x, 0),
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              // 隐藏（飞行中）直接乘进同一条透明度：零时长、同层合成，
              // 不嵌套第二层 Opacity（锚点仍在同一布局盒内）。
              child: Opacity(opacity: hidden ? 0 : opacity, child: card),
            ),
          ),
        ),
      ),
    );
  }

  /// 封面卡（三封面/飞行副本共用 [CoverCard]）：外观（r18 + 1px 描边 +
  /// 柔和阴影、裁剪 17）由 [CoverAppearance.page] 统一给出，与飞行副本同源。
  ///
  /// 统一走无缩放缓存键（与顶栏/迷你条/预加载一致），邻位封面升到中间
  /// 只是 transform 插值，不会因缓存键不同重新解码、闪占位图。
  /// [artworkUrlOverride] 供换图淡化渲染旧 URL（曲目身份不变、只换图片地址）。
  Widget _buildCoverCard(
    BuildContext context,
    Track? track,
    double size, {
    Key? key,
    CoverAppearance appearance = CoverAppearance.page,
    Widget? fallback,
    String? placeholderUrl,
    String? artworkUrlOverride,
  }) {
    final url = artworkUrlOverride ?? realCoverUrlOf(track);
    return CoverCard(
      key: key,
      size: size,
      appearance: appearance,
      content: (context, clip, iconSize) {
        final coverEdge = playbackCoverDecodeEdge(context);
        final placeholder = placeholderUrl != null && placeholderUrl != url
            ? _buildCoverImage(
                context,
                placeholderUrl,
                iconSize: iconSize,
                coverEdge: coverEdge,
              )
            : fallback;
        return _buildCoverImage(
          context,
          url,
          iconSize: iconSize,
          coverEdge: coverEdge,
          fallbackUrl: defaultCoverUrl,
          placeholder: placeholder,
          // 缺图槽位也走同一回退（默认封面 → Molia 标志），不展示
          // 「最近播放」封面冒充当前曲目。
          errorWidget:
              fallback ?? buildFallbackArtwork(context, iconSize: iconSize),
        );
      },
    );
  }

  /// 播放页封面图片：始终走 [AppNetworkImage] 展示原图。
  Widget _buildCoverImage(
    BuildContext context,
    String? url, {
    required double iconSize,
    required int coverEdge,
    String? fallbackUrl,
    Widget? placeholder,
    Widget? errorWidget,
  }) {
    return AppNetworkImage(
      url: url,
      fallbackUrl: fallbackUrl,
      fit: BoxFit.cover,
      // 与顶栏↔播放页飞行共享同一外观源（图标态落点必须与真身同尺寸）。
      fallbackIconSize: iconSize,
      memCacheWidth: coverEdge,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }

  Widget _buildConfigurableMainContent(
    BuildContext context,
    Track? track, {
    required double artDimension,
    Key? coverKey,
  }) {
    return AnimatedBuilder(
      // 播放态缩放 × 按压反馈（两者相乘合成，互不覆盖）：播放态只用极轻微
      // 的缩放，暂停时封面保持清晰（变暗 20% 会让封面看起来像被禁用）。
      animation: centerScaleAnimation,
      builder: (context, child) {
        return DeckSlotPressScale(
          scale: playStateScaleAnimation.value * pressScaleFor(DeckSlot.center),
          onPointerDown: () => onPressStart(DeckSlot.center),
          onPointerUp: onPressEnd,
          onPointerCancel: onPressEnd,
          onTap: onTapCenter,
          child: child!,
        );
      },
      child: RepaintBoundary(
        child: KeyedSubtree(
          key: coverKey,
          child: _buildCoverCard(
            context,
            track,
            artDimension,
            fallback: buildFallbackArtwork(context),
          ),
        ),
      ),
    );
  }
}
