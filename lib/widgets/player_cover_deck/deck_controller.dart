/// 封面堆叠控制器：切歌会话、七根动画控制器与全部视觉状态。
///
/// 与 vsync / 动画强耦合，因此留在 widget 层（`lib/widgets/player_cover_deck/`），
/// 不进 providers。入口组件只负责订阅播放 / 封面变化并把生命周期转进来；
/// 拖拽、settle、连切接管、兜底超时与空闲淡化时机都在这里。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../../services/haptics.dart';
import '../cover_handoff.dart';
import '../player_cover_session.dart';
import 'deck_handoff_tracker.dart';
import 'deck_models.dart';
import 'deck_visual_state.dart';

/// 封面堆叠的动画 / 状态机控制器。
///
/// 持有唯一一根进度控制器、七根动画控制器、连切接管快照与全部手势跟踪；
/// 通过 [artworkFrame] 把一帧视觉交给渲染层，通过 [onVisualsChanged] 通知
/// 入口组件走 `setState`（离散的身份 / 换图变化，与原实现一致）。
class DeckController implements CoverSwapHost {
  DeckController({
    required TickerProvider vsync,
    required this.realCoverUrlOf,
    required this.snapshotOf,
    required this.displayTrackOf,
    required this.artDimensionOf,
    required this.isLargeScreenOf,
    required this.isPlayingOf,
    required this.isMounted,
    required this.gesturesBlockedOf,
    required this.onTrackSwapped,
    required this.onSkipRequested,
    required this.onVisualsChanged,
    required Track? initialDisplayTrack,
  }) {
    _session = CoverSwapSession(host: this);
    _playStateController = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialDefault(
        snapToEnd: true,
      ),
      vsync: vsync,
      initialValue: 0,
    );
    _playStateScaleAnimation = Tween<double>(
      begin: 0.98,
      end: 1.0,
    ).animate(_playStateController);

