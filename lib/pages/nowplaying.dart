import 'dart:math';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/widgets/adaptive_layout.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/now_playing_controller.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/scroll_edge_fade.dart';
import 'package:molia/widgets/shell_page_visibility.dart';
import 'package:molia/widgets/track_info_view.dart';

import '../l10n/app_localizations.dart';
import '../theme/motion_policy.dart';
import 'nowplaying_desktop_layout.dart';

part 'nowplaying_gestures.dart';

/// 正在播放页：全屏播放器（可收起为 0 高度）+ 队列/歌词/歌曲信息三个 PageView。
///
/// 收起态没有页内迷你条：移动端顶栏的播放条是唯一迷你播放器。收起后本页
/// 直接让出播放器高度给内容区，壳层顶栏播放条回来承接封面 / 歌名 / 传输键。
class NowPlaying extends StatefulWidget {
  /// 顶栏共享元素控制器：全屏播放器为其提供封面/歌名/进度锚点。
  final PlayerMorphController? morph;

  /// 展开 / 收起意图：页面自己的手势入口（圆点、内容下拉、播放器拖拽）
  /// 不直接跑动画，而是请壳层统一发起顶栏 ⇄ 播放页的共享封面飞行。
  ///
  /// 为 null 时（单测直接挂载页面）退回本地动画，便于独立验证页面行为。
  final ValueChanged<bool>? onRequestExpansion;

  /// 外部 tab / 展开请求（如底栏队列按钮「跳播放页 + 切队列」）。
  final NowPlayingController? controller;

  /// 展开态回写：页面在布局 / 动画落定时把「是否完整展开」交给壳层。
  ///
  /// 壳层的 `ShellPresentation` 持有真值；页面只报告自己的高度状态。
  final ValueChanged<bool>? onExpansionChanged;

  /// 布局能力回写：当前版式是否有收起态（窄单栏 true / 宽版式、桌面 false）。
  final ValueChanged<bool>? onMiniCapableChanged;

  /// 桌面骨架专用版式：左「封面 + 控制」固定栏 + 右「队列 / 歌词 / 歌曲
  /// 信息」三 tab（默认歌词，与移动端圆点页序一致）。
  ///
  /// 桌面没有收起态与圆点手势，此模式下展开 / 收起请求忽略；移动骨架
  /// （含平板宽屏）保持既有 PageView 版式。
  final bool desktopLayout;

