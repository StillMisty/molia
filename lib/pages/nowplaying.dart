import 'dart:math';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/now_playing_controller.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/shell_page_visibility.dart';
import 'package:molia/widgets/shell_reselect.dart';
import 'package:molia/widgets/track_info_view.dart';

import '../l10n/app_localizations.dart';

/// 正在播放页：全屏播放器（可折叠为迷你条）+ 队列/歌词/歌曲信息三个 PageView。
class NowPlaying extends StatefulWidget {
  /// 顶栏共享元素控制器：全屏播放器为其提供封面/歌名/进度锚点。
  final PlayerMorphController? morph;

  /// 壳层「重复点击底栏 / 导航轨播放目的地」的请求通道：迷你 ⇄ 完整切换。
  final ShellReselectSignal? reselect;

  /// 外部 tab 切换请求（如底栏队列按钮「跳播放页 + 切队列」）。
  final NowPlayingController? controller;

  /// 桌面骨架专用版式：左「封面 + 控制」固定栏 + 右「队列 / 歌词 / 歌曲
  /// 信息」三 tab（默认歌词，与移动端圆点页序一致）。
  ///
  /// 桌面没有迷你态与圆点手势，此模式下 `reselect` 请求忽略；移动骨架
  /// （含平板宽屏）保持既有 PageView 版式。
  final bool desktopLayout;

  const NowPlaying({
    super.key,
    this.morph,
    this.reselect,
    this.controller,
    this.desktopLayout = false,
  });

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

  /// 歌曲信息页滚动控制器（同一判定的第三页）。
  late final ScrollController _infoScrollController;

  /// 播放器展开进度：0 = 迷你条、1 = 完整播放器（小屏）。
  ///
  /// motor expressive spatial 弹簧（380/0.8）：拖动跟手直接写进度，松手按
  /// 手势速度续跑吸附。
  late final SingleMotionController _expandController;
  bool _isMini = false;

  /// 当前布局是否为大屏（两栏）：大屏播放器始终完整、没有迷你态，
  /// 重复点击请求直接忽略（不能让 `_isMini` 在大屏被翻转）。布局期写入。
  bool _isLargeScreen = false;

  /// 播放器区域可用的最大高度（跟手拖拽的行程基准）。
  double _playerMaxHeight = 340;

  /// 收起态：内容区上滑/下滑累计位移（用于列表滑到顶下拉切换）。
  double _contentSwipeDy = 0;
  double _contentSwipeDx = 0;

  /// 本次内容区手势已触发过切换（一次手势只触发一次）。
  bool _contentToggleDone = false;

  /// 默认显示歌词页；页序见 [_buildPages]：队列 / 歌词 / 歌曲信息
  /// （索引与 [NowPlayingController] 共用一份定义）。
  static const int _currentPageIndex = nowPlayingLyricsTabIndex;
  static const int _queuePageIndex = nowPlayingQueueTabIndex;
  static const int _infoPageIndex = nowPlayingInfoTabIndex;

  /// 桌面版式播放器列宽度：封面按可用宽高自适应，这一列只负责给它留出
  /// 「封面 + 两侧邻位露出」的横向余量（480 下封面边 ≈288，
  /// 见 `cover_deck_metrics.dart`）。
  static const double _desktopPlayerColumnWidth = 480;

  /// 桌面版式右侧分页：0 = 队列、1 = 歌词、2 = 歌曲信息。
  late int _desktopTab;

  /// 移动 / 平板版式当前落定的内容页（PageView 落定后更新）。
  ///
  /// 与 [_desktopTab] 分开：桌面没有 [PageView]，tab 选中态由
  /// `M3ETabsView` 的回调驱动；两者都用于歌词页的 tab 门控（停在队列 /
  /// 信息 tab 时不跟随播放进度）。
  ///
  /// 用 notifier 而不是 state：翻页只需要重建 PageView 子树，不能让播放器 /
  /// 封面 deck 跟着整页 setState 重建。
  late final ValueNotifier<int> _visibleTab;

