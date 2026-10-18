/// 应用壳（App Shell）：导航栏 / 顶栏 / 迷你播放条 / 页面层。
///
/// main.dart 是唯一 composition root 且禁止被测试 import，壳层独立成文件后
/// 测试可直接挂载。composition root 仍负责创建 provider 与主题，本文件只
/// 消费注入的 provider。
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, visibleForTesting;
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
import '../services/system_fonts_service.dart';
import '../services/window/window_chrome.dart';
import '../theme/animated_scheme.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_network_image.dart';
import '../widgets/cover_appearance.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/global_search_overlay.dart';
import '../widgets/icon_swap.dart';
import '../widgets/now_playing_controller.dart';
import '../widgets/playback_selectors.dart';
import '../widgets/player_morph.dart';
import '../widgets/shell_reselect.dart';
import '../widgets/shell_page_visibility.dart';
import 'desktop/desktop_shell.dart';
import 'shell_chrome.dart';

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
  const MyApp({super.key, this.desktopShell});

  /// 桌面骨架开关（**测试专用**）：null = 按平台判定（Linux / Windows /
  /// macOS 走桌面骨架），true / false 强制指定。真机永远走平台判定。
  final bool? desktopShell;

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

  /// 顶栏搜索「查看全部结果 / 窄窗搜索入口」的一次性意图：资料库页切到
  /// 搜索 tab 并回顶（用户刚搜过，落点是搜索 tab 而不是上次停留的 tab）。
  final ShellReselectSignal _showSearchRequest = ShellReselectSignal();

  /// 每个目的地一个「重复点击」意图通道：页面订阅后自行响应
  /// （播放页 = 迷你 ⇄ 完整；资料库 / 收藏 = 回到列表顶部），壳层不消费。
  final Map<ShellDestination, ShellReselectSignal> _reselect = {
    for (final destination in ShellDestination.values)
      destination: ShellReselectSignal(),
  };

  /// 搜索遮罩的打开入口（Ctrl+F / 顶栏品牌区路径）：遮罩宿主挂在
  /// DesktopShell 里，控制器由壳层持有后下传。
  final GlobalSearchController _globalSearch = GlobalSearchController();

  /// 播放页右栏的 tab 切换请求通道（底栏队列按钮 / Esc 的「关闭队列」）。
  ///
  /// 壳层不读播放页的界面状态（tab 由页面自己持有），只能表达一次意图；
  /// 页面侧消费时机见 `widgets/now_playing_controller.dart`。
  final NowPlayingController _nowPlaying = NowPlayingController();

  /// 页面实例固定（key 稳定），顺序/显隐只影响底栏映射与分层透明度，
  /// 页面状态（滚动/搜索词等）天然保持。
  late final Map<ShellDestination, Widget> _pages = {
    ShellDestination.nowPlaying: NowPlaying(
      morph: _morph,
      reselect: _reselect[ShellDestination.nowPlaying],
      controller: _nowPlaying,
      // 桌面骨架的播放页换成「封面 + 控制 / 队列·歌词·信息」版式（无迷你态）；
      // 移动 / 平板骨架保持 PageView 版式。
      desktopLayout: _desktopShell,
    ),
    ShellDestination.favorites: FavoritesPage(
      reselect: _reselect[ShellDestination.favorites],
    ),
    ShellDestination.library: Library(
      reselect: _reselect[ShellDestination.library],
      showSearchRequest: _showSearchRequest,
    ),
  };

  /// 是否挂载桌面骨架：Linux / Windows / macOS 为真；[MyApp.desktopShell]
  /// 非空时以它为准（测试强制走另一侧骨架）。
  bool get _desktopShell =>
      widget.desktopShell ?? isDesktopPlatform();

  /// 当前选中的目的地（与底栏顺序解耦；初值 = 导航偏好的启动首页）。
  late ShellDestination _selectedDestination;
  late ShellDestination _previousDestination;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _morphAnimation.addListener(_onMorphTick);
    // 启动首页：导航偏好在首帧前已就绪（组合根 await 过 preferencesReady），
    // 这里同步读取即可；存储值不可见时 effectiveHomeDestination 已回退到
    // 第一个可见目的地。
    _selectedDestination = context.read<NavProvider>().effectiveHomeDestination;
    _previousDestination = _selectedDestination;
    // 顶栏 / 底栏的曲目信息区必须与「手动进入播放页」后的状态一致（播放页
    // 激活即收起封面）：否则恢复会话后顶栏会重复显示曲目封面/进度。
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
    _nowPlaying.dispose();
    _globalSearch.dispose();
    for (final signal in _reselect.values) {
      signal.dispose();
    }
    _showSearchRequest.dispose();
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
      _startMorphToPage();
    } else if (leavingPlayer) {
      _startMorphBackToBar();
    } else {
      // 两端都不是播放页：不涉及共享元素，确保两端真身可见。
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(false);
    }
  }

  /// 底栏队列按钮：跳播放页 + 让页内右栏切到队列 tab。
  ///
  /// 跳页走 [_selectDestination]（已在播放页时它自己 no-op），请求照发——
  /// 「看队列」在播放页里同样成立（控制器不看界面状态，重复请求也生效）。
  void _openQueue() {
    _selectDestination(ShellDestination.nowPlaying);
    _nowPlaying.showQueueTab();
  }

  /// Esc 的壳层命令（可配置的「关闭队列」）：队列是播放页右栏的一栏，壳层
  /// 看不到页内 tab，命令按目的地生效 —— 在播放页里把队列视图收成默认页
  /// （停在其它栏时同样回默认页，等于「回默认页」）；其它目的地 no-op。
  void _closeQueuePanel() {
    if (_selectedDestination != ShellDestination.nowPlaying) return;
    _nowPlaying.showLyricsTab();
  }

  /// 底栏 → 播放页的飞行：起点与终点分两帧抓。
  ///
  /// 起点（底栏封面）只在点击这一帧存在——底栏在播放页整条让位，重建后就
  /// 没了；终点（页内封面）恰恰相反——让位使内容区高 +80，页内封面随垂直
  /// 居中下移，重建前的矩形不是落点。因此本帧抓起点、先把两端封面收进飞行
  /// 态（避免真身与副本同帧重影），帧末（让位后的布局已成立）抓终点再起飞：
  /// 副本飞行终点就是真身的实际落点，交接帧零位移。
  void _startMorphToPage() {
    _completeMorph();
    final barCover = _morph.rectOf(_morph.barCoverKey);
    if (barCover == null) {
      // 起点不在场（启动就落在播放页等）：跳过飞行，只对齐两端状态。
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(true);
      return;
    }
    _morph.setBarHeaderHidden(true);
    _morph.setPageHeaderHidden(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectedDestination != ShellDestination.nowPlaying) {
        // 一帧之内又离开了播放页：这次进入被撤销，两端状态按「不在播放页」
        // 对齐（两端真身都可见）。
        _morph.setPageHeaderHidden(false);
        _morph.setBarHeaderHidden(false);
        return;
      }
      final pageCover = _morph.rectOf(_morph.pageCoverKey);
      if (pageCover == null) {
        // 终点不可用：不飞，页内封面直接亮出（顶栏/底栏这一端不在场，无重影）。
        _morph.setPageHeaderHidden(false);
        return;
      }
      _flyMorph(
        PlayerMorphGeometry(
          barCover: barCover,
          pageCover: pageCover,
          toPage: true,
        ),
      );
    });
  }

  /// 播放页 → 底栏的飞行：底栏在播放页里整条让位，锚点要等它回到树里才有。
  ///
  /// 本帧先让底栏复位、并把两端封面收进飞行态（底栏封面出现时就是空位，
  /// 下一帧副本从同一位置起飞，接得上）；帧末（底栏已完成布局）抓两端锚点、
  /// 再下一帧起飞——代价是飞行比切页晚一帧（16ms），肉眼不可辨。
  void _startMorphBackToBar() {
    _morph.setBarHeaderHidden(true);
    _morph.setPageHeaderHidden(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectedDestination == ShellDestination.nowPlaying) {
        // 一帧之内又回到播放页：这次离开被撤销，状态按「在播放页」对齐
        // （底栏封面仍收起，与启动就落在播放页时同一口径）。
        _morph.setBarHeaderHidden(true);
        _morph.setPageHeaderHidden(false);
        return;
      }
      _completeMorph();
      final geometry = _morph.captureGeometry(toPage: false);
      if (geometry == null) {
        // 锚点缺失（迷你态/首帧）：跳过飞行，两端真身可见。
        _morph.setPageHeaderHidden(false);
        _morph.setBarHeaderHidden(false);
        return;
      }
      _flyMorph(geometry);
    });
  }

  /// 起飞：两端封面的显示状态 + Overlay 副本 + 弹簧。
  ///
  /// 封面 URL 与锚点在同一刻抓取：飞行期间不换图（副本承接的是起飞时那一张）。
  void _flyMorph(PlayerMorphGeometry geometry) {
    _morph.setBarHeaderHidden(true);
    if (geometry.toPage) _morph.setPageHeaderHidden(true);
    _morphGeometry = geometry;
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

  /// 打开设置弹层（顶栏入口，三个目的地共用）；返回处理见 [showSettingsSheet]。
  void _openSettings(BuildContext context) {
    HapticsService.lightImpact();
    showSettingsSheet(context);
  }

  /// 打开搜索遮罩（顶栏品牌区点击 / 全局快捷键 Ctrl+F 同一条路径）。
  ///
  /// 宽窄窗不再分流：遮罩自体全屏呈现、搜索条居中，任何窗口宽下都是同一个
  /// 落点（宽度判定只服务遮罩内的布局，不再决定入口形态）。
  void _openGlobalSearch() => _globalSearch.focus();

  /// 打开资料库搜索：发一次「显示搜索 tab」意图再切目的地。
  ///
  /// 资料库页三个 tab 共用一页，只切目的地会停在用户上次停留的 tab
  /// （搜过却在看热榜时，点「查看全部结果」看不到结果）。
  void _openLibrarySearch() {
    _showSearchRequest.trigger();
    _onDestinationSelected(ShellDestination.library);
  }

  /// 全局快捷键 Ctrl+1/2/3：切到第 [index] 个可见目的地；越界忽略。
  ///
  /// 已选中项不触发重复点击语义（回顶 / 折叠播放器）：快捷键是「切页」，
  /// 不是「再点一次」。
  void _selectVisibleDestinationAt(int index) {
    final visible = context.read<NavProvider>().visibleDestinations;
    if (index < 0 || index >= visible.length) return;
    _selectDestination(visible[index]);
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

    // 导航 / 顶栏 spec：两套骨架共用一份（目的地映射 / 标签 / 设置按钮 /
    // 窗口控件 / 拖动区），骨架各自适配渲染（见 shell_chrome.dart）。
    final chrome = ShellChrome(
      destinations: visibleDestinations,
      selectedDestination: selectedDestination,
      selectedIndex: selectedIndex,
      l10n: l10n,
      onDestinationSelected: _onDestinationSelected,
      onOpenSettings: () => _openSettings(context),
    );

    // 桌面骨架：顶栏瘦身 + 恒折叠侧栏 + 页面栈（底栏播放条在非播放页出现）
    // （结构见 `desktop/desktop_shell.dart`）；移动 / 平板骨架保持原结构。
    // 桌面布局值在这里解析一次（窗口宽 / 平台位），页面与骨架只消费
    // （见 `widgets/desktop_layout.dart`）。
    if (_desktopShell) {
      return DesktopLayout.scope(
        context,
        child: DesktopShell(
          chrome: chrome,
          pageStack: _buildPageStack(),
          morph: _morph,
          // 搜索遮罩：入口（品牌区 / Ctrl+F）与「查看全部结果」分别接线。
          // 后者落在资料库目的地：完整结果（分段 / 分页 / 歌手链接）在那里，
          // 且共用同一个 SearchProvider 实例。
          onViewAllResults: _openLibrarySearch,
          onOpenSearch: _openGlobalSearch,
          // 全局快捷键：Ctrl+F 打开搜索遮罩、Ctrl+1/2/3 切可见目的地，
          // DesktopShell 只负责在顶层监听按键，落点由壳层回调决定。
          searchController: _globalSearch,
          onSelectDestinationIndex: _selectVisibleDestinationAt,
          // 队列入口（底栏按钮）与 Esc 的「关闭队列」都要落回播放页右栏，
          // 由壳层持有控制器后分发。
          onOpenQueue: _openQueue,
          onCloseQueuePanel: _closeQueuePanel,
        ),
      );
    }

    // 顶栏由 ShellChrome 统一构造（titleSpacing / 无返回键 / 拖动区包装）：
    // 整条顶栏是窗口拖动区（隐藏标题栏后唯一的拖动入口），高度走 AppBar
    // 自报（56 工具栏 + 10 波浪进度），非桌面平台 WindowDragArea 是纯透传。
    final appBar = chrome.appBar(
      context: context,
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
      ],
      bottom: PreferredSize(
        // 波浪进度条需要振幅空间（M3E 默认 wavyContainerHeight=10）；
        // 高度同时由 `_shellBarProgressHeight` 钉在进度条自身，见该常量注释。
        preferredSize: const Size.fromHeight(_shellBarProgressHeight),
        child: _ShellBarProgress(morph: _morph),
      ),
    );

    return DesktopLayout.scope(
      context,
      child: Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            if (isLargeScreen)
              M3ENavigationRail(
                // 固定 96dp 窄轨（alwaysCollapse）：无展开按钮、不可展开；
                // 标签常显，替代 Material 侧 hover 才出现的 tooltip。
                type: M3ENavigationRailType.alwaysCollapse,
                selectedIndex: selectedIndex,
                onDestinationSelected: chrome.selectDestinationAt,
                sections: [
                  M3ENavigationRailSection(
                    destinations: chrome.railDestinations(),
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
                  onDestinationSelected: chrome.selectDestinationAt,
                  destinations: chrome.barDestinations(),
                ),
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
/// 入场同理不做微缩（缩放会让飞行副本落在缩放后的位置）。
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
        //
        // 既非「当前页」也非「上一页」（切换过渡的另一端）时，页面整体
        // Offstage：省掉整页 layout（Opacity(0) 只省 paint）。
        return ShellPageVisibility(
          visible: selected,
          child: Offstage(
            offstage: !selected && !outgoing,
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
              // 出场 90ms（先走），入场 160ms。
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
                  // 未自定义「应用字体」时跟随平台默认 UI 字体（启动时解析，
                  // 见 SystemFontsService.loadPlatformDefaultFamily）。
                  platformDefaultFontFamily:
                      SystemFontsService.platformDefaultFamily,
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
                  // appBuilder 只做系统栏 AnnotatedRegion：
                  // M3E 内部已用 M3ETheme 包裹 child，MaterialApp 的 Theme 又
                  // 位于 builder 之上（见 material_ui app.dart _materialBuilder），
                  // 此处不重复包 Theme。
                  appBuilder: (context, child) {
                    final themedChild = child ?? const SizedBox.shrink();
                    final baseMediaQuery = MediaQuery.of(context);
                    final baseScale = baseMediaQuery.textScaler.scale(1.0);
                    final mediaData = baseMediaQuery.copyWith(
                      textScaler: TextScaler.linear(baseScale),
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

