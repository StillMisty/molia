import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/player_morph.dart';

import '../l10n/app_localizations.dart';

/// 正在播放页：全屏播放器（可折叠为迷你条）+ 队列/歌词两个 PageView。
class NowPlaying extends StatefulWidget {
  /// 顶栏共享元素控制器：全屏播放器为其提供封面/歌名/进度锚点。
  final PlayerMorphController? morph;

  const NowPlaying({super.key, this.morph});

  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final PageController _pageController;

  /// 队列页滚动控制器：用于「滑到顶后再下拉切换播放器」判定（不抢列表滚动）。
  late final ScrollController _queueScrollController;

  /// 歌词页滚动控制器：同一判定的歌词侧（外部注入 [LyricsWidget]）。
  late final ScrollController _lyricsScrollController;

  /// 播放器展开进度：0 = 迷你条、1 = 完整播放器（小屏）。
  late final AnimationController _expandController;
  bool _isMini = false;

  /// 播放器区域可用的最大高度（跟手拖拽的行程基准）。
  double _playerMaxHeight = 340;

  /// 收起态：内容区上滑/下滑累计位移（用于列表滑到顶下拉切换）。
  double _contentSwipeDy = 0;
  double _contentSwipeDx = 0;

  /// 本次内容区手势已触发过切换（一次手势只触发一次）。
  bool _contentToggleDone = false;

  static const int _currentPageIndex = 1; // 默认显示歌词页

