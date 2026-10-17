/// 应用壳（App Shell）：导航栏 / 顶栏 / 迷你播放条 / 页面层。
///
/// main.dart 是唯一 composition root 且禁止被测试 import，壳层独立成文件后
/// 测试可直接挂载。composition root 仍负责创建 provider 与主题，本文件只
/// 消费注入的 provider。
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../pages/favorites.dart';
import '../pages/library.dart';
import '../pages/nowplaying.dart';
import '../pages/settings_page.dart';
import '../providers/nav_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/theme_provider.dart';
import '../services/app_branding_service.dart';
import '../services/data_saver_service.dart';
import '../services/haptics.dart';
import '../services/language_service.dart';
import '../services/play_statistics_service.dart';
import '../services/window/window_chrome.dart';
import '../theme/animated_scheme.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_network_image.dart';
import '../widgets/cover_appearance.dart';
import '../widgets/icon_swap.dart';
import '../widgets/nav_destination_icons.dart';
import '../widgets/playback_selectors.dart';
import '../widgets/player_morph.dart';
import '../widgets/shell_reselect.dart';
import '../widgets/shell_page_visibility.dart';

/// 当前曲目的封面 URL（空串视同无封面）：顶栏真身与共享飞行副本同一份取值。
String? _coverUrlOf(PlaybackProvider provider) =>
    artworkUrlOf(provider.snapshot.current);

/// 顶栏进度条槽高（= M3E 波浪进度条容器高 `wavyContainerHeight`，振幅有空间）。
///
/// 高度必须由消费面钉死：`AppBar.bottom` 只声明 `preferredSize`、**不给子级
/// 收紧约束**，AppBar 内部又把 bottom 放进 `Column(spaceBetween)` —— 子级拿到
/// 松约束并底对齐。平直态（暂停）自身只有 4dp 高，不钉住时其中心比波浪态
/// （10dp）低 3dp，play/pause 切换整条跳变。
const double _shellBarProgressHeight = 10;


/// 顶栏底部进度条：播放中波浪、暂停平直（波浪动画不会停，会像还在播放）。
///
/// 槽高固定为 [_shellBarProgressHeight]：两种形态同槽心，play/pause 切换
/// 不跳（AppBar.bottom 给子级的是松约束，见常量注释）。
class ProgressIndicator extends StatefulWidget {
  /// 当前进度（来自 provider.position 单一时钟，无自外推）。
  final Duration position;
  final double duration;

  /// 是否正在播放：暂停时用非波浪进度条（波浪动画会一直动，像还在播放）。
  final bool isPlaying;

  const ProgressIndicator({
    super.key,
    required this.position,
    required this.duration,
    this.isPlaying = true,
  });

  @override
  State<ProgressIndicator> createState() => _ProgressIndicatorState();
}