    _coverController = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialDefault(
        snapToEnd: true,
      ),
      vsync: vsync,
      initialValue: 0,
    )..value = 1.0;

    _sourceNeighborFade = AnimationController(
      duration: _reconcileFadeDuration,
      vsync: vsync,
      value: 1.0,
    );
    _reconcileCorrection = AnimationController(
      duration: _reconcileCorrectionDuration,
      vsync: vsync,
      value: 1.0,
    );
    _slotIdentityFade = AnimationController(
      duration: _slotIdentityFadeDuration,
      vsync: vsync,
      value: 1.0,
    );
    _artworkRefreshFade = AnimationController(
      duration: _artworkRefreshFadeDuration,
      vsync: vsync,
      value: 1.0,
    );
    _pressController = SingleMotionController(
      motion: SpringMotion(
        M3EMotion.expressiveSpatialPress.toDescription(),
        snapToEnd: true,
      ),
      vsync: vsync,
      initialValue: 0,
    );
    _centerScaleAnimation = Listenable.merge([
      _playStateController,
      _pressController,
    ]);
    _visuals = DeckVisualState(
      slotIdentityFade: _slotIdentityFade,
      artworkRefreshFade: _artworkRefreshFade,
      realCoverUrlOf: realCoverUrlOf,
      onVisualsChanged: onVisualsChanged,
      initialDisplayTrack: initialDisplayTrack,
    );
    _coverStackAnimation = Listenable.merge([
      _session.changes,
      _coverController,
      _sourceNeighborFade,
      _reconcileCorrection,
      _visuals.animation,
      _pressController,
    ]);
    // 即时切歌落位即会话结束（完成中 → 空闲）；拖动提交由对账路径收尾。
    _coverController.addStatusListener(_handleCoverStatus);
    _reconcileCorrection.addStatusListener(_handleCorrectionStatus);
    _pressController.addStatusListener(_handlePressStatus);
  }

  /// 真实封面 URL（自定义 / 原始；默认封面只做展示兜底）。
  final String? Function(Track?) realCoverUrlOf;

  /// 当前播放快照（未绑定时 null）。
  final PlaybackSnapshot? Function() snapshotOf;

  /// 父级当前展示曲目（隐藏态切歌直接接管它）。
  final Track? Function() displayTrackOf;

  final double Function() artDimensionOf;
  final bool Function() isLargeScreenOf;
  final bool Function() isPlayingOf;
  final bool Function() isMounted;

  /// 飞行 / 封面飞行进行中：不接受新手势。
  final bool Function() gesturesBlockedOf;

  final void Function(bool duringDrag)? onTrackSwapped;
  final void Function(int direction) onSkipRequested;

  /// 离散视觉变化（中心换图 / 槽位身份淡换撤销 / 校正结束）：入口组件 setState。
  final VoidCallback onVisualsChanged;

  /// 拖动对账落位后源侧新身份的纯透明度淡入时长。
  static const Duration _reconcileFadeDuration = Duration(milliseconds: 180);

  /// 对账校正时长：到位曲目与预览目标不一致时，中心封面原位交叉淡化校正。
  static const Duration _reconcileCorrectionDuration = Duration(
    milliseconds: 220,
  );

  /// 空闲期槽位身份交叉淡化时长（原位、纯透明度）。
  static const Duration _slotIdentityFadeDuration = Duration(milliseconds: 180);

  /// 中心封面同 id 换图（音源补图）交叉淡化时长。
  static const Duration _artworkRefreshFadeDuration = Duration(
    milliseconds: 250,
  );

  /// 封面按压反馈：按下缩放比例；进/出走 M3E 按压弹簧（见控制器注释）。
  static const double _pressScale = 0.96;

  /// 拖动方向反转的判定阈值（进度域）：超过它才把手势视为回拖。
  ///
  /// 只做「当前封面置顶」的层级切换，不改身份；阈值用来吃掉手指抖动，
  /// 同时按累计位移判定，慢速回拖也能在约 1% 行程内切过来。
  static const double _reverseHandoffProgress = 0.01;

  /// 连切接管的进度上限。
  ///
  /// 弹簧接近落位时中心卡已贴住中心，继续沿用 q 插值会让滑出卡在极短
  /// 剩余行程里扫过整侧槽（超高速滑行）；此时改成「上一段落位、新一段
  /// 从起点重播」的兜底。
  static const double _takeoverMaxProgress = 0.75;

  double? _dragStartX;
  double? _dragStartY;
  bool _isHorizontalDragConfirmed = false;
  double _dragDx = 0;

  /// 本次拖动最近一次方向切换时的进度锚点（回拖层级判定用）。
  double _previewTrendAnchor = 0;

  /// 拖动回拖/松手回弹时，正在回位的当前封面是否压在上层。
  ///
  /// 正向拖动与落位时目标封面在上；回拖时如果仍让中心预览目标压着当前
  /// 封面，视觉上就像下一首盖住了正在回来的当前封面。
  bool _outgoingCoverOnTop = false;

  /// 连切接管快照与更早滑出卡（tail）。
  final DeckHandoffTracker _handoffs = DeckHandoffTracker();

  /// 正在把进度重置到 0（restart / 兜底）。controller 的 value setter 会按
  /// 旧 target 合成 completed 状态，不能让它误触发会话落位并清掉刚捕获的
  /// handoff 快照。
  bool _resettingCoverProgress = false;

  /// 切歌会话状态机：拖动预览、提交等待、对账、兜底与方向提示的唯一持有者。
  late final CoverSwapSession _session;

  /// 提交兜底计时器（会话经 [armTimeout] 武装、[disarmTimeout] 取消）。
  Timer? _pendingTimer;

  /// 唯一一根进度控制器：拖动跟手与切歌动画共用（不允许第二条视觉进度）。
  ///
  /// motor expressive spatial 弹簧（380/0.8）：拖动直接写进度（画面 = 手指
  /// 位移），松手由弹簧带速度续跑；透明度窗口从进度派生并截断 0..1
  /// （M3E 规范：effects 不过冲）。
  late SingleMotionController _coverController;

  /// 拖动对账落位后源侧新身份的纯透明度淡入；只在 idle 稳态渲染里作用于
  /// 会话方向的源侧槽位。
  ///
  /// 预览窗口已经渲染同一身份时从当前透明度接管（p=1 直接满值），只有身份
  /// 不一致 / 不可预测时才从 0 重放 180ms。
  late AnimationController _sourceNeighborFade;

  /// 对账校正控制器：0→1 期间中心旧预览卡淡出、实际曲目卡淡入（原位无位移）。
  late AnimationController _reconcileCorrection;

  /// 空闲槽位身份交叉淡化控制器：1 = 稳态；身份变化时 0 → 1。
  late AnimationController _slotIdentityFade;

  /// 中心封面换图控制器：1 = 稳态；同 id、URL 更新时 0 → 1。
  late AnimationController _artworkRefreshFade;

  /// 封面堆叠重绘源：切歌过渡 + 对账后的源侧淡入 + 校正/槽位淡换/换图。
  late final Listenable _coverStackAnimation;

  /// 空闲视觉（中心换图 / 槽位身份淡化）与身份跟踪。
  late final DeckVisualState _visuals;

  /// 播放态中心封面轻微缩放（暂停时保持清晰，不做变暗）。
  /// motor expressive spatial 弹簧，暂停/播放来回切换带速度续跑。
  late SingleMotionController _playStateController;
  late Animation<double> _playStateScaleAnimation;

  /// 按压反馈控制器：0 = 未按、1 = 按到底（缩放 [_pressScale]）。
  ///
  /// M3E 按压弹簧（`M3EMotion.expressiveSpatialPress` 380/0.55）：按下即时、
  /// 抬起带轻微回弹。
  late SingleMotionController _pressController;

  /// 当前被按压的槽位；抬起回弹结束（[AnimationStatus.dismissed]）后清空。
  DeckSlot? _pressedSlot;

  /// 中心封面缩放重绘源：播放态缩放 × 按压反馈。
  late final Listenable _centerScaleAnimation;

  CoverSwapSession get session => _session;
  Listenable get stackAnimation => _coverStackAnimation;
  Listenable get centerScaleAnimation => _centerScaleAnimation;
  Animation<double> get playStateScaleAnimation => _playStateScaleAnimation;

  /// 拖动对账落位等需要读取的当前进度。
  double get progress => _coverController.value;

  /// 提交 / 切歌 / 回弹动画是否仍在跑（空闲淡化的门控）。
  bool get coverAnimating => _coverController.isAnimating;

  /// 绑定时建立/校正会话身份并同步播放态缩放。
  void attachPlayback({
    required PlaybackSnapshot snapshot,
    required Track? displayTrack,
  }) {
    // 首帧（或换 provider）：以 deck 实际展示的曲目建立/校正会话身份，
    // 并同步一次播放态缩放初始值。挂载时快照已有当前曲目（冷启动恢复 /
    // 系统媒体恢复）按稳态接管，不把「本来就在展示的曲目」当成切歌入场。
    _session.adoptInitial(snapshot);
    _session.observe(snapshot: snapshot, displayTrack: displayTrack);
    // 渲染起点就是当前身份：槽位跟踪对齐，不补身份淡换。
    adoptSteadySlots();
    _syncPlayState(isPlayingOf());
  }

  /// 播放快照通知（微任务里调用）：切歌检测 + 空闲视觉刷新。
  void ingestPlayback({
    required PlaybackSnapshot snapshot,
    required Track? displayTrack,
    required bool isPlaying,
  }) {
    _syncPlayState(isPlaying);
    final bool trackChanged = _session.observe(
      snapshot: snapshot,
      displayTrack: displayTrack,
    );
    // 切歌（身份/动画/对账）由会话接管；同 id 的重复通知才刷新空闲视觉。
    if (!trackChanged) {
      _visuals.refreshIdleVisuals(
        snapshot,
        previous: _session.state.previous,
        animatedTrackId: _session.state.animatedTrackId,
        sessionVisible: _session.state.visible,
        sessionIdle: _session.state.phase == CoverSwapPhase.idle,
        progressAnimating: _coverController.isAnimating,
      );
    }
  }

  /// 页面可见性（TickerMode）变化 → 会话立即落位。
  void setVisible(bool value) => _session.setVisible(value);

  /// 中心封面同 id、封面 URL 变化（音源补图）：以约 250ms 交叉淡化换图。
  void syncCenterArtwork(Track? track) =>
      _visuals.syncCenterArtwork(track, visible: _session.state.visible);

  /// 播放态中心封面缩放同步：播放 → 1.0、暂停 → 0.98。
  void _syncPlayState(bool playing) {
    if (!_session.state.visible) {
      // 不可见：直接落位（ticker 被静音，启动动画会冻结、回来再播）。
      _playStateController.value = playing ? 1.0 : 0.0;
      return;
    }
    _playStateController.animateTo(playing ? 1.0 : 0.0);
  }

  // CoverSwapHost：会话的效果宿主
  //
  // 会话决定「什么时候」，这里决定「怎么做」：控制器编排、post-frame 调度、
  // 播放命令与父级联动都在这一侧；排序不变量（例如「settling 前先把进度钉回
  // 起点」）由会话的调用顺序 + 本侧实现共同持有。

  @override
  bool get progressAnimating => _coverController.isAnimating;

  @override
  void previewProgress(double progress) {
    // 手指接管进度：弹停在播的弹簧后直接写值（画面 = 手指位移）。
    if (_coverController.isAnimating) _coverController.stop(canceled: true);
    // 回拖层级：按「自上次切向以来的累计位移」判定，慢速回拖也能生效，
    // 同时避免单帧抖动来回换层。
    final double trend = progress - _previewTrendAnchor;
    if (trend > _reverseHandoffProgress) {
      _outgoingCoverOnTop = false;
      _previewTrendAnchor = progress;
    } else if (trend < -_reverseHandoffProgress) {
      _outgoingCoverOnTop = true;
      _previewTrendAnchor = progress;
    }
    _coverController.value = progress;
  }

  @override
  void land({required double progressVelocity}) {
    HapticsService.mediumImpact();
    // 提交落位：目标封面重新回到上层（与稳态一致）。
    _outgoingCoverOnTop = false;
    // 从当前拖动进度继续走到落位；带上手势速度（进度域，画面 = |dx| / range）。
    _coverController.animateTo(1, withVelocity: progressVelocity);
  }

  @override
  void releasePreview({double progressVelocity = 0}) {
    // 松手回弹：当前封面从下面回到中心，必须压在回退中的目标封面之上。
    _outgoingCoverOnTop = true;
    if (!_session.state.visible) {
      // 不可见：直接回位（ticker 被静音，弹簧会冻结在半途）。
      _coverController.value = 0;
      _session.returnCompleted();
      return;
    }
    // 回退期间保留预览目标身份（见 CoverSwapPhase.returning）：等弹簧自然
    // 走完再撤下预览视觉。只认 ticker 的自然完成——被新拖动/切歌取消时
    // `then` 不会触发；也不能监听 dismissed：直接写 value 也会发该状态。
    unawaited(
      _coverController.animateTo(0, withVelocity: progressVelocity).then((_) {
        if (!isMounted()) return;
        _session.returnCompleted();
      }),
    );
  }

  @override
  void startSettle({required int direction, required Track nextTrack}) {
    // 即时切歌/快速连切：目标始终在上层。
    _outgoingCoverOnTop = false;
    // 上一个会话可能停在（或正在）校正：新切歌直接接管，停掉校正控制器。
    if (_reconcileCorrection.isAnimating) _reconcileCorrection.stop();
    final bool midFlight = _coverSwapMidFlight;
    final double p0 = _coverController.value.clamp(0.0, 1.0);
    // 次序不变量：这里必须读「本次迁移前」的会话身份（旧中心 / 旧滑出）。
    // 会话在 startSettle 返回后才改写 _to/_from/phase，捕获逻辑依赖该顺序，
    // 不要在调用前重置会话或移动这段读取。
    final Track? previousCenter = _session.state.to;
    final Track? previousOutgoing = _session.state.from;
    final bool targetIsOldOutgoing =
        previousOutgoing != null &&
        trackKeyOf(nextTrack) == trackKeyOf(previousOutgoing);
    // 续走快路径：同一方向、未接近落位，且新中心不是上一段滑出卡（否则
    // 新中心必须从 A 的捕获视觉起，不能再用全局 p 的中途位置）。
    final bool canContinue =
        midFlight &&
        _session.state.phase == CoverSwapPhase.settling &&
        direction == _session.state.direction &&
        p0 < _takeoverMaxProgress &&
        previousCenter != null &&
        !targetIsOldOutgoing;
    // restart 接管：方向反转 / 接近落位 / 目标是上一段滑出卡。新弹簧从
    // p=0 起跑，但两端起点视觉来自接管瞬间，不再「落位后重播」。
    final bool canRestart =
        midFlight &&
        _session.state.phase == CoverSwapPhase.settling &&
        previousCenter != null &&
        !canContinue;
    if (canContinue) {
      _handoffs.captureContinuous(
        progress: p0,
        direction: direction,
        sessionDirection: _session.state.direction,
        centerTrack: previousCenter,
        oldOutgoing: previousOutgoing,
        nextTrack: nextTrack,
        sideOffset: _sideOffset,
      );
    } else if (canRestart) {
      _handoffs.captureRestart(
        progress: p0,
        direction: direction,
        oldDirection: _session.state.direction,
        centerTrack: previousCenter,
        oldOutgoing: previousOutgoing,
        nextTrack: nextTrack,
        sideOffset: _sideOffset,
      );
      _resetCoverProgress();
    } else {
      // 非弹簧途中（或会话不可接管）：保持原有安全兜底。
      _handoffs.clear();
      _resetCoverProgress();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      onTrackSwapped?.call(false);
      if (canContinue) {
        // 从当前进度接着走：新会话的 q 把接管起点映射到剩余行程。
        _coverController.animateTo(1);
      } else {
        _coverController.animateTo(1, from: 0, withVelocity: 0);
      }
    });
  }

  /// 侧槽相对中心的横向偏移（占主封面边长的比例）。
  double get _sideOffset => artDimensionOf() * coverHandoffSideOffsetFactor;

  /// 把进度重置到 0；屏蔽控制器因旧 target 合成的 completed 状态。
  void _resetCoverProgress() {
    _resettingCoverProgress = true;
    try {
      _coverController.stop(canceled: true);
      _coverController.value = 0;
    } finally {
      _resettingCoverProgress = false;
    }
  }

  @override
  void settleDuringDrag() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      // 用户正在拖动预览：动画不接管，由手指继续驱动（标题入场也让位）。
      onTrackSwapped?.call(true);
      if (_coverController.isAnimating) {
        _coverController.stop(canceled: true);
      }
    });
  }

  @override
  void settleCommit() {
    _outgoingCoverOnTop = false;
    // 预览期间源侧新身份已经渲染（再下一首 / 再上一首）。对账后若实际源侧
    // 就是同一身份，直接从预览透明度接管，不再重放 180ms 淡入；身份不一致
    // 或不可预测（随机轮末等）时保留原有淡入兜底。
    final snapshot = snapshotOf();
    final previewNeighbor = _session.state.previewSourceNeighbor;
    final actualSource = snapshot == null
        ? null
        : (_session.state.direction == 1 ? snapshot.next : snapshot.previous);
    final bool continuous =
        previewNeighbor != null &&
        actualSource != null &&
        previewNeighbor.id == actualSource.id;
    final double start = continuous
        ? coverSourceFadeStartFor(
            coverSourceNewNeighborOpacityAt(
              _coverController.value.clamp(0.0, 1.0),
            ),
          )
        : 0.0;
    _sourceNeighborFade.value = start;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      onTrackSwapped?.call(false);
      // 过渡已在提交时走完：画面即最终态，直接落位；若还在换场中段
      // （快速对账），保持它继续（center 已是 displayTrack，位置连续）。
      if (!_coverSwapMidFlight) _coverController.value = 1.0;
      if (start < 1) _sourceNeighborFade.forward(from: start);
    });
  }

  @override
  void crossfadeCorrection() {
    _outgoingCoverOnTop = false;
    _reconcileCorrection.value = 0;
    _sourceNeighborFade.value = 0;
    _reconcileCorrection.forward();
    _sourceNeighborFade.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      onTrackSwapped?.call(false);
      if (!_coverSwapMidFlight) _coverController.value = 1.0;
    });
  }

  @override
  void adoptSteadySlots() {
    final snapshot = snapshotOf();
    if (snapshot == null) return;
    _visuals.adoptSteadySlots(
      previous: _session.state.previous,
      next: snapshot.next,
    );
  }

  @override
  void hardReset({Track? adoptTrack}) {
    disarmTimeout();
    _coverController.stop(canceled: true);
    _coverController.value = 1.0;
    _sourceNeighborFade.value = 1.0;
    _reconcileCorrection.value = 1.0;
    _pressController.stop();
    _pressController.value = 0;
    _pressedSlot = null;
    _outgoingCoverOnTop = false;
    _previewTrendAnchor = 0;
    _handoffs.clear();
    _resetDragTracking();
    // 隐藏态切歌：父级还没按新曲目重建，中心身份直接接管传入曲目。
    _visuals.hardReset(adoptTrack ?? displayTrackOf());
    _syncPlayState(isPlayingOf());
  }

  @override
  void requestSkip(int direction) => onSkipRequested(direction);

  @override
  void notifySwapped(bool duringDrag) => onTrackSwapped?.call(duringDrag);

  @override
  void armTimeout(Duration duration) {
    disarmTimeout();
    _pendingTimer = Timer(duration, () {
      if (!isMounted()) return;
      _session.timeoutFired();
    });
  }

  @override
  void disarmTimeout() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  /// 按压反馈开始（原始指针事件驱动：TapGestureRecognizer 的 onTapDown 与
  /// 横滑识别器竞争时要等 100ms 判定或抬手才触发，给不了「按下即反馈」）。
  void pressStart(DeckSlot slot) {
    _pressedSlot = slot;
    _pressController.animateTo(1);
  }

  /// 按压反馈结束（抬手/取消/横滑接管）：回弹到 0。
  void pressEnd() {
    if (_pressedSlot == null) return;
    _pressController.animateTo(0);
  }

  /// 按压回弹结束：清掉按压槽位（缩放已回 1，无需重建）。
  void _handlePressStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    _pressedSlot = null;
  }

  /// 某槽位的按压缩放；未按压的槽位恒 1.0。
  double pressScaleFor(DeckSlot slot) => slot == _pressedSlot
      ? 1 - (1 - _pressScale) * _pressController.value
      : 1.0;

  /// 飞行开始时收尾仍按在屏上的拖动/按压：IgnorePointer 只影响后续命中，
  /// 已建立的指针路由不会自动发 cancel；不主动收尾会让 dragActive 卡住。
  void abortGestureForFlight() {
    pressEnd();
    if (_session.state.dragActive) {
      _session.dragCancel();
      _resetDragTracking();
    }
  }

  /// 校正控制器走完：对账校正结束（会话回 idle，槽位身份按新快照稳态接管）。
  void _handleCorrectionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _session.correctionCompleted();
  }

  /// 进度控制器落位：即时切歌结束 / 提交过渡落位后开始校正 / 回弹落位。
  ///
  /// 三种收尾都属于会话时机（见 [CoverSwapSession.progressCompleted]）。
  void _handleCoverStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 进度重置到 0 时的合成 completed 不是真实落位，不能清 handoff。
    if (_resettingCoverProgress) return;
    // 落位帧起稳态槽位接管：清掉接管快照，避免下一次会话误用过期起点。
    _handoffs.clear();
    _session.progressCompleted();
  }

  void handleHorizontalDragStart(DragStartDetails details) {
    // 横滑接管：按压反馈让位（拖动跟手本身就是反馈）。
    pressEnd();
    // 过渡动画 / 顶栏⇄播放页飞行期间不接受新手势（提交等待与校正由会话
    // 自己拒绝）：一次拖动只对应一次切歌，避免两段过渡叠加；飞行期间由
    // 副本承接，deck 本身冻结。
    if (_coverSwapMidFlight || gesturesBlockedOf()) {
      return;
    }
    if (!_session.dragStart()) return;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
    // 新手势的层级从「目标在上」起步；第一次有效位移会按趋势重新判定。
    _outgoingCoverOnTop = false;
    _previewTrendAnchor = _coverController.value;
  }

  void handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_session.state.dragActive ||
        _dragStartX == null ||
        _dragStartY == null) {
      return;
    }

    final dx = details.globalPosition.dx - _dragStartX!;
    final dy = details.globalPosition.dy - _dragStartY!;

    if (!_isHorizontalDragConfirmed) {
      if (dy.abs() > dx.abs() * 1.5) {
        // 纵向意图更明确：放弃本次横向拖动（展开/收起交给外层手势）。
        _session.dragCancel();
        _resetDragTracking();
        return;
      } else if (dx.abs() > 10.0) {
        _isHorizontalDragConfirmed = true;
      }
    }

    if (!_isHorizontalDragConfirmed) return;
    _dragDx = dx;
    // 进度即画面进度：拖动跟手与弹簧吸附同源，松手从同一进度续播不跳。
    final double visual = (dx.abs() / _coverSwapRange).clamp(0.0, 1.0);
    _session.dragUpdate(delta: dx, progress: visual);
  }

  /// 是否处于「换场中段」。
  ///
  /// 弹簧在容差内会一直报 `isAnimating`（进度 ≈1 的不可见拖尾），不能直接
  /// 当「过渡进行中」判定——否则新手势/新切歌会在尾部窗口被饿死，看起来
  /// 像动画没播。真正中段才「续走不重放」。
  bool get _coverSwapMidFlight =>
      _coverController.isAnimating && _coverController.value < 0.99;

  /// 拖动行程：约 0.6 个封面宽度走完整段过渡（也是速度→进度的换算基准）。
  double get _coverSwapRange => max(48.0, artDimensionOf() * 0.6);

  /// 松手：达标且存在预览目标则提交切歌；未达标/边界回弹。
  void handleHorizontalDragEnd(DragEndDetails details) {
    // 本次手势已被忽略（提交等待期间的拖动）。
    if (!_session.state.dragActive) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dx = _dragDx;
    final confirmed = _isHorizontalDragConfirmed;
    final wasPreviewing = _session.state.previewActive;
    _session.dragEnd();
    _resetDragTracking();
    if (!confirmed) return;

    final bool large = isLargeScreenOf();
    final threshold = large ? 400.0 : 800.0;
    final triggerDistance = large ? 40.0 : 80.0;
    final bool shouldCommit =
        velocity.abs() > threshold || dx.abs() > triggerDistance;

    // 只有进入过预览（存在可切换的目标）才允许提交；边界拖动直接回弹。
    if (!wasPreviewing) return;

    // 手势速度换算到进度域（画面进度 = |dx| / range），松手从同一进度续播。
    final double progressVelocity = -velocity / _coverSwapRange;
    if (shouldCommit) {
      _session.commit(progressVelocity: progressVelocity);
    } else {
      _session.releasePreview(progressVelocity: progressVelocity);
    }
  }

  void handleHorizontalDragCancel() {
    _session.dragCancel();
    _resetDragTracking();
  }

  /// 复位 deck 侧的手势跟踪（会话的拖动状态由会话自己收尾）。
  void _resetDragTracking() {
    _dragStartX = null;
    _dragStartY = null;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
  }

  /// 把会话 / 控制器 / 空闲视觉折算成渲染层的一帧输入。
  DeckArtworkFrame artworkFrame({
    required PlaybackSnapshot snapshot,
    required Track? displayTrack,
    required ValueListenable<double>? sideReveal,
    required bool pageCoverHidden,
    required Key? morphCoverKey,
  }) {
    final session = _session.state;
    final correcting = session.phase == CoverSwapPhase.correcting;
    // 预览视觉（拖动跟手 / 提交等待 / 回退中）都由会话目标驱动：
    // 回退中若换回当前曲目，目标槽位会在回弹半途闪成当前封面。
    final showingPreview = session.showingPreviewTarget;
    final animating =
        !correcting &&
        (showingPreview ||
            _coverController.isAnimating ||
            session.phase == CoverSwapPhase.settling);
    final double p = _coverController.value;
    final CoverHandoff? handoff = _handoffs.handoff;
    final bool handoffActive =
        handoff != null &&
        session.phase == CoverSwapPhase.settling &&
        trackKeyOf(session.from) == trackKeyOf(handoff.previousCenterTrack);
    return DeckArtworkFrame(
      displayTrack: displayTrack,
      snapshot: snapshot,
      session: session,
      artDimension: artDimensionOf(),
      progress: p,
      correcting: correcting,
      animating: animating,
      showingPreview: showingPreview,
      outgoingOnTop: _outgoingCoverOnTop,
      handoff: handoff,
      handoffActive: handoffActive,
      handoffTails: _handoffs.tails,
      leftOutgoing: _visuals.leftSlotOutgoing,
      rightOutgoing: _visuals.rightSlotOutgoing,
      sourceFade: Curves.easeOut.transform(
        _sourceNeighborFade.value.clamp(0.0, 1.0),
      ),
      identityFade: Curves.easeOut.transform(
        _visuals.slotIdentityValue.clamp(0.0, 1.0),
      ),
      artworkFade: Curves.easeOut.transform(
        _visuals.artworkRefreshValue.clamp(0.0, 1.0),
      ),
      correctionFade: Curves.easeOut.transform(
        _reconcileCorrection.value.clamp(0.0, 1.0),
      ),
      sideTransitioning:
          _visuals.slotIdentityAnimating || _sourceNeighborFade.isAnimating,
      centerArtworkRefreshing: _visuals.centerArtworkRefreshing,
      outgoingCenterArtworkUrl: _visuals.outgoingCenterArtworkUrl,
      currentImageUrl: realCoverUrlOf(displayTrack),
      sideReveal: sideReveal,
      pageCoverHidden: pageCoverHidden,
      morphCoverKey: morphCoverKey,
    );
  }

  void dispose() {
    disarmTimeout();
    _visuals.dispose();
    _reconcileCorrection.removeStatusListener(_handleCorrectionStatus);
    _reconcileCorrection.dispose();
    _slotIdentityFade.dispose();
    _artworkRefreshFade.dispose();
    _sourceNeighborFade.dispose();
    _playStateController.dispose();
    _pressController.removeStatusListener(_handlePressStatus);
    _pressController.dispose();
    _coverController.removeStatusListener(_handleCoverStatus);
    _coverController.dispose();
  }
}