  /// 桌面版式右栏内容与 tab 栏之间的间距（M3E：tab 栏与内容同为 16 口径，
  /// 内容左右边距由各内容组件自持）。
  static const double _desktopContentTopPadding = 16;

  // 页面与屏幕尺寸缓存：避免 PageView 每次重建导致歌词/队列滚动状态丢失。
  List<PageData>? _cachedPages;
  bool? _cachedIsLargeScreen;
  Size? _cachedScreenSize;

  @override
  void initState() {
    super.initState();
    // 请求先于挂载（壳层先发请求、页面后才挂载）：作为初始页消费，不补动画。
    final int? requested = widget.controller?.requestedTab;
    _desktopTab = requested ?? nowPlayingLyricsTabIndex;
    _visibleTab = ValueNotifier<int>(
      requested ?? nowPlayingLyricsTabIndex,
    );
    _pageController =
        PageController(initialPage: requested ?? _currentPageIndex);
    _queueScrollController = ScrollController();
    _lyricsScrollController = ScrollController();
    _infoScrollController = ScrollController();
    _expandController = SingleMotionController(
      motion:
          const MaterialSpringMotion.expressiveSpatialDefault(snapToEnd: true),
      vsync: this,
      initialValue: 0,
    )..value = 1.0;
    _expandController.addListener(_handleExpandProgress);
    widget.reselect?.addListener(_handleReselect);
    widget.controller?.addListener(_handleTabRequest);
  }