class _ProgressIndicatorState extends State<ProgressIndicator>
    with SingleTickerProviderStateMixin {
  late double _currentProgress;
  late final AnimationController _animationController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _currentProgress = widget.position.inMilliseconds.toDouble();

    _progressAnimation = Tween<double>(
      begin: _currentProgress,
      end: _currentProgress,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void didUpdateWidget(ProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.position.inMilliseconds.toDouble();
    // 仅 seek/切歌等 >1s 的跳变做 300ms 平滑过渡；
    // 常规推进直接跟随 position 通道。
    if ((target - _currentProgress).abs() > 1000) {
      final display = _animationController.isAnimating
          ? _progressAnimation.value
          : _currentProgress;
      _progressAnimation = Tween<double>(
        begin: display,
        end: target,
      ).animate(CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOut,
      ));
      _currentProgress = target;
      _animationController.forward(from: 0);
    } else {
      _currentProgress = target;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progressAnimation,
      builder: (context, child) {
        final displayProgress = _animationController.isAnimating
            ? _progressAnimation.value
            : _currentProgress;
        final double? fraction = widget.duration > 0
            ? (displayProgress / widget.duration).clamp(0.0, 1.0)
            : null;

        // 暂停时切到平直进度条：波浪动画不会停，与暂停状态矛盾。
        // 固定槽高见 [_shellBarProgressHeight]：两种形态同槽心，不跳变。
        return SizedBox(
          height: _shellBarProgressHeight,
          child: widget.isPlaying
              ? M3EProgressIndicator.linearWavy(
                  value: fraction,
                  linearSize: M3EProgressIndicatorSize.s,
                  strokeWidth: 4.0,
                  trackStrokeWidth: 4.0,
                  trackColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  color: Theme.of(context).colorScheme.primary,
                )
              : M3EProgressIndicator.linear(
                  value: fraction,
                  linearSize: M3EProgressIndicatorSize.s,
                  strokeWidth: 4.0,
                  trackStrokeWidth: 4.0,
                  trackColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  color: Theme.of(context).colorScheme.primary,
                ),
        );
      },
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  /// 顶栏 ↔ 播放页共享元素飞行控制器。
  final PlayerMorphController _morph = PlayerMorphController();

  /// 顶栏曲目信息区（歌名/作者 + 播放/下一首按钮）的入场进度。
  ///
  /// 一根 expressive spatial 弹簧同时驱动文本位移/淡入与按钮缩放 pop：
  /// 文本与按钮是两个兄弟子树，弹簧必须由共同祖先持有，不能各建一根。
  late final _BarHeaderReveal _barReveal;

  /// tab 淡入淡出（fade-through）控制器。
  late final AnimationController _tabTransition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..value = 1.0;

  /// 共享元素飞行控制器。
  ///
  /// M3E no-overshoot spatial 弹簧（`aospSpatial` 380/1.0，对齐 Android 共享
  /// 元素默认 `spring(StiffnessMediumLow=400, noBouncy)`）：副本在弹簧落定帧
  /// 零速度精确交接。每次飞行的起点用新抓取的锚点几何（`from: 0`），中途被
  /// 打断则直接换新飞。
  late final SingleMotionController _morphAnimation = SingleMotionController(
    motion:
        SpringMotion(M3EMotion.aospSpatial.toDescription(), snapToEnd: true),
    vsync: this,
    initialValue: 1,
  );

  OverlayEntry? _morphEntry;
  PlayerMorphGeometry? _morphGeometry;
  int _morphToken = 0;

  /// 每个目的地一个「重复点击」意图通道：页面订阅后自行响应
  /// （播放页 = 迷你 ⇄ 完整；资料库 / 收藏 = 回到列表顶部），壳层不消费。
  final Map<ShellDestination, ShellReselectSignal> _reselect = {
    for (final destination in ShellDestination.values)
      destination: ShellReselectSignal(),
  };

  /// 页面实例固定（key 稳定），顺序/显隐只影响底栏映射与分层透明度，
  /// 页面状态（滚动/搜索词等）天然保持。
  late final Map<ShellDestination, Widget> _pages = {
    ShellDestination.nowPlaying: NowPlaying(
      morph: _morph,
      reselect: _reselect[ShellDestination.nowPlaying],
    ),
    ShellDestination.favorites: FavoritesPage(
      reselect: _reselect[ShellDestination.favorites],
    ),
    ShellDestination.library: Library(
      reselect: _reselect[ShellDestination.library],
    ),
  };

  /// 当前选中的目的地（与底栏顺序解耦；默认落在播放页）。
  ShellDestination _selectedDestination = ShellDestination.nowPlaying;
  ShellDestination _previousDestination = ShellDestination.nowPlaying;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _morphAnimation.addListener(_onMorphTick);
    // 冷启动默认落在播放页：顶栏必须与「手动进入播放页」后的状态一致
    // （收起为应用标识）。否则恢复会话后顶栏会重复显示曲目封面/进度。
    _morph.setBarHeaderHidden(
      _selectedDestination == ShellDestination.nowPlaying,
    );
    _barReveal = _BarHeaderReveal(
      vsync: this,
      revealed: !_morph.barHeaderHidden,
    );
    _morph.addListener(_syncBarReveal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ThemeProvider>().updateThemeFromSystem(context);
    });
  }

  /// 顶栏曲目信息区跟随 [PlayerMorphController.barHeaderHidden]（飞行起止
  /// 时也由它统一翻转，避免两处各判一次）。
  void _syncBarReveal() => _barReveal.setRevealed(!_morph.barHeaderHidden);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _morphAnimation.removeListener(_onMorphTick);
    _morphAnimation.dispose();
    _tabTransition.dispose();
    _morph.removeListener(_syncBarReveal);
    _barReveal.dispose();
    _morphEntry?.remove();
    _morphEntry = null;
    _morph.dispose();
    for (final signal in _reselect.values) {
      signal.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<ThemeProvider>().updateThemeFromSystem(context);
    }
  }

  @override
  void didChangePlatformBrightness() {
    context.read<ThemeProvider>().updateThemeFromSystem(context);
  }

  /// 目的地被点击（底栏与导航轨共用）：
  /// - 未选中 → 切页（含顶栏 ⇄ 播放页共享元素飞行）；
  /// - 已选中 → 把重复点击交给页面：播放页切换迷你 ⇄ 完整、
  ///   资料库 / 收藏回到列表顶部。
  ///
  /// 进入播放页的飞行期间忽略重复点击：此刻折叠会与飞行副本抢封面
  /// （页内迷你 ⇄ 完整飞行与顶栏飞行同帧竞争），等飞行落定（~0.4s）再切换。
  void _onDestinationSelected(ShellDestination destination) {
    if (destination != _selectedDestination) {
      _selectDestination(destination);
      return;
    }
    if (destination == ShellDestination.nowPlaying && _morphGeometry != null) {
      return;
    }
    // 重复点击是一次真实的点按（列表回顶 / 播放器折叠都是肉眼可见的动作），
    // 给一次轻震：壳层统一在此触发 —— 页面侧对重复点击的响应不再自带触感，
    // 避免同一次点击两次震动（命中忽略分支时不震动）。
    HapticsService.lightImpact();
    _reselect[destination]?.trigger();
  }

  void _selectDestination(ShellDestination destination) {
    if (destination == _selectedDestination) return;
    HapticsService.lightImpact();
    final leavingPlayer = _selectedDestination == ShellDestination.nowPlaying;
    final enteringPlayer = destination == ShellDestination.nowPlaying;
    setState(() {
      _previousDestination = _selectedDestination;
      _selectedDestination = destination;
    });
    _tabTransition.forward(from: 0);
    if (enteringPlayer) {
      _startMorph(toPage: true);
    } else if (leavingPlayer) {
      _startMorph(toPage: false);
    } else {
      // 两端都不是播放页：不涉及共享元素，确保两端真身可见。
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(false);
    }
  }

  /// 开始一次顶栏 ↔ 播放页飞行；锚点缺失（迷你态/首帧）时优雅跳过。
  void _startMorph({required bool toPage}) {
    _completeMorph();
    final geometry = _morph.captureGeometry(toPage: toPage);
    if (geometry == null) {
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(toPage);
      return;
    }
    _morph.setBarHeaderHidden(true);
    if (toPage) _morph.setPageHeaderHidden(true);
    _morphGeometry = geometry;
    // 封面 URL 与锚点在同一刻抓取：飞行期间不换图（副本承接的是起飞时那一张）。
    final url = _coverUrlOf(context.read<PlaybackProvider>());
    final token = ++_morphToken;
    _morphEntry = OverlayEntry(
      builder: (context) => PlayerMorphFlight(
        animation: _morphAnimation,
        geometry: geometry,
        url: url,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_morphEntry!);
    // 弹簧从起点跑满全程；落定帧由 [_onMorphTick] 完成交接（whenComplete
    // 只是兜底：中途被新飞行接管会被取消，不触发）。
    _morphAnimation.animateTo(1, from: 0, withVelocity: 0).whenComplete(() {
      if (!mounted || token != _morphToken) return;
      _completeMorph();
    });
  }

  /// 飞行到达（[PlayerMorphFlight.flightPortion]）即在同一帧完成交接：
  /// 先亮出目标端真身、再移除飞行副本，两端封面位置完全一致，无尾段闪烁。
  ///
  /// `snapToEnd` 保证最后一步 value 精确为 1.0，此处即落定帧（零速度）。
  void _onMorphTick() {
    if (_morphGeometry == null) return;
    if (_morphAnimation.value >= PlayerMorphFlight.flightPortion) {
      _completeMorph();
    }
  }

  void _removeMorphOverlay() {
    _morphEntry?.remove();
    _morphEntry = null;
  }

  void _completeMorph() {
    _morphToken++;
    final geometry = _morphGeometry;
    _morphGeometry = null;
    if (geometry == null) {
      _removeMorphOverlay();
      return;
    }
    // 落位：目标端真身瞬时亮出（AnimatedOpacity 的 reveal 方向时长为 0），
    // 同一帧移除飞行副本；播放页激活时顶栏收起（内容由页面承接）。
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(geometry.toPage);
    _removeMorphOverlay();
  }

  String _destinationLabel(
    AppLocalizations l10n,
    ShellDestination destination,
  ) =>
      switch (destination) {
        ShellDestination.nowPlaying => l10n.nowPlayingLabel,
        ShellDestination.favorites => l10n.favoritesLabel,
        ShellDestination.library => l10n.libraryLabel,
      };

  /// 打开设置弹层（顶栏入口，三个目的地共用）；返回处理见 [showSettingsSheet]。
  void _openSettings(BuildContext context) {
    HapticsService.lightImpact();
    showSettingsSheet(context);
  }

  /// 页面分层：选中页在最上层淡入，上一页快速淡出（fade-through）。
  Widget _buildPageStack() {
    final ordered = <ShellDestination>[
      for (final destination in ShellDestination.values)
        if (destination != _selectedDestination) destination,
      _selectedDestination,
    ];
    return Stack(
      children: [
        for (final destination in ordered)
          _ShellPageLayer(
            key: ValueKey(destination),
            selected: destination == _selectedDestination,
            outgoing: destination == _previousDestination &&
                destination != _selectedDestination,
            animation: _tabTransition,
            child: _pages[destination]!,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shellLayout = context.layoutType(ResponsivePageType.shell);
    final isLargeScreen = shellLayout.preferTwoPane;
    final l10n = AppLocalizations.of(context)!;
    final visibleDestinations =
        context.watch<NavProvider>().visibleDestinations;
    // 选中项被隐藏时回退到第一个可见目的地（重新显示后自动恢复）。
    final selectedDestination = visibleDestinations.isEmpty
        ? _selectedDestination
        : (visibleDestinations.contains(_selectedDestination)
            ? _selectedDestination
            : visibleDestinations.first);
    final selectedIndex = visibleDestinations.indexOf(selectedDestination);

    // 顶栏整体是窗口拖动区（隐藏标题栏后唯一的拖动入口）：外层 PreferredSize
    // 用 AppBar 自报高度（56 工具栏 + 10 波浪进度），总高度与改动前一致，
    // 非桌面平台 WindowDragArea 是纯透传。
    final appBar = AppBar(
      titleSpacing: 12,
      // 壳层是根页面，永远不需要返回键；且路由内的局部历史条目
      // （如 M3E 下拉菜单打开时）会让 ModalRoute.canPop 变真，
      // 默认的 automaticallyImplyLeading 会在此刻冒出返回箭头。
      automaticallyImplyLeading: false,
      title: WindowDoubleTapMaximize(
        // 双击顶栏标题区（拖动区的非按钮部分）= 最大化 / 还原（桌面肌肉记忆）；
        // 按钮区不参与，避免双击按钮顺带改窗口状态。
        child: _ShellBarHeader(
          morph: _morph,
          reveal: _barReveal,
          onOpenPlayer: () => _selectDestination(ShellDestination.nowPlaying),
        ),
      ),
      actions: [
        // 顶栏右侧：播放页只留设置（播放/切歌由页面内部控制区承担）；
        // 其余页面（资料库 / 收藏）是迷你播放器（显式播放/暂停 + 下一首）
        // 加设置入口 —— 设置不再只有播放页够得着。
        // 两个按钮与歌名/作者共用同一根入场弹簧（缩放 pop + 淡入）。
        if (selectedDestination != ShellDestination.nowPlaying) ...[
          _BarPlayPauseButton(reveal: _barReveal),
          _BarNextButton(reveal: _barReveal),
        ],
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          onPressed: () => _openSettings(context),
          tooltip: l10n.settingsTitle,
          icon: const Icon(Icons.settings_rounded),
        ),
        if (WindowChrome.isSupported) const _WindowControls(),
        const SizedBox(width: 8),
      ],
      bottom: PreferredSize(
        // 波浪进度条需要振幅空间（M3E 默认 wavyContainerHeight=10）；
        // 高度同时由 `_shellBarProgressHeight` 钉在进度条自身，见该常量注释。
        preferredSize: const Size.fromHeight(_shellBarProgressHeight),
        child: _ShellBarProgress(morph: _morph),
      ),
    );

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(
          AppBar.preferredHeightFor(context, appBar.preferredSize),
        ),
        child: WindowDragArea(child: appBar),
      ),
      body: Row(
        children: [
          if (isLargeScreen)
            M3ENavigationRail(
              // 固定 96dp 窄轨（alwaysCollapse）：无展开按钮、不可展开；
              // 标签常显，替代 Material 侧 hover 才出现的 tooltip。
              type: M3ENavigationRailType.alwaysCollapse,
              selectedIndex: selectedIndex,
              onDestinationSelected: (int index) =>
                  _onDestinationSelected(visibleDestinations[index]),
              sections: [
                M3ENavigationRailSection(
                  destinations: [
                    for (final destination in visibleDestinations)
                      M3ENavigationRailDestination(
                        icon: destination.outlinedIcon,
                        selectedIcon: destination.filledIcon,
                        label: _destinationLabel(l10n, destination),
                      ),
                  ],
                ),
              ],
            ),
          Expanded(child: _buildPageStack()),
        ],
      ),
      bottomNavigationBar: isLargeScreen
          ? null
          : SafeArea(
              bottom: false,
              child: M3ENavigationBar(
                // iOS 使用紧凑高度（M3E 最小档 64）。
                size: defaultTargetPlatform == TargetPlatform.iOS
                    ? M3ENavBarSize.small
                    : M3ENavBarSize.medium,
                labelBehavior: M3ENavBarLabelBehavior.onlySelected,
                selectedIndex: selectedIndex,
                onDestinationSelected: (int index) =>
                    _onDestinationSelected(visibleDestinations[index]),
                destinations: [
                  for (final destination in visibleDestinations)
                    M3ENavigationBarDestination(
                      icon: destination.outlinedIcon,
                      selectedIcon: destination.filledIcon,
                      label: _destinationLabel(l10n, destination),
                    ),
                ],
              ),
            ),
    );
  }
}

