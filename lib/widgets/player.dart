import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../managers/artwork_cache.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../models/play_mode.dart';
import '../services/data_saver_service.dart';
import '../services/haptics.dart';
import '../utils/responsive.dart';
import 'app_network_image.dart';
import 'cover_appearance.dart';
import 'icon_swap.dart';
import 'player_cover_deck.dart';
import 'player_morph.dart';

/// 迷你条封面外观与飞行定义在 `cover_appearance.dart`；这里再导出给既有
/// import 面（迷你封面回退图标尺寸等）。
export 'cover_appearance.dart' show miniCoverFallbackIconSize;

/// 迷你播放条高度（收起态）：展开/收起动画的迷你端基准，播放页共用。
const double miniPlayerHeight = 72;

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（与其它行组件同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

class Player extends StatefulWidget {
  final bool isLargeScreen;

  /// 封面区横向手势宿主 key（由封面堆叠模块持有）：拖动期间 element 必须
  /// 稳定（识别器不被 dispose），同时供测试精确定位这一层手势。
  static const Key artworkSwipeHostKey = PlayerCoverDeck.swipeHostKey;

  /// 顶栏共享元素控制器：为封面/歌名/进度提供锚点并接收隐藏状态。
  final PlayerMorphController? morph;

  /// 小屏完整页的展开进度（0=迷你、1=完整）；为 null 时直接渲染完整布局。
  ///
  /// 迷你/完整两套布局由同一控制器驱动：容器高度连续插值、封面飞行共享。
  final Animation<double>? expandAnimation;

  /// 迷你层被点击时请求展开（由宿主翻转 [expandAnimation]）。
  final VoidCallback? onToggleExpand;

  const Player({
    super.key,
    this.isLargeScreen = false,
    this.morph,
    this.expandAnimation,
    this.onToggleExpand,
  });

  @override
  State<Player> createState() => _PlayerState();
}

class _PlayerState extends State<Player> with TickerProviderStateMixin {
  Track? _lastTrack;

  /// 最近一次展示的封面地址：仅供迷你占位与预取复用（取色不在此处触发）。
  String? _lastImageUrl;

  // 标题单行 38、进度排 56、两者间距 14。
  static const double _textSectionHeight = 38;
  static const double _seekSectionHeight = 56;
  static const double _sectionsReservedHeight =
      _textSectionHeight + _seekSectionHeight + 14;

  /// 封面堆叠纵向余量：邻位封面缩放 0.78 + 旋转 0.05rad 后并不超出主封面
  /// 高度，纵向只留阴影的一点余量。
  static const double _artStackVerticalFactor = 1.06;

  /// 封面尺寸：宽向留出邻位封面（96），高向扣掉标题/进度排与阴影余量。
  double _artDimensionFor(double maxWidth, double maxHeight) {
    final double byWidth = max(0, maxWidth - 96);
    final double byHeight = maxHeight.isFinite
        ? max(0,
            (maxHeight - _sectionsReservedHeight) / _artStackVerticalFactor)
        : double.infinity;
    return min(byWidth, byHeight);
  }

  /// 完整播放器内容高度：高度贴合内容，避免大片留白。
  double _playerContentHeight(double art) =>
      art * _artStackVerticalFactor + _sectionsReservedHeight;

  /// 进度条拖动预览（毫秒）：非空时滑杆显示本地值、忽略 position 通道，
  /// 松手后提交 seek 并保留显示，直到 position 追上目标或超时。
  final _seekPreviewMs = ValueNotifier<double?>(null);
  int? _seekTargetMs;
  Timer? _seekSettleTimer;
  ValueListenable<Duration>? _positionListenable;

  /// 迷你 ⇄ 完整切换时的封面飞行：两端锚点与页内 Stack 坐标系。
  final GlobalKey _playerStackKey = GlobalKey(debugLabel: 'playerStack');
  final GlobalKey _miniCoverKey = GlobalKey(debugLabel: 'miniCover');
  final GlobalKey _fullCoverKey = GlobalKey(debugLabel: 'fullCover');
  Rect? _coverFlightFrom;
  Rect? _coverFlightTo;
  bool _coverFlightActive = false;