  const NowPlaying({
    super.key,
    this.morph,
    this.onRequestExpansion,
    this.controller,
    this.onExpansionChanged,
    this.onMiniCapableChanged,
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

  /// 宽版式（左右两栏）/ 桌面版式的滚动控制器。
  ///
  /// 为什么不与单栏复用：旋转或跨断点时新旧版式会在同一帧里短暂共存，
  /// 同一个 ScrollController 同时挂两个 ScrollView 会触发
  /// `_positions.length == 1` 断言。两套控制器让切换自然交接；代价是
  /// 切换版式后滚动位置归零（旋转本来也换了阅读区域）。
  late final ScrollController _wideQueueScrollController;
  late final ScrollController _wideLyricsScrollController;
  late final ScrollController _wideInfoScrollController;

  /// 播放器展开进度：0 = 收起（高度 0）、1 = 完整播放器（小屏）。
  ///
  /// motor expressive spatial 弹簧（380/0.8）：拖动跟手直接写进度，松手按
  /// 手势速度续跑吸附。封面飞行不在这里做——顶栏 ⇄ 播放页的副本由壳层
  /// 统一驱动，页面只负责高度与透明度。
  late final SingleMotionController _expandController;
  bool _isMini = false;

  /// 松手当刻的手势速度（进度域/秒），由 [onRequestExpansion] 之前的
  /// 拖拽入口暂存，等壳层回发 expand / collapse 请求时再交给弹簧续跑。
  ///
  /// 页内手势不直接动画（共享封面飞行由壳层统一发起），速度必须跨这一跳
  /// 传下去；否则每次拖拽松手都会从零速度重新起步，跟手感明显变钝。
  double _pendingExpansionVelocity = 0;

  /// 当前布局是否有收起态（窄单栏）。桌面两栏 / 移动宽版式恒为 false：
  /// 返回层级要据此决定「歌词整页先恢复播放页」还是交给系统退出，壳层也据此
  /// 决定顶栏显示播放条还是品牌位。
  bool _miniCapable = true;

  /// 壳层是否把本页放在前台（布局期写入，不触发重建）。隐藏页的展开态
  /// 不能拦返回：从资料库按返回应先回目的地，而不是收起后台的播放器。
  bool _shellVisible = true;

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

  /// 桌面版式右侧分页：0 = 队列、1 = 歌词、2 = 歌曲信息。
  late int _desktopTab;

  /// 当前是否真的走桌面两栏版式（右侧三 tab）。桌面骨架落到单栏时仍用
  /// PageView，外部 tab 请求必须走跳页而不是改 [_desktopTab]。
  bool _desktopTabs = false;

  /// 已消费到的 [NowPlayingController.tabRequestVersion]：展开 / 收起意图与
  /// tab 请求共用一次通知，只有 tab 版本前进才重放 tab。
  int _handledTabRequest = 0;

  /// 最近一次回写给壳层的展开态 / 布局能力：真值在壳层展示模块，这里只做
  /// 去重，避免每次 build 都排一个帧末写入。
  bool? _reportedExpansion;
  bool _reportedMiniCapable = false;

  /// 移动 / 平板版式当前落定的内容页（PageView 落定后更新）。
  ///
  /// 与 [_desktopTab] 分开：桌面没有 [PageView]，tab 选中态由
  /// `M3ETabsView` 的回调驱动；两者都用于歌词页的 tab 门控（停在队列 /
  /// 信息 tab 时不跟随播放进度）。
  ///
  /// 用 notifier 而不是 state：翻页只需要重建 PageView 子树，不能让播放器 /
  /// 封面 deck 跟着整页 setState 重建。
  late final ValueNotifier<int> _visibleTab;

  // 页面缓存：避免 PageView 每次重建导致歌词/队列滚动状态丢失。
  List<PageData>? _cachedPages;

  /// 缓存页面对应的版式（单栏 / 宽版式）。版式变化必须重建页面，让两套
  /// ScrollController 各自交接（见 [_wideQueueScrollController]）。
  bool? _cachedPagesWide;

  /// 上一次判定过的宽版式结果（null = 尚未判定）。
  bool? _cachedUsesWideLayout;

  @override
  void initState() {
    super.initState();
    // 请求先于挂载（壳层先发请求、页面后才挂载）：作为初始页消费，不补动画。
    final int? requested = widget.controller?.requestedTab;
    _desktopTab = requested ?? nowPlayingLyricsTabIndex;
    _visibleTab = ValueNotifier<int>(requested ?? nowPlayingLyricsTabIndex);
    // 壳层返回层级读的是「当前 tab」：挂载时就同步一次，避免先点开队列
    // 再按 Esc 时壳层还停留在默认歌词页。
    widget.controller?.activeTab.value = requested ?? nowPlayingLyricsTabIndex;
    // 挂载前已消费过的请求不再重放（初始页已经取过 requestedTab）。
    _handledTabRequest = widget.controller?.tabRequestVersion ?? 0;
    _pageController = PageController(
      initialPage: requested ?? _currentPageIndex,
    );
    _queueScrollController = ScrollController();
    _lyricsScrollController = ScrollController();
    _infoScrollController = ScrollController();
    _wideQueueScrollController = ScrollController();
    _wideLyricsScrollController = ScrollController();
    _wideInfoScrollController = ScrollController();
    _expandController = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialDefault(
        snapToEnd: true,
      ),
      vsync: this,
      initialValue: 0,
    )..value = 1.0;
    _expandController.addListener(_handleExpandProgress);
    widget.controller?.addListener(_handleControllerRequest);
  }

  @override
  void didUpdateWidget(covariant NowPlaying oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleControllerRequest);
      widget.controller?.addListener(_handleControllerRequest);
    }
    // 回写通道换了接收方：去重缓存作废，下一次布局重新报告真值。
    if (oldWidget.onExpansionChanged != widget.onExpansionChanged) {
      _reportedExpansion = null;
    }
    if (oldWidget.onMiniCapableChanged != widget.onMiniCapableChanged) {
      _reportedMiniCapable = false;
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_handleControllerRequest);
    _expandController.dispose();
    _pageController.dispose();
    _visibleTab.dispose();
    _queueScrollController.dispose();
    _lyricsScrollController.dispose();
    _infoScrollController.dispose();
    _wideQueueScrollController.dispose();
    _wideLyricsScrollController.dispose();
    _wideInfoScrollController.dispose();
    super.dispose();
  }

  List<PageData> _buildPages(BuildContext context, {required bool wide}) {
    if (_cachedPages != null && _cachedPagesWide == wide) {
      return _cachedPages!;
    }
    _cachedPagesWide = wide;
    final queueController = wide
        ? _wideQueueScrollController
        : _queueScrollController;
    final lyricsController = wide
        ? _wideLyricsScrollController
        : _lyricsScrollController;
    final infoController = wide
        ? _wideInfoScrollController
        : _infoScrollController;

    _cachedPages = [
      PageData(
        title: AppLocalizations.of(context)!.queueTab,
        icon: Icons.queue_music_rounded,
        page: RepaintBoundary(
          // 稳定 key：测试 / 自动化按它断言「当前落在哪一页」。
          key: const Key('nowPlayingQueuePage'),
          child: QueueDisplay(
            controller: queueController,
            // 顶部留出圆点过渡带，列表首项不被渐隐吃掉。
            topPadding: _dotsBandHeight + 2,
          ),
        ),
      ),
      PageData(
        title: AppLocalizations.of(context)!.lyricsTab,
        icon: Icons.lyrics_rounded,
        page: RepaintBoundary(
          key: const Key('nowPlayingLyricsPage'),
          // 歌词快捷操作只在收起态（歌词区展开）显示。
          child: LyricsWidget(
            quickActionsEnabled: _isMini,
            controller: lyricsController,
          ),
        ),
      ),
      PageData(
        title: AppLocalizations.of(context)!.trackInfoTabTitle,
        icon: Icons.info_rounded,
        page: RepaintBoundary(
          key: const Key('nowPlayingInfoPage'),
          child: TrackInfoView(
            controller: infoController,
            // 顶部留出圆点过渡带，内容首行不被渐隐吃掉（与队列页一致）。
            topPadding: _dotsBandHeight + 2,
          ),
        ),
      ),
    ];

    return _cachedPages!;
  }

  /// PageView 内容页：每页按「壳层可见 && 是当前 tab」套上可见性 scope。
  ///
  /// [wide] 决定页面缓存使用哪一套滚动控制器（见 [_wideQueueScrollController]）。
  List<Widget> _buildTabPages(
    BuildContext context, {
    required bool shellVisible,
    required int visibleTab,
    required bool wide,
  }) {
    final pages = _buildPages(context, wide: wide);
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
    widget.controller?.activeTab.value = index;
  }

  /// 收起态切换的重建转发：`nowplaying_gestures.dart` 的 extension 不能直接
  /// 调用 protected 的 `setState`（Dart 限制），留一个私有转发。
  void _applyMiniState(bool mini) {
    setState(() {
      _isMini = mini;
      // 歌词页操作按钮可见性跟随展开态，需重建页面实例。
      _cachedPages = null;
    });
  }

  @override
  bool get wantKeepAlive => true;

  bool _getUsesWideLayout(BuildContext context) {
    final bool wide = usesWideNowPlayingLayout(AdaptiveLayoutScope.of(context));

    // 只有版式真正切换时才失效页面缓存。窗口拖动时 MediaQuery 尺寸每帧都
    // 变，若按尺寸清缓存，三个 tab 页会每帧重建、滚动位置与已解码内容全丢；
    // 宽度变化本身由歌词 / 队列 / 信息页各自自适应，不需要重造页面。
    if (wide != _cachedUsesWideLayout) {
      _cachedUsesWideLayout = wide;
      _cachedPages = null;
    }
    return wide;
  }

  /// 圆点过渡带高度：内容顶部在这条带内渐隐，圆点浮于其中。
  ///
  /// 20 是「圆点 + 上下各 6 的手感余量」这一档：带子只影响内容首行的渐隐与
  /// 首项留白（队列 / 信息页的 `topPadding` 同源），再高就是白给的空行。
  static const double _dotsBandHeight = 20;

  /// 歌词/队列小圆点切换行（常显；由父级 Positioned 撑满宽度）。
  ///
  /// [wide] 与 [_buildTabPages] 同源：圆点标签页也读当前版式的页面缓存。
  /// [onActiveTap] 点击已激活圆点时触发（播放页 = 展开/收起切换）。
  Widget _buildDotsRow({VoidCallback? onActiveTap, required bool wide}) {
    return SizedBox(
      width: double.infinity,
      height: _dotsBandHeight,
      child: Center(
        child: LyricsQueueDots(
          pages: _buildPages(context, wide: wide),
          pageController: _pageController,
          onActiveTap: onActiveTap,
        ),
      ),
    );
  }

  /// 内容顶部渐隐过渡：列表/歌词滑到圆点带下面时淡出（不是硬切）。
  ///
  /// 论证（为什么用覆盖层而不是 ShaderMask）见 [ScrollEdgeFade]。
  Widget _buildTopFade(BuildContext context, {required Widget child}) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _dotsBandHeight,
          child: ScrollEdgeFade(edge: FadeEdge.top, extent: _dotsBandHeight),
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
      key: const Key('wideNowPlayingLayout'),
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
                            wide: true,
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
                  child: RepaintBoundary(child: _buildDotsRow(wide: true)),
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
    if (index == _desktopTab) {
      widget.controller?.activeTab.value = index;
      return;
    }
    setState(() => _desktopTab = index);
    widget.controller?.activeTab.value = index;
  }

  /// 桌面骨架版式：左播放器 + 右队列 / 歌词 / 信息三 tab（版式见
  /// `nowplaying_desktop_layout.dart`；本页只传状态与控制器）。
  Widget _buildDesktopLayout(
    BuildContext context, {
    required bool shellVisible,
  }) {
    return NowPlayingDesktopLayout(
      morph: widget.morph,
      selectedTab: _desktopTab,
      onTabSelected: _selectDesktopTab,
      queueController: _wideQueueScrollController,
      lyricsController: _wideLyricsScrollController,
      infoController: _wideInfoScrollController,
      wrapLyrics: (child) => _withTabVisibility(
        shellVisible: shellVisible,
        tabIndex: nowPlayingLyricsTabIndex,
        visibleTab: _desktopTab,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // 壳层可见性只读一次：页面隐藏时内部 tab 一并不活跃（见 _withTabVisibility）。
    final bool shellVisible =
        ShellPageVisibility.maybeVisibleOf(context) ?? true;
    // 布局期写入：隐藏页的展开态不参与壳层返回层级（见 _syncExpanded）。
    _shellVisible = shellVisible;

    // 桌面版式由壳层启用：宽窗口用「左播放器 + 右队列/歌词/信息」两栏；
    // 窄窗口（compact / medium）退回单栏，480 窗口下两栏必然互相挤压。
    final layout = AdaptiveLayoutScope.of(context);
    if (widget.desktopLayout && layout.isExpanded) {
      _desktopTabs = true;
      _miniCapable = false;
      _syncExpanded();
      _syncMiniCapable();
      return _buildDesktopLayout(context, shellVisible: shellVisible);
    }
    _desktopTabs = false;

    final bool usesWideLayout = _getUsesWideLayout(context);
    // 桌面骨架即使窗口落到单栏也没有顶栏播放条可承接收起态：始终按
    // 「不可收起」写回，避免收起成 0 高度后没有明确的展开入口。
    _miniCapable = !widget.desktopLayout && !usesWideLayout;
    _syncExpanded();
    _syncMiniCapable();

    if (usesWideLayout) {
      return _buildCollapsedLargeLayout(context, shellVisible: shellVisible);
    }

    // 小屏 / 中屏：播放器高度随展开进度连续插值（收起为 0），
    // 下方是歌词/队列圆点切换行与内容区。
    return Scaffold(
      key: const Key('singlePaneNowPlaying'),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 矮窗口（贴靠到 480×400）不能沿用 340 的地板：地板高于可用高度时
          // 内容区会被压成 0。窗口高 < 520 时改为「播放器 + 140 内容」，
          // 保证歌词 / 队列仍有一行可操作的高度。
          final double playerMaxHeight = constraints.maxHeight < 520
              ? max(180.0, constraints.maxHeight - 140)
              : max(340.0, constraints.maxHeight - 180);
          // 供播放器区域的跟手拖拽换算行程（布局期写入，不触发重建）。
          _playerMaxHeight = playerMaxHeight;
          return Column(
            children: [
              // 播放器区域：展开态下拉收起（收起态高度为 0，上拉入口在内容区）。
              // 宽版式 / 桌面版式没有收起态，不挂拖拽回调：否则能把高度拖小且
              // 松手后壳层拒绝收起，停在半截。
              GestureDetector(
                onVerticalDragUpdate: _miniCapable
                    ? _handlePlayerDragUpdate
                    : null,
                onVerticalDragEnd: _miniCapable ? _handlePlayerDragEnd : null,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: playerMaxHeight),
                  child: Player(
                    isLargeScreen: false,
                    morph: widget.morph,
                    expandAnimation: _expandController,
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
                                  wide: false,
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
                        child: _buildDotsRow(
                          onActiveTap: _toggleExpand,
                          wide: false,
                        ),
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
