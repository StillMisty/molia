/// 连切接管的身份 / tail 编排（cover handoff tracker）。
///
/// 只管理接管快照与更早滑出卡（tail）的生命周期；视觉公式仍在
/// `cover_handoff.dart`，控制器负责决定何时捕获 / 清空。独立出来让
/// [DeckController] 保持可读与单文件体积约束。
library;

import '../../domain/models/track.dart';
import '../cover_appearance.dart' show trackKeyOf;
import '../cover_handoff.dart';
import 'deck_models.dart';

/// 接管快照 + 被替换下来的 tail 列表。
class DeckHandoffTracker {
  CoverHandoff? _handoff;
  final List<CoverHandoffTail> _tails = <CoverHandoffTail>[];

  CoverHandoff? get handoff => _handoff;
  List<CoverHandoffTail> get tails => _tails;

  /// 落位 / hardReset：清掉接管快照，避免下一次会话误用过期起点。
  void clear() {
    _handoff = null;
    _tails.clear();
  }

  /// 追加 tail：同一 track 只保留一张（避免连续链叠影），最多两层。
  ///
  /// [exclude] 是新中心 track：新中心不能同时留在 tail 列表（回绕/重复 id
  /// 时尤其重要）。
  void _addTail(CoverHandoffTail tail, {Track? exclude}) {
    final String trackKey = trackKeyOf(tail.track)!;
    if (exclude != null && trackKeyOf(exclude) == trackKey) return;
    if (_tails.any((existing) => trackKeyOf(existing.track) == trackKey)) {
      return;
    }
    _tails.add(tail);
    while (_tails.length > 2) {
      _tails.removeAt(0);
    }
  }

  /// 移除指定 track 的 tail（新中心接管同一身份时调用）。
  void _removeTail(Track? track) {
    if (track == null) return;
    final String trackKey = trackKeyOf(track)!;
    _tails.removeWhere((tail) => trackKeyOf(tail.track) == trackKey);
  }

  /// 捕获连切接管状态：中心卡（上一段的进场卡）与上一段滑出卡。
  ///
  /// 新会话的滑出卡以中心卡捕获位置为起点，用 `q = (p - p0) / (1 - p0)`
  /// 连续插值到目标侧槽；新的中心卡继续沿用全局 `p` 的侧槽入场公式，
  /// 因此它在 p0 帧与旧中心卡完全重合，形成无缝接管。公式在
  /// `cover_handoff.dart`，这里只做身份/图层编排。
  void captureContinuous({
    required double progress,
    required int direction,
    required int sessionDirection,
    required Track centerTrack,
    required Track? oldOutgoing,
    required Track nextTrack,
    required double sideOffset,
  }) {
    // 新中心若恰好也是旧 tail（回绕/重复 id），先移除避免同曲两张卡。
    _removeTail(nextTrack);
    // 链路中的上一段：若已是接管会话，它的滑出卡由 q 公式绘制，必须按
    // 当前渲染值捕获，不能再用新会话公式重算。
    final CoverHandoff? previousHandoff = _handoff;
    if (previousHandoff != null) {
      final CoverHandoffTail? tail = coverHandoffTailFromOutgoingHandoff(
        previousHandoff,
        progress,
        sideOffset: sideOffset,
      );
      if (tail != null) _addTail(tail, exclude: nextTrack);
    } else if (oldOutgoing != null) {
      // 上一段是常规滑出：中心运动公式在 p0 的值就是它此刻的视觉状态。
      _addTail(
        coverHandoffTailFromRegularOutgoing(
          track: oldOutgoing,
          p0: progress,
          direction: sessionDirection,
          sideOffset: sideOffset,
        ),
        exclude: nextTrack,
      );
    }
    // p0 已进入源侧淡入窗口时，新中心 C 在上一帧就是右/左槽的 source
    // neighbor。捕获它的实际视觉作为新中心起点（位置/透明度都连续）；
    // 未进入窗口时 C 本来看不见，继续用全局 p 公式即可。
    final double sourceOpacity = coverSourceNewNeighborOpacityAt(progress);
    final bool captureSourceCenter = sourceOpacity > 0.01;
    _handoff = CoverHandoff(
      kind: CoverHandoffKind.continuous,
      p0: progress,
      direction: direction,
      previousCenterTrack: centerTrack,
      outgoingFrom: _centerVisualAt(
        progress: progress,
        centerTrack: centerTrack,
        direction: sessionDirection,
        sideOffset: sideOffset,
      ),
      centerFrom: captureSourceCenter
          ? coverSourceNeighborVisual(
              direction: direction,
              sideOffset: sideOffset,
              opacity: sourceOpacity,
            )
          : null,
      centerFromTrack: captureSourceCenter ? nextTrack : null,
    );
  }