  /// 本次封面飞行的终点端：true = 收起（终点迷你），false = 展开（终点完整）。
  /// 用于按「进度到达终端阈值」结束飞行，不等弹簧容差拖尾。
  bool _coverFlightToMini = false;

  /// 切歌入场：M3E no-overshoot spatial 弹簧（aospSpatial 380/1.0）驱动文字
  /// 轻量上移落位 + 同源淡入，与封面切歌同帧启动；连续切歌带速度续跑。
  /// 弹簧保持无过冲是刻意的设计意图。
  late SingleMotionController _trackEntrance;

  /// 页面可见性（TickerMode）：隐藏时标题入场直接落位，不冻结等回到页面再播。
  bool _tickersEnabled = true;

  @override
  void initState() {
    super.initState();
    _trackEntrance = SingleMotionController(
      motion:
          SpringMotion(M3EMotion.aospSpatial.toDescription(), snapToEnd: true),
      vsync: this,
      initialValue: 1,
    );

    widget.expandAnimation?.addStatusListener(_handleExpandStatus);
    widget.expandAnimation?.addListener(_handleExpandValue);

    _positionListenable = context.read<PlaybackProvider>().position;
    _positionListenable!.addListener(_handlePositionTick);

    if (_lastImageUrl != null) {
      _prefetchImage(_lastImageUrl!);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
  }

  /// seek 提交后，position 追上目标（或超时兜底）才撤下预览，
  /// 避免滑杆在通道追上之前回跳到旧位置。
  void _handlePositionTick() {
    final target = _seekTargetMs;
    if (target == null) return;
    final current = _positionListenable?.value.inMilliseconds ?? 0;
    if ((current - target).abs() <= 800) {
      _seekTargetMs = null;
      _seekSettleTimer?.cancel();
      _seekPreviewMs.value = null;
    }
  }

  /// 松手提交 seek：保留拖动值显示直到 position 追上。
  void _commitSeek(double value, PlaybackProvider playbackProvider) {
    final target = value.round();
    _seekTargetMs = target;
    _seekPreviewMs.value = value;
    _seekSettleTimer?.cancel();
    _seekSettleTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_seekTargetMs != target) return;
      _seekTargetMs = null;
      _seekPreviewMs.value = null;
    });
    playbackProvider.seekToPosition(target);
  }

  @override
  void didUpdateWidget(covariant Player oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandAnimation != widget.expandAnimation) {
      oldWidget.expandAnimation?.removeStatusListener(_handleExpandStatus);
      oldWidget.expandAnimation?.removeListener(_handleExpandValue);
      widget.expandAnimation?.addStatusListener(_handleExpandStatus);
      widget.expandAnimation?.addListener(_handleExpandValue);
    }
  }

  /// 迷你/完整切换开始：抓取两端封面矩形，交由页内 Stack 飞行；
  /// 视觉落定即撤下副本（[_handleExpandValue]），状态回调仅兜底。
  ///
  /// 侧邻位没有独立入场演出：随页面层/完整层自身淡入以稳态出现。
  void _handleExpandStatus(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        // 同一份锚点几何实现（含祖先缩放的两角映射）；这里取页内 Stack 本地坐标。
        final from =
            anchorRectOf(_miniCoverKey, container: _playerStackKey);
        final to = anchorRectOf(_fullCoverKey, container: _playerStackKey);
        if (from == null || to == null) return;
        setState(() {
          _coverFlightFrom = from;
          _coverFlightTo = to;
          _coverFlightActive = true;
          // 起点进度决定结束端：从完整态出发 = 收起，从迷你态出发 = 展开。
          _coverFlightToMini =
              (widget.expandAnimation?.value ?? 0) >= 0.5;
        });
      case AnimationStatus.completed:
      case AnimationStatus.dismissed:
        _endCoverFlight();
    }
  }

  /// 进度到达终端阈值（~0.5%）即结束飞行。
  ///
  /// 弹簧的容差拖尾让落定状态晚于视觉落定（~0.35s），不能让真身封面
  /// 一直被副本顶替（期间点击封面会落空）。
  void _handleExpandValue() {
    if (!_coverFlightActive) return;
    final double value = widget.expandAnimation?.value ?? 0;
    if (_coverFlightToMini ? value <= 0.005 : value >= 0.995) {
      _endCoverFlight();
    }
  }

  void _endCoverFlight() {
    if (!_coverFlightActive) return;
    setState(() {
      _coverFlightActive = false;
      _coverFlightFrom = null;
      _coverFlightTo = null;
    });
  }

  Future<void> _prefetchImage(String imageUrl) async {
    // 省流模式（移动数据 + 已开启封面省流）：跳过封面预取
    // （ArtworkCache 网关在只读缓存未命中时会抛错，这里提前拦截）。
    if (context.read<DataSaverService?>()?.blockNetworkArtwork ?? false) {
      return;
    }
    // 与封面显示完全同键（共享 CacheManager、无缩放）：预取才能命中
    // 后续 AppNetworkImage / 飞行副本的 ImageCache 查询，避免无效下载。
    final provider = await artworkImageProvider(imageUrl);
    if (!mounted) return;
    await precacheImage(provider, context);
  }

  @override
  void dispose() {
    widget.expandAnimation?.removeStatusListener(_handleExpandStatus);
    widget.expandAnimation?.removeListener(_handleExpandValue);
    _positionListenable?.removeListener(_handlePositionTick);
    _seekSettleTimer?.cancel();
    _seekPreviewMs.dispose();
    _trackEntrance.dispose();
    super.dispose();
  }

  /// 封面切换时的显示预取：与显示路径完全同键，命中的图直接进 ImageCache。
  ///
  /// 取色不在这里触发：composition root 的 `ArtworkThemeSync` 监听
  /// PlaybackProvider（任何页面/后台切歌都走同一条取色链路，省流时读本地
  /// 缓存，未命中保持现色）。这里只负责预取，让 AppNetworkImage / 飞行副本
  /// 复用同一张已解码图。
  void _prefetchArtworkIfNeeded(BuildContext context, Track? displayTrack) {
    final currentImageUrl = artworkUrlOf(displayTrack);
    if (currentImageUrl == null || currentImageUrl == _lastImageUrl) return;
    _lastImageUrl = currentImageUrl;
    // 省流模式（移动数据 + 已开启封面省流）：跳过封面预取
    // （ArtworkCache 网关在只读缓存未命中时会抛错，这里提前拦截）。
    if (context.read<DataSaverService?>()?.blockNetworkArtwork ?? false) {
      return;
    }
    _prefetchImage(currentImageUrl);
  }

  /// 歌手展示名（唯一词表 [Track.artistLabel]；无有效歌手回退 l10n 兜底）。
  static String _artistsLabel(BuildContext context, Track track) {
    final label = track.artistLabel;
    return label.isEmpty ? _l10n(context).unknownArtist : label;
  }

  /// 封面模块的切歌联动（切歌帧的 post-frame 触发）：清掉进度拖动预览、
  /// 非拖动中切换时启动标题入场（拖动中让位拖动预览）。
  void _handleTrackSwapped(bool duringDrag) {
    _clearSeekPreviewAfterTrackChange();
    if (duringDrag) return;
    if (_tickersEnabled) {
      _trackEntrance.animateTo(1, from: 0, withVelocity: 0);
    } else {
      // 页面不可见：直接落位，避免回到播放页时标题再弹一遍。
      _trackEntrance.value = 1.0;
    }
  }

  /// 切歌后清掉进度拖动预览，避免旧进度残留在滑杆上。
  void _clearSeekPreviewAfterTrackChange() {
    _seekTargetMs = null;
    _seekSettleTimer?.cancel();
    _seekPreviewMs.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlaybackProvider, Track?>(
        (provider) => provider.snapshot.current);

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    final displayTrack = track ?? _lastTrack;
    if (track != null) {
      _lastTrack = track;
    }

    // 封面预取（显示路径；取色由组合根的 ArtworkThemeSync 统一触发）
    _prefetchArtworkIfNeeded(context, displayTrack);

    if (widget.isLargeScreen) {
      return RepaintBoundary(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _buildLargeScreenPlayerLayout(displayTrack, playbackProvider),
          ),
        ),
      );
    }

    final expand = widget.expandAnimation;
    if (expand == null) {
      return RepaintBoundary(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: double.infinity),
            child:
                _buildSmallScreenPlayerLayout(displayTrack, playbackProvider),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: _buildExpandableSmallScreenLayout(
        displayTrack,
        playbackProvider,
        expand,
      ),
    );
  }

  /// 小屏完整播放器：三封面堆叠 → 标题/作者（单行）→ 可拖动进度排。
  ///
  /// 高度感知：可用高度（NowPlaying 传入的 maxHeight）不足时收缩封面，
  /// 避免进度排把歌词区挤出屏幕。
  Widget _buildSmallScreenPlayerLayout(
    Track? displayTrack,
    PlaybackProvider playbackProvider, {
    PlayerMorphController? morph,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double artDimension =
            _artDimensionFor(constraints.maxWidth, constraints.maxHeight);
        // 宽度方向仍需留出邻位封面露出的边（横向 1.38），纵向只留阴影余量。
        final double stackDimension = artDimension * 1.38;
        final double stackHeight =
            artDimension * _artStackVerticalFactor;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PlayerCoverDeck(
              displayTrack: displayTrack,
              artDimension: artDimension,
              stackDimension: stackDimension,
              stackHeight: stackHeight,
              fullCoverKey: _fullCoverKey,
              isLargeScreen: widget.isLargeScreen,
              morph: morph,
              coverFlightActive: _coverFlightActive,
              onTrackSwapped: _handleTrackSwapped,
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildTrackInfo(context, displayTrack, playbackProvider),
            ),
            const SizedBox(height: 2),
            _buildSeekBar(context, playbackProvider),
          ],
        );
      },
    );
  }

  /// 迷你 ⇄ 完整：同一控制器驱动容器高度、交叉淡化与封面飞行。
  ///
  /// 两套布局始终挂载（完整层按最终高度布局、顶部对齐裁剪），高度连续过渡；
  /// 封面由页内飞行副本在两端锚点间插值，两套布局共享同一次飞行。
  Widget _buildExpandableSmallScreenLayout(
    Track? displayTrack,
    PlaybackProvider playbackProvider,
    Animation<double> expand,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double fullHeight = constraints.maxHeight.isFinite
            ? min(
                constraints.maxHeight,
                _playerContentHeight(_artDimensionFor(
                    constraints.maxWidth, constraints.maxHeight)),
              )
            : 560.0;
        return AnimatedBuilder(
          animation: expand,
          builder: (context, _) {
            // motor 弹簧进度即运动曲线；截断 0..1：
            // 高度不过冲，避免内容区随过冲回流；透明度由同一进度派生。
            final double t = expand.value.clamp(0.0, 1.0);
            final double height = lerpDouble(miniPlayerHeight, fullHeight, t)!;
            final double miniOpacity =
                1 - Curves.easeOutCubic.transform((t / 0.45).clamp(0.0, 1.0));
            final double fullOpacity = Curves.easeInCubic
                .transform(((t - 0.35) / 0.65).clamp(0.0, 1.0));
            final Rect? flightRect =
                (_coverFlightActive && _coverFlightFrom != null && _coverFlightTo != null)
                    ? Rect.lerp(_coverFlightFrom!, _coverFlightTo!, t)
                    : null;
            // 展开完成才挂 morph 锚点：迷你态下顶栏⇄播放页飞行应走
            // 「跳过」路径，避免飞到不可见的完整封面锚点。
            final PlayerMorphController? morph =
                t >= 1.0 ? widget.morph : null;
            return SizedBox(
              height: height,
              child: ClipRect(
                child: Stack(
                  key: _playerStackKey,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // 完整层：始终按最终高度布局，避免过渡中重排封面。
                    Positioned.fill(
                      child: OverflowBox(
                        minHeight: fullHeight,
                        maxHeight: fullHeight,
                        alignment: Alignment.topCenter,
                        child: ExcludeSemantics(
                          excluding: t < 0.5,
                          child: IgnorePointer(
                            ignoring: t < 0.5,
                            child: Opacity(
                              opacity: fullOpacity,
                              child: _buildSmallScreenPlayerLayout(
                                displayTrack,
                                playbackProvider,
                                morph: morph,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 迷你层：固定 72，点击整条即展开。
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: miniPlayerHeight,
                      child: ExcludeSemantics(
                        excluding: t >= 0.5,
                        child: IgnorePointer(
                          ignoring: t >= 0.5,
                          child: Opacity(
                            opacity: miniOpacity,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onToggleExpand,
                              child: _buildMiniPlayer(
                                  context, displayTrack, playbackProvider),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 共享封面飞行副本：真实封面在飞行期间隐藏。
                    if (flightRect != null)
                      CoverFlightLayer(
                        animation: expand,
                        flight: CoverFlight(
                          otherRect: _coverFlightFrom!,
                          pageRect: _coverFlightTo!,
                          otherAppearance: CoverAppearance.mini,
                          toPage: true,
                        ),
                        url: artworkUrlOf(displayTrack),
                        // 两真身都是主题默认封面（最近播放图/标志）。
                        fallback: (context, iconSize) =>
                            buildDefaultArtwork(context, iconSize: iconSize),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 进度排：收藏（左）+ 可拖动波浪进度（中）+ 播放模式（右）。
  ///
  /// 拖动期间本地预览、松手才提交 seek。
  Widget _buildSeekBar(
    BuildContext context,
    PlaybackProvider playbackProvider,
  ) {
    final mode = context.select<PlaybackProvider, PlayMode>(
        (provider) => provider.currentMode);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          _buildFavoriteButton(),
          const SizedBox(width: 4),
          Expanded(child: _buildSeekSlider(context, playbackProvider)),
          const SizedBox(width: 4),
          _buildModeButton(context, mode, () {
            HapticsService.lightImpact();
            playbackProvider.togglePlayMode();
          }),
        ],
      ),
    );
  }

  /// 播放模式：与收藏同一套简单图标按钮。
  Widget _buildModeButton(
      BuildContext context, PlayMode mode, VoidCallback onPressed) {
    final l10n = AppLocalizations.of(context);
    final label = switch (mode) {
      PlayMode.sequential => l10n?.playModeSequential,
      PlayMode.shuffle => l10n?.playModeShuffle,
      PlayMode.singleRepeat => l10n?.playModeSingleRepeat,
    };
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: M3EIconButtonSize.sm,
      visualSize: const Size(44, 44),
      // 颜色交给 standard 变体默认值（不手写 primary 强调）。
      icon: IconSwap<PlayMode>(
        value: mode,
        builder: (context, mode) => Icon(_getPlayModeIcon(mode)),
      ),
      tooltip: label,
      onPressed: onPressed,
    );
  }

  /// 可拖动进度滑杆：拖动中显示本地值（不被 position 通道回拽），
  /// 松手提交 seek；拖动气泡显示目标时间。
  ///
  /// 外层 `RepaintBoundary` 是硬需求：`M3ESlider.wavy` 内部是 `repeat()` 的
  /// 无限动画（包内每帧重建/重绘轨道），不隔离的话播放中每次波形重绘都会把
  /// 整个播放器（封面 + 阴影 + 文字）卷进同一图层重光栅化。
  Widget _buildSeekSlider(
      BuildContext context, PlaybackProvider playbackProvider) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double?>(
        valueListenable: _seekPreviewMs,
        builder: (context, previewMs, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: playbackProvider.position,
            builder: (context, position, _) {
              final (durationMs, isPlaying) =
                  context.select<PlaybackProvider, (int, bool)>(
                (provider) => (
                  provider.snapshot.duration.inMilliseconds,
                  provider.isPlaying,
                ),
              );
              final bool enabled = playbackProvider.hasTrack && durationMs > 0;
              final double maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
              final double valueMs =
                  (previewMs ?? position.inMilliseconds.toDouble())
                      .clamp(0.0, maxMs);
              final ValueChanged<double>? onChanged = enabled
                  ? (value) {
                      // 新拖动作废上一次的等待落点。
                      _seekTargetMs = null;
                      _seekSettleTimer?.cancel();
                      _seekPreviewMs.value = value;
                    }
                  : null;
              final ValueChanged<double>? onChangeEnd = enabled
                  ? (value) => _commitSeek(value, playbackProvider)
                  : null;

              // 暂停时切到平直滑杆：波浪动画不会停（一直在动），
              // 与「已暂停」的状态自相矛盾。
              if (!isPlaying) {
                return M3ESlider(
                  value: valueMs,
                  min: 0,
                  max: maxMs,
                  size: M3ESliderSize.xs,
                  trackThickness: 6,
                  enabled: enabled,
                  label: _formatSeekTime(valueMs.round()),
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                );
              }
              return M3ESlider.wavy(
                value: valueMs,
                min: 0,
                max: maxMs,
                size: M3ESliderSize.xs,
                trackThickness: 6,
                enabled: enabled,
                label: _formatSeekTime(valueMs.round()),
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              );
            },
          );
        },
      ),
    );
  }

  /// 拖动气泡时间：m:ss。
  String _formatSeekTime(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 标题/作者：单行「歌名 · 作者」+ 无过冲轻量入场（上移 14px）。
  Widget _buildTrackInfo(
    BuildContext context,
    Track? displayTrack,
    PlaybackProvider playbackProvider,
  ) {
    return AnimatedBuilder(
      animation: _trackEntrance,
      builder: (context, child) {
        final t = _trackEntrance.value;
        return Transform.translate(
          offset: Offset(0, (1 - t) * 14),
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: _buildTrackInfoText(context, displayTrack, playbackProvider),
    );
  }

  /// 「歌名 · 作者」单行块：超长省略（单行是为了给歌词/队列让出纵向空间）。
  ///
  /// 标题块不带左侧竖条：它与进度把手同宽、同色、同形，上下相邻时会被读成
  /// 重复元素（用户反馈的「两根竖条」），且形似可拖动的把手却不可交互；
  /// 强调色只留给可交互控件（波浪进度/把手）。
  Widget _buildTrackInfoText(
    BuildContext context,
    Track? displayTrack,
    PlaybackProvider playbackProvider,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final header = displayTrack?.title ??
        playbackProvider.lastPlayedTrackName ??
        'No track playing';
    final artistText = displayTrack != null
        ? _artistsLabel(context, displayTrack)
        : playbackProvider.lastPlayedArtists ?? _l10n(context).unknownArtist;

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: header,
            // 标题/作者与全 App 文本契约一致：onSurface / onSurfaceVariant；
            // 强调色只给可交互控件（进度波浪/把手）。
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
          ),
          if (artistText.isNotEmpty)
            TextSpan(
              text: '  ·  $artistText',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  IconData _getPlayModeIcon(PlayMode mode) {
    switch (mode) {
      case PlayMode.shuffle:
        return Icons.shuffle_rounded;
      case PlayMode.sequential:
        return Icons.repeat_rounded;
      case PlayMode.singleRepeat:
        return Icons.repeat_one_rounded;
    }
  }

  /// 本地收藏按钮：加入/移出默认收藏列表（无当前曲目/资料库时隐藏）。
  Widget _buildFavoriteButton({
    M3EIconButtonSize size = M3EIconButtonSize.sm,
    Size visualSize = const Size(44, 44),
  }) =>
      _FavoriteButton(size: size, visualSize: visualSize);

  Widget _buildMiniPlayer(
    BuildContext context,
    Track? track,
    PlaybackProvider playback,
  ) {
    final isPlaying = context.select<PlaybackProvider, bool>(
        (provider) => provider.isPlaying);

    return SizedBox(
      height: miniPlayerHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.isCompact ? 8 : 16,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
          // 卡片外观（外边圆角 8、裁剪 8、回退图标 24）由 CoverAppearance.mini
          // 统一给出；迷你 ⇄ 完整飞行期间真身隐藏，由飞行副本承接。
          Opacity(
            opacity: _coverFlightActive ? 0 : 1,
            child: CoverCard(
              key: _miniCoverKey,
              size: 48,
              appearance: CoverAppearance.mini,
              content: (context, clip, iconSize) =>
                  _buildMiniAlbumArt(track, iconSize),
            ),
          ),
          SizedBox(width: context.isCompact ? 8 : 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track?.title ??
                      playback.lastPlayedTrackName ??
                      'No track playing',
                  // 迷你条文本与列表页契约一致：标题 onSurface、
                  // 作者 onSurfaceVariant，强调色只给控件。
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  track != null
                      ? _artistsLabel(context, track)
                      : playback.lastPlayedArtists ??
                          _l10n(context).unknownArtist,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _buildResponsiveControlButtons(context, playback, isPlaying),
                ],
              ),
            ),
          ),
          // 收起态也要有进度：细波浪线贴底常显（展开后可拖动 seek）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 10,
            child: _buildMiniProgress(context, playback),
          ),
        ],
      ),
    );
  }

  /// 迷你条底部细进度线。
  ///
  /// 播放中用波浪线（与全屏滑杆一致）；暂停时切平直线——波浪动画不会停，
  /// 会让人以为还在播放。外层 `RepaintBoundary` 把无限波浪动画的重绘限制在
  /// 进度线面积内（理由同全屏滑杆）。
  Widget _buildMiniProgress(BuildContext context, PlaybackProvider playback) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playback.position,
        builder: (context, position, _) {
          final (durationMs, isPlaying) =
              context.select<PlaybackProvider, (int, bool)>(
            (provider) => (
              provider.snapshot.duration.inMilliseconds,
              provider.isPlaying,
            ),
          );
          if (durationMs <= 0) {
            // 无曲目/无时长：只画静态轨道，避免不确定波浪动画抢视线。
            return Center(
              child: Container(
                width: double.infinity,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }
          final double fraction =
              (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
          if (!isPlaying) {
            return M3EProgressIndicator.linear(
              value: fraction,
              linearSize: M3EProgressIndicatorSize.s,
              strokeWidth: 3,
              trackStrokeWidth: 3,
              trackColor: scheme.surfaceContainerHighest,
              color: scheme.primary,
            );
          }
          return M3EProgressIndicator.linearWavy(
            value: fraction,
            linearSize: M3EProgressIndicatorSize.s,
            strokeWidth: 3,
            trackStrokeWidth: 3,
            trackColor: scheme.surfaceContainerHighest,
            color: scheme.primary,
          );
        },
      ),
    );
  }

  /// 迷你播放器控制排：与全屏控制排同序（收藏/上一首/播放/下一首）、同风格；
  /// 极窄屏退化为仅播放键。
  Widget _buildResponsiveControlButtons(
    BuildContext context,
    PlaybackProvider playback,
    bool isPlaying,
  ) {
    if (context.isCompact) {
      return _buildPlayPauseButton(
        context,
        playback,
        isPlaying,
        size: M3EIconButtonSize.xs,
        visualSize: const Size(36, 36),
      );
    }
    final bool narrow = context.isNarrow;
    final visualSize = narrow ? const Size(32, 32) : const Size(40, 40);
    final size = narrow ? M3EIconButtonSize.xs : M3EIconButtonSize.sm;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildFavoriteButton(
          size: size,
          visualSize: visualSize,
        ),
        _buildMiniIconControl(
          context,
          icon: Icons.skip_previous_rounded,
          size: size,
          visualSize: visualSize,
          onPressed: () {
            HapticsService.lightImpact();
            playback.skipToPrevious();
          },
        ),
        _buildPlayPauseButton(
          context,
          playback,
          isPlaying,
          size: size,
          visualSize: visualSize,
        ),
        _buildMiniIconControl(
          context,
          icon: Icons.skip_next_rounded,
          size: size,
          visualSize: visualSize,
          onPressed: () {
            HapticsService.lightImpact();
            playback.skipToNext();
          },
        ),
      ],
    );
  }

  Widget _buildMiniIconControl(
    BuildContext context, {
    required IconData icon,
    required M3EIconButtonSize size,
    required Size visualSize,
    required VoidCallback onPressed,
  }) {
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: size,
      visualSize: visualSize,
      // 图标颜色交给 standard 变体默认值。
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  Widget _buildPlayPauseButton(
    BuildContext context,
    PlaybackProvider playback,
    bool isPlaying, {
    required M3EIconButtonSize size,
    required Size visualSize,
  }) {
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: size,
      visualSize: visualSize,
      icon: IconSwap<bool>(
        value: isPlaying,
        builder: (context, isPlaying) => Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          // 颜色交给 standard 变体默认值。
        ),
      ),
      onPressed: () {
        HapticsService.lightImpact();
        playback.togglePlayPause();
      },
    );
  }

  Widget _buildMiniAlbumArt(Track? track, double iconSize) {
    final displayTrack = track ?? _lastTrack;
    final String? currentImageUrl = artworkUrlOf(displayTrack);

    // 不缩放：与顶栏/播放页/预加载共用同一 ImageCache 键，
    // 迷你 ⇄ 完整飞行与切歌动画才能复用同一张已解码图。
    return AppNetworkImage(
      key: ValueKey(currentImageUrl),
      url: currentImageUrl,
      fit: BoxFit.cover,
      fallbackIconSize: iconSize,
      placeholder: _lastTrack != null && _lastImageUrl != null
          ? AppNetworkImage(
              url: _lastImageUrl,
              fit: BoxFit.cover,
              fallbackIconSize: iconSize,
            )
          : buildDefaultArtwork(context),
      errorWidget: buildDefaultArtwork(context),
    );
  }

  /// 大屏全屏播放器：与小屏同构（三封面堆叠 → 标题/作者 → 可拖动进度排），
  /// 封面按两轴可用空间自适应。
  Widget _buildLargeScreenPlayerLayout(
      Track? displayTrack, PlaybackProvider playbackProvider) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double textSectionFixedHeight = 56.0;
        const double seekSectionHeight = 56.0;
        const double spacingBelowArt = 2.0;
        const double artExternalPaddingHorizontal = 48.0 * 2;
        const double artExternalPaddingVertical = 24.0 * 2;

        double artContentAvailableWidth =
            constraints.maxWidth - artExternalPaddingHorizontal;
        double artContentAvailableHeight = constraints.maxHeight -
            textSectionFixedHeight -
            seekSectionHeight -
            spacingBelowArt -
            artExternalPaddingVertical;
        artContentAvailableWidth = max(0, artContentAvailableWidth);
        artContentAvailableHeight = max(0, artContentAvailableHeight);
        // 纵向同样只留阴影余量（与小屏一致）。
        double artDimension = min(artContentAvailableWidth,
            artContentAvailableHeight / _artStackVerticalFactor);
        artDimension = max(0, artDimension);

        final double stackDimension = artDimension * 1.38;
        final double stackHeight = artDimension * _artStackVerticalFactor;

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            PlayerCoverDeck(
              displayTrack: displayTrack,
              artDimension: artDimension,
              stackDimension: stackDimension,
              stackHeight: stackHeight,
              fullCoverKey: _fullCoverKey,
              isLargeScreen: widget.isLargeScreen,
              morph: widget.morph,
              coverFlightActive: _coverFlightActive,
              onTrackSwapped: _handleTrackSwapped,
            ),
            const SizedBox(height: spacingBelowArt),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildTrackInfo(context, displayTrack, playbackProvider),
            ),
            const SizedBox(height: spacingBelowArt),
            _buildSeekBar(context, playbackProvider),
          ],
        );
      },
    );
  }
}

/// 收藏按钮独立成组件：布局在 [LayoutBuilder] 内构建时，
/// `context.select` 必须发生在组件自身 build 中（State.context 在布局阶段
/// 使用会被 provider 断言拦截）。
///
/// 收藏反馈只靠图标态（实心/空心），不弹 Snackbar。
/// 写路径唯一：`LibraryProvider.toggleFavoriteTrack`（播放页不直连仓库）。
class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({
    this.size = M3EIconButtonSize.sm,
    this.visualSize = const Size(44, 44),
  });

  final M3EIconButtonSize size;
  final Size visualSize;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    final track = context.select<PlaybackProvider, Track?>(
        (provider) => provider.snapshot.current);
    if (library == null || track == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('zh'));
    final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: size,
      visualSize: visualSize,
      icon: IconSwap<bool>(
        value: favorite,
        // 与收藏页行内心形同一契约：已收藏 primary、未收藏 onSurfaceVariant。
        builder: (context, favorite) => Icon(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: favorite
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      tooltip: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: () async {
        HapticsService.lightImpact();
        await library.toggleFavoriteTrack(track);
      },
    );
  }
}
