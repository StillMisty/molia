/// 播放页封面堆叠模块（cover deck）。
///
/// 收拢完整播放器封面区的三封面堆叠渲染、横滑切歌的全部手势与动画状态、
/// 切歌提交与对账；播放器（`player.dart`）只负责布局尺寸、顶栏/迷你共享
/// 飞行锚点与主题取色联动。
///
/// 槽位（slot）：左 = 上一首、中 = 当前（拖动/提交时为预览目标）、右 = 下一首；
/// 切歌（swap）动画与拖动跟手共用模块内部同一条进度控制器；拖动/提交/对账/
/// 兜底等全部会话状态收敛在唯一一个 [CoverSwapSession] 中。
///
/// 切歌检测由播放快照监听驱动（[PlaybackProvider] 通知 → 比较当前曲目 id），
/// build 期间不再做切歌判定，只刷新空闲缓存（下一首身份与方向提示，必须与旧
/// 实现同帧刷新才能保持快速连切的方向基准）。
///
/// 对外公开的最小面：
/// - [PlayerCoverDeck]：组件（槽位渲染 + 手势宿主 + 切歌会话状态）；
/// - [artworkUrlOf] / [trackKeyOf] / [buildDefaultArtwork] /
///   [buildFallbackArtwork]：封面 URL 与占位工具，迷你条 / 飞行副本共用。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../models/play_mode.dart';
import '../providers/playback_provider.dart';
import 'app_network_image.dart';
import 'molia_mark.dart';
import 'player_cover_session.dart';
import 'player_cover_swap.dart';
import 'player_morph.dart';

/// 曲目封面 URL（空串视同无封面；领域 Track 自带可靠 id/artwork）。
String? artworkUrlOf(Track? track) {
  final url = track?.artwork?.uri.toString();
  return url == null || url.isEmpty ? null : url;
}

/// 曲目的稳定 key（领域 id）。
String? trackKeyOf(Track? track) => track?.id.uri;

/// 无封面时的中性占位：主题容器色背景 + Molia 标志。
Widget buildFallbackArtwork(BuildContext context, {Key? key}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    key: key,
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: MoliaMark(
      size: 64,
      color: scheme.onSurfaceVariant,
    ),
  );
}

/// 构建默认/回退封面：优先使用持久化的最后播放封面；没有（或加载失败）时
/// 用中性占位图标。
Widget buildDefaultArtwork(
  BuildContext context, {
  Key? key,
  BoxFit fit = BoxFit.cover,
}) {
  final lastPlayedImageUrl =
      context.read<PlaybackProvider>().lastPlayedImageUrl;
  if (lastPlayedImageUrl != null) {
    return AppNetworkImage(
      key: key ?? const ValueKey('last_played_image'),
      url: lastPlayedImageUrl,
      fit: fit,
      fallbackIconSize: 64,
      errorWidget: buildFallbackArtwork(context, key: key),
    );
  }
  return buildFallbackArtwork(context,
      key: key ?? const ValueKey('default_image'));
}

/// 完整播放器封面堆叠：三封面（槽位）渲染 + 横滑切歌手势 + 切歌会话状态。
///
/// 播放器只提供布局尺寸（[artDimension]/[stackDimension]/[stackHeight]）、
/// 共享飞行锚点（[morph]/[fullCoverKey]/[coverFlightActive]）与切歌联动回调
/// （[onTrackSwapped]）；封面 URL、占位、拖动、切歌、对账都归本模块。
class PlayerCoverDeck extends StatefulWidget {
  /// 封面区横向手势宿主 key：拖动期间 element 必须稳定（识别器不被
  /// dispose），同时供测试精确定位这一层手势。
  static const Key swipeHostKey = ValueKey('artworkSwipeHost');

  /// 中心槽位（进场）封面的语义 key：切歌中间帧从哪一侧入场是可观察行为，
  /// 对外用这个锚点定位中心封面（也供共享飞行之外的调试/断言使用）。
  static const Key centerCoverCardKey = ValueKey('coverSlotCenter');

  const PlayerCoverDeck({
    super.key,
    required this.displayTrack,
    required this.artDimension,
    required this.stackDimension,
    required this.stackHeight,
    required this.fullCoverKey,
    this.isLargeScreen = false,
    this.morph,
    this.expandAnimation,
    this.coverFlightActive = false,
    this.onTrackSwapped,
  });

  /// 展示曲目（播放器已按 `current ?? 最近播放` 回退解析）。
  final Track? displayTrack;

  /// 当前布局的封面边长（拖动跟手换算行程时需要）。
  final double artDimension;

  /// 堆叠容器尺寸（播放器按可用空间计算，本模块只负责渲染）。
  final double stackDimension;
  final double stackHeight;

  /// 主封面锚点：迷你 ⇄ 完整飞行抓取落点矩形用（播放器持有该 key）。
  final GlobalKey fullCoverKey;

  /// 大屏布局：拖动提交阈值（距离/速度）按屏型取不同值。
  final bool isLargeScreen;

