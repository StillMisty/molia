/// 播放页封面堆叠模块（cover deck）入口。
///
/// 渲染层在 `deck_artwork_stack.dart`，槽位包装在 `deck_slots.dart`，共享
/// key / 一帧视觉快照在 `deck_models.dart`，动画与会话时机在
/// `deck_controller.dart`；本文件只保留组件、生命周期、播放快照订阅、
/// 手势宿主与 build 组合。
///
/// 槽位（slot）：左 = 上一首、中 = 当前（拖动/提交/回退时为预览目标）、
/// 右 = 下一首；切歌（swap）动画与拖动跟手共用模块内部同一条进度控制器；
/// 拖动/提交/对账/兜底等全部会话时机收敛在唯一一个 [CoverSwapSession] 中。
///
/// 对外公开的最小面：
/// - [PlayerCoverDeck]：组件（入口 + 手势宿主 + 会话的效果宿主）；
/// - [trackKeyOf] / [buildDefaultArtwork] / [buildFallbackArtwork]：
///   稳定身份与占位工具，由 barrel `player_cover_deck.dart` 再导出。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/track.dart';
import '../../providers/playback_provider.dart';
import '../../services/covers/cover_resolution.dart';
import '../../services/haptics.dart';
import '../../theme/motion_policy.dart';
import '../player_cover_session.dart';
import '../player_morph.dart';
import '../track_artwork.dart';
import 'deck_artwork_stack.dart';
import 'deck_controller.dart';
import 'deck_models.dart';

/// 完整播放器封面堆叠：三封面（槽位）渲染 + 横滑切歌手势 + 切歌会话状态。
///
/// 播放器只提供布局尺寸（[artDimension]/[stackDimension]/[stackHeight]）、
/// 共享飞行锚点（[morph]）与切歌联动回调（[onTrackSwapped]）；封面 URL、
/// 占位、拖动、切歌、对账都归本模块。
class PlayerCoverDeck extends StatefulWidget {
  /// 封面区横向手势宿主 key：拖动期间 element 必须稳定（识别器不被
  /// dispose），同时供测试精确定位这一层手势。
  static const Key swipeHostKey = ValueKey('artworkSwipeHost');

  /// 中心槽位（进场）封面的语义 key：切歌中间帧从哪一侧入场是可观察行为，
  /// 对外用这个锚点定位中心封面（也供共享飞行之外的调试/断言使用）。
  static const Key centerCoverCardKey = deckCenterCoverCardKey;

  /// 滑出（旧中心）封面的语义 key：滑出卡是否参与切歌动画是可观察行为，
  /// 对外用这个锚点断言。对账校正期间它也是淡出中的旧预览卡。
  static const Key outgoingCoverCardKey = deckOutgoingCoverCardKey;

  /// 中心封面换图（同 id、URL 更新）时旧图卡片的语义 key：换图淡化是否
  /// 以「旧图淡出 + 新图淡入」表达，对外用这个锚点断言。
  static const Key outgoingArtworkCardKey = deckOutgoingArtworkCardKey;

  /// 左右槽位卡按身份（track id）的语义 key：空闲期身份交叉淡化时同一槽位
  /// 会并存新旧两张卡（旧淡出、新淡入），测试需要按身份分别定位并采样
  /// 透明度（不读私有字段）。
  static Key sideCoverCardKey({required bool left, required TrackId id}) =>
      deckSideCoverCardKey(left: left, id: id);

  /// 中心封面按身份（track id）的语义 key：稳态中心、拖动/提交/回退的
  /// 预览目标与对账校正后的实际曲目都可观察（不读私有字段）。
  static Key centerCoverTrackKey(TrackId id) => deckCenterCoverTrackKey(id);

  /// 封面堆叠容器（三封面的布局盒）的语义 key：堆叠尺寸是否落在播放器列 /
  /// 分栏内是可观察行为，对外用这个锚点断言。
  static const Key stackKey = ValueKey('coverDeckStack');

  const PlayerCoverDeck({
    super.key,
    required this.displayTrack,
    required this.artDimension,
    required this.stackDimension,
    required this.stackHeight,
    this.isLargeScreen = false,
    this.morph,
    this.onTrackSwapped,
  });

  /// 展示曲目（播放器已按 `current ?? 最近播放` 回退解析）。
  final Track? displayTrack;

  /// 当前布局的封面边长（拖动跟手换算行程时需要）。
  final double artDimension;

  /// 堆叠容器尺寸（播放器按可用空间计算，本模块只负责渲染）。
  final double stackDimension;
  final double stackHeight;

  /// 大屏布局：拖动提交阈值（距离/速度）按屏型取不同值。
  final bool isLargeScreen;

  /// 顶栏共享飞行控制器：提供播放页封面锚点并同步隐藏状态。
  final PlayerMorphController? morph;

