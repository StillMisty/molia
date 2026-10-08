import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../managers/artwork_cache.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../models/play_mode.dart';
import '../providers/theme_provider.dart';
import '../services/data_saver_service.dart';
import '../utils/responsive.dart';
import 'app_network_image.dart';
import 'molia_mark.dart';
import 'player_morph.dart';

/// 迷你播放条高度（收起态）：展开/收起动画的迷你端基准，播放页共用。
const double miniPlayerHeight = 72;

class Player extends StatefulWidget {
  final bool isLargeScreen;

  /// 顶栏共享元素控制器：为封面/歌名/进度提供锚点并接收隐藏状态。
  final PlayerMorphController? morph;

  /// 小屏完整页的展开进度（0=迷你、1=完整）；为 null 时直接渲染完整布局。
  ///
  /// 迷你/完整两套布局由同一控制器驱动：容器高度连续插值、封面飞行共享，
  /// 不再是两棵独立子树的 150ms 纯淡入淡出。
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
  double? _dragStartX;
  double? _dragStartY;
  bool _isHorizontalDragConfirmed = false;
  double _dragDx = 0;
  Track? _lastTrack;
  String? _lastImageUrl;
  String? _previousImageUrl;
  bool _isThemeUpdating = false;
  late AnimationController _playStateController;
  late Animation<double> _playStateScaleAnimation;

  // ---- 完整播放器布局（小屏） ----
  // 标题单行 38、进度排 56、两者间距 14。
  static const double _textSectionHeight = 38;
  static const double _seekSectionHeight = 56;
  static const double _sectionsReservedHeight =
      _textSectionHeight + _seekSectionHeight + 14;

  /// 封面堆叠纵向余量：邻位封面缩放 0.78 + 旋转 0.05rad 后并不超出主封面
  /// 高度，纵向只留阴影的一点余量（旧的 1.38 上下留白全在白占空间）。
  static const double _artStackVerticalFactor = 1.06;

  /// 当前布局使用的封面边长（拖动跟手换算拖动行程时需要）。
  double _lastArtDimension = 0;

  /// 封面尺寸：宽向留出邻位封面（96），高向扣掉标题/进度排与阴影余量。
  double _artDimensionFor(double maxWidth, double maxHeight) {
    final double byWidth = max(0, maxWidth - 96);
    final double byHeight = maxHeight.isFinite
        ? max(0,
            (maxHeight - _sectionsReservedHeight) / _artStackVerticalFactor)
        : double.infinity;
    return min(byWidth, byHeight);
  }

  /// 完整播放器内容高度：播放器贴合内容，不再留出大片空白。
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

  /// 切歌入场：spring 过冲（easeOutBack）驱动文字错位落位。
  late AnimationController _trackEntranceController;
  late Animation<double> _trackEntrance;
  String? _lastAnimatedTrackId;

  /// 三封面堆叠：切歌时当前滑出、邻位进中、新邻位浮现。
  late AnimationController _coverController;
  Track? _previousTrack;
  Track? _outgoingTrack;
  Track? _oldNeighbor;
  Track? _lastNextTrack;
  int _coverDirection = 1; // 1 = 下一首（向左滑出），-1 = 上一首

  /// 横向拖动跟手：拖动期间由手指驱动 [_coverController] 的进度，
  /// 中心位显示邻位封面（松手后才真正切歌）。
  bool _draggingCover = false;

  /// 手指是否仍在拖动（用于区分「拖动进行中」与「松手后等待切歌的预览」）。
  bool _dragActive = false;

  /// 本次拖动触发了切歌：动画已完成（画面即最终态）时不重放过渡。
  bool _dragTriggeredSkip = false;

  /// 拖动切歌的兜底计时器：取链失败等情况下不能永远停在邻位预览。
  Timer? _dragPendingTimer;

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