/// 单个 tab 页分层在过渡进度 [progress]（`_tabTransition` 原始值 0..1）
/// 下的透明度与缩放。
///
/// 不变量：**除「过渡进行中的出场层」外，任何状态的缩放都必须是 1.0**。
/// 顶栏⇄播放页飞行在点击那一刻同步抓取锚点（`localToGlobal` 含祖先变换），
/// 隐藏页残留的非 1 缩放会让飞行副本落在错误的位置/尺寸上，交接瞬间真身
/// 跳变（「飞过头再复位」）。出场微缩只在过渡进行中有意义——过渡走完时
/// opacity 已是 0，此后按 1.0 参与布局与后续锚点抓取。
///
/// 入场同理不做微缩（历史回归：入场缩放曾让副本落在缩放后的位置）。
@visibleForTesting
({double opacity, double scale}) shellPageLayerPresentation({
  required bool selected,
  required bool outgoing,
  required double progress,
}) {
  final t = Curves.easeInOutCubic.transform(progress);
  if (selected) {
    final inT = Curves.easeOutCubic.transform(
      ((t - 0.15) / 0.85).clamp(0.0, 1.0),
    );
    return (opacity: inT, scale: 1.0);
  }
  if (outgoing && progress < 1.0) {
    final outT = (t / 0.35).clamp(0.0, 1.0);
    return (
      opacity: 1.0 - Curves.easeInCubic.transform(outT),
      scale: 1.0 + (0.97 - 1.0) * outT,
    );
  }
  return (opacity: 0.0, scale: 1.0);
}