  @override
  void didUpdateWidget(covariant NowPlaying oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reselect != widget.reselect) {
      oldWidget.reselect?.removeListener(_handleReselect);
      widget.reselect?.addListener(_handleReselect);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleTabRequest);
      widget.controller?.addListener(_handleTabRequest);
    }
  }

  @override
  void dispose() {
    widget.reselect?.removeListener(_handleReselect);
    widget.controller?.removeListener(_handleTabRequest);
    _expandController.dispose();
    _pageController.dispose();
    _visibleTab.dispose();
    _queueScrollController.dispose();
    _lyricsScrollController.dispose();
    _infoScrollController.dispose();
    super.dispose();
  }

  /// 展开/收起切换：按当前进度过半决定方向。
  ///
  /// 不用落定状态（[_isMini]）判定：弹簧有容差拖尾，「落定回调」晚于视觉
  /// 落定约 0.35s，滚动到一半连点/到顶快速再拉会打进过期目标。
  void _toggleExpand() {
    HapticsService.lightImpact();
    _animateToggleExpand();
  }

  /// 切换动作本体（不含触感）：本次点击的轻震由调用方负责。
  void _animateToggleExpand() {
    _expandController.animateTo(_expandController.value >= 0.5 ? 0.0 : 1.0);
  }

  /// 壳层重复点击「播放」目的地：与迷你条点击 / 圆点点击 / 到顶下拉同一入口。
  ///
  /// 大屏与桌面版式都没有迷你态（播放器始终完整），忽略请求。
  /// 触感由壳层对重复点击统一给出（见 [ShellReselectSignal]），此处不再补一次。
  void _handleReselect() {
    if (widget.desktopLayout || _isLargeScreen) return;
    _animateToggleExpand();
  }

  /// 外部 tab 请求（[NowPlayingController]）：切到请求的页。
  ///
  /// 请求是动作不是状态：重复请求、请求当前页都照样处理（页面可能刚挂载，
  /// 用户也可能手动切走后再触发一次）。
  void _handleTabRequest() {
    final int? requested = widget.controller?.requestedTab;
    if (requested == null || !mounted) return;

    if (widget.desktopLayout) {
      _selectDesktopTab(requested);
      return;
    }

    if (!_pageController.hasClients) {
      // 挂载了但还没布局（请求落在 initState 与首帧之间）：初始页已在
      // initState 取过，这里只兜一次帧末补跳。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(requested);
        }
      });
      return;
    }
    _pageController.animateToPage(
      requested,
      duration: M3EMotion.medium2,
      curve: M3EMotion.emphasizedDecelerate,
    );
  }

  /// 展开进度跨过阈值即同步迷你态（视觉落定口径，不等弹簧容差拖尾）。
  void _handleExpandProgress() {
    final double progress = _expandController.value;
    if (progress >= 0.99) {
      _setMini(false);
    } else if (progress <= 0.01) {
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

  /// 播放器区域跟手拖拽行程基准：约 0.6 个最大高度走完整段（一次拇指
  /// 上滑即可展开）；也是释放速度 → 进度域的换算基准。
  double get _expandDragExtent =>
      max(200.0, (_playerMaxHeight - miniPlayerHeight) * 0.6);

  /// 播放器区域跟手拖拽：迷你条上拉展开、播放器下拉收起（过半/甩动吸附）。
  void _handlePlayerDragUpdate(DragUpdateDetails details) {
    final double extent = _expandDragExtent;
    // 手指向上（dy 负）→ 展开。
    final double delta = -details.delta.dy / extent;
    _expandController.value =
        (_expandController.value + delta).clamp(0.0, 1.0);
  }

  void _handlePlayerDragEnd(DragEndDetails details) {
    final double upVelocity = -(details.primaryVelocity ?? 0);
    // 位置 + 速度投影：快速甩动即使行程短也按方向吸附。
    final double projected = _expandController.value + upVelocity / 1800;
    HapticsService.lightImpact();
    final bool expand = projected >= 0.5;
    final double extent = _expandDragExtent;
    _expandController.animateTo(
      expand ? 1.0 : 0.0,
      // 手势速度换算到进度域（上滑 = 展开 = 进度增加），弹簧带惯性续跑。
      withVelocity: extent <= 0 ? 0 : upVelocity / extent,
    );
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
      PageData(
        title: AppLocalizations.of(context)!.trackInfoTabTitle,
        icon: Icons.info_rounded,
        page: RepaintBoundary(
          child: TrackInfoView(
            controller: _infoScrollController,
            // 顶部留出圆点过渡带，内容首行不被渐隐吃掉（与队列页一致）。
            topPadding: _dotsBandHeight + 2,
          ),
        ),
      ),
    ];

    return _cachedPages!;
  }

  /// PageView 内容页：每页按「壳层可见 && 是当前 tab」套上可见性 scope。
  List<Widget> _buildTabPages(
    BuildContext context, {
    required bool shellVisible,
    required int visibleTab,
  }) {
    final pages = _buildPages(context);
    return [
      for (var index = 0; index < pages.length; index++)
        _withTabVisibility(
          shellVisible: shellVisible,
          tabIndex: index,
          visibleTab: visibleTab,
          child: pages[index].page,
        ),
    ];
  }

  /// 给内容页套上可见性 scope：`visible = 壳层可见 && 本页是当前 tab`。
  ///
  /// [ShellPageVisibility] 的壳层语义是「整个页面是否在前台」；播放页内部的
  /// 队列 / 歌词 / 信息是页内 tab，这里把它作为**最近的** scope 再包一层，
  /// 歌词页据此在停在别的 tab 时放弃 position 订阅与自动滚动。作用域只覆盖
  /// 播放页子树，资料库 / 收藏页看到的仍是壳层自己的那个 scope。
  Widget _withTabVisibility({
    required bool shellVisible,
    required int tabIndex,
    required int visibleTab,
    required Widget child,
  }) {
    return ShellPageVisibility(
      visible: shellVisible && tabIndex == visibleTab,
      child: child,
    );
  }

  /// PageView 落定到新页：只写 notifier（相同页不写），
  /// 由 PageView 外层的 [ValueListenableBuilder] 重建翻页子树。
  void _handleVisiblePageChanged(int index) {
    if (!mounted || index == _visibleTab.value) return;
    _visibleTab.value = index;
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

  /// 圆点过渡带高度：内容顶部在这条带内渐隐，圆点浮于其中。
  ///
  /// 20 是「圆点 + 上下各 6 的手感余量」这一档：带子只影响内容首行的渐隐与
  /// 首项留白（队列 / 信息页的 `topPadding` 同源），再高就是白给的空行。
  static const double _dotsBandHeight = 20;

  /// 歌词/队列小圆点切换行（常显；由父级 Positioned 撑满宽度）。
  ///
  /// [onActiveTap] 点击已激活圆点时触发（播放页 = 展开/收起切换）。
  Widget _buildDotsRow({VoidCallback? onActiveTap}) {
    return SizedBox(
      width: double.infinity,
      height: _dotsBandHeight,
      child: Center(
        child: LyricsQueueDots(
          pages: _buildPages(context),
          pageController: _pageController,
          onActiveTap: onActiveTap,
        ),
      ),
    );
  }

  /// 内容顶部渐隐过渡：列表/歌词滑到圆点带下面时淡出（不是硬切）。
  ///
  /// 顶部渐变的 surface 覆盖层（不是 ShaderMask + dstIn）：两者视觉等价
  /// （页面背景就是 `colorScheme.surface`，mask 的 alpha 与覆盖层不透明度互补），
  /// 但 ShaderMask 会给内容区整块建立 saveLayer —— 滚动歌词 / 队列时每帧都要
  /// 重新合成整块区域；覆盖层只是一次普通渐变绘制。
  Widget _buildTopFade(BuildContext context, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _dotsBandHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surface,
                    scheme.surface.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 切换（收缩→展开、展开→收起）：
  // - 播放器区域跟手上下拖拽；
  // - 队列/歌词已滑到顶部后继续下拉超过阈值（把内容往上推，不抢内容滚动）。
  // 内容上下滚动、横向翻页自身不参与切换。

  /// 当前内容页（0 = 队列、1 = 歌词、2 = 歌曲信息）。
  int get _currentContentPage {
    if (!_pageController.hasClients) return _currentPageIndex;
    return _pageController.page?.round() ?? _currentPageIndex;
  }

  /// 页索引 → 滚动控制器（新增页面时必须同步登记，否则该页
  /// 「滑到顶再下拉收起播放器」失效）。
  ScrollController _scrollControllerOf(int page) => switch (page) {
        _queuePageIndex => _queueScrollController,
        _infoPageIndex => _infoScrollController,
        _ => _lyricsScrollController,
      };

  /// 当前内容页是否已在顶部（未挂载/无滚动条时视为在顶）。
  bool get _contentAtTop {
    final controller = _scrollControllerOf(_currentContentPage);
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

  Widget _buildCollapsedLargeLayout(
    BuildContext context, {
    required bool shellVisible,
  }) {
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 1,
            child: RepaintBoundary(
              child: SizedBox(
                height: double.infinity,
                child: Center(
                  child: Player(
                    isLargeScreen: true,
                    morph: widget.morph,
                  ),
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
                      // tab 落定只重建 PageView 子树：播放器 / 封面 deck 不跟
                      // 着整页 setState 重建（_visibleTab 用 notifier 的原因）。
                      child: ValueListenableBuilder<int>(
                        valueListenable: _visibleTab,
                        builder: (context, visibleTab, _) => PageView(
                          controller: _pageController,
                          onPageChanged: _handleVisiblePageChanged,
                          children: _buildTabPages(
                            context,
                            shellVisible: shellVisible,
                            visibleTab: visibleTab,
                          ),
                        ),
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

  /// 桌面版式右侧 tab 切换（点标签与滑动分页同一入口，外部请求也走这里）。
  void _selectDesktopTab(int index) {
    if (index == _desktopTab) return;
    setState(() => _desktopTab = index);
  }

  /// 桌面骨架版式：左「播放器」固定列 + 右「队列 / 歌词 / 歌曲信息」三 tab。
  ///
  /// 与移动版式的差别：没有迷你态与圆点切换（也不需要展开/收起与内容
  /// 下拉手势），页序与默认页跟移动端一致（队列 / 歌词 / 信息，默认歌词）。
  Widget _buildDesktopLayout(
    BuildContext context, {
    required bool shellVisible,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: _desktopPlayerColumnWidth,
            // 大屏播放器布局：封面自适应 + 歌名/歌手两行 + 进度 + 传输控制
            // （desktopLayout：传输排在播放器列里，见 player.dart）。
            child: Player(
              isLargeScreen: true,
              desktopLayout: true,
              morph: widget.morph,
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Padding(
                  // 次 tab（图标 + 文案一行）：行高由 M3ETabTheme.height（48）
                  // 决定，纵向不再叠加自拟内边距；左右 16 与下方内容同一
                  // 内容边距（M3E 口径）。
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: M3ETabs(
                    // 次 tab：图标在文案左侧、同一行排布（桌面右栏是内容区里
                    // 的分组切换，不是顶层导航）。
                    variant: M3ETabsVariant.secondary,
                    tabs: [
                      M3ETab(
                        icon: const Icon(M3EIcons.queue_music_rounded),
                        label: l10n.queueTab,
                      ),
                      M3ETab(
                        icon: const Icon(M3EIcons.lyrics_rounded),
                        label: l10n.lyricsTab,
                      ),
                      M3ETab(
                        icon: const Icon(M3EIcons.info_rounded),
                        label: l10n.trackInfoTabTitle,
                      ),
                    ],
                    selectedIndex: _desktopTab,
                    onTabSelected: _selectDesktopTab,
                  ),
                ),
                Expanded(
                  child: M3ETabsView(
                    selectedIndex: _desktopTab,
                    onTabSelected: _selectDesktopTab,
                    children: [
                      RepaintBoundary(
                        // 当前曲目由左侧播放器承载，队列页只列其后曲目
                        // （includeCurrent 保持 false，不重复展示）。
                        child: QueueDisplay(
                          controller: _queueScrollController,
                          // tab 栏与内容之间留 16（M3E 口径）。
                          topPadding: _desktopContentTopPadding,
                        ),
                      ),
                      RepaintBoundary(
                        // 歌词页是唯一订阅播放进度的页内 tab：停在别的 tab
                        // 时通过 nearest scope 放弃 position 订阅（与移动版式
                        // 的 PageView 同一语义）。
                        child: _withTabVisibility(
                          shellVisible: shellVisible,
                          tabIndex: nowPlayingLyricsTabIndex,
                          visibleTab: _desktopTab,
                          child: LyricsWidget(
                            // 桌面歌词区常展开（无迷你条可让位），快捷操作常显。
                            quickActionsEnabled: true,
                            controller: _lyricsScrollController,
                          ),
                        ),
                      ),
                      RepaintBoundary(
                        // 分页左右没有圆点过渡带，顶部留白按 tab 栏下的内容间距；
                        // 内容左右边距由内容自带（16，与 tab 栏对齐）。
                        child: TrackInfoView(
                          controller: _infoScrollController,
                          topPadding: _desktopContentTopPadding,
                        ),
                      ),
                    ],
                  ),
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

    // 壳层可见性只读一次：页面隐藏时内部 tab 一并不活跃（见 _withTabVisibility）。
    final bool shellVisible =
        ShellPageVisibility.maybeVisibleOf(context) ?? true;

    // 桌面版式由壳层启用：布局与窗口宽度解耦（窄窗口也保持两栏），
    // 不走移动骨架的尺寸分支。
    if (widget.desktopLayout) {
      return _buildDesktopLayout(context, shellVisible: shellVisible);
    }

    final bool isLargeScreen = _getIsLargeScreen(context);
    // 布局期写入（不触发重建）：壳层重复点击的忽略判定要读最新布局。
    _isLargeScreen = isLargeScreen;

    if (isLargeScreen) {
      return _buildCollapsedLargeLayout(context, shellVisible: shellVisible);
    }

    // 小屏：播放器高度随展开进度连续插值，
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
                            // 与两栏版式同一门控：只重建翻页子树。
                            child: ValueListenableBuilder<int>(
                              valueListenable: _visibleTab,
                              builder: (context, visibleTab, _) => PageView(
                                controller: _pageController,
                                onPageChanged: _handleVisiblePageChanged,
                                children: _buildTabPages(
                                  context,
                                  shellVisible: shellVisible,
                                  visibleTab: visibleTab,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