  // 页面与屏幕尺寸缓存：避免 PageView 每次重建导致歌词/队列滚动状态丢失。
  List<PageData>? _cachedPages;
  bool? _cachedIsLargeScreen;
  Size? _cachedScreenSize;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentPageIndex);
    _queueScrollController = ScrollController();
    _lyricsScrollController = ScrollController();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    )..addStatusListener(_handleExpandSettled);
  }

  @override
  void dispose() {
    _expandController.dispose();
    _pageController.dispose();
    _queueScrollController.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  /// 折叠/展开播放器（轻点迷你条 / 列表滑到顶下拉）：同一控制器驱动
  /// 高度、交叉淡化与封面飞行。
  void _toggleExpand() {
    HapticFeedback.lightImpact();
    if (_isMini) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  /// 展开动画落定后同步迷你态（轻点与跟手拖拽共用同一收尾）。
  void _handleExpandSettled(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _setMini(false);
    } else if (status == AnimationStatus.dismissed) {
      _setMini(true);
    }
  }

  void _setMini(bool mini) {
    if (_isMini == mini || !mounted) return;
    setState(() {
      _isMini = mini;
      // 歌词页操作按钮可见性跟随展开态，需重建页面实例。
      _cachedPages = null;
    });
  }

  /// 播放器区域跟手拖拽：迷你条上拉展开、播放器下拉收起（过半/甩动吸附）。
  void _handlePlayerDragUpdate(DragUpdateDetails details) {
    // 约 0.6 个最大高度走完整段（一次拇指上滑即可展开）。
    final double extent =
        max(200.0, (_playerMaxHeight - miniPlayerHeight) * 0.6);
    // 手指向上（dy 负）→ 展开。
    final double delta = -details.delta.dy / extent;
    _expandController.value =
        (_expandController.value + delta).clamp(0.0, 1.0);
  }

  void _handlePlayerDragEnd(DragEndDetails details) {
    final double upVelocity = -(details.primaryVelocity ?? 0);
    // 位置 + 速度投影：快速甩动即使行程短也按方向吸附。
    final double projected = _expandController.value + upVelocity / 1800;
    HapticFeedback.lightImpact();
    if (projected >= 0.5) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  List<PageData> _buildPages(BuildContext context) {
    if (_cachedPages != null) {
      return _cachedPages!;
    }

    _cachedPages = [
      PageData(
        title: AppLocalizations.of(context)!.queueTab,
        icon: Icons.queue_music_rounded,
        page: RepaintBoundary(
          child: QueueDisplay(
            controller: _queueScrollController,
            // 顶部留出圆点过渡带，列表首项不被渐隐吃掉。
            topPadding: _dotsBandHeight + 2,
          ),
        ),
      ),
      PageData(
        title: AppLocalizations.of(context)!.lyricsTab,
        icon: Icons.lyrics_rounded,
        page: RepaintBoundary(
          // 歌词快捷操作只在收起态（歌词区展开）显示。
          child: LyricsWidget(
            quickActionsEnabled: _isMini,
            controller: _lyricsScrollController,
          ),
        ),
      ),
    ];

    return _cachedPages!;
  }

  @override
  bool get wantKeepAlive => true;

  bool _getIsLargeScreen(BuildContext context) {
    final currentSize = MediaQuery.of(context).size;

    // 尺寸变化时同时失效页面与布局缓存。
    if (_cachedScreenSize != currentSize) {
      _cachedScreenSize = currentSize;
      _cachedIsLargeScreen = null;
      _cachedPages = null;
    }

    _cachedIsLargeScreen ??=
        context.layoutType(ResponsivePageType.shell).preferTwoPane;
    return _cachedIsLargeScreen!;
  }

  /// 圆点过渡带高度：内容顶部在这条带内渐隐，圆点浮于其中（不再单独占一行）。
  static const double _dotsBandHeight = 24;

  /// 歌词/队列小圆点切换行（常显；由父级 Positioned 撑满宽度）。
  ///
  /// [onActiveTap] 点击已激活圆点时触发（播放页 = 展开/收起切换）。
  Widget _buildDotsRow({VoidCallback? onActiveTap}) {
    return Center(
      child: LyricsQueueDots(
        pages: _buildPages(context),
        pageController: _pageController,
        onActiveTap: onActiveTap,
      ),
    );
  }

  /// 内容顶部渐隐过渡：列表/歌词滑到圆点带下面时淡出（不是硬切）。
  ///
  /// 用 ShaderMask + dstIn：只取 shader 的 alpha，不引入任何硬编码颜色，
  /// 背景换主题也不会露出色块。
  Widget _buildTopFade(BuildContext context, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final double height = bounds.height;
        final double stop =
            height <= 0 ? 0.0 : (_dotsBandHeight / height).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withValues(alpha: 0),
            scheme.surface,
            scheme.surface,
          ],
          stops: [0, stop, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }

  // ---- 手势区域 ----
  // 切换（收缩→展开、展开→收起）：
  // - 播放器区域跟手上下拖拽；
  // - 队列/歌词已滑到顶部后继续下拉超过阈值（把内容往上推，不抢内容滚动）。
  // 内容上下滚动、横向翻页自身不参与切换。

  /// 当前内容页（0 = 队列、1 = 歌词）。
  int get _currentContentPage {
    if (!_pageController.hasClients) return _currentPageIndex;
    return _pageController.page?.round() ?? _currentPageIndex;
  }

  /// 当前内容页是否已在顶部（未挂载/无滚动条时视为在顶）。
  bool get _contentAtTop {
    final controller = _currentContentPage == 0
        ? _queueScrollController
        : _lyricsScrollController;
    return !controller.hasClients || controller.offset <= 0;
  }

  void _onContentPointerDown(PointerDownEvent event) {
    _contentSwipeDy = 0;
    _contentSwipeDx = 0;
    _contentToggleDone = false;
  }

  void _onContentPointerMove(PointerMoveEvent event) {
    if (_contentToggleDone) return;
    // 不在顶部：位移属于内容滚动本身，不累计——否则「一次拖到顶」会在
    // 到达顶部的瞬间用积攒的位移误触发切换。
    if (!_contentAtTop) {
      _resetContentSwipe();
      return;
    }
    _contentSwipeDy += event.delta.dy;
    _contentSwipeDx += event.delta.dx;
    final bool mostlyVertical =
        _contentSwipeDy.abs() > _contentSwipeDx.abs() * 1.5;
    if (!mostlyVertical) return;
    if (_contentSwipeDy > 80) {
      // 已在顶部，继续往下拉（内容上推）= 切换播放器展开/收起。
      // 本次手势只触发一次，避免动画未落定就被反向再触发。
      _contentToggleDone = true;
      _resetContentSwipe();
      _toggleExpand();
    }
  }

  void _resetContentSwipe() {
    _contentSwipeDy = 0;
    _contentSwipeDx = 0;
  }

  Widget _buildCollapsedLargeLayout(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 1,
            child: RepaintBoundary(
              child: SizedBox(
                height: double.infinity,
                child: Center(
                  child: Player(isLargeScreen: true, morph: widget.morph),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: _buildTopFade(
                      context,
                      child: PageView(
                        controller: _pageController,
                        children: _buildPages(context)
                            .map((page) => page.page)
                            .toList(),
                      ),
                    ),
                  ),
                ),
                // 圆点浮在过渡带里（空区不挡内容的手势）。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: _dotsBandHeight,
                  child: RepaintBoundary(child: _buildDotsRow()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bool isLargeScreen = _getIsLargeScreen(context);

    if (isLargeScreen) {
      return _buildCollapsedLargeLayout(context);
    }

    // 小屏：播放器高度随展开进度连续插值（不再跳变），
    // 下方是歌词/队列圆点切换行与内容区。
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double playerMaxHeight =
              max(340.0, constraints.maxHeight - 180);
          // 供播放器区域的跟手拖拽换算行程（布局期写入，不触发重建）。
          _playerMaxHeight = playerMaxHeight;
          return Column(
            children: [
              // 播放器区域：跟手拖拽（迷你条上拉展开、播放器下拉收起）。
              GestureDetector(
                onVerticalDragUpdate: _handlePlayerDragUpdate,
                onVerticalDragEnd: _handlePlayerDragEnd,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: playerMaxHeight),
                  child: Player(
                    isLargeScreen: false,
                    morph: widget.morph,
                    expandAnimation: _expandController,
                    onToggleExpand: _toggleExpand,
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Listener(
                        // 队列页上滑 = 展开、滑到顶再下滑 = 收起（监听原始
                        // 指针，不与歌词/队列滚动、翻页手势竞争）。
                        onPointerDown: _onContentPointerDown,
                        onPointerMove: _onContentPointerMove,
                        onPointerUp: (_) => _resetContentSwipe(),
                        onPointerCancel: (_) => _resetContentSwipe(),
                        child: RepaintBoundary(
                          child: _buildTopFade(
                            context,
                            child: PageView(
                              controller: _pageController,
                              children: _buildPages(context)
                                  .map((page) => page.page)
                                  .toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 圆点浮在过渡带里（不再单独占一行高度）。
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: _dotsBandHeight,
                      child: RepaintBoundary(
                        child: _buildDotsRow(onActiveTap: _toggleExpand),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