/// 单个 tab 页的分层包装：fade-through（出场快速淡出微缩，入场淡入回落）。
///
/// `child` 为稳定实例：动画每帧只重建包装层，页面子树不重建（状态保持）。
/// 透明度/缩放由 [shellPageLayerPresentation] 唯一计算（含「隐藏页必须
/// scale==1」约束）。
class _ShellPageLayer extends StatelessWidget {
  const _ShellPageLayer({
    super.key,
    required this.selected,
    required this.outgoing,
    required this.animation,
    required this.child,
  });

  final bool selected;
  final bool outgoing;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final presentation = shellPageLayerPresentation(
          selected: selected,
          outgoing: outgoing,
          progress: animation.value,
        );
        // 可见性门控：隐藏页面的组件放弃 provider 订阅（见 ShellPageVisibility），
        // TickerMode 只静音动画，挡不住 ChangeNotifier 触发的整页重建。
        return ShellPageVisibility(
          visible: selected,
          child: IgnorePointer(
            ignoring: !selected,
            child: TickerMode(
              enabled: selected,
              child: Opacity(
                opacity: presentation.opacity,
                child: Transform.scale(
                  scale: presentation.scale,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶栏头部：左侧当前曲目封面（无封面回退音符图标），旁边歌名 + 作者。
///
/// 点击整条头部进入播放页（与点底栏「播放」同路径，触发共享封面飞行）；
/// 播放页激活（或飞行中）时交叉淡出为应用图标 + 自定义应用名，不响应点击。
class _ShellBarHeader extends StatelessWidget {
  const _ShellBarHeader({
    required this.morph,
    required this.reveal,
    required this.onOpenPlayer,
  });

  final PlayerMorphController morph;

  /// 曲目信息区入场进度（与播放/下一首按钮共用一根弹簧，见 [_BarHeaderReveal]）。
  final _BarHeaderReveal reveal;

  /// 进入播放页。点击区域覆盖封面 + 歌名整条：封面 40×40 仍达不到 48dp
  /// 的独立触控目标，也不符合迷你条「点哪都进播放页」的惯例。
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    // 无曲目标题时信息区本来就回退应用名，不做入场动画（避免同文案
    // 位移淡入与标题淡出叠影）。
    final hasTrackTitle = context.select<PlaybackProvider, bool>(
      (provider) {
        final track = provider.snapshot.current;
        return track != null && track.title.isNotEmpty;
      },
    );
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        // 刻意不用 M3ETappable：它点击时会请求焦点，搜索页输入中点击顶栏
        // 会打断输入；GestureDetector 与播放页封面的手势实现保持一致。
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: showTrack ? onOpenPlayer : null,
          child: Row(
            children: [
              // 封面与歌名+作者两行文本等高（titleMedium 24 + labelSmall 16）。
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedOpacity(
                      // 顶栏⇄播放页飞行落位时，真身封面必须与副本移除同帧亮出
                      // （duration 0 = 同步跳变）；收起方向的淡出保持 160ms。
                      duration: showTrack
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      opacity: showTrack ? 1 : 0,
                      child: _BarCover(key: morph.barCoverKey),
                    ),
                    AnimatedOpacity(
                      duration: showTrack
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      opacity: showTrack ? 0 : 1,
                      child: ColorFiltered(
                        // 同 MoliaMark：Image.color 在 Impeller 下会引入
                        // 1px 边缘杂线（见已知坑 19），用 ColorFiltered 着色。
                        colorFilter: ColorFilter.mode(
                          Theme.of(context).colorScheme.onSurface,
                          BlendMode.srcIn,
                        ),
                        child: Image.asset(
                          'assets/icons/adaptive_icon_monochrome.png',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: hasTrackTitle
                    ? _BarHeaderTransition(reveal: reveal, showTrack: showTrack)
                    : const _AppTitleText(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶栏曲目信息区（歌名/作者 + 播放/下一首按钮）的共享入场进度。
///
/// 一根 expressive spatial 弹簧（800 / 0.6，轻微过冲，`snapToEnd` 落定精确
/// 吸附）从 0（隐藏）到 1（展示）；消费面把进度 clamp 到 0..1 后派生
/// 位移 / 缩放与透明度（effects 不过冲）。文本与按钮是两个兄弟子树，
/// 弹簧由壳层 State 持有后分别消费；快速连切靠 motor 中途重定向续接。
class _BarHeaderReveal extends ChangeNotifier {
  _BarHeaderReveal({required TickerProvider vsync, required bool revealed})
      : _motion = SingleMotionController(
          motion: SpringMotion(
            M3EMotion.expressiveSpatialFast.toDescription(),
            snapToEnd: true,
          ),
          vsync: vsync,
          initialValue: revealed ? 1 : 0,
        ) {
    _motion.addListener(notifyListeners);
  }

  final SingleMotionController _motion;

  /// 原始弹簧进度（可能短暂过冲 1；消费面自行 clamp）。
  double get progress => _motion.value;

  void setRevealed(bool value) => _motion.animateTo(value ? 1 : 0);

  @override
  void dispose() {
    _motion.removeListener(notifyListeners);
    _motion.dispose();
    super.dispose();
  }
}

/// 顶栏文本区转场：歌名 + 作者作为一块整体入场（不错峰），应用名出场
/// 先行走短时长淡出（fade-through 先后节奏，消除两段文字长时间叠影）。
///
/// 入场方向（曲目信息）：expressive spatial 弹簧驱动 −6dp → 0 位移，
/// 透明度从同一根弹簧进度 clamp 0..1（spatial 与 effects 同帧耦合）。
/// 出场方向（应用名）：90ms + 曲线淡出（effects 保持时长+曲线，不走弹簧）。
class _BarHeaderTransition extends StatelessWidget {
  const _BarHeaderTransition({required this.reveal, required this.showTrack});

  final _BarHeaderReveal reveal;

  /// true = 展示曲目信息（应用名出场中）。
  final bool showTrack;

  /// 入场横向位移幅度（dp）：4–8dp 区间，避免与封面飞行的零速度交接打架。
  static const double _offsetX = 6;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) {
        final t = reveal.progress.clamp(0.0, 1.0);
        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            Transform.translate(
              offset: Offset(-_offsetX * (1 - t), 0),
              child: Opacity(
                opacity: t,
                child: const _BarTrackInfo(),
              ),
            ),
            AnimatedOpacity(
              // 出场 90ms（先走），入场保持 160ms（与旧观感一致）。
              duration: Duration(milliseconds: showTrack ? 90 : 160),
              curve: showTrack ? Curves.easeIn : Curves.easeOut,
              opacity: showTrack ? 0 : 1,
              child: const _AppTitleText(),
            ),
          ],
        );
      },
    );
  }
}

/// 顶栏封面：跟随当前曲目；无封面时音符图标兜底。
///
/// 点击进入播放页的手势由 [_ShellBarHeader] 整条承接（封面 40×40
/// 仍小于 48dp 触控目标），本组件只负责展示，避免手势与展示耦合。
class _BarCover extends StatelessWidget {
  const _BarCover({super.key});

  @override
  Widget build(BuildContext context) {
    final coverUrl = context.select<PlaybackProvider, String?>(
      _coverUrlOf,
    );
    // 卡片外观（r8、无描边阴影、回退图标 22）由 CoverAppearance.bar 统一给出。
    return CoverCard(
      size: 40,
      appearance: CoverAppearance.bar,
      content: (context, clip, iconSize) => AppNetworkImage(
        url: coverUrl,
        borderRadius: clip,
        // 与飞行副本共用同一外观源（图标态飞行起点必须与真身同尺寸）。
        fallbackIconSize: iconSize,
      ),
    );
  }
}

/// 顶栏「播放/暂停」按钮（非播放页）：图标随播放态切换；无曲目（含冷启动
/// 恢复态）时禁用，与「下一首」同一契约。`select` 只订阅 hasTrack/播放态，
/// 不触发整个 Shell 重建。
///
/// 顶栏唯一的高亮按钮（tonal）：一屏只留一个视觉重点，其余图标无底色。
/// 入场与歌名/作者共用同一根弹簧：0.92→1 缩放 pop + 透明度同步。
class _BarPlayPauseButton extends StatelessWidget {
  const _BarPlayPauseButton({required this.reveal});

  final _BarHeaderReveal reveal;

  @override
  Widget build(BuildContext context) {
    final (hasTrack, isPlaying) =
        context.select<PlaybackProvider, (bool, bool)>(
      (provider) => (provider.hasTrack, provider.isPlaying),
    );
    final l10n = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) => _BarRevealTransition(
        progress: reveal.progress,
        child: M3EIconButton(
          variant: M3EIconButtonVariant.tonal,
          tooltip: isPlaying ? l10n.pause : l10n.play,
          icon: IconSwap<bool>(
            value: isPlaying,
            builder: (context, isPlaying) => Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          onPressed: hasTrack
              ? () {
                  HapticsService.lightImpact();
                  context.read<PlaybackProvider>().togglePlayPause();
                }
              : null,
        ),
      ),
    );
  }
}

/// 顶栏「下一首」按钮（非播放页）：无曲目（含冷启动恢复态）时禁用，
/// 避免空操作误导；`select` 只订阅 hasTrack，不触发整个 Shell 重建。
///
/// 无底色标准样式：顶栏唯一高亮留给旁边的播放/暂停。
/// 入场与播放/暂停按钮同一根弹簧（与歌名/作者同源）。
class _BarNextButton extends StatelessWidget {
  const _BarNextButton({required this.reveal});

  final _BarHeaderReveal reveal;

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackProvider, bool>(
      (provider) => provider.hasTrack,
    );
    final l10n = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) => _BarRevealTransition(
        progress: reveal.progress,
        child: M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          tooltip: l10n.nextTrackTooltip,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: hasTrack
              ? () {
                  HapticsService.lightImpact();
                  context.read<PlaybackProvider>().skipToNext();
                }
              : null,
        ),
      ),
    );
  }
}

/// 顶栏按钮的入场表现：缩放 0.92→1（幅度 ≤8%）+ 透明度同源 clamp 0..1。
/// 完全隐藏时不参与命中测试（flight 期间按钮已挂载但不可见）。
class _BarRevealTransition extends StatelessWidget {
  const _BarRevealTransition({required this.progress, required this.child});

  /// 原始弹簧进度（可能短暂过冲）。
  final double progress;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0);
    return IgnorePointer(
      ignoring: t <= 0,
      child: Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
    );
  }
}

/// 顶栏窗口按钮（仅 Linux / Windows 桌面构建）：最小化 / 最大化-还原 / 关闭。
///
/// 隐藏原生标题栏后由它承担系统按钮职责；其余平台整组不构建，
/// 顶栏与改动前逐像素一致。图标随 [WindowChrome.maximized] 切换
/// （最大化时显示「还原」）。
///
/// 三键与旁边应用按钮**同规格**（M3E `sm` 档：24 图标 / 40 视觉格 /
/// 48 触控目标），不做桌面风格的紧凑化——顶部一排按钮观感统一优先；
/// 与应用操作之间用一段短竖线分界，右侧贴窗口角，保留「窗口控制」的
/// 识别度。关闭键遵循桌面习惯：hover / 按下时底色转 `errorContainer`、
/// 字形转 `onErrorContainer`（危险色只在这里出现，不影响其它按钮）。
///
/// 字形选型：最小化用 [Icons.remove_rounded]（居中横线）而不是
/// [Icons.minimize_rounded]——后者是 Material 的「下沉横线」设计，
/// 笔画中心比同排的方形 / 叉低 6/24，看上去像没对齐。
class _WindowControls extends StatelessWidget {
  const _WindowControls();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与左侧应用操作分界的短竖线（上下各留 10dp，长度约 36dp）。
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: M3EDivider(
            axis: M3EDividerAxis.vertical,
            indent: 10,
            endIndent: 10,
          ),
        ),
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          tooltip: l10n.windowMinimize,
          icon: const Icon(Icons.remove_rounded),
          onPressed: WindowChrome.minimize,
        ),
        ValueListenableBuilder<bool>(
          valueListenable: WindowChrome.maximized,
          builder: (context, maximized, _) => M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            tooltip: maximized ? l10n.windowRestore : l10n.windowMaximize,
            icon: IconSwap<bool>(
              value: maximized,
              builder: (context, maximized) => Icon(
                maximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                // 20 而不是 24：Material 的方形/双方形字形更实（16dp 笔画），
                // 与 24 档的叉（12dp）并排时显得重；20 档≈13dp 与叉对齐。
                size: 20,
              ),
            ),
            onPressed: WindowChrome.toggleMaximize,
          ),
        ),
        const _WindowCloseButton(),
      ],
    );
  }
}

