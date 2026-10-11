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
/// 切歌视觉：
/// - 时长 320ms、easeOutCubic；拖动跟手按同一条曲线反解，松手不跳；
/// - 目标槽位旧身份与源槽位新身份按进度窗口交叉淡化（仅透明度、原位不动）；
/// - 两张移动卡（旧中封 → 目标槽位、新中封 ← 源槽位）全程插值，透明度
///   1.0 ↔ 0.85 连续过渡（进场卡从 85% 起步，消除起手闪跳）。
///
/// 对账与会话外槽位更新：
/// - 提交对账到非预览曲目：进入 `correcting`，中心封面以 220ms 原位交叉淡化
///   校正（旧预览卡淡出、实际曲目卡淡入，无位移），随后按新快照重建槽位；
///   提交过渡尚未落位时先让它走完再校正（从稳态起步，避免半途起跳）；
/// - 空闲期槽位身份变化（加歌/删歌/开关随机/next 变空）：180ms 原位交叉
///   淡化（旧淡出、新淡入，变空则淡出为空），会话激活期间由会话窗口负责；
/// - 中心封面同 id、封面 URL 更新（音源补图）：250ms 交叉淡化换图；
/// - 左槽「上一首」= 播放顺序最近一首（history 末位）→ 队列前一位 → 空
///   （排除与当前同 id），与后端 `skipToPrevious` 及拖动预览同源。
///
/// 切歌检测与空闲缓存刷新由播放快照监听驱动（[PlaybackProvider] 通知 →
/// 比较当前曲目 id；同曲通知刷新下一首身份与方向提示），build 期间零写入。
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

  /// 滑出（旧中心）封面的语义 key：滑出卡是否参与切歌动画是可观察行为，
  /// 对外用这个锚点断言。对账校正期间它也是淡出中的旧预览卡。
  static const Key outgoingCoverCardKey = ValueKey('coverSlotOutgoing');

  /// 中心封面换图（同 id、URL 更新）时旧图卡片的语义 key：换图淡化是否
  /// 以「旧图淡出 + 新图淡入」表达，对外用这个锚点断言。
  static const Key outgoingArtworkCardKey = ValueKey('coverArtworkOutgoing');

  /// 左右槽位卡按身份（track id）的语义 key：空闲期身份交叉淡化时同一槽位
  /// 会并存新旧两张卡（旧淡出、新淡入），测试需要按身份分别定位并采样
  /// 透明度（不读私有字段）。
  static Key sideCoverCardKey({required bool left, required TrackId id}) =>
      ValueKey('coverSlot${left ? 'Left' : 'Right'}:${id.uri}');

  /// 稳态中心封面按身份（track id）的语义 key：对账校正后中心到底展示
  /// 哪一首是可观察行为，对外用这个锚点断言（不读私有字段）。
  static Key centerCoverTrackKey(TrackId id) =>
      ValueKey('coverSlotCenter:${id.uri}');

  const PlayerCoverDeck({
    super.key,
    required this.displayTrack,
    required this.artDimension,
    required this.stackDimension,
    required this.stackHeight,
    required this.fullCoverKey,
    this.isLargeScreen = false,
    this.morph,
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
  /// 切歌过渡时长；拖动跟手按同一曲线反解，松手不跳。
  static const Duration _coverSwapDuration = Duration(milliseconds: 320);

  /// 邻位稳态透明度；窗口淡出/淡入的端点值（p=0 / p=1 与稳态卡一致）。
  static const double _neighborOpacity = 0.85;

  /// 目标槽位旧身份淡出窗口终点：p ∈ [0, 0.4] 内 0.85 → 0（窗口内 easeOut）。
  static const double _oldNeighborFadeEnd = 0.4;

  /// 源槽位新身份淡入窗口起点：p ∈ [0.6, 1] 内 0 → 0.85（窗口内 easeInOut）。
  static const double _newNeighborFadeStart = 0.6;

  /// 拖动对账落位后源侧新身份的纯透明度淡入时长。
  static const Duration _reconcileFadeDuration = Duration(milliseconds: 180);

  /// 对账校正时长：到位曲目与预览目标不一致时，中心封面原位交叉淡化校正。
  static const Duration _reconcileCorrectionDuration = Duration(milliseconds: 220);

  /// 空闲期槽位身份交叉淡化时长（原位、纯透明度）。
  static const Duration _slotIdentityFadeDuration = Duration(milliseconds: 180);

  /// 中心封面同 id 换图（音源补图）交叉淡化时长。
  static const Duration _artworkRefreshFadeDuration = Duration(milliseconds: 250);

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

  /// 拖动对账落位后源侧新身份的纯透明度淡入；只在 idle 稳态渲染里作用于
  /// 会话方向的源侧槽位。
  late AnimationController _sourceNeighborFade;

  /// 对账校正控制器：0→1 期间中心旧预览卡淡出、实际曲目卡淡入（原位无位移）。
  late AnimationController _reconcileCorrection;

  /// 空闲槽位身份交叉淡化控制器：1 = 稳态；身份变化时 0 → 1。
  late AnimationController _slotIdentityFade;

  /// 中心封面换图控制器：1 = 稳态；同 id、URL 更新时 0 → 1。
  late AnimationController _artworkRefreshFade;

  /// 封面堆叠重绘源：切歌过渡 + 对账后的源侧淡入 + 校正/槽位淡换/换图。
  late final Listenable _coverStackAnimation;

  /// 已确认的对账结果：提交过渡尚未落位时先记住，落位后再开始校正
  /// （校正必须从稳态起步，否则旧预览卡会从半途位置跳回中心）。
  String? _pendingCorrectionId;

  /// 中心封面当前身份与 URL（同 id 换图时 URL 是淡出起点；起点可以为空，
  /// 即「音源补图」：从无封面淡入到有封面）。
  String? _centerTrackId;
  String? _centerArtworkUrl;

  /// 中心封面是否正在换图（淡出起点 [_outgoingCenterArtworkUrl] 可以为空，
  /// 所以淡出卡是否渲染不能用「旧 URL 非空」判断）。
  bool _centerArtworkRefreshing = false;

  /// 中心封面淡出中的旧 URL（换图起点；无封面时为 null）。
  String? _outgoingCenterArtworkUrl;

  /// 空闲槽位身份跟踪：最近一次稳态渲染的身份（下一次变化的淡出起点）
  /// 与正在淡出的旧身份。
  Track? _leftSlotShown;
  Track? _rightSlotShown;
  Track? _leftSlotOutgoing;
  Track? _rightSlotOutgoing;

  /// 播放态中心封面轻微缩放（暂停时保持清晰，不做变暗）。
  late AnimationController _playStateController;
  late Animation<double> _playStateScaleAnimation;

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
      duration: _coverSwapDuration,
      vsync: this,
    )..value = 1.0;

    _sourceNeighborFade = AnimationController(
      duration: _reconcileFadeDuration,
      vsync: this,
      value: 1.0,
    );
    _reconcileCorrection = AnimationController(
      duration: _reconcileCorrectionDuration,
      vsync: this,
      value: 1.0,
    );
    _slotIdentityFade = AnimationController(
      duration: _slotIdentityFadeDuration,
      vsync: this,
      value: 1.0,
    );
    _artworkRefreshFade = AnimationController(
      duration: _artworkRefreshFadeDuration,
      vsync: this,
      value: 1.0,
    );
    // 中心换图的淡出起点必须是「挂载时正在展示的 URL」：首个快照若只补了
    // 封面 URL（同 id），didUpdateWidget 才能识别为换图而不是首帧接管。
    _centerTrackId = trackKeyOf(widget.displayTrack);
    _centerArtworkUrl = artworkUrlOf(widget.displayTrack);
    _coverStackAnimation = Listenable.merge([
      _coverController,
      _sourceNeighborFade,
      _reconcileCorrection,
      _slotIdentityFade,
      _artworkRefreshFade,
    ]);
    // 即时切歌落位即会话结束（完成中 → 空闲）；拖动提交由对账路径收尾。
    _coverController.addStatusListener(_handleCoverStatus);
    _reconcileCorrection.addStatusListener(_handleCorrectionStatus);
    _slotIdentityFade.addStatusListener(_handleSlotIdentityStatus);
    _artworkRefreshFade.addStatusListener(_handleArtworkRefreshStatus);
    // 顶栏⇄播放页飞行期间中心封面隐藏，必须监听 morph 控制器重建真身。
    widget.morph?.addListener(_onMorphChanged);
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
    }
    // provider 可能被替换：父级重建时重新检查订阅（此时 widget.displayTrack
    // 已来自新快照）。
    _bindPlaybackIfNeeded();
    // 中心封面同 id、URL 更新（音源补图）：250ms 交叉淡化换图，不播切歌动画。
    _syncCenterArtwork(widget.displayTrack);
  }

  /// 订阅（或换绑）播放 Provider，并在换绑后同步一次会话身份。
  ///
  /// `context.read` 不建立依赖：本模块不因每次通知整树重建，只在检测到曲目
  /// 变化时 setState。provider 被替换时必须重新订阅，否则会话会停留在旧
  /// provider 的曲目上。
  void _bindPlaybackIfNeeded() {
    final playback = context.read<PlaybackProvider>();
    if (identical(playback, _playback)) return;
    _playback?.removeListener(_handlePlaybackChanged);
    _playback = playback;
    playback.addListener(_handlePlaybackChanged);
    // 首帧（或换 provider）：以 deck 实际展示的曲目建立/校正会话身份，
    // 并同步一次播放态缩放初始值。
    _syncDisplayTrack(playback);
    _syncPlayState(playback);
  }

  /// 播放态中心封面缩放同步：播放 → 1.0、暂停 → 0.98（300ms）。
  ///
  /// 由快照通知驱动（build 期间零写入），AnimatedBuilder 监听控制器重建。
  void _syncPlayState(PlaybackProvider playback) {
    if (playback.isPlaying) {
      _playStateController.forward();
    } else {
      _playStateController.reverse();
    }
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
      _syncPlayState(playback);
      final track = playback.snapshot.current;
      final id = trackKeyOf(track);
      if (id == null || id == _session.animatedTrackId) {
        // 同一首的重复通知只刷新对象引用（快照值变才发，代价可忽略）；
        // current 未变但队列/身份可能变化：刷新空闲槽位淡换与中心换图，
        // 并按新快照刷新空闲缓存（下一首身份与方向提示）。
        if (track != null) _session.seenTrack = track;
        _refreshIdleVisuals(playback);
        _refreshIdleCache(playback);
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
        // 切歌处理之后按新快照刷新空闲缓存：快速连切时下一次判定需要
        // 「变化前」基准。
        _refreshIdleCache(playback);
      });
    });
  }

  /// 首帧 / 换 provider：以当前展示曲目为基准同步会话身份。
  ///
  /// 无旧曲（`oldTrack = null`）时只播放入场动画（方向无意义按向前），
  /// 不产生「切歌」的滑出身份。
  void _syncDisplayTrack(PlaybackProvider playback) {
    final track = widget.displayTrack;
    final id = trackKeyOf(track);
    if (id == null) {
      // 无展示曲目：只做一次空闲缓存初始同步（首帧/挂载的 build 零写入）。
      _refreshIdleCache(playback);
      return;
    }
    if (id == _session.animatedTrackId) {
      _session.seenTrack = track;
      _refreshIdleCache(playback);
      return;
    }
    _handleTrackChanged(
      id: id,
      track: track!,
      oldTrack: _session.seenTrack,
      playback: playback,
    );
    _session.seenTrack = track;
    _refreshIdleCache(playback);
  }

  void _onMorphChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// current 未变时的空闲刷新：中心换图 + 左右槽位身份淡换。
  ///
  /// 在通知微任务里（下一帧构建前）判定并启动淡化：淡化起点必须先把控制器
  /// 归零，否则会先闪一帧新身份/新图再回跳。会话激活期间（拖动/提交/过渡/
  /// 校正）槽位身份由会话窗口负责，这里只接管中心换图。
  void _refreshIdleVisuals(PlaybackProvider playback) {
    final snapshot = playback.snapshot;
    final current = snapshot.current;
    final currentId = trackKeyOf(current);
    // 中心封面同 id、URL 变化（音源补图）：250ms 交叉淡化换图，不播切歌动画。
    // current 已变（切歌/清空）时由切歌与校正路径接管，不做换图淡化。
    if (currentId != null &&
        currentId == _session.animatedTrackId &&
        currentId == _centerTrackId) {
      final url = artworkUrlOf(current);
      if (url != _centerArtworkUrl) {
        if (_artworkRefreshFade.isAnimating) {
          // 换图淡化中再次更新：直接接管新 URL（以当前透明度渲染），不重启动画。
          _centerArtworkUrl = url;
        } else {
          setState(() {
            _outgoingCenterArtworkUrl = _centerArtworkUrl;
            _centerArtworkRefreshing = true;
            _centerArtworkUrl = url;
            _artworkRefreshFade.value = 0;
          });
          _artworkRefreshFade.forward();
        }
      }
    }
    _refreshIdleSlots(snapshot);
  }

  /// 空闲缓存刷新：下一首身份、左槽身份、滑出身份清理与方向判定提示。
  ///
  /// 由播放快照通知（微任务）与挂载同步调用（build 期间零写入）：方向纯
  /// 函数消费「变化前」提示，必须来自最近一次稳态快照，快速连切的方向基准
  /// 才不漂移。会话激活（拖动/提交/过渡/校正）期间不刷新，由会话窗口负责。
  void _refreshIdleCache(PlaybackProvider playback) {
    if (_coverController.isAnimating || _session.previewActive) return;
    final snapshot = playback.snapshot;
    _session
      ..lastNext = snapshot.next
      ..previous = _resolvePreviousTrack(snapshot);
    if (_session.phase == CoverSwapPhase.idle) {
      // 只清真正结束（idle）的会话：settling 检测帧（动画尚未在 post-frame
      // 启动）必须保留刚建立的滑出身份，否则滑出卡全程不渲染。
      _session.from = null;
    }
    _cacheDirectionHints(snapshot);
    // 稳态槽位身份跟踪对齐快照（作为下一次身份变化的淡出起点）；淡化
    // 进行中由淡化路径接管，不叠加。
    if (_session.phase == CoverSwapPhase.idle &&
        !_slotIdentityFade.isAnimating) {
      _leftSlotShown = _session.previous;
      _rightSlotShown = snapshot.next;
    }
  }

  /// 空闲期槽位身份变化（加歌/删歌/开关随机导致上一首/下一首换人）：
  /// 以约 180ms 原位交叉淡化表达；身份变为空则淡出为空。
  ///
  /// 门控：只在会话 idle 且过渡动画已停下时接管——拖动/提交/校正期间槽位
  /// 身份由会话窗口负责，不得叠加。
  void _refreshIdleSlots(PlaybackSnapshot snapshot) {
    if (_session.phase != CoverSwapPhase.idle || _coverController.isAnimating) {
      return;
    }
    final left = _resolvePreviousTrack(snapshot);
    final right = snapshot.next;
    final bool leftChanged = _leftSlotShown?.id != left?.id;
    final bool rightChanged = _rightSlotShown?.id != right?.id;
    if (!leftChanged && !rightChanged) return;
    if (_slotIdentityFade.isAnimating) {
      // 淡化中身份再次变化：直接接管新身份（以当前透明度渲染），不重启动画
      // （重启动画会让已淡出的卡透明度回跳）。该侧若还没在淡出（另一侧先
      // 变化），补一个淡出起点：从当前透明度起步，避免直接硬切身份。
      setState(() {
        if (leftChanged) {
          _leftSlotOutgoing ??= _leftSlotShown;
          _leftSlotShown = left;
        }
        if (rightChanged) {
          _rightSlotOutgoing ??= _rightSlotShown;
          _rightSlotShown = right;
        }
      });
      return;
    }
    setState(() {
      if (leftChanged) {
        _leftSlotOutgoing = _leftSlotShown;
        _leftSlotShown = left;
      }
      if (rightChanged) {
        _rightSlotOutgoing = _rightSlotShown;
        _rightSlotShown = right;
      }
      _slotIdentityFade.value = 0;
    });
    _slotIdentityFade.forward();
  }

  /// 会话结束/稳态帧：把槽位身份跟踪对齐到快照（并清掉淡出中的旧身份）。
  ///
  /// 会话窗口（切歌/对账）已经把槽位身份演到位，直接接管不补淡换；空闲期
  /// 后续的变化才会以 [CoverSwapSession] 之外的淡换表达。
  void _syncSlotIdentityTracking(PlaybackSnapshot snapshot) {
    _leftSlotShown = _resolvePreviousTrack(snapshot);
    _rightSlotShown = snapshot.next;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
  }

  /// 中心封面同 id、封面 URL 变化（音源补图）：以约 250ms 交叉淡化换图。
  ///
  /// 只在同一曲目 id 内换 URL 时触发；id 变化（切歌/对账落位）由切歌与校正
  /// 路径负责，这里只接管新身份、不播换图淡化。淡化起点必须在新 URL 渲染
  /// 之前把控制器归零，否则会先闪一帧新图再回跳旧图，因此放在这里而不是 build。
  void _syncCenterArtwork(Track? track) {
    final id = trackKeyOf(track);
    final url = artworkUrlOf(track);
    if (id != _centerTrackId) {
      _centerTrackId = id;
      _centerArtworkUrl = url;
      _centerArtworkRefreshing = false;
      _outgoingCenterArtworkUrl = null;
      if (_artworkRefreshFade.value != 1.0) _artworkRefreshFade.value = 1.0;
      return;
    }
    if (url == _centerArtworkUrl) return;
    if (_artworkRefreshFade.isAnimating) {
      _centerArtworkUrl = url;
      return;
    }
    _outgoingCenterArtworkUrl = _centerArtworkUrl;
    _centerArtworkRefreshing = true;
    _centerArtworkUrl = url;
    _artworkRefreshFade.value = 0;
    _artworkRefreshFade.forward();
  }

  /// 换图淡化结束：撤下旧图卡片（稳态只留实际曲目卡）。
  void _handleArtworkRefreshStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_centerArtworkRefreshing) return;
    setState(() => _centerArtworkRefreshing = false);
  }

  /// 槽位身份交叉淡化结束：撤下淡出中的旧身份卡。
  void _handleSlotIdentityStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_leftSlotOutgoing == null && _rightSlotOutgoing == null) return;
    setState(() {
      _leftSlotOutgoing = null;
      _rightSlotOutgoing = null;
    });
  }

  /// 校正结束（220ms 走完）：会话回 idle，槽位身份按新快照稳态接管。
  void _handleCorrectionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_session.phase != CoverSwapPhase.correcting) return;
    final playback = _playback;
    setState(() {
      _session
        ..phase = CoverSwapPhase.idle
        ..to = null
        ..from = null;
      if (playback != null) _syncSlotIdentityTracking(playback.snapshot);
    });
  }

  /// 进度控制器落位（完成中 → 空闲）：即时切歌会话到此结束。
  ///
  /// 拖动提交的收尾在对账路径（[_reconcileDragCommit]）；这里只清理即时
  /// 切歌的身份，不触发重建（视觉已由控制器最后一帧画完，下一次切歌或
  /// 空闲缓存帧自然覆盖）。
  void _handleCoverStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_session.phase == CoverSwapPhase.settling) {
      _session
        ..phase = CoverSwapPhase.idle
        ..to = null;
      // 会话窗口已把槽位身份演到位：跟踪对齐快照，避免下一次空闲变化
      // 把切换前的旧身份当成淡出起点（幽灵淡出）。
      final playback = _playback;
      if (playback != null) _syncSlotIdentityTracking(playback.snapshot);
      return;
    }
    // 提交过渡落位：对账到别的曲目时现在才开始校正（预览卡已滑到中心，
    // 从稳态起步，无半途位移跳变）。
    if (_pendingCorrectionId != null &&
        _session.phase == CoverSwapPhase.committed) {
      final playback = _playback;
      if (playback != null) _startReconcileCorrection(playback: playback);
      return;
    }
    // 拖动回弹落位（idle）：回弹期间快照可能变化，这里对齐槽位身份跟踪，
    // 避免下一次身份变化以过期身份为淡出起点（幽灵淡出）。
    if (_session.phase == CoverSwapPhase.idle &&
        !_slotIdentityFade.isAnimating) {
      final playback = _playback;
      if (playback != null) _syncSlotIdentityTracking(playback.snapshot);
    }
  }

  @override
  void dispose() {
    _playback?.removeListener(_handlePlaybackChanged);
    widget.morph?.removeListener(_onMorphChanged);
    _cancelPendingWatchdog();
    _artworkRefreshFade.removeStatusListener(_handleArtworkRefreshStatus);
    _artworkRefreshFade.dispose();
    _slotIdentityFade.removeStatusListener(_handleSlotIdentityStatus);
    _slotIdentityFade.dispose();
    _reconcileCorrection.removeStatusListener(_handleCorrectionStatus);
    _reconcileCorrection.dispose();
    _sourceNeighborFade.dispose();
    _playStateController.dispose();
    _coverController.removeStatusListener(_handleCoverStatus);
    _coverController.dispose();
    super.dispose();
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    // 提交等待 / 对账校正 / 过渡动画 / 迷你⇄完整封面飞行期间不接受新手势：
    // 一次拖动只对应一次切歌，避免两段过渡叠加；校正期间放行会把中心从
    // 中间态跳回旧预览目标（校正被弃）。
    if (_session.awaitingReconcile ||
        _session.phase == CoverSwapPhase.correcting ||
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
  /// 下一首（shuffle 会消费同一个随机值），previous 用 [_resolvePreviousTrack]
  /// （history 末位 → 队列前一位 → 空，与后端 previous 的实现一致）。
  Track? _previewTargetFor(int dir, PlaybackProvider playback) {
    final snapshot = playback.snapshot;
    final Track? target = dir == 1
        ? snapshot.next
        : (dir == -1 ? _resolvePreviousTrack(snapshot) : null);
    if (target == null) return null;
    // 目标就是当前曲目（如队列首的 previous）：没有可预览的切换，按边界处理。
    final current = snapshot.current;
    if (current != null && target.id == current.id) return null;
    return target;
  }

  /// 左槽「上一首」身份：播放顺序最近一首（history 末位）→ 队列前一位
  /// （`currentIndex > 0` 时的 `queue[currentIndex-1]`）→ 空。
  ///
  /// 排除与当前曲目同 id：队首回退时后端会把「当前自身」当成 previous，
  /// 界面上不能显示一张和自己一样的上一首（显示为空）。
  Track? _resolvePreviousTrack(PlaybackSnapshot snapshot) {
    final Track? target;
    if (snapshot.history.isNotEmpty) {
      target = snapshot.history.last;
    } else {
      final index = snapshot.currentIndex;
      target = (index > 0 && index < snapshot.queue.length)
          ? snapshot.queue[index - 1]
          : null;
    }
    if (target == null) return null;
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
      // 无可切换目标：拖动起点就是边界时不进入预览（松手也不提交）；
      // 预览已激活期间同向重解析为 null（列表变化，如 next 变空）时
      // 保持会话目标、进度冻结，不撤下预览（松手后按提交/对账路径收尾）；
      // 反向拖回边界才撤下预览回弹。
      if (session.phase == CoverSwapPhase.preview &&
          dir != session.direction) {
        _returnCoverPreview();
      }
      return;
    }

    if (!session.previewActive) {
      session.phase = CoverSwapPhase.preview;
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
    final bool shouldCommit =
        velocity.abs() > threshold || dx.abs() > triggerDistance;

    // 只有进入过预览（存在可切换的目标）才允许提交；边界拖动直接回弹。
    if (!wasPreviewing || previewTrack == null) {
      if (wasPreviewing) _returnCoverPreview();
      return;
    }

    if (shouldCommit) {
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
      ..to = null;
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

  /// 缓存「变化前」的方向判定提示（空闲缓存刷新与每次切歌解析后调用）。
  ///
  /// 方向纯函数消费的是变化前的提示：变化后快照的 next/history 已经翻页，
  /// 无法代表用户实际来的方向。空闲缓存保证常规切歌拿到最近一次稳态
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
      // 上一个会话可能停在（或正在）校正：新切歌直接接管，停掉校正控制器。
      if (_reconcileCorrection.isAnimating) _reconcileCorrection.stop();
      _pendingCorrectionId = null;
      session
        ..phase = CoverSwapPhase.settling
        ..to = track;
      // 新会话先把进度钉在起点：检测帧就画在 p=0（与稳态的源槽位卡一致），
      // 而不是先画落位态、动画启动后再回跳。动画在 post-frame 从同一进度
      // 续走；快速连切（控制器仍在动）保持当前进度，不回起点重放。
      if (!_coverController.isAnimating) {
        _coverController.value = 0;
      }
    }
    session.direction = direction == coverSwapBackward ? -1 : 1;
    session.oldNeighbor = direction == coverSwapBackward
        ? session.lastNext
        : session.previous;
    // 新快照即下一次切歌的「变化前」基准（快速连切时动画中不会有空闲帧）。
    _cacheDirectionHints(snapshot);
    // 播放顺序由播放快照维护（后端记录实际播放顺序）：左槽「上一首」=
    // 播放顺序最近一首 → 队列前一位 → 空（与后端 previous 同源）。
    session
      ..previous = _resolvePreviousTrack(snapshot)
      ..from = oldTrack
      // 旧封面作为切歌动画中未加载完成时的占位，避免黑块闪一下。
      ..placeholderUrl = artworkUrlOf(oldTrack) ?? session.placeholderUrl;
    _cancelPendingWatchdog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_session.previewActive) {
        // 用户正在拖动预览：动画不接管，由手指继续驱动（标题入场也让位）。
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
  /// 等待快照 current 变为会话目标：
  /// - 匹配 → 无缝完成（过渡已在提交时走完，不回起点、不重播）；
  /// - 不匹配（随机目标 / 失败恢复 / 列表变化落到别的曲目）→ 进入校正阶段：
  ///   中心封面以 220ms 原位交叉淡化校正到实际曲目（旧预览卡淡出、实际
  ///   曲目卡淡入，同位置无位移），随后按新快照重建槽位并回 idle；
  /// - 提交过渡尚未落位时先记住对账结果，落位后再校正（校正从稳态起步，
  ///   避免旧预览卡从半途位置跳回中心）。
  ///
  /// 不管到位的是不是当初预览的那首，都在这里收尾，绝不让预览态悬空
  /// （否则只能等 6s 兜底超时）。
  void _reconcileDragCommit({
    required String id,
    required PlaybackProvider playback,
  }) {
    _cancelPendingWatchdog();
    if (trackKeyOf(_session.to) == id) {
      _settleDragCommit(playback: playback);
      return;
    }
    if (_coverController.isAnimating) {
      _pendingCorrectionId = id;
      return;
    }
    _startReconcileCorrection(playback: playback);
  }

  /// 对账匹配：无缝落位到目标曲目，并补源侧新身份的 180ms 纯透明度淡入。
  void _settleDragCommit({required PlaybackProvider playback}) {
    final session = _session;
    final snapshot = playback.snapshot;
    session
      ..phase = CoverSwapPhase.idle
      ..to = null
      ..previous = _resolvePreviousTrack(snapshot);
    // 对账后新快照即下一次切歌的「变化前」基准。
    _cacheDirectionHints(snapshot);
    // 槽位身份已由切歌窗口演到位：跟踪对齐快照，空闲期不补淡换。
    _syncSlotIdentityTracking(snapshot);
    // 拖动期间源侧新身份没有渲染（UI 只有一位前瞻），落位时补一个纯透明度
    // 淡入；先同步置 0，避免这一帧先以稳态画出来再回跳（闪一下）。
    _sourceNeighborFade.value = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      // 过渡已在提交时走完：画面即最终态，直接落位；若还在走（快速
      // 对账），保持它继续（center 已是 displayTrack，位置连续）。
      if (!_coverController.isAnimating) {
        _coverController.value = 1.0;
      }
      _sourceNeighborFade.forward(from: 0);
    });
  }

  /// 开始对账校正：中心封面从预览目标以 220ms 原位淡化到实际曲目。
  ///
  /// 只在提交过渡落位后调用。校正期间左右槽位直接按新快照稳态渲染（源侧
  /// 新身份仍走 180ms 纯淡入，与匹配路径一致），校正结束会话回 idle，
  /// 稳态渲染无缝接管——「按新快照重建槽位身份」在校正窗口内即已到位。
  void _startReconcileCorrection({required PlaybackProvider playback}) {
    final snapshot = playback.snapshot;
    _pendingCorrectionId = null;
    setState(() {
      _session
        ..phase = CoverSwapPhase.correcting
        ..previous = _resolvePreviousTrack(snapshot);
      // 对账后新快照即下一次切歌的「变化前」基准。
      _cacheDirectionHints(snapshot);
      // 槽位身份按新快照稳态接管：跟踪对齐，空闲期不把校正前的身份
      // 当成淡出起点（幽灵淡出）。
      _syncSlotIdentityTracking(snapshot);
      _reconcileCorrection.value = 0;
    });
    _sourceNeighborFade.value = 0;
    _reconcileCorrection.forward();
    _sourceNeighborFade.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      if (!_coverController.isAnimating) _coverController.value = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // 切歌检测与空闲缓存刷新都在播放快照监听里完成：build 期间零写入，
    // 这里只渲染当前会话/稳态画面。
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
                // settling 在检测帧（动画尚未在 post-frame 启动）也按过渡渲染：
                // 滑出卡必须从会话建立的第一帧起就参与（否则会先画落位态再
                // 回跳，且空闲缓存可能误清会话身份）。
                // correcting（对账校正）只走中心交叉淡化：左右槽按新快照
                // 稳态渲染，不叠加切歌窗口。
                final session = _session;
                final correcting = session.phase == CoverSwapPhase.correcting;
                final dragging = session.previewActive;
                final animating = !correcting &&
                    (dragging ||
                        _coverController.isAnimating ||
                        session.phase == CoverSwapPhase.settling);
                // p 是进度控制器原始值（线性时间）；窗口化交叉按 p 取窗口，
                // 移动卡用 easeOutCubic 的 t 做位移/旋转/缩放插值。
                final double p = _coverController.value;
                final t = Curves.easeOutCubic.transform(p);
                final dir = session.direction;
                final double sideSize = widget.artDimension * 0.78;
                final double offset = widget.artDimension * 0.30;
                const double sideRotation = 0.05;

                final children = <Widget>[];

                // 目标槽位旧身份：窗口 p∈[0, 0.4] 内 0.85→0 原位淡出（无位移），
                // 与源槽位新身份的淡入窗口（p∈[0.6, 1]）错开——同一槽位不出现
                // 两张半透明封面叠加的「叠影」。
                if (animating && session.oldNeighbor != null) {
                  children.add(_sideCoverLayer(
                    context,
                    session.oldNeighbor,
                    sideSize: sideSize,
                    x: -offset * dir,
                    rotation: -sideRotation * dir,
                    opacity: _oldNeighborOpacityAt(p),
                  ));
                }

                if (animating) {
                  // 源槽位新身份：窗口 p∈[0.6, 1] 内 0→0.85 原位淡入（无位移）。
                  // 拖动预览阶段不预取「再下一首」（UI 只有一位前瞻），留空槽，
                  // 由对账落位后的 180ms 纯淡入补上。
                  if (!dragging) {
                    final nextItem = playbackProvider.snapshot.next;
                    final sourceTrack = dir == 1 ? nextItem : session.previous;
                    children.add(_sideCoverLayer(
                      context,
                      sourceTrack,
                      sideSize: sideSize,
                      x: offset * dir,
                      rotation: sideRotation * dir,
                      opacity: _sourceNewNeighborOpacityAt(p),
                      placeholderUrl: currentImageUrl,
                    ));
                  }
                  // 滑出的旧当前 → 目标槽位：全程插值（终点与稳态槽位卡
                  // 完全重合：位置/旋转/缩放/透明度一致，动画结束无 pop）。
                  if (session.from != null) {
                    children.add(_mainCoverLayer(
                      context,
                      session.from,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      slotKey: PlayerCoverDeck.outgoingCoverCardKey,
                      x: -offset * dir * t,
                      rotation: -sideRotation * dir * t,
                      scale: 1.0 - 0.22 * t,
                      opacity: 1.0 - 0.15 * t,
                      interactive: false,
                    ));
                  }
                } else {
                  // 稳态邻位：可点击切歌（左=上一首，右=下一首）。
                  // - 拖动对账落位后的源侧新身份以纯透明度淡入（无位移/缩放/旋转）；
                  // - 空闲期身份变化（加歌/删歌/开关随机/next 变空）以约
                  //   180ms 原位交叉淡化表达（旧身份淡出、新身份淡入）。
                  // 两个淡化控制器稳态都停在 1，倍率不产生任何影响。
                  final double sourceFade = Curves.easeOut
                      .transform(_sourceNeighborFade.value.clamp(0.0, 1.0));
                  final double identityFade = Curves.easeOut
                      .transform(_slotIdentityFade.value.clamp(0.0, 1.0));
                  children.addAll(_idleSideLayers(
                    context,
                    left: true,
                    shown: session.previous,
                    outgoing: _leftSlotOutgoing,
                    sideSize: sideSize,
                    x: -offset,
                    rotation: -sideRotation,
                    sourceFade: dir == -1 ? sourceFade : 1.0,
                    identityFade: identityFade,
                    placeholderUrl: currentImageUrl,
                    // 左槽点击 = 上一首：只要展示了身份（history 末位或
                    // 队列前一位，与后端 skipToPrevious 的回退、拖动预览
                    // 同源）就可点；左槽为空时不渲染卡片，自然不可点。
                    onTap: playbackProvider.hasTrack
                        ? playbackProvider.skipToPrevious
                        : null,
                  ));
                  children.addAll(_idleSideLayers(
                    context,
                    left: false,
                    shown: playbackProvider.snapshot.next,
                    outgoing: _rightSlotOutgoing,
                    sideSize: sideSize,
                    x: offset,
                    rotation: sideRotation,
                    sourceFade: dir == 1 ? sourceFade : 1.0,
                    identityFade: identityFade,
                    placeholderUrl: currentImageUrl,
                    onTap: playbackProvider.hasTrack
                        ? playbackProvider.skipToNext
                        : null,
                  ));
                }

                // 中心位：拖动/提交时由预览目标封面顶上（真正的切歌在松手后
                // 才发生）；动画/稳态下就是当前曲目。顶栏⇄播放页飞行时只隐藏
                // 这一张。预览目标在拖动开始时固定，不重读快照（否则提交后
                // 快照先推新邻位，中心封面会闪成再下一首）。
                //
                // 透明度随进度 0.85→1.0 连续插值：p=0 时与稳态的源槽位卡
                // 完全一致（0.85），消除「动画首帧硬跳 1.0」的起手闪跳；
                // p=1 时与稳态中心封面一致（1.0）。
                if (correcting) {
                  // 对账校正：旧预览卡（原位）淡出、实际曲目卡淡入，全程
                  // 无位移/缩放——到位曲目与预览目标不同时只换图不搬位。
                  final double correctionFade = Curves.easeOut
                      .transform(_reconcileCorrection.value.clamp(0.0, 1.0));
                  if (session.to != null) {
                    children.add(_mainCoverLayer(
                      context,
                      session.to,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      slotKey: PlayerCoverDeck.outgoingCoverCardKey,
                      x: 0,
                      rotation: 0,
                      scale: 1.0,
                      opacity: 1.0 - correctionFade,
                      interactive: false,
                    ));
                  }
                  children.addAll(_steadyCenterLayers(
                    context,
                    playbackProvider,
                    opacity: correctionFade,
                  ));
                } else if (animating) {
                  final Track? centerTrack = dragging
                      ? (session.to ?? widget.displayTrack)
                      : widget.displayTrack;
                  children.add(_mainCoverLayer(
                    context,
                    centerTrack,
                    playbackProvider,
                    artDimension: widget.artDimension,
                    slotKey: PlayerCoverDeck.centerCoverCardKey,
                    x: dir * offset * (1 - t),
                    rotation: sideRotation * dir * (1 - t),
                    scale: 0.78 + 0.22 * t,
                    opacity: 0.85 + 0.15 * t,
                    interactive: !dragging,
                    coverKey: widget.morph?.pageCoverKey,
                    hidden: widget.morph?.pageHeaderHidden ?? false,
                    placeholderUrl:
                        dragging ? currentImageUrl : session.placeholderUrl,
                  ));
                } else {
                  // 稳态中心：同 id、URL 更新（音源补图）时以约 250ms 交叉
                  // 淡化换图（旧图淡出、新图淡入），不播切歌动画。
                  children.addAll(_steadyCenterLayers(
                    context,
                    playbackProvider,
                    opacity: 1.0,
                  ));
                }

                return Stack(clipBehavior: Clip.none, children: children);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 目标槽位旧身份透明度：窗口 p∈[0, 0.4] 内 0.85→0（窗口内 easeOut），
  /// 之后保持 0。窗口化交叉让旧身份先退场、新身份后进场。
  double _oldNeighborOpacityAt(double p) {
    final double window = (p / _oldNeighborFadeEnd).clamp(0.0, 1.0);
    return _neighborOpacity * (1 - Curves.easeOut.transform(window));
  }

  /// 源槽位新身份透明度：窗口 p∈[0.6, 1] 内 0→0.85（窗口内 easeInOut）。
  double _sourceNewNeighborOpacityAt(double p) {
    final double window =
        ((p - _newNeighborFadeStart) / (1 - _newNeighborFadeStart))
            .clamp(0.0, 1.0);
    return _neighborOpacity * Curves.easeInOut.transform(window);
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
    required String? placeholderUrl,
    required VoidCallback? onTap,
  }) {
    final double base = _neighborOpacity * sourceFade;
    final layers = <Widget>[];
    if (outgoing != null) {
      layers.add(_sideCoverLayer(
        context,
        outgoing,
        sideSize: sideSize,
        x: x,
        rotation: rotation,
        opacity: base * (1 - identityFade),
        cardKey: PlayerCoverDeck.sideCoverCardKey(left: left, id: outgoing.id),
        placeholderUrl: placeholderUrl,
      ));
    }
    if (shown != null) {
      layers.add(_sideCoverLayer(
        context,
        shown,
        sideSize: sideSize,
        x: x,
        rotation: rotation,
        opacity: base * identityFade,
        cardKey: PlayerCoverDeck.sideCoverCardKey(left: left, id: shown.id),
        placeholderUrl: placeholderUrl,
        onTap: onTap,
      ));
    }
    return layers;
  }

  /// 稳态中心封面层：实际曲目卡（交互 + 共享飞行锚点），同 id 换图淡化
  /// 期间追加旧 URL 卡（原位淡出、不可交互）。
  List<Widget> _steadyCenterLayers(
    BuildContext context,
    PlaybackProvider playbackProvider, {
    required double opacity,
  }) {
    final double artworkFade =
        Curves.easeOut.transform(_artworkRefreshFade.value.clamp(0.0, 1.0));
    final layers = <Widget>[];
    if (_centerArtworkRefreshing && artworkFade < 1) {
      layers.add(_mainCoverLayer(
        context,
        widget.displayTrack,
        playbackProvider,
        artDimension: widget.artDimension,
        slotKey: PlayerCoverDeck.outgoingArtworkCardKey,
        x: 0,
        rotation: 0,
        scale: 1.0,
        opacity: opacity * (1 - artworkFade),
        interactive: false,
        // 空串表达「明确无封面」（音源补图前的起点）：传 null 会被当作
        // 「未提供覆盖」而回退到曲目当前（新）URL，旧图卡就变成新图了。
        artworkUrlOverride: _outgoingCenterArtworkUrl ?? '',
        fallback: buildDefaultArtwork(context),
      ));
    }
    layers.add(_mainCoverLayer(
      context,
      widget.displayTrack,
      playbackProvider,
      artDimension: widget.artDimension,
      slotKey: PlayerCoverDeck.centerCoverCardKey,
      trackKey: widget.displayTrack == null
          ? null
          : PlayerCoverDeck.centerCoverTrackKey(widget.displayTrack!.id),
      x: 0,
      rotation: 0,
      scale: 1.0,
      opacity: opacity * artworkFade,
      interactive: true,
      coverKey: widget.morph?.pageCoverKey,
      hidden: widget.morph?.pageHeaderHidden ?? false,
      placeholderUrl: _session.placeholderUrl,
    ));
    return layers;
  }

  /// 邻位封面（压在当前封面之下；[onTap] 非空时可点击切歌）。
  ///
  /// 只渲染稳态几何（位置/旋转/尺寸固定），透明度由调用方按窗口/淡入
  /// 计算——侧邻位不再有独立的位移/缩放入场演出。不参与 hit test 时
  /// （[onTap] 为空）忽略指针。[cardKey] 是身份语义 key（空闲淡换时同一
  /// 槽位并存新旧两张卡，测试按身份定位）；key 落在 SizedBox 卡本体上而不是
  /// 外层 KeyedSubtree——邻位点击测试用「GestureDetector.child is SizedBox」
  /// 定位卡片，结构不得改变。
  Widget _sideCoverLayer(
    BuildContext context,
    Track? track, {
    required double sideSize,
    required double x,
    required double rotation,
    required double opacity,
    Key? cardKey,
    String? placeholderUrl,
    VoidCallback? onTap,
  }) {
    if (track == null) return const SizedBox.shrink();
    Widget card = _buildCoverCard(context, track, sideSize,
        key: cardKey, placeholderUrl: placeholderUrl);
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
          offset: Offset(x, 0),
          child: Transform.rotate(
            angle: rotation,
            child: Opacity(
              opacity: opacity,
              child: IgnorePointer(
                ignoring: onTap == null,
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前/滑出封面（可交互时保留滑动手势与点击播放/暂停）。
  ///
  /// [artworkUrlOverride] 用于换图淡化的旧 URL 卡：曲目身份相同、只换图片
  /// 地址（[fallback] 与稳态中心卡一致，避免缺图时占位不一致）。
  /// [trackKey] 是中心封面的身份语义 key（校正后展示的是哪一首）。
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
    Key? trackKey,
    Key? coverKey,
    bool hidden = false,
    String? placeholderUrl,
    String? artworkUrlOverride,
    Widget? fallback,
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
            placeholderUrl: placeholderUrl,
            artworkUrlOverride: artworkUrlOverride,
            fallback: fallback);
    if (slotKey != null) {
      card = KeyedSubtree(key: slotKey, child: card);
    }
    if (trackKey != null) {
      card = KeyedSubtree(key: trackKey, child: card);
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
  /// [artworkUrlOverride] 供换图淡化渲染旧 URL（曲目身份不变、只换图片地址）。
  Widget _buildCoverCard(
    BuildContext context,
    Track? track,
    double size, {
    Key? key,
    double radius = 18,
    Widget? fallback,
    String? placeholderUrl,
    String? artworkUrlOverride,
  }) {
    final url = artworkUrlOverride ?? artworkUrlOf(track);
    final scheme = Theme.of(context).colorScheme;
    final placeholder = placeholderUrl != null && placeholderUrl != url
        ? AppNetworkImage(
            url: placeholderUrl,
            fit: BoxFit.cover,
            fallbackIconSize: size * 0.35,
          )
        : fallback;
    return SizedBox(
      key: key,
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