  /// 展示曲目切换联动（切换帧的 post-frame 触发）：播放器借此清除进度
  /// 拖动残留并启动标题入场。[duringDrag] = 切换发生在拖动进行中，此时
  /// 跳过标题入场，让位给拖动预览。
  final void Function(bool duringDrag)? onTrackSwapped;

  @override
  State<PlayerCoverDeck> createState() => _PlayerCoverDeckState();
}

class _PlayerCoverDeckState extends State<PlayerCoverDeck>
    with TickerProviderStateMixin {
  /// 切歌会话 + 全部动画控制器与视觉状态。
  late final DeckController _controller;

  /// 已订阅的播放 Provider（运行时可能被替换，见 [_bindPlaybackIfNeeded]）。
  PlaybackProvider? _playback;

  /// 已订阅的封面解析器（换封面时中心 / 邻位立即换图）。
  CoverResolver? _covers;
  void Function()? _removeCoverListener;

  /// 当前解析器（挂载时从 Provider / 全局单例解析一次，随后由订阅换绑）。
  CoverResolver get _coverResolver => _covers!;

  /// 真实封面 URL（自定义 / 原始；默认封面只做展示兜底）。
  String? _realCoverUrlOf(Track? track) => _coverResolver.realOf(track).url;

  /// 页中心封面是否隐藏：顶栏 ⇄ 播放页飞行期间，真身由飞行副本承接。
  /// 直接乘进中心层的同一条 Opacity（不嵌套第二层，否则「最近透明度」观测
  /// 会失真，也会多一次合成）。
  bool get _pageCoverHidden => widget.morph?.pageHeaderHidden ?? false;

  /// 快照通知已排入微任务（同一批通知只对账一次）。
  bool _trackSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _covers = coverResolverOf(context);
    _controller = DeckController(
      vsync: this,
      initialDisplayTrack: widget.displayTrack,
      realCoverUrlOf: _realCoverUrlOf,
      snapshotOf: () => _playback?.snapshot,
      displayTrackOf: () => widget.displayTrack,
      artDimensionOf: () => widget.artDimension,
      isLargeScreenOf: () => widget.isLargeScreen,
      isPlayingOf: () => _playback?.isPlaying ?? false,
      isMounted: () => mounted,
      gesturesBlockedOf: () => widget.morph?.pageHeaderHidden ?? false,
      onTrackSwapped: (duringDrag) => widget.onTrackSwapped?.call(duringDrag),
      onSkipRequested: _requestSkip,
      onVisualsChanged: _onDeckVisualsChanged,
    );
    // 顶栏⇄播放页飞行期间中心封面隐藏，必须监听 morph 控制器重建真身。
    widget.morph?.addListener(_onMorphChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 快照监听：切歌检测完全由通知驱动（build 期间不判定切歌）。
    _bindPlaybackIfNeeded();
    // 自定义封面索引变化：同 id 换图走既有 250ms 中心淡化。
    _bindCoversIfNeeded();
    // 页面可见性（tab 切换）：任一方向翻转都立即落位。
    _syncTickerMode();
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
    _controller.syncCenterArtwork(widget.displayTrack);
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
    _controller.attachPlayback(
      snapshot: playback.snapshot,
      displayTrack: widget.displayTrack,
    );
  }

  /// 订阅封面解析器：当前曲目换图 / 恢复原图后立即刷新中心与邻位。
  void _bindCoversIfNeeded() {
    final covers = coverResolverOf(context);
    if (identical(covers, _covers)) return;
    _removeCoverListener?.call();
    _covers = covers;
    _removeCoverListener = covers.addChangeListener(_onCustomCoverChanged);
  }

  void _onCustomCoverChanged() {
    if (!mounted) return;
    // 先走同 id 换图的淡化路径（transition 与中心身份都由它维护），再
    // setState 让邻位槽也按新索引重算（自定义封面可作用于上一首 / 下一首）。
    _controller.syncCenterArtwork(widget.displayTrack);
    setState(() {});
  }

  /// 页面可见性变化（TickerMode）→ 会话。
  ///
  /// 任一方向翻转都立即落位到稳态（理由见 [CoverSwapSession.setVisible]：
  /// 顶栏⇄播放页飞行抓到的锚点必须始终是稳态矩形）。
  void _syncTickerMode() {
    _controller.setVisible(TickerMode.valuesOf(context).enabled);
  }

  /// 请求后端切歌（方向 = 会话方向）。
  void _requestSkip(int direction) {
    final playback = _playback;
    if (playback == null) return;
    if (direction < 0) {
      playback.skipToPrevious();
    } else {
      playback.skipToNext();
    }
  }

  /// 播放快照通知：合并同一批通知到微任务统一对账。
  ///
  /// - 不在通知回调里直接改 UI：通知可能来自构建/布局期间，微任务一定在
  ///   下一帧构建前运行（不会在 build/布局期间改状态），且同一批（同一次
  ///   抖动）多条通知只处理一次；
  /// - 切歌检测与空闲缓存（左槽身份 / 下一首 / 方向提示）都归
  ///   [CoverSwapSession.observe]：会话是唯一写入者，这里只补渲染侧的空闲
  ///   视觉（中心换图 / 槽位身份淡换）；
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
      _controller.ingestPlayback(
        snapshot: playback.snapshot,
        displayTrack: widget.displayTrack,
        isPlaying: playback.isPlaying,
      );
    });
  }

  void _onMorphChanged() {
    if (!mounted) return;
    if (_pageCoverHidden) _controller.abortGestureForFlight();
    setState(() {});
  }

  /// 控制器离散视觉变化（中心换图 / 槽位淡换撤销）：与原 setState 同点重建。
  void _onDeckVisualsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _playback?.removeListener(_handlePlaybackChanged);
    _removeCoverListener?.call();
    widget.morph?.removeListener(_onMorphChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // 切歌检测与空闲缓存刷新都在播放快照监听里（微任务）完成：build 期间
    // 零写入，这里只渲染当前会话/稳态画面。
    return _buildArtworkStack(context, playback);
  }

  /// 三封面堆叠的交互宿主：手势固定在 [AnimatedBuilder] 外层。
  ///
  /// 拖动期间中心卡会因 `interactive` 换型重建，手势挂在卡上会被 dispose
  /// （表现为滑到一半冻住、松手无反应）。宿主 element 稳定，控制器逐帧
  /// 重建只影响子树。
  Widget _buildArtworkStack(
    BuildContext context,
    PlaybackProvider playbackProvider,
  ) {
    // 飞行期间整层退出 hit test（中心点击/横滑/按压都冻结）。已按下的指针
    // 不会被 IgnorePointer 自动取消，隐藏翻转到 true 时由
    // [_controller.abortGestureForFlight] 主动收尾，避免拖动状态卡死。
    return IgnorePointer(
      ignoring: _pageCoverHidden,
      child: Listener(
        // DragGestureRecognizer 对「已接受」手势的 PointerCancel 也走 onEnd
        // （不是 onCancel），而 Listener 先于识别器收到取消事件：这里直接
        // 按取消处理并复位，随后识别器的 onEnd 因 dragActive=false 被忽略，
        // 避免系统打断被当成松手提交切歌。
        onPointerCancel: (_) => _controller.handleHorizontalDragCancel(),
        child: GestureDetector(
          key: PlayerCoverDeck.swipeHostKey,
          behavior: HitTestBehavior.opaque,
          // 从手指真实按下位置起算位移：默认的 start 会吃掉 touch slop，
          // 拖动距离与阈值判断都会缩小（110px 的滑动会被量成 80px）。
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: _controller.handleHorizontalDragStart,
          onHorizontalDragUpdate: _controller.handleHorizontalDragUpdate,
          onHorizontalDragEnd: _controller.handleHorizontalDragEnd,
          onHorizontalDragCancel: _controller.handleHorizontalDragCancel,
          child: Center(
            child: SizedBox(
              key: PlayerCoverDeck.stackKey,
              width: widget.stackDimension,
              height: widget.stackHeight,
              child: AnimatedBuilder(
                animation: _controller.stackAnimation,
                builder: (context, _) {
                  // 减弱动效直接落位（不订阅侧槽 reveal）。
                  final ValueListenable<double>? sideReveal =
                      reduceMotionOf(context)
                      ? null
                      : widget.morph?.pageDeckReveal;
                  final bool deckFrozen = _pageCoverHidden;
                  return DeckArtworkStack(
                    frame: _controller.artworkFrame(
                      snapshot: playbackProvider.snapshot,
                      displayTrack: widget.displayTrack,
                      sideReveal: sideReveal,
                      pageCoverHidden: _pageCoverHidden,
                      morphCoverKey: widget.morph?.pageCoverKey,
                    ),
                    playback: playbackProvider,
                    realCoverUrlOf: _realCoverUrlOf,
                    defaultCoverUrl: _coverResolver.defaultCoverUrl,
                    centerScaleAnimation: _controller.centerScaleAnimation,
                    playStateScaleAnimation:
                        _controller.playStateScaleAnimation,
                    pressScaleFor: _controller.pressScaleFor,
                    onPressStart: _controller.pressStart,
                    onPressEnd: _controller.pressEnd,
                    onTapCenter: () {
                      HapticsService.lightImpact();
                      playbackProvider.togglePlayPause();
                    },
                    // 左槽点击 = 上一首：只要展示了身份就可点；飞行期间
                    // 禁用点击（副本/锚点交接期间不接受切歌）。
                    onTapPrevious: !deckFrozen && playbackProvider.hasTrack
                        ? () {
                            HapticsService.lightImpact();
                            playbackProvider.skipToPrevious();
                          }
                        : null,
                    onTapNext: !deckFrozen && playbackProvider.hasTrack
                        ? () {
                            HapticsService.lightImpact();
                            playbackProvider.skipToNext();
                          }
                        : null,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