/// 关闭键：hover / 按下走危险色（桌面习惯：关闭是破坏性操作）。
///
/// 底色用 `M3EIconButtonDecoration.overlayColor` 覆盖 M3E 的中性 state
/// layer，字形色由外层 [MouseRegion] 的 hover 状态给出（decoration 的
/// `foregroundColor` 只在 disabled/selected 上解析，不带 hover）。
class _WindowCloseButton extends StatefulWidget {
  const _WindowCloseButton();

  @override
  State<_WindowCloseButton> createState() => _WindowCloseButtonState();
}

class _WindowCloseButtonState extends State<_WindowCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = M3ETheme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        tooltip: l10n.windowClose,
        decoration: _hovered
            ? M3EIconButtonDecoration(
                overlayColor: WidgetStatePropertyAll<Color?>(
                  scheme.errorContainer,
                ),
              )
            : null,
        icon: Icon(
          Icons.close_rounded,
          color: _hovered ? scheme.onErrorContainer : null,
        ),
        onPressed: WindowChrome.close,
      ),
    );
  }
}

/// 顶栏歌名/作者锚点；无曲目时回退到自定义应用名。
class _BarTrackInfo extends StatelessWidget {
  const _BarTrackInfo();

  @override
  Widget build(BuildContext context) {
    final info = context.select<PlaybackProvider, (String?, String?)>(
      (provider) {
        final track = provider.snapshot.current;
        return (track?.title, track?.artistLabel);
      },
    );
    final (name, artists) = info;
    if (name == null || name.isEmpty) {
      return const _AppTitleText();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        if (artists != null && artists.isNotEmpty)
          Text(
            artists,
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
      ],
    );
  }
}