  /// restart 接管：新弹簧 p=0→1，但旧中心 B / 旧滑出 A 从接管瞬间的视觉
  /// 起步。方向反转时新中心通常就是 A，直接从 A 的当前视觉插值到中心；
  /// 否则新中心从新方向的侧槽（p=0 全槽位）入场。
  void captureRestart({
    required double progress,
    required int direction,
    required int oldDirection,
    required Track centerTrack,
    required Track? oldOutgoing,
    required Track nextTrack,
    required double sideOffset,
  }) {
    final CoverHandoffVisual centerVisual = _centerVisualAt(
      progress: progress,
      centerTrack: centerTrack,
      direction: oldDirection,
      sideOffset: sideOffset,
    );
    final CoverHandoffVisual? outgoingVisual = oldOutgoing == null
        ? null
        : coverOutgoingVisualAt(
            handoff: _handoff,
            progress: progress,
            direction: oldDirection,
            sideOffset: sideOffset,
          );
    final bool targetIsOldOutgoing =
        oldOutgoing != null && trackKeyOf(nextTrack) == trackKeyOf(oldOutgoing);

    // 新中心若恰好也是旧 tail（回绕/重复 id），先移除避免同曲两张卡。
    _removeTail(nextTrack);

    // 旧 tail 在 restart 时进度归零，必须按当前渲染值 rebase 到 p0=0，
    // 否则会被冻结在旧进度上（甚至永不消失）。
    final List<CoverHandoffTail> oldTails = List.of(_tails);
    _tails.clear();
    for (final tail in oldTails) {
      // 新中心接管同一身份时，旧 tail 不能继续画（否则同曲两张卡）；
      // 同一身份只保留最近捕获的一张 tail（_addTail 去重）。
      if (trackKeyOf(tail.track) == trackKeyOf(nextTrack)) continue;
      final CoverHandoffVisual visual = tail.visualAt(
        progress,
        sideOffset: sideOffset,
        fadeSpan: deckTakeoverTailFadeSpan,
      );
      if (visual.opacity <= 0.01) continue;
      _addTail(tail.rebased(p0: 0, visual: visual), exclude: nextTrack);
    }
    // 旧滑出 A 若成为新中心，不能同时以 tail 重复渲染；否则保留短淡出。
    if (!targetIsOldOutgoing && oldOutgoing != null && outgoingVisual != null) {
      _addTail(
        CoverHandoffTail(
          track: oldOutgoing,
          p0: 0,
          direction: oldDirection,
          from: outgoingVisual,
        ),
        exclude: nextTrack,
      );
    }
    // C != A 时，若 C 已经作为上一段的 source neighbor 半透明出现，接住
    // 它在旧方向侧槽的实际视觉；否则才用全侧槽 0.85 入场。
    final double sourceOpacity = targetIsOldOutgoing
        ? 0
        : coverSourceNewNeighborOpacityAt(progress);
    final bool captureSourceCenter = sourceOpacity > 0.01;
    final CoverHandoffVisual? sourceCenterFrom = captureSourceCenter
        ? coverSourceNeighborVisual(
            direction: oldDirection,
            sideOffset: sideOffset,
            opacity: sourceOpacity,
          )
        : null;
    _handoff = CoverHandoff(
      kind: CoverHandoffKind.restart,
      p0: 0,
      direction: direction,
      previousCenterTrack: centerTrack,
      outgoingFrom: centerVisual,
      centerFrom: targetIsOldOutgoing ? outgoingVisual : sourceCenterFrom,
      centerFromTrack: targetIsOldOutgoing || captureSourceCenter
          ? nextTrack
          : null,
    );
  }

  /// 上一段中心卡在 [progress] 的实际视觉。
  ///
  /// 常规会话用全局 p 公式；若上一段接管时捕获过新中心起点（restart 的
  /// C==A，或 continuous 的 source neighbor），中心可能已被 override，必须
  /// 按捕获视觉取实际值，链式接管才不会以公式位置重新起跳。
  CoverHandoffVisual _centerVisualAt({
    required double progress,
    required Track? centerTrack,
    required int direction,
    required double sideOffset,
  }) => coverCenterVisualAt(
    handoff: _handoff,
    centerTrack: centerTrack,
    progress: progress,
    direction: direction,
    sideOffset: sideOffset,
  );
}