    _trackEntranceController = AnimationController(
      duration: const Duration(milliseconds: 650),
      vsync: this,
    )..value = 1.0;
    _trackEntrance = CurvedAnimation(
      parent: _trackEntranceController,
      curve: Curves.easeOutBack,
    );

    _coverController = AnimationController(
      duration: const Duration(milliseconds: 460),
      vsync: this,
    )..value = 1.0;

    widget.expandAnimation?.addStatusListener(_handleExpandStatus);
    // 顶栏⇄播放页飞行时只有封面隐藏：必须监听 morph 控制器才能重建真身。
    widget.morph?.addListener(_onMorphChanged);

    _positionListenable = context.read<PlaybackProvider>().position;
    _positionListenable!.addListener(_handlePositionTick);

    if (_lastImageUrl != null) {
      _prefetchImage(_lastImageUrl!);
    }
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
      widget.expandAnimation?.addStatusListener(_handleExpandStatus);
    }
    if (oldWidget.morph != widget.morph) {
      oldWidget.morph?.removeListener(_onMorphChanged);
      widget.morph?.addListener(_onMorphChanged);
    }
  }

  void _onMorphChanged() {
    if (mounted) setState(() {});
  }

  /// 迷你/完整切换开始：抓取两端封面矩形，交由页内 Stack 飞行；
  /// 结束：撤下飞行副本，恢复真身封面。
  void _handleExpandStatus(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        final from = _localRectOf(_miniCoverKey);
        final to = _localRectOf(_fullCoverKey);
        if (from == null || to == null) return;
        setState(() {
          _coverFlightFrom = from;
          _coverFlightTo = to;
          _coverFlightActive = true;
        });
      case AnimationStatus.completed:
      case AnimationStatus.dismissed:
        if (!_coverFlightActive) return;
        setState(() {
          _coverFlightActive = false;
          _coverFlightFrom = null;
          _coverFlightTo = null;
        });
    }
  }

  /// 元素相对播放器 Stack 的本地矩形（飞行副本定位用）。
  Rect? _localRectOf(GlobalKey key) {
    final stackBox =
        _playerStackKey.currentContext?.findRenderObject() as RenderBox?;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || box == null || !box.hasSize) return null;
    final topLeft = stackBox.globalToLocal(box.localToGlobal(Offset.zero));
    return topLeft & box.size;
  }

  Future<void> _prefetchImage(String imageUrl) async {
    // 省流模式（移动数据 + 已开启封面省流）：跳过封面预取
    // （ArtworkCache 网关在只读缓存未命中时会抛错，这里提前拦截）。
    if (context.read<DataSaverService?>()?.blockNetworkArtwork ?? false) {
      return;
    }
    // 与封面显示完全同键（共享 CacheManager、无缩放）：预取才真正命中
    // 后续 AppNetworkImage / 飞行副本的 ImageCache 查询，不再白下载。
    final provider = await artworkImageProvider(imageUrl);
    if (!mounted) return;
    await precacheImage(provider, context);
  }

  /// 构建默认/回退图像 Widget
  /// 优先使用持久化的最后播放图像；没有（或加载失败）时用中性图标占位。
  Widget _buildDefaultImage({Key? key, BoxFit fit = BoxFit.cover}) {
    final lastPlayedImageUrl =
        context.read<PlaybackProvider>().lastPlayedImageUrl;
    if (lastPlayedImageUrl != null) {
      return AppNetworkImage(
        key: key ?? const ValueKey('last_played_image'),
        url: lastPlayedImageUrl,
        fit: fit,
        fallbackIconSize: 64,
        errorWidget: _buildFallbackArtwork(key: key),
      );
    }
    return _buildFallbackArtwork(key: key ?? const ValueKey('default_image'));
  }

  /// 无封面时的中性占位：主题容器色背景 + Molia 标志。
  Widget _buildFallbackArtwork({Key? key}) {
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

  @override
  void dispose() {
    widget.expandAnimation?.removeStatusListener(_handleExpandStatus);
    widget.morph?.removeListener(_onMorphChanged);
    _positionListenable?.removeListener(_handlePositionTick);
    _seekSettleTimer?.cancel();
    _dragPendingTimer?.cancel();
    _seekPreviewMs.dispose();
    _playStateController.dispose();
    _trackEntranceController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
    _dragTriggeredSkip = false;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragStartX == null || _dragStartY == null) return;

    final dx = details.globalPosition.dx - _dragStartX!;
    final dy = details.globalPosition.dy - _dragStartY!;

    if (!_isHorizontalDragConfirmed) {
      if (dy.abs() > dx.abs() * 1.5) {
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

  /// 拖动跟手：中心位换邻位封面、按滑动距离过渡（与切歌动画同一进度）。
  void _updateDragPreview(double dx) {
    _dragActive = true;
    if (!_draggingCover) {
      _draggingCover = true;
      _coverController.stop();
    }
    final int dir = dx < 0 ? 1 : -1; // 左滑 = 下一首
    if (dir != _coverDirection || _outgoingTrack == null) {
      _coverDirection = dir;
      // 拖动预览里「滑出」的是当前封面；反向侧旧邻位让位。
      _outgoingTrack = _lastTrack;
      _oldNeighbor = dir == 1 ? _previousTrack : _lastNextTrack;
    }
    // 拖动行程：约 0.6 个封面宽度走完整段过渡。
    final double range = max(48.0, _lastArtDimension * 0.6);
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

  /// 松手：达标则从当前拖动进度续播到落位并切歌；未达标回弹。
  void _handleHorizontalDragEnd(
      DragEndDetails details, PlaybackProvider playback) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dx = _dragDx;
    final confirmed = _isHorizontalDragConfirmed;
    final wasDragging = _draggingCover;
    _resetHorizontalDrag();
    if (!confirmed) return;

    final threshold = widget.isLargeScreen ? 400.0 : 800.0;
    final triggerDistance = widget.isLargeScreen ? 40.0 : 80.0;
    final bool trigger =
        velocity.abs() > threshold || dx.abs() > triggerDistance;

    if (wasDragging) {
      _dragActive = false;
      if (trigger) {
        HapticFeedback.mediumImpact();
        _dragTriggeredSkip = true;
        // 从当前拖动进度继续走到落位；随后保持「邻位封面」预览，直到曲目
        // 真正切换（取链可能需要几百毫秒）——否则动画跑完会先回落成旧封面、
        // 再跳成新封面，看起来像卡住/来回闪。
        _coverController.forward();
        _startDragPendingWatchdog();
        if (dx > 0) {
          playback.skipToPrevious();
        } else {
          playback.skipToNext();
        }
      } else {
        _draggingCover = false;
        _dragTriggeredSkip = false;
        _coverController.animateBack(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }

    if (trigger) {
      HapticFeedback.mediumImpact();
      if (dx > 0) {
        playback.skipToPrevious();
      } else {
        playback.skipToNext();
      }
    }
  }

  void _handleHorizontalDragCancel() {
    _dragActive = false;
    if (_draggingCover && !_dragTriggeredSkip) {
      _draggingCover = false;
      _coverController.animateBack(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
    _resetHorizontalDrag();
  }

  /// 拖动切歌的兜底：等待曲目切换期间保持预览；超时（如取链失败）则回弹。
  void _startDragPendingWatchdog() {
    _dragPendingTimer?.cancel();
    _dragPendingTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_draggingCover) return;
      _draggingCover = false;
      _dragTriggeredSkip = false;
      _coverController.animateBack(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  void _resetHorizontalDrag() {
    _dragStartX = null;
    _dragStartY = null;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
  }

  /// 根据当前专辑封面更新主题色
  void _updateThemeIfNeeded(BuildContext context, Track? displayTrack) {
    final String? currentImageUrl = _artworkUrlOf(displayTrack);

    if (currentImageUrl != null && currentImageUrl != _lastImageUrl) {
      // 省流模式：跳过封面下载与取色（保持现有主题色），
      // 也不更新 _lastImageUrl，恢复 Wi-Fi 后仍能补取色。
      if (context.read<DataSaverService?>()?.blockNetworkArtwork ?? false) {
        return;
      }

      _prefetchImage(currentImageUrl);

      if (!_isThemeUpdating) {
        _isThemeUpdating = true;
        _lastImageUrl = currentImageUrl;

        // 在异步操作前缓存 context 相关的值
        final themeProvider = context.read<ThemeProvider>();
        final screenWidth = MediaQuery.sizeOf(context).width.toInt();
        final brightness = MediaQuery.platformBrightnessOf(context);

        Future.delayed(const Duration(milliseconds: 500), () async {
          try {
            if (!mounted || currentImageUrl != _lastImageUrl) return;
            // 走共享封面缓存取图：与显示路径同一份磁盘缓存（不再经
            // 默认 CacheManager 二次下载同一张封面）。
            final imageProvider = await artworkImageProvider(
              currentImageUrl,
              maxWidth: screenWidth,
            );
            if (!mounted || currentImageUrl != _lastImageUrl) return;
            themeProvider.updateThemeFromImage(
              imageProvider: imageProvider,
              brightness: brightness,
              cacheKey: currentImageUrl,
            );
          } finally {
            _isThemeUpdating = false;
          }
        });
      }
    }
  }

  /// 曲目封面 URL（空串视同无封面；领域 Track 自带可靠 id/artwork）。
  static String? _artworkUrlOf(Track? track) {
    final url = track?.artwork?.uri.toString();
    return url == null || url.isEmpty ? null : url;
  }

  /// 曲目的稳定 key（领域 id）。
  static String? _trackKey(Track? track) => track?.id.uri;

  /// 歌手展示名（多歌手逗号连接；无有效歌手回退 Unknown Artist）。
  static String _artistsLabel(Track track) {
    final joined = track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    return joined.isEmpty ? 'Unknown Artist' : joined;
  }

  /// 切歌：判定方向（下一首/上一首/跳转）并维护上一首历史，
  /// 触发三封面滑动与文字 spring 入场。
  void _onTrackChanged(
    String newId,
    Track? oldTrack,
    PlaybackProvider provider,
  ) {
    final nextId = provider.snapshot.next?.id.uri;
    final prevId = _previousTrack?.id.uri;
    final int direction;
    if (nextId != null && nextId == newId) {
      direction = 1;
    } else if (prevId != null && prevId == newId) {
      direction = -1;
    } else {
      direction = 0; // 队列点选等跳转：按前进处理
    }
    _coverDirection = direction == -1 ? -1 : 1;
    _oldNeighbor = direction == -1 ? _lastNextTrack : _previousTrack;
    // 播放顺序由播放快照维护（后端记录实际播放顺序）：
    // 最新一首即「上一首」，回退时后端已弹出，这里自然指向更早一首。
    _previousTrack = provider.snapshot.history.isNotEmpty
        ? provider.snapshot.history.last
        : null;
    _outgoingTrack = oldTrack;
    // 旧封面作为切歌动画中未加载完成时的占位，避免黑块闪一下。
    _previousImageUrl = _artworkUrlOf(oldTrack) ?? _previousImageUrl;
    _lastAnimatedTrackId = newId;
    // 拖动触发的切歌：过渡可能已经走完（画面即最终态），不要再重放。
    final bool dragTriggered = _dragTriggeredSkip;
    _dragTriggeredSkip = false;
    _dragPendingTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 切歌后清掉拖动/等待落点的进度预览，避免旧进度残留在滑杆上。
      _seekTargetMs = null;
      _seekSettleTimer?.cancel();
      _seekPreviewMs.value = null;
      if (_dragActive) {
        // 用户又开始了新的拖动：预览交给新拖动继续驱动，不接管动画。
        if (_coverController.isAnimating) _coverController.stop();
        return;
      }
      // 拖动预览（邻位封面）到此才撤下：曲目已经真正切换。
      _draggingCover = false;
      if (dragTriggered && !_coverController.isAnimating) {
        // 拖动已经完成过渡：画面就是最终状态，直接落位。
        _coverController.value = 1.0;
      } else if (_coverController.isAnimating) {
        // 拖动续播 / 快速连切：从当前进度接着走，不回到起点重放。
        _coverController.forward();
      } else {
        _coverController.forward(from: 0);
      }
      _trackEntranceController.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlaybackProvider, Track?>(
        (provider) => provider.snapshot.current);

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    final displayTrack = track ?? _lastTrack;

    // 切歌检测必须在 _lastTrack 更新前执行（oldTrack 即上一首）。
    final trackId = _trackKey(displayTrack);
    if (trackId != null && trackId != _lastAnimatedTrackId) {
      _onTrackChanged(trackId, _lastTrack, playbackProvider);
    }
    if (track != null) {
      _lastTrack = track;
    }

    // 空闲帧缓存下一首（上一首方向的旧邻位判定需要）。
    if (!_coverController.isAnimating && !_draggingCover) {
      _lastNextTrack = playbackProvider.snapshot.next;
      _outgoingTrack = null;
    }

    // 主题更新（对 miniplayer 和全屏播放器都生效）
    _updateThemeIfNeeded(context, displayTrack);

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
            _buildArtworkStack(
              context,
              displayTrack,
              playbackProvider,
              artDimension: artDimension,
              stackDimension: stackDimension,
              stackHeight: stackHeight,
              morph: morph,
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
  /// 两套布局始终挂载（完整层按最终高度布局、顶部对齐裁剪），高度过渡
  /// 不再跳变；封面由页内飞行副本在两端锚点间插值，不再是两份封面各淡各的。
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
            final double raw = expand.value.clamp(0.0, 1.0);
            final double t = Curves.easeInOutCubic.transform(raw);
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
                raw >= 1.0 ? widget.morph : null;
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
                      Positioned.fromRect(
                        rect: flightRect,
                        child: IgnorePointer(
                          child: _buildFlightCover(
                            context,
                            displayTrack,
                            flightRect.width,
                            lerpDouble(8, 18, t)!,
                          ),
                        ),
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

  /// 迷你 ⇄ 完整飞行副本封面：与两端真身同键的同步 provider，
  /// 首帧即出图（不闪占位）。
  Widget _buildFlightCover(
    BuildContext context,
    Track? track,
    double size,
    double radius,
  ) {
    final scheme = Theme.of(context).colorScheme;
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
        child: MorphCover(
          url: _artworkUrlOf(track),
          borderRadius: BorderRadius.circular(radius - 1),
          fallback: _buildDefaultImage(),
        ),
      ),
    );
  }

  /// 三封面堆叠：左=上一首、中=当前、右=下一首（左右压住露出边缘）。
  ///
  /// 切歌动画与「拖动跟手」共用同一条进度（[`_coverController`]）：横向拖动
  /// 时中心位由邻位封面顶上、按滑动距离过渡；松手后从同一进度续播或回弹。
  /// 无上一首/下一首时对应槽位为空（不闪、不空跳）。
  /// [context] 传 AnimatedBuilder 的 builder context（select 需在 build 期）。
  Widget _buildArtworkStack(
    BuildContext context,
    Track? displayTrack,
    PlaybackProvider playbackProvider, {
    required double artDimension,
    required double stackDimension,
    required double stackHeight,
    PlayerMorphController? morph,
  }) {
    final String? currentImageUrl = _artworkUrlOf(displayTrack);
    _lastArtDimension = artDimension;
    return Center(
      child: SizedBox(
        width: stackDimension,
        height: stackHeight,
        child: AnimatedBuilder(
          animation: _coverController,
          builder: (context, _) {
            // 拖动预览与切歌动画共用渲染：拖动时进度由手指驱动。
            final dragging = _draggingCover;
            final animating = dragging || _coverController.isAnimating;
            final t = Curves.easeOutCubic.transform(_coverController.value);
            final dir = _coverDirection;
            final double sideSize = artDimension * 0.78;
            final double offset = artDimension * 0.30;
            const double sideRotation = 0.05;

            final children = <Widget>[];

            // 旧邻位淡出（方向切换时另一侧让位）。
            if (animating && _oldNeighbor != null) {
              children.add(_sideCoverLayer(
                context,
                _oldNeighbor,
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
                final sourceTrack = dir == 1 ? nextItem : _previousTrack;
                children.add(_sideCoverLayer(
                  context,
                  sourceTrack,
                  sideSize: sideSize,
                  x: offset * dir + (1 - t) * offset * 0.3 * dir,
                  rotation: sideRotation * dir * (0.4 + 0.6 * t),
                  opacity: t * 0.85,
                  placeholderUrl: currentImageUrl,
                ));
              }
              // 滑出的旧当前 → 目标邻位。
              if (_outgoingTrack != null) {
                children.add(_mainCoverLayer(
                  context,
                  _outgoingTrack,
                  playbackProvider,
                  artDimension: artDimension,
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
                _previousTrack,
                sideSize: sideSize,
                x: -offset,
                rotation: -sideRotation,
                opacity: 0.85,
                placeholderUrl: currentImageUrl,
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
                onTap: playbackProvider.hasTrack
                    ? playbackProvider.skipToNext
                    : null,
              ));
            }

            // 中心位：拖动时由邻位封面顶上（真正的切歌在松手后才发生）；
            // 动画/稳态下就是当前曲目。顶栏⇄播放页飞行时只隐藏这一张。
            final Track? centerTrack = dragging
                ? (dir == 1 ? playbackProvider.snapshot.next : _previousTrack)
                : displayTrack;
            children.add(_mainCoverLayer(
              context,
              centerTrack,
              playbackProvider,
              artDimension: artDimension,
              x: animating ? dir * offset * (1 - t) : 0,
              rotation: animating ? sideRotation * dir * (1 - t) : 0,
              scale: animating ? 0.78 + 0.22 * t : 1.0,
              opacity: 1,
              interactive: !dragging,
              coverKey: morph?.pageCoverKey,
              hidden: morph?.pageHeaderHidden ?? false,
              placeholderUrl: dragging ? currentImageUrl : _previousImageUrl,
            ));

            return Stack(clipBehavior: Clip.none, children: children);
          },
        ),
      ),
    );
  }

  /// 邻位封面（压在当前封面之下；[onTap] 非空时可点击切歌）。
  Widget _sideCoverLayer(
    BuildContext context,
    Track? track, {
    required double sideSize,
    required double x,
    required double rotation,
    required double opacity,
    String? placeholderUrl,
    VoidCallback? onTap,
  }) {
    if (track == null) return const SizedBox.shrink();
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
    Key? coverKey,
    bool hidden = false,
    String? placeholderUrl,
  }) {
    final Widget card = interactive
        ? _buildConfigurableMainContent(
            track,
            playbackProvider,
            isPlaying:
                context.select<PlaybackProvider, bool>((p) => p.isPlaying),
            artDimension: artDimension,
            coverKey: coverKey,
            hidden: hidden,
            placeholderUrl: placeholderUrl,
          )
        : _buildCoverCard(context, track, artDimension,
            placeholderUrl: placeholderUrl);
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
    final url = _artworkUrlOf(track);
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
          _buildFavoriteButton(playbackProvider),
          const SizedBox(width: 4),
          Expanded(child: _buildSeekSlider(context, playbackProvider)),
          const SizedBox(width: 4),
          _buildModeButton(context, mode, () {
            HapticFeedback.lightImpact();
            playbackProvider.togglePlayMode();
          }),
        ],
      ),
    );
  }

  /// 播放模式：与收藏同一套简单图标按钮（不再用双层错位底片）。
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
      icon: Icon(_getPlayModeIcon(mode)),
      tooltip: label,
      onPressed: onPressed,
    );
  }

  /// 可拖动进度滑杆：拖动中显示本地值（不被 position 通道回拽），
  /// 松手提交 seek；拖动气泡显示目标时间。
  Widget _buildSeekSlider(
      BuildContext context, PlaybackProvider playbackProvider) {
    return ValueListenableBuilder<double?>(
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
    );
  }

  /// 拖动气泡时间：m:ss。
  String _formatSeekTime(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 标题/作者：单行「歌名 · 作者」+ spring 入场。
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
          offset: Offset(0, (1 - t) * 22),
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: HeaderAndFooter(
        header: displayTrack?.title ??
            playbackProvider.lastPlayedTrackName ??
            'No track playing',
        footer: displayTrack != null
            ? _artistsLabel(displayTrack)
            : playbackProvider.lastPlayedArtists ?? 'Unknown Artist',
        track: displayTrack,
      ),
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
  Widget _buildFavoriteButton(
    PlaybackProvider playback, {
    M3EIconButtonSize size = M3EIconButtonSize.sm,
    Size visualSize = const Size(44, 44),
  }) =>
      _FavoriteButton(playback: playback, size: size, visualSize: visualSize);

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
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: KeyedSubtree(
                key: _miniCoverKey,
                child: Opacity(
                  // 迷你 ⇄ 完整飞行期间真身隐藏，由飞行副本承接。
                  opacity: _coverFlightActive ? 0 : 1,
                  child: _buildMiniAlbumArt(track),
                ),
              ),
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
                      ? _artistsLabel(track)
                      : playback.lastPlayedArtists ?? 'Unknown Artist',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Control Buttons - 响应式设计
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
  /// 会让人以为还在播放。
  Widget _buildMiniProgress(BuildContext context, PlaybackProvider playback) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Duration>(
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
          playback,
          size: size,
          visualSize: visualSize,
        ),
        _buildMiniIconControl(
          context,
          icon: Icons.skip_previous_rounded,
          size: size,
          visualSize: visualSize,
          onPressed: () {
            HapticFeedback.lightImpact();
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
            HapticFeedback.lightImpact();
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
      // 图标颜色交给 standard 变体默认值（不再手写 primary 强调）。
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
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        // 颜色交给 standard 变体默认值。
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          key: ValueKey(isPlaying),
        ),
      ),
      onPressed: () {
        HapticFeedback.lightImpact();
        playback.togglePlayPause();
      },
    );
  }

  Widget _buildMiniAlbumArt(Track? track) {
    final displayTrack = track ?? _lastTrack;
    final String? currentImageUrl = _artworkUrlOf(displayTrack);

    // 不缩放：与顶栏/播放页/预加载共用同一 ImageCache 键，
    // 迷你 ⇄ 完整飞行与切歌动画才能复用同一张已解码图。
    return AppNetworkImage(
      key: ValueKey(currentImageUrl),
      url: currentImageUrl,
      fit: BoxFit.cover,
      fallbackIconSize: 24,
      placeholder: _lastTrack != null && _lastImageUrl != null
          ? AppNetworkImage(
              url: _lastImageUrl,
              fit: BoxFit.cover,
              fallbackIconSize: 24,
            )
          : _buildDefaultImage(),
      errorWidget: _buildDefaultImage(),
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
        // 纵向同样只留阴影余量（与小屏一致，不再白占空间）。
        double artDimension = min(artContentAvailableWidth,
            artContentAvailableHeight / _artStackVerticalFactor);
        artDimension = max(0, artDimension);

        final double stackDimension = artDimension * 1.38;
        final double stackHeight = artDimension * _artStackVerticalFactor;

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildArtworkStack(
              context,
              displayTrack,
              playbackProvider,
              artDimension: artDimension,
              stackDimension: stackDimension,
              stackHeight: stackHeight,
              morph: widget.morph,
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

  Widget _buildConfigurableMainContent(
    Track? track,
    PlaybackProvider playback, {
    required bool isPlaying,
    required double artDimension,
    Key? coverKey,
    bool hidden = false,
    String? placeholderUrl,
  }) {
    if (isPlaying) {
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
        onHorizontalDragStart: _handleHorizontalDragStart,
        onHorizontalDragUpdate: _handleHorizontalDragUpdate,
        onHorizontalDragEnd: (details) =>
            _handleHorizontalDragEnd(details, playback),
        onHorizontalDragCancel: _handleHorizontalDragCancel,
        // 点击封面 = 播放/暂停；上一曲/下一曲由左右邻位封面承接。
        onTap: () {
          HapticFeedback.lightImpact();
          playback.togglePlayPause();
        },
        child: RepaintBoundary(
          child: KeyedSubtree(
            key: coverKey,
            child: KeyedSubtree(
              key: _fullCoverKey,
              child: AnimatedOpacity(
                // 隐藏用淡出（飞行起点在别处，淡出自然）；亮出必须瞬时——
                // 飞行副本与真身在同一帧交接，淡入会造成尾段亮度下陷（闪动）。
                duration: (hidden || _coverFlightActive)
                    ? const Duration(milliseconds: 160)
                    : Duration.zero,
                // 顶栏⇄播放页飞行 / 迷你⇄完整飞行期间真身隐藏，
                // 由飞行副本承接（其余元素不参与共享飞行）。
                opacity: (hidden || _coverFlightActive) ? 0 : 1,
                child: _buildCoverCard(
                  context,
                  track,
                  artDimension,
                  fallback: _buildDefaultImage(),
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

/// 收藏按钮独立成组件：布局在 [LayoutBuilder] 内构建时，
/// `context.select` 必须发生在组件自身 build 中（State.context 在布局阶段
/// 使用会被 provider 断言拦截）。
///
/// 收藏反馈只靠图标态（实心/空心），不再弹 Snackbar。
class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({
    required this.playback,
    this.size = M3EIconButtonSize.sm,
    this.visualSize = const Size(44, 44),
  });

  final PlaybackProvider playback;
  final M3EIconButtonSize size;
  final Size visualSize;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    final trackId = context.select<PlaybackProvider, TrackId?>(
        (provider) => provider.currentTrackId);
    if (library == null || trackId == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('zh'));
    final favorite = library.isFavorite(trackId.sourceKey, trackId.id);
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: size,
      visualSize: visualSize,
      icon: Icon(
        favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        // 与收藏页行内心形同一契约：已收藏 primary、未收藏 onSurfaceVariant。
        color: favorite
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: () async {
        HapticFeedback.lightImpact();
        await playback.toggleCurrentFavorite();
      },
    );
  }
}


/// 标题/作者单行块：左侧竖条「书脊」+「歌名 · 作者」，超长省略。
///
/// 单行是为了给歌词/队列让出纵向空间（两行版本太占位置）。
class HeaderAndFooter extends StatelessWidget {
  final String header;
  final String footer;
  final Track? track;

  const HeaderAndFooter({
    super.key,
    required this.header,
    required this.footer,
    this.track,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artists = track?.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join(', ') ??
        '';
    final artistText = artists.isNotEmpty ? artists : footer;

    return Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: header,
                  // 标题/作者与全 App 文本契约一致：onSurface /
                  // onSurfaceVariant；强调色只留给左侧标记条。
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
          ),
        ),
      ],
    );
  }
}