/// 自定义应用名（设置页可改，未自定义时随语言为 Molia/茉咏）。
class _AppTitleText extends StatelessWidget {
  const _AppTitleText();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppBrandingService.titleNotifier,
      builder: (context, title, _) => Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 顶栏底部进度条锚点：播放页激活时收起（进度由页面内的同一元素承接）。
class _ShellBarProgress extends StatelessWidget {
  const _ShellBarProgress({required this.morph});

  final PlayerMorphController morph;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) => AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: morph.barHeaderHidden ? 0 : 1,
        child: ProgressBarSelector(
          builder: (context, position, state, child) {
            if (!state.hasTrack) {
              return const SizedBox(height: _shellBarProgressHeight);
            }
            return ProgressIndicator(
              position: position,
              duration: state.duration.toDouble(),
              // 暂停时顶栏进度也切平直（波浪动画看起来像还在播放）。
              isPlaying: state.isPlaying,
            );
          },
        ),
      ),
    );
  }
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// home 宿主 context：位于 Navigator/Overlay 之下，供 NotificationService
/// 展示 M3ESnackbar（ScaffoldMessenger 的 context 在 Overlay 之上不可用）。
final GlobalKey appRootKey = GlobalKey(debugLabel: 'appRoot');

class MyThemedApp extends StatefulWidget {
  const MyThemedApp({super.key, this.onUserInteraction});