  /// 顶栏共享飞行控制器：提供播放页封面锚点并同步隐藏状态。
  final PlayerMorphController? morph;

  /// 迷你 ⇄ 完整展开进度：本模块监听其状态沿触发侧邻位入场
  /// （展开开始藏起、展开落位演出）；飞行副本本身由播放器管理。
  final Animation<double>? expandAnimation;

  /// 迷你 ⇄ 完整封面飞行进行中：主封面真身隐藏、新手势被忽略。
  final bool coverFlightActive;

  /// 展示曲目切换联动（切换帧的 post-frame 触发）：播放器借此清除进度
  /// 拖动残留并启动标题入场。[duringDrag] = 切换发生在拖动进行中，此时
  /// 跳过标题入场，让位给拖动预览。
  final void Function(bool duringDrag)? onTrackSwapped;

  @override
  State<PlayerCoverDeck> createState() => _PlayerCoverDeckState();
}

class _PlayerCoverDeckState extends State<PlayerCoverDeck>
    with TickerProviderStateMixin {
  // ---- 横向拖动跟踪（从手指真实按下位置起算） ----
  double? _dragStartX;
  double? _dragStartY;
  bool _isHorizontalDragConfirmed = false;
  double _dragDx = 0;

  /// 切歌会话：拖动预览、提交等待、对账、兜底与方向提示的唯一状态对象。
  final CoverSwapSession _session = CoverSwapSession();

  /// 已订阅的播放 Provider（运行时可能被替换，见 [_bindPlaybackIfNeeded]）。
  PlaybackProvider? _playback;

  /// 快照通知已排入微任务（同一批通知只对账一次）。
  bool _trackSyncScheduled = false;

  /// 唯一一根进度控制器：拖动跟手与切歌动画共用（不允许第二条视觉进度）。
  late AnimationController _coverController;

  /// 侧边（上一首/下一首）封面入场进度：0 = 藏在中心封面背后（透明、
  /// 内收、放平），1 = 稳态。三处触发：滑动提交落位、顶栏⇄播放页飞行
  /// 落位、迷你⇄完整展开落位。
  late AnimationController _prevNeighborEntrance;
  late AnimationController _nextNeighborEntrance;

  /// 封面堆叠重绘源：中心过渡 + 两侧入场。
  late final Listenable _coverStackAnimation;

  /// 播放态中心封面轻微缩放（暂停时保持清晰，不做变暗）。
  late AnimationController _playStateController;
  late Animation<double> _playStateScaleAnimation;

  /// morph 的 pageHeaderHidden 上一帧值（检测「飞向播放页」与「落位」沿）。
  bool _pageHeaderWasHidden = false;

  @override
  void initState() {
    super.initState();
    _playStateController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _playStateScaleAnimation = Tween<double>(begin: 0.98, end: 1.0).animate(
        CurvedAnimation(
            parent: _playStateController, curve: Curves.easeOutCubic));

    _coverController = AnimationController(
      duration: const Duration(milliseconds: 460),
      vsync: this,
    )..value = 1.0;

    _prevNeighborEntrance = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: 1.0,
    );
    _nextNeighborEntrance = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: 1.0,
    );
    _coverStackAnimation = Listenable.merge([
      _coverController,
      _prevNeighborEntrance,
      _nextNeighborEntrance,
    ]);
    // 即时切歌落位即会话结束（完成中 → 空闲）；拖动提交由对账路径收尾。
    _coverController.addStatusListener(_handleCoverStatus);
    _pageHeaderWasHidden = widget.morph?.pageHeaderHidden ?? false;
    // 顶栏⇄播放页飞行时只有封面隐藏：必须监听 morph 控制器才能重建真身。
    widget.morph?.addListener(_onMorphChanged);
    widget.expandAnimation?.addStatusListener(_handleExpandStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 快照监听：切歌检测完全由通知驱动（build 期间不再判定切歌）。
    _bindPlaybackIfNeeded();
  }

  @override
  void didUpdateWidget(covariant PlayerCoverDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.morph != widget.morph) {
      oldWidget.morph?.removeListener(_onMorphChanged);
      widget.morph?.addListener(_onMorphChanged);
      _pageHeaderWasHidden = widget.morph?.pageHeaderHidden ?? false;
    }
    if (oldWidget.expandAnimation != widget.expandAnimation) {
      oldWidget.expandAnimation?.removeStatusListener(_handleExpandStatus);
      widget.expandAnimation?.addStatusListener(_handleExpandStatus);
    }
    // provider 可能被替换：父级重建时重新检查订阅（此时 widget.displayTrack
    // 已来自新快照）。
    _bindPlaybackIfNeeded();
  }

  /// 订阅（或换绑）播放 Provider，并在换绑后同步一次会话身份。
  ///
  /// `context.read` 不建立依赖：本模块不因每次通知整树重建，只在检测到曲目
  /// 变化时 setState——渲染触发时机与旧 build 内检测一致。provider 被替换时
  /// 必须重新订阅，否则会话会停留在旧 provider 的曲目上。
  void _bindPlaybackIfNeeded() {
    final playback = context.read<PlaybackProvider>();
    if (identical(playback, _playback)) return;
    _playback?.removeListener(_handlePlaybackChanged);
    _playback = playback;
    playback.addListener(_handlePlaybackChanged);
    // 首帧（或换 provider）：以 deck 实际展示的曲目建立/校正会话身份，
    // 等价旧实现在首个 build 里的检测路径。
    _syncDisplayTrack(playback);
  }

  /// 播放快照通知：合并同一批通知到微任务统一对账。
  ///
  /// - 不在通知回调里直接改 UI：通知可能来自构建/布局期间，微任务一定在
  ///   下一帧构建前运行（不会在 build/布局期间改状态），且同一批（同一次
  ///   抖动）多条通知只处理一次；
  /// - current 为 null（停止/清空）不改变动画身份（deck 仍展示上一首），
  ///   之后同一首恢复也不会重播；只有 id 真正变化才开启新会话。
  void _handlePlaybackChanged() {
    if (_trackSyncScheduled) return;
    _trackSyncScheduled = true;
    scheduleMicrotask(() {
      _trackSyncScheduled = false;
      if (!mounted) return;
      final playback = _playback;
      if (playback == null) return;
      final track = playback.snapshot.current;
      final id = trackKeyOf(track);
      if (id == null || id == _session.animatedTrackId) {
        // 同一首的重复通知只刷新对象引用（快照值变才发，代价可忽略）。
        if (track != null) _session.seenTrack = track;
        return;
      }
      setState(() {
        _handleTrackChanged(
          id: id,
          track: track!,
          oldTrack: _session.seenTrack,
          playback: playback,
        );
        _session.seenTrack = track;
      });
    });
  }

  /// 首帧 / 换 provider：以当前展示曲目为基准同步会话身份。
  ///
  /// 与旧 build 内首帧检测等价：无旧曲（`oldTrack = null`）时只播放入场
  /// 动画（方向无意义按向前），不产生「切歌」的滑出身份。
  void _syncDisplayTrack(PlaybackProvider playback) {
    final track = widget.displayTrack;
    final id = trackKeyOf(track);
    if (id == null) return;
    if (id == _session.animatedTrackId) {
      _session.seenTrack = track;
      return;
    }
    _handleTrackChanged(
      id: id,
      track: track!,
      oldTrack: _session.seenTrack,
      playback: playback,
    );
    _session.seenTrack = track;
  }

  void _onMorphChanged() {
    if (!mounted) return;
    // pageHeaderHidden 的上升沿 = 飞向播放页开始（页面淡入阶段侧边封面
    // 先藏在中心背后）；下降沿 = 中心封面飞行落位（侧边封面从背后展开）。
    // 离开播放页时该字段不变，侧边封面随整页淡出，不重复演出。
    final bool hidden = widget.morph?.pageHeaderHidden ?? false;
    if (hidden != _pageHeaderWasHidden) {
      _pageHeaderWasHidden = hidden;
      if (hidden) {
        _prevNeighborEntrance.value = 0;
        _nextNeighborEntrance.value = 0;
      } else {
        _prevNeighborEntrance.forward(from: 0);
        _nextNeighborEntrance.forward(from: 0);
      }
    }
    setState(() {});
  }

  /// 迷你 ⇄ 完整展开的状态沿：展开开始把侧边封面藏到中心背后，展开落位
  /// 再从背后展开（收起时随完整层淡出，不演出——与原播放器行为一致）。
  ///
  /// 飞行副本本身由播放器管理；这里只负责侧邻位入场。
  void _handleExpandStatus(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.forward:
        _prevNeighborEntrance.value = 0;
        _nextNeighborEntrance.value = 0;
      case AnimationStatus.completed:
        _prevNeighborEntrance.forward(from: 0);
        _nextNeighborEntrance.forward(from: 0);
      case AnimationStatus.reverse:
      case AnimationStatus.dismissed:
        break;
    }
  }

  /// 进度控制器落位（完成中 → 空闲）：即时切歌会话到此结束。
  ///
  /// 拖动提交的收尾在对账路径（[_reconcileDragCommit]）；这里只清理即时
  /// 切歌的身份，不触发重建（视觉已由控制器最后一帧画完，下一次切歌或
  /// 空闲缓存帧自然覆盖）。
  void _handleCoverStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_session.phase != CoverSwapPhase.settling) return;
    _session
      ..phase = CoverSwapPhase.idle
      ..trigger = null
      ..to = null;
  }

  @override
  void dispose() {
    _playback?.removeListener(_handlePlaybackChanged);
    widget.morph?.removeListener(_onMorphChanged);
    widget.expandAnimation?.removeStatusListener(_handleExpandStatus);
    _cancelPendingWatchdog();
    _prevNeighborEntrance.dispose();
    _nextNeighborEntrance.dispose();
    _playStateController.dispose();
    _coverController.removeStatusListener(_handleCoverStatus);
    _coverController.dispose();
    super.dispose();
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    // 提交等待 / 过渡动画 / 迷你⇄完整封面飞行期间不接受新手势：
    // 一次拖动只对应一次切歌，避免两段过渡叠加。
    if (_session.awaitingReconcile ||
        _coverController.isAnimating ||
        widget.coverFlightActive) {
      return;
    }
    _session.dragActive = true;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_session.dragActive || _dragStartX == null || _dragStartY == null) {
      return;
    }

    final dx = details.globalPosition.dx - _dragStartX!;
    final dy = details.globalPosition.dy - _dragStartY!;

    if (!_isHorizontalDragConfirmed) {
      if (dy.abs() > dx.abs() * 1.5) {
        // 纵向意图更明确：放弃本次横向拖动（展开/收起交给外层手势）。
        _resetHorizontalDrag();
        return;
      } else if (dx.abs() > 10.0) {
        _isHorizontalDragConfirmed = true;
      }
    }

    if (_isHorizontalDragConfirmed) {
      _dragDx = dx;
      _updateDragPreview(dx);
    }
  }

  /// 本次拖动方向对应的预览目标；无目标（队列到头/无可回退曲目）返回 null。
  ///
  /// 必须与实际的 `skipToNext/skipToPrevious` 同源：next 用快照解析好的
  /// 下一首（shuffle 会消费同一个随机值），previous 用播放历史、为空时
  /// 回退队列前一位（与后端 previous 的实现一致）。
  Track? _previewTargetFor(int dir, PlaybackProvider playback) {
    final snapshot = playback.snapshot;
    final Track? target;
    if (dir == 1) {
      target = snapshot.next;
    } else if (snapshot.history.isNotEmpty) {
      target = snapshot.history.last;
    } else {
      final index = snapshot.currentIndex;
      target = (index > 0 && index < snapshot.queue.length)
          ? snapshot.queue[index - 1]
          : null;
    }
    if (target == null) return null;
    // 目标就是当前曲目（如队列首的 previous）：没有可预览的切换，按边界处理。
    final current = snapshot.current;
    if (current != null && target.id == current.id) return null;
    return target;
  }

  /// 拖动跟手：中心位换预览目标封面、按滑动距离过渡（与切歌动画同一进度）。
  void _updateDragPreview(double dx) {
    final playback = context.read<PlaybackProvider>();
    final int dir = dx < 0 ? 1 : -1; // 左滑 = 下一首
    final Track? target = _previewTargetFor(dir, playback);
    final session = _session;

    if (target == null) {
      // 队列到头：硬边界，不进入预览（松手也不提交）。若已进入预览后
      // 反向拖到边界，则撤下预览回弹。
      if (session.phase == CoverSwapPhase.preview) {
        _returnCoverPreview();
      }
      return;
    }

    if (!session.previewActive) {
      session
        ..phase = CoverSwapPhase.preview
        ..trigger = CoverSwapTrigger.drag;
      _coverController.stop();
    }
    if (dir != session.direction || session.from == null) {
      session.direction = dir;
      // 拖动预览里「滑出」的是当前封面；反向侧旧邻位让位。
      session.from = session.seenTrack;
      session.oldNeighbor = dir == 1 ? session.previous : session.lastNext;
    }
    session.to = target;
    // 拖动行程：约 0.6 个封面宽度走完整段过渡。
    final double range = max(48.0, widget.artDimension * 0.6);
    final double visual = (dx.abs() / range).clamp(0.0, 1.0);
    // 反解切歌动画曲线：画面进度与手指位移一致，松手后从同一进度续播不跳。
    _coverController.value = _inverseCoverCurve(visual);
  }

  /// [Curves.easeOutCubic]（切歌动画曲线）的数值反解。
  double _inverseCoverCurve(double visual) {
    double low = 0;
    double high = 1;
    for (var i = 0; i < 12; i++) {
      final double mid = (low + high) / 2;
      if (Curves.easeOutCubic.transform(mid) < visual) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (low + high) / 2;
  }

  /// 松手：达标且有预览目标则从当前进度续播到落位并提交切歌；
  /// 未达标/边界回弹。
  void _handleHorizontalDragEnd(
      DragEndDetails details, PlaybackProvider playback) {
    // 本次手势已被忽略（提交等待期间的拖动）。
    if (!_session.dragActive) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dx = _dragDx;
    final confirmed = _isHorizontalDragConfirmed;
    final wasPreviewing = _session.previewActive;
    final previewTrack = _session.to;
    _resetHorizontalDrag();
    if (!confirmed) return;

    final threshold = widget.isLargeScreen ? 400.0 : 800.0;
    final triggerDistance = widget.isLargeScreen ? 40.0 : 80.0;
    final bool trigger =
        velocity.abs() > threshold || dx.abs() > triggerDistance;

    // 只有进入过预览（存在可切换的目标）才允许提交；边界拖动直接回弹。
    if (!wasPreviewing || previewTrack == null) {
      if (wasPreviewing) _returnCoverPreview();
      return;
    }

    if (trigger) {
      HapticFeedback.mediumImpact();
      // 进入「已提交等待对账」：预览立即走完并保持，直到曲目真正切换
      // （取链可能需要几百毫秒）——否则动画跑完会先回落成旧封面、
      // 再跳成新封面，看起来像卡住/来回闪。
      _session.phase = CoverSwapPhase.committed;
      // 从当前拖动进度继续走到落位。
      _coverController.forward();
      _startDragPendingWatchdog();
      if (dx > 0) {
        playback.skipToPrevious();
      } else {
        playback.skipToNext();
      }
    } else {
      _returnCoverPreview();
    }
  }

  void _handleHorizontalDragCancel() {
    if (!_session.dragActive) return;
    _resetHorizontalDrag();
    // 已提交的预览不因手势取消而撤下：继续等后端对账（超时有兜底）。
    if (!_session.awaitingReconcile) _returnCoverPreview();
  }

  /// 撤下拖动/提交预览并回弹到稳态（不切歌）。
  void _returnCoverPreview() {
    if (!_session.previewActive) return;
    _session
      ..phase = CoverSwapPhase.idle
      ..to = null
      ..trigger = null;
    _cancelPendingWatchdog();
    _coverController.animateBack(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// 提交切歌的兜底：等待曲目切换期间保持预览；超时（如取链失败）则回弹。
  void _startDragPendingWatchdog() {
    _cancelPendingWatchdog();
    _session.pendingTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_session.awaitingReconcile) return;
      _returnCoverPreview();
    });
  }

  /// 取消切歌提交的兜底计时器。
  void _cancelPendingWatchdog() {
    _session.pendingTimer?.cancel();
    _session.pendingTimer = null;
  }

  void _resetHorizontalDrag() {
    _session.dragActive = false;
    _dragStartX = null;
    _dragStartY = null;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
  }

  /// 缓存「变化前」的方向判定提示（空闲帧与每次切歌解析后调用）。
  ///
  /// 方向纯函数消费的是变化前的提示：变化后快照的 next/history 已经翻页，
  /// 无法代表用户实际来的方向。空闲帧缓存保证常规切歌拿到最近一次稳态
  /// 快照；切歌后立即刷新保证快速连切时下一次判定也有正确的「中间态」提示。
  void _cacheDirectionHints(PlaybackSnapshot snapshot) {
    _session
      ..prevHint = snapshot.history.isNotEmpty ? snapshot.history.last : null
      ..nextHint = snapshot.next
      ..hintIndex = snapshot.currentIndex;
  }

  /// 展示曲目发生切换：拖动提交走对账落位；其余切歌判定方向并播放入场。
  void _handleTrackChanged({
    required String id,
    required Track track,
    required Track? oldTrack,
    required PlaybackProvider playback,
  }) {
    _session.animatedTrackId = id;
    if (_session.awaitingReconcile) {
      _reconcileDragCommit(id: id, playback: playback);
      return;
    }

    // 方向判定：用「变化前」缓存的提示 + 新快照信息调纯函数（规则与优先级
    // 见 player_cover_swap.dart）。据此，队列点选/跳转也能得到真实方向，
    // 不再一律按向前处理。
    final snapshot = playback.snapshot;
    final int direction = resolveCoverSwapDirection(
      from: oldTrack,
      to: track,
      prevHint: _session.prevHint,
      nextHint: _session.nextHint,
      queue: snapshot.queue,
      oldIndex: _session.hintIndex,
      newIndex: snapshot.currentIndex,
      shuffle: snapshot.mode == PlayMode.shuffle,
    );
    final session = _session;
    // 拖动预览进行中时，阶段与预览目标归拖动会话（切歌只更新身份供拖动
    // 继续驱动）；其余情况进入即时切歌的「完成中」。
    if (!session.previewActive) {
      session
        ..phase = CoverSwapPhase.settling
        ..trigger = CoverSwapTrigger.immediate
        ..to = track;
    }
    session.direction = direction == coverSwapBackward ? -1 : 1;
    session.oldNeighbor = direction == coverSwapBackward
        ? session.lastNext
        : session.previous;
    // 新快照即下一次切歌的「变化前」基准（快速连切时动画中不会有空闲帧）。
    _cacheDirectionHints(snapshot);
    // 播放顺序由播放快照维护（后端记录实际播放顺序）：
    // 最新一首即「上一首」，回退时后端已弹出，这里自然指向更早一首。
    session
      ..previous = snapshot.history.isNotEmpty ? snapshot.history.last : null
      ..from = oldTrack
      // 旧封面作为切歌动画中未加载完成时的占位，避免黑块闪一下。
      ..placeholderUrl = artworkUrlOf(oldTrack) ?? session.placeholderUrl;
    _cancelPendingWatchdog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_session.dragActive) {
        // 用户正在拖动：预览交给新拖动继续驱动，不接管动画；
        // 标题入场也让位（此时只有进度预览需要清理）。
        widget.onTrackSwapped?.call(true);
        if (_coverController.isAnimating) _coverController.stop();
        return;
      }
      widget.onTrackSwapped?.call(false);
      if (_coverController.isAnimating) {
        // 拖动续播 / 快速连切：从当前进度接着走，不回到起点重放。
        _coverController.forward();
      } else {
        _coverController.forward(from: 0);
      }
    });
  }

  /// 拖动提交后的对账落位。
  ///
  /// 不管到位的是不是当初预览的那首（队列变化、随机目标、失败恢复），都在
  /// 这一帧落位到实际 current，绝不让预览态悬空（否则只能等 6s 兜底超时）。
  ///
  /// #6（对账校正淡化）挂点：此处可用 [CoverSwapSession.to]（提交时固定
  /// 的预览目标）与 [id]（到位曲目）比较；不匹配时进入
  /// [CoverSwapPhase.correcting]，从当前进度续播 220ms 校正淡化。本票两条
  /// 路径保持一致：直接按实际 current 落位。
  void _reconcileDragCommit({
    required String id,
    required PlaybackProvider playback,
  }) {
    final session = _session;
    final history = playback.snapshot.history;
    _cancelPendingWatchdog();
    session
      ..phase = CoverSwapPhase.idle
      ..to = null
      ..trigger = null
      ..previous = history.isNotEmpty ? history.last : null;
    // 对账后新快照即下一次切歌的「变化前」基准。
    _cacheDirectionHints(playback.snapshot);
    // 拖动时无法预知「新的再下一首/再上一首」身份（只有一位前瞻），
    // 落位时让它从中心封面背后补一个入场，而不是直接出现在槽位。
    // 先同步置 0：避免这一帧先以稳态画出来再回跳（闪一下）。
    final bool toNext = session.direction == 1;
    if (toNext) {
      _nextNeighborEntrance.value = 0;
    } else {
      _prevNeighborEntrance.value = 0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      // 过渡已在提交时走完：画面即最终态，直接落位；若还在走（快速
      // 对账），保持它继续（center 已是 displayTrack，位置连续）。
      if (!_coverController.isAnimating) {
        _coverController.value = 1.0;
      }
      if (toNext) {
        _nextNeighborEntrance.forward(from: 0);
      } else {
        _prevNeighborEntrance.forward(from: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();

    // 切歌检测已移到播放快照监听（[_handlePlaybackChanged] / [_syncDisplayTrack]），
    // build 期间不再做切歌判定，只刷新空闲缓存：下一首身份与方向判定提示
    // 必须在与旧实现相同的帧上刷新，否则快速连切的方向基准会漂移。
    if (!_coverController.isAnimating && !_session.previewActive) {
      _session
        ..lastNext = playback.snapshot.next
        // 空闲帧清空滑出身份：动画已落位，陈旧封面不能复活（旧实现同语义）。
        ..from = null;
      _cacheDirectionHints(playback.snapshot);
    }

    return _buildArtworkStack(context, playback);
  }

  /// 三封面堆叠：左=上一首、中=当前、右=下一首（左右压住露出边缘）。
  ///
  /// 切歌动画与「拖动跟手」共用同一条进度（[`_coverController`]）：横向拖动
  /// 时中心位由预览目标封面顶上、按滑动距离过渡；松手后从同一进度续播或回弹。
  /// 无上一首/下一首时对应槽位为空（不闪、不空跳）。
  ///
  /// 横向手势宿主固定在 [AnimatedBuilder] 外层：拖动期间中心卡会因
  /// `interactive` 换型重建，手势挂在卡上会被 dispose（表现为滑到一半冻住、
  /// 松手无反应）。宿主 element 稳定，控制器逐帧重建只影响子树。
  Widget _buildArtworkStack(
    BuildContext context,
    PlaybackProvider playbackProvider,
  ) {
    final String? currentImageUrl = artworkUrlOf(widget.displayTrack);
    return Listener(
      // DragGestureRecognizer 对「已接受」手势的 PointerCancel 也走 onEnd
      // （不是 onCancel），而 Listener 先于识别器收到取消事件：这里直接
      // 按取消处理并复位，随后识别器的 onEnd 因 dragActive=false 被忽略，
      // 避免系统打断被当成松手提交切歌。
      onPointerCancel: (_) => _handleHorizontalDragCancel(),
      child: GestureDetector(
        key: PlayerCoverDeck.swipeHostKey,
        behavior: HitTestBehavior.opaque,
        // 从手指真实按下位置起算位移：默认的 start 会吃掉 touch slop，
        // 拖动距离与阈值判断都会缩小（110px 的滑动会被量成 80px）。
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _handleHorizontalDragStart,
        onHorizontalDragUpdate: _handleHorizontalDragUpdate,
        onHorizontalDragEnd: (details) =>
            _handleHorizontalDragEnd(details, playbackProvider),
        onHorizontalDragCancel: _handleHorizontalDragCancel,
        child: Center(
          child: SizedBox(
            width: widget.stackDimension,
            height: widget.stackHeight,
            child: AnimatedBuilder(
              animation: _coverStackAnimation,
              builder: (context, _) {
                // 拖动预览与切歌动画共用渲染：拖动时进度由手指驱动。
                final session = _session;
                final dragging = session.previewActive;
                final animating = dragging || _coverController.isAnimating;
                final t = Curves.easeOutCubic.transform(_coverController.value);
                final dir = session.direction;
                final double sideSize = widget.artDimension * 0.78;
                final double offset = widget.artDimension * 0.30;
                const double sideRotation = 0.05;

                final children = <Widget>[];

                // 旧邻位淡出（方向切换时另一侧让位）。
                if (animating && session.oldNeighbor != null) {
                  children.add(_sideCoverLayer(
                    context,
                    session.oldNeighbor,
                    sideSize: sideSize,
                    x: -offset * dir,
                    rotation: -sideRotation * dir,
                    opacity: (1 - t) * 0.85,
                  ));
                }

                if (animating) {
                  // 源侧新邻位浮现（下一首时在右，上一首时在左）。
                  // 拖动预览阶段不预取「再下一首」（UI 只有一位前瞻），留空槽。
                  if (!dragging) {
                    final nextItem = playbackProvider.snapshot.next;
                    final sourceTrack = dir == 1 ? nextItem : session.previous;
                    children.add(_sideCoverLayer(
                      context,
                      sourceTrack,
                      sideSize: sideSize,
                      x: offset * dir + (1 - t) * offset * 0.3 * dir,
                      rotation: sideRotation * dir * (0.4 + 0.6 * t),
                      opacity: t * 0.85,
                      placeholderUrl: currentImageUrl,
                      // 落位补入场时也作用于这条「源侧浮现」，避免切换
                      // 与入场叠加时位置/透明度跳变。
                      entrance: dir == 1
                          ? _nextNeighborEntrance.value
                          : _prevNeighborEntrance.value,
                    ));
                  }
                  // 滑出的旧当前 → 目标邻位。
                  if (session.from != null) {
                    children.add(_mainCoverLayer(
                      context,
                      session.from,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      x: -offset * dir * t,
                      rotation: -sideRotation * dir * t,
                      scale: 1.0 - 0.22 * t,
                      opacity: 1.0 - 0.15 * t,
                      interactive: false,
                    ));
                  }
                } else {
                  // 稳态邻位：可点击切歌（左=上一首，右=下一首）。
                  children.add(_sideCoverLayer(
                    context,
                    session.previous,
                    sideSize: sideSize,
                    x: -offset,
                    rotation: -sideRotation,
                    opacity: 0.85,
                    placeholderUrl: currentImageUrl,
                    entrance: _prevNeighborEntrance.value,
                    onTap: playbackProvider.hasTrack
                        ? playbackProvider.skipToPrevious
                        : null,
                  ));
                  children.add(_sideCoverLayer(
                    context,
                    playbackProvider.snapshot.next,
                    sideSize: sideSize,
                    x: offset,
                    rotation: sideRotation,
                    opacity: 0.85,
                    placeholderUrl: currentImageUrl,
                    entrance: _nextNeighborEntrance.value,
                    onTap: playbackProvider.hasTrack
                        ? playbackProvider.skipToNext
                        : null,
                  ));
                }

                // 中心位：拖动/提交时由预览目标封面顶上（真正的切歌在松手后
                // 才发生）；动画/稳态下就是当前曲目。顶栏⇄播放页飞行时只隐藏
                // 这一张。预览目标在拖动开始时固定，不重读快照（否则提交后
                // 快照先推新邻位，中心封面会闪成再下一首）。
                final Track? centerTrack = dragging
                    ? (session.to ?? widget.displayTrack)
                    : widget.displayTrack;
                children.add(_mainCoverLayer(
                  context,
                  centerTrack,
                  playbackProvider,
                  artDimension: widget.artDimension,
                  slotKey: PlayerCoverDeck.centerCoverCardKey,
                  x: animating ? dir * offset * (1 - t) : 0,
                  rotation: animating ? sideRotation * dir * (1 - t) : 0,
                  scale: animating ? 0.78 + 0.22 * t : 1.0,
                  opacity: 1,
                  interactive: !dragging,
                  coverKey: widget.morph?.pageCoverKey,
                  hidden: widget.morph?.pageHeaderHidden ?? false,
                  placeholderUrl:
                      dragging ? currentImageUrl : session.placeholderUrl,
                ));

                return Stack(clipBehavior: Clip.none, children: children);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 邻位封面（压在当前封面之下；[onTap] 非空时可点击切歌）。
  ///
  /// [entrance] 是侧边入场进度（0 = 藏在中心封面背后：透明、内收、放平；
  /// 1 = 稳态）。只改透明度/位移/旋转/缩放，不参与 hit test（<0.5 忽略）。
  Widget _sideCoverLayer(
    BuildContext context,
    Track? track, {
    required double sideSize,
    required double x,
    required double rotation,
    required double opacity,
    String? placeholderUrl,
    VoidCallback? onTap,
    double entrance = 1.0,
  }) {
    if (track == null) return const SizedBox.shrink();
    // 传入的是入场控制器原始进度，这里统一套 easeOutCubic（先快后缓的展开感）。
    final double e =
        Curves.easeOutCubic.transform(entrance.clamp(0.0, 1.0));
    // 从中心背后滑出：起点更靠中间、更平、略小，终点即稳态。
    final double entranceX = x * (0.55 + 0.45 * e);
    final double entranceRotation = rotation * (0.3 + 0.7 * e);
    final double entranceOpacity = opacity * e;
    final double entranceScale = 0.92 + 0.08 * e;
    Widget card =
        _buildCoverCard(context, track, sideSize, placeholderUrl: placeholderUrl);
    if (onTap != null) {
      card = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: card,
      );
    }
    return Positioned.fill(
      child: Center(
        child: Transform.translate(
          offset: Offset(entranceX, 0),
          child: Transform.rotate(
            angle: entranceRotation,
            child: Opacity(
              opacity: entranceOpacity,
              child: IgnorePointer(
                ignoring: onTap == null || e < 0.5,
                child: Transform.scale(scale: entranceScale, child: card),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前/滑出封面（可交互时保留滑动手势与点击播放/暂停）。
  Widget _mainCoverLayer(
    BuildContext context,
    Track? track,
    PlaybackProvider playbackProvider, {
    required double artDimension,
    required double x,
    required double rotation,
    required double scale,
    required double opacity,
    required bool interactive,
    Key? slotKey,
    Key? coverKey,
    bool hidden = false,
    String? placeholderUrl,
  }) {
    Widget card = interactive
        ? _buildConfigurableMainContent(
            context,
            track,
            playbackProvider,
            artDimension: artDimension,
            coverKey: coverKey,
            hidden: hidden,
            placeholderUrl: placeholderUrl,
          )
        : _buildCoverCard(context, track, artDimension,
            placeholderUrl: placeholderUrl);
    if (slotKey != null) {
      card = KeyedSubtree(key: slotKey, child: card);
    }
    return Positioned.fill(
      child: Center(
        child: Transform.translate(
          offset: Offset(x, 0),
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              child: Opacity(opacity: opacity, child: card),
            ),
          ),
        ),
      ),
    );
  }

  /// 封面卡（三封面/飞行副本共用同一渲染与缓存键）：
  /// 细描边 + 柔和阴影 + 圆角图。
  ///
  /// 统一走无缩放缓存键（与顶栏/迷你条/预加载一致），邻位封面升到中间
  /// 只是 transform 插值，不再因缓存键不同重新解码、闪占位图。
  Widget _buildCoverCard(
    BuildContext context,
    Track? track,
    double size, {
    double radius = 18,
    Widget? fallback,
    String? placeholderUrl,
  }) {
    final url = artworkUrlOf(track);
    final scheme = Theme.of(context).colorScheme;
    final placeholder = placeholderUrl != null && placeholderUrl != url
        ? AppNetworkImage(
            url: placeholderUrl,
            fit: BoxFit.cover,
            fallbackIconSize: size * 0.35,
          )
        : fallback;
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: scheme.outlineVariant, width: 1),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: AppNetworkImage(
            url: url,
            fit: BoxFit.cover,
            fallbackIconSize: size * 0.35,
            placeholder: placeholder,
            errorWidget: fallback,
          ),
        ),
      ),
    );
  }

  Widget _buildConfigurableMainContent(
    BuildContext context,
    Track? track,
    PlaybackProvider playback, {
    required double artDimension,
    Key? coverKey,
    bool hidden = false,
    String? placeholderUrl,
  }) {
    if (context.select<PlaybackProvider, bool>((p) => p.isPlaying)) {
      _playStateController.forward();
    } else {
      _playStateController.reverse();
    }

    return AnimatedBuilder(
      // 播放态只用极轻微的缩放：暂停时封面保持清晰（不再变暗 20%，
      // 那会让封面看起来像被禁用，反而不优雅）。
      animation: _playStateController,
      builder: (context, child) {
        return Transform.scale(
          scale: _playStateScaleAnimation.value,
          child: child,
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 点击封面 = 播放/暂停；横向拖动由封面区手势宿主统一承接
        // （见 [_buildArtworkStack]：手势不能在拖动期间换型重建）。
        onTap: () {
          HapticFeedback.lightImpact();
          playback.togglePlayPause();
        },
        child: RepaintBoundary(
          child: KeyedSubtree(
            key: coverKey,
            child: KeyedSubtree(
              key: widget.fullCoverKey,
              child: AnimatedOpacity(
                // 隐藏用淡出（飞行起点在别处，淡出自然）；亮出必须瞬时——
                // 飞行副本与真身在同一帧交接，淡入会造成尾段亮度下陷（闪动）。
                duration: (hidden || widget.coverFlightActive)
                    ? const Duration(milliseconds: 160)
                    : Duration.zero,
                // 顶栏⇄播放页飞行 / 迷你⇄完整飞行期间真身隐藏，
                // 由飞行副本承接（其余元素不参与共享飞行）。
                opacity: (hidden || widget.coverFlightActive) ? 0 : 1,
                child: _buildCoverCard(
                  context,
                  track,
                  artDimension,
                  fallback: buildDefaultArtwork(context),
                  placeholderUrl: placeholderUrl,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