  /// 用户交互回调（组合根接同步调度器：续期「最近交互」的活跃窗口）。
  final VoidCallback? onUserInteraction;

  @override
  State<MyThemedApp> createState() => _MyThemedAppState();
}

class _MyThemedAppState extends State<MyThemedApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedLocale();
    // 自定义应用名称（顶栏回退文案）需要重建 MaterialApp.title。
    AppBrandingService.titleNotifier.addListener(_onBrandingChanged);
    AppBrandingService.load();
    // 震动反馈开关（设备本地偏好）：载入后全应用触感立即按它判定。
    HapticsService.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Android 后台不再广播网络变化（Android 8+）：回前台时主动刷新一次，
    // 否则「离开 Wi-Fi 后仍按 Wi-Fi 判定」，省流模式不会按时生效。
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<DataSaverService>().refreshConnectivity();
    } else if (state == AppLifecycleState.paused) {
      // 进入后台立即落盘播放会话：被系统杀进程时冷启动恢复进度更准
      // （平时按 1s 节流保存）。
      context.read<PlaybackProvider>().flushPlaybackSession();
      // 听歌统计：立即落盘进行中的播放事件（被杀进程最多丢 ~15s 进度）。
      context.read<PlayStatisticsService>().flush();
    }
  }

  void _onBrandingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppBrandingService.titleNotifier.removeListener(_onBrandingChanged);
    super.dispose();
  }

  Future<void> _loadSavedLocale() async {
    final savedLocale = await LanguageService.getSavedLocale();
    if (savedLocale != null) {
      LanguageService.localeNotifier.value = savedLocale;
    }
  }

  /// 品牌默认名跟随界面语言（en=Molia / zh=茉咏）。
  ///
  /// 只读计算 + 帧末注入：build 阶段直接更新 notifier 会触发
  /// markNeedsBuild 告警；已自定义名称时 applyLocalizedDefault 内部自动忽略。
  void _syncLocalizedBranding(Locale? locale) {
    final effective =
        locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final resolved = LanguageService.supportedLocales
            .any((supported) => supported.languageCode == effective.languageCode)
        ? effective
        : LanguageService.supportedLocales.first;
    final name = lookupAppLocalizations(resolved).appName;
    if (name == AppBrandingService.defaultTitle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppBrandingService.applyLocalizedDefault(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // ThemeProvider（主题模式 + 基础配色 + 封面覆盖 + 纯黑）是唯一主题来源：
    // Selector 提升到壳外，colorScheme 变化时重建整个 M3EMaterialApp，
    // 同时刷新 material_ui ThemeData 与 M3EThemeData。
    // 应用语言走 LanguageService.localeNotifier，设置页切换后立即生效。
    //
    // 莫奈配色由 DynamicColorBuilder 提供（平台不支持时回调 null）：
    // 基础配色=壁纸时生效；注入必须放到 post-frame，避免 build 中同步
    // 触发 notifyListeners。
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context
              .read<ThemeProvider>()
              .updateMonetSchemes(lightDynamic, darkDynamic);
        });
        return ValueListenableBuilder<Locale?>(
          valueListenable: LanguageService.localeNotifier,
          builder: (context, locale, _) {
            // 品牌默认名随界面语言本地化（Molia / 茉咏）。
            _syncLocalizedBranding(locale);
            return Selector<ThemeProvider,
                ({ColorScheme scheme, String? fontFamily})>(
            selector: (context, provider) => (
              scheme: provider.colorScheme,
              fontFamily: provider.appFontFamily,
            ),
            // 方案色变化（切歌取色/莫奈/种子色/亮度）经 AnimatedSchemeBuilder
            // 平滑过渡，避免整站颜色闪变；只插值 ColorScheme，material_ui 与
            // M3E 两套主题都由同一插值结果重建，保证过渡期一致。
            // 字体族变化不参与插值，由同一 Selector 直接触发两套主题重建。
            builder: (context, themeState, _) => AnimatedSchemeBuilder(
              scheme: themeState.scheme,
              builder: (context, animatedScheme) {
                final systemUiOverlayStyle =
                    buildSystemUiOverlayStyle(animatedScheme);
                final themedData = buildAppThemeData(
                  animatedScheme,
                  systemUiOverlayStyle: systemUiOverlayStyle,
                  fontFamily: themeState.fontFamily,
                );

                return M3EMaterialApp(
                  title: AppBrandingService.titleNotifier.value,
                  scaffoldMessengerKey: scaffoldMessengerKey,
                  navigatorKey: navigatorKey,
                  locale: locale,
                  // material_ui 的 delegates 已合并 Material/Widgets/Cupertino 三套文案
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    ...GlobalMaterialLocalizations.delegates,
                  ],
                  supportedLocales: LanguageService.supportedLocales,
                  // material_ui 透传：既有组件通过 Theme.of 读到的外观保持现状。
                  theme: themedData,
                  darkTheme: themedData,
                  // M3E 侧数据：颜色/字体从 themedData 映射（按 ThemeData 实例缓存）。
                  data: M3EThemeData.fromMaterial(themedData),
                  // 方案色过渡已由 AnimatedSchemeBuilder 逐帧插值完成，
                  // 关掉 MaterialApp 内置主题动画，避免二次缓动造成两套主题不同步。
                  themeAnimationStyle: AnimationStyle.noAnimation,
                  // 系统亮度由 ThemeProvider.updateThemeFromSystem 驱动，
                  // 封面/莫奈取色由 ThemeProvider 内部优先级决定；不启用 M3E
                  // 自适应与 OS 动态色，避免双主题源互相覆盖。
                  autoTheming: false,
                  dynamicColoring: false,
                  // targetSdk 37（Android 15+ 强制 edge-to-edge）下保持系统栏透明、
                  // 内容绘制到系统栏下方，与 settings_page.dart 的 edgeToEdge 行为一致。
                  drawUnderSystemBars: true,
                  // appBuilder 只做系统栏 AnnotatedRegion + Web 字号缩放：
                  // M3E 内部已用 M3ETheme 包裹 child，MaterialApp 的 Theme 又
                  // 位于 builder 之上（见 material_ui app.dart _materialBuilder），
                  // 此处不重复包 Theme。
                  appBuilder: (context, child) {
                    final themedChild = child ?? const SizedBox.shrink();
                    final baseMediaQuery = MediaQuery.of(context);
                    final double textScaleMultiplier = kIsWeb ? 1.12 : 1.0;
                    final baseScale = baseMediaQuery.textScaler.scale(1.0);
                    final mediaData = baseMediaQuery.copyWith(
                      textScaler:
                          TextScaler.linear(baseScale * textScaleMultiplier),
                    );

                    return AnnotatedRegion<SystemUiOverlayStyle>(
                      value: systemUiOverlayStyle,
                      child: MediaQuery(
                        data: mediaData,
                        // 用户交互（含弹层 / 菜单，都在 Navigator 之内）→
                        // 同步调度器续期「最近交互」窗口；只观察不拦截。
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (_) =>
                              widget.onUserInteraction?.call(),
                          child: themedChild,
                        ),
                      ),
                    );
                  },
                  home: MyApp(key: appRootKey),
                );
              },
            ),
          );
          },
        );
      },
    );
  }
}

