/// 应用壳（App Shell）：导航栏 / 顶栏 / 迷你播放条 / 页面层。
///
/// main.dart 是唯一 composition root 且禁止被测试 import；壳层独立成
/// library，测试可直接挂载。composition root 仍负责创建 provider 与主题，
/// 本文件只消费注入的 provider。
///
/// 部件按职责拆在 `shell/` 下的 part 中（顶栏、页面层、进度条、配对队列、
/// 主题应用、全局 key）。part 共享本 library 的私有实现，对外公开类型只经
/// `lib/app/app_shell.dart` barrel 转发。
library;

import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/models/sync_nearby_pairing.dart';
import '../../l10n/app_localizations.dart';
import '../../pages/favorites.dart';
import '../../pages/library.dart';
import '../../pages/nowplaying.dart';
import '../../pages/onboarding_flow.dart';
import '../../pages/sync_nearby_pairing_dialogs.dart';
import '../../pages/sync_notices.dart';
import '../../providers/nav_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/back_claims.dart';
import '../../services/haptics.dart';
import '../../services/language_service.dart';
import '../../services/onboarding_store.dart';
import '../../services/system_fonts_service.dart';
import '../../services/window/window_chrome.dart';
import '../../theme/animated_scheme.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion_policy.dart';
import '../../widgets/responsive.dart';
import '../../widgets/adaptive_layout.dart';
import '../../widgets/cover_fallback.dart';
import '../../widgets/desktop_layout.dart';
import '../../widgets/global_search_overlay.dart';
import '../../widgets/m3e_page_route.dart';
import '../../widgets/now_playing_controller.dart';
import '../../widgets/now_playing_summary.dart';
import '../../widgets/playback_selectors.dart';
import '../../widgets/playback_transport.dart';
import '../../widgets/player_morph.dart';
import '../../widgets/settings/settings_sheet.dart';
import '../../widgets/shell_reselect.dart';
import '../../widgets/shell_page_visibility.dart';
import '../app_presence_ticker_mode.dart';
import '../desktop/desktop_shell.dart';
import '../shell_chrome.dart';
import '../tray_dormant_gate.dart';

part 'app_keys.dart';
part 'pairing_queue.dart';
part 'shell_back_intent.dart';
part 'shell_bar.dart';
part 'shell_page_layer.dart';
part 'shell_progress.dart';
part 'themed_app.dart';

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.desktopShell,
    this.showOnboarding = false,
    this.onboardingStore,
  });

  /// 桌面骨架开关（**测试专用**）：null = 按平台判定（Linux / Windows /
  /// macOS 走桌面骨架），true / false 强制指定。真机永远走平台判定。
  final bool? desktopShell;

  /// 启动时是否还没完成首次引导（组合根在 runApp 前读设备本地标记决定）。
  ///
  /// 只代表启动那一刻；托盘休眠后的壳层重建还要叠加进程内完成态，
  /// 见 [OnboardingStore.completedInSession]。
  final bool showOnboarding;

  /// 完成标记写入器（测试注入；生产为默认 prefs 实现）。
  final OnboardingStore? onboardingStore;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  /// 顶栏 ↔ 播放页共享元素飞行控制器。
  final PlayerMorphController _morph = PlayerMorphController();

  /// 首次引导是否仍在显示：完成 / 跳过后切回正常壳层，不经过路由。
  late bool _showOnboarding;

  /// 顶栏曲目信息区（歌名/作者 + 播放/下一首按钮）的入场进度。
  ///
  /// 一根 expressive spatial 弹簧同时驱动文本位移/淡入与按钮缩放 pop：
  /// 文本与按钮是两个兄弟子树，弹簧必须由共同祖先持有，不能各建一根。
  late final _BarHeaderReveal _barReveal;

  /// tab 淡入淡出（fade-through）控制器：M3E expressive spatial 弹簧。
  ///
  /// 弹簧只负责时间曲线（快出、缓落定）；透明度 / 缩放的形状仍由
  /// `shellPageLayerPresentation` 内的 Curves 决定，两者不重复缓动。
  ///
  /// 用 bounded 控制器：`forward(from: 0)` 从 0 重新起播，
  /// 显式设值被夹在 0..1。字段类型必须写具体的 bounded 类：工厂
  /// `SingleMotionController.bounded` 的静态返回类型是基类，拿不到 `forward`。
  ///
  /// `snapToEnd` 不能省：`shellPageLayerPresentation` 用 `progress < 1.0`
  /// 判定出场层是否仍在过渡，弹簧自然收敛会停在 0.999…，出场页就会一直
  /// 残留 0.97 缩放（顶栏⇄播放页飞行抓锚点时真身跳变）。
  late final BoundedSingleMotionController _tabTransition =
      BoundedSingleMotionController(
        motion: SpringMotion(
          M3EMotion.expressiveSpatialDefault.toDescription(),
          snapToEnd: true,
        ),
        vsync: this,
        initialValue: 1,
        lowerBound: 0,
        upperBound: 1,
      );

  /// 共享元素飞行控制器。
  ///
  /// M3E no-overshoot spatial 弹簧（`aospSpatial` 380/1.0，对齐 Android 共享
  /// 元素默认 `spring(StiffnessMediumLow=400, noBouncy)`）：副本在弹簧落定帧
  /// 零速度精确交接。每次飞行的起点用新抓取的锚点几何（`from: 0`），中途被
  /// 打断则直接换新飞。
  late final SingleMotionController _morphAnimation = SingleMotionController(
    motion: SpringMotion(
      M3EMotion.aospSpatial.toDescription(),
      snapToEnd: true,
    ),
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

  /// 「长按收藏目的地」意图通道：页面订阅后切到收藏页并定位当前播放曲目。
  ///
  /// 与 [_reselect] 分开持有：长按不是重复点击，页面响应也不同（回到顶部
  /// vs. 定位当前曲目）。目前只有收藏目的地接线。
  final ShellLongPressSignal _locatePlaying = ShellLongPressSignal();

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
      locatePlaying: _locatePlaying,
    ),
    ShellDestination.library: Library(
      reselect: _reselect[ShellDestination.library],
      showSearchRequest: _showSearchRequest,
    ),
  };

  /// 是否挂载桌面骨架：Linux / Windows / macOS 为真；[MyApp.desktopShell]
  /// 非空时以它为准（测试强制走另一侧骨架）。
  bool get _desktopShell => widget.desktopShell ?? isDesktopPlatform();

  /// 当前选中的目的地（与底栏顺序解耦；初值 = 导航偏好的启动首页）。
  ///
  /// 这是「存储的选中项」，可能被运行时隐藏（如同步关掉当前底栏项）；
  /// 壳层渲染与交互一律消费 [_effectiveDestination]，不要直接读它。
  late ShellDestination _selectedDestination;
  late ShellDestination _previousDestination;

  /// 最近一次渲染（或由用户选中）的有效目的地。
  ///
  /// 可见性变化（如同步隐藏 / 恢复当前目的地）会绕过 [_selectDestination]
  /// 改写有效选中项，[didChangeDependencies] 据此识别并同步播放页 morph 状态。
  late ShellDestination _renderedDestination;

  /// 实际生效的选中目的地：导航 chrome、页面栈与重复点击判定共用的唯一来源。
  ///
  /// 存储的选中项被运行时隐藏（如同步应用远端导航设置）时回退到第一个可见
  /// 目的地。只读计算，不回写 [_selectedDestination]：隐藏项重新可见后天然
  /// 恢复原选中项，也避免同步应用期间写回造成回环。
  ShellDestination get _effectiveDestination {
    final visible = context.read<NavProvider>().visibleDestinations;
    // NavProvider 保证至少保留 1 个可见项；空列表仅作防御。
    if (visible.isEmpty) return _selectedDestination;
    return visible.contains(_selectedDestination)
        ? _selectedDestination
        : visible.first;
  }

  @override
  void initState() {
    super.initState();
    // 托盘休眠会卸载并重建整棵界面，重建时拿到的仍是启动时的
    // `showOnboarding`；本次进程已完成 / 跳过时不能再引导一次。
    _showOnboarding =
        widget.showOnboarding && !OnboardingStore.completedInSession;
    WidgetsBinding.instance.addObserver(this);
    _morphAnimation.addListener(_onMorphTick);
    // 展开态变化要重算 PopScope.canPop（壳层返回层级的第一优先是收起
    // 播放器）；页面只在动画落定 / 布局后写，不会在构建期触发这里。
    _nowPlaying.expanded.addListener(_onNowPlayingExpandedChanged);
    // 启动首页：导航偏好在首帧前已就绪（组合根 await 过 preferencesReady），
    // 这里同步读取即可；存储值不可见时 effectiveHomeDestination 已回退到
    // 第一个可见目的地。
    _selectedDestination = context.read<NavProvider>().effectiveHomeDestination;
    _previousDestination = _selectedDestination;
    _renderedDestination = _selectedDestination;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 可见性变化（如同步隐藏当前目的地）会改写有效选中项，但没有经过
    // [_selectDestination]；把播放页 morph 状态对齐到新的有效选中项，
    // 避免页面栈已回退、顶栏却仍停留在播放页形态（曲目区/进度条收起）。
    final effective = _effectiveDestination;
    if (effective == _renderedDestination) return;
    _renderedDestination = effective;
    _completeMorph();
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(effective == ShellDestination.nowPlaying);
  }

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
    _nowPlaying.expanded.removeListener(_onNowPlayingExpandedChanged);
    _nowPlaying.dispose();
    _globalSearch.dispose();
    for (final signal in _reselect.values) {
      signal.dispose();
    }
    _locatePlaying.dispose();
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
    if (destination != _effectiveDestination) {
      _selectDestination(destination);
      return;
    }
    if (destination == ShellDestination.nowPlaying && _morphGeometry != null) {
      return;
    }
    // 重复点击是一次真实的点按（列表回顶 / 播放器折叠都是肉眼可见的动作），
    // 给一次轻震：壳层统一在此触发 —— 页面侧的重复点击响应不带触感，
    // 避免同一次点击两次震动（命中忽略分支时不震动）。
    HapticsService.lightImpact();
    _reselect[destination]?.trigger();
  }

  /// 长按收藏目的地：切到收藏页并请求页面定位当前播放曲目。
  ///
  /// 页面在下一帧才可见，滚动请求由页面自己挂起、等列表布局完成后再消费
  /// （见 `FavoritesPage.locatePlaying`）。触感只给一次：从别的目的地过来
  /// 由 [_selectDestination] 给，已经在本页时由这里补上。
  void _onFavoritesLongPress() {
    const favorites = ShellDestination.favorites;
    if (!context.read<NavProvider>().isVisible(favorites)) return;
    if (_effectiveDestination != favorites) {
      _selectDestination(favorites);
    } else {
      HapticsService.lightImpact();
    }
    _locatePlaying.trigger();
  }

  void _selectDestination(ShellDestination destination) {
    final nav = context.read<NavProvider>();
    // 隐藏目的地不参与导航（与 chrome / 页面栈同一可见集合）：否则 raw
    // 选中项会再次与有效选中项分叉，页面栈回退到另一个可见项。
    if (!nav.isVisible(destination)) return;
    // 过渡的起点必须是当前真正显示的页，而不是被隐藏的 raw 选中项。
    final current = _effectiveDestination;
    if (destination == current) return;
    HapticsService.lightImpact();
    final leavingPlayer = current == ShellDestination.nowPlaying;
    final enteringPlayer = destination == ShellDestination.nowPlaying;
    setState(() {
      _previousDestination = current;
      _selectedDestination = destination;
      _renderedDestination = destination;
    });
    if (reduceMotionOf(context)) {
      // 减弱动效：tab 淡入淡出与封面飞行都直达终态（不 forward(from: 0)、
      // 不插 Overlay 飞行副本）；两端状态仍按「谁在播放页」对齐。
      _tabTransition.value = 1;
      _completeMorph();
      _alignMorphEnds(onPlayerPage: enteringPlayer);
      return;
    }
    _tabTransition.forward(from: 0);
    if (enteringPlayer) {
      _startMorphToPage();
    } else if (leavingPlayer) {
      _startMorphBackToBar();
    } else {
      // 两端都不是播放页：不涉及共享元素，确保两端真身可见、侧槽落位。
      _alignMorphEnds(onPlayerPage: false);
    }
  }

  /// 两端封面状态对齐到「不在飞行中」的稳态：真身可见、侧槽落位。
  ///
  /// 进入 / 离开播放页的异常分支（锚点缺失、一帧内撤销、减弱动效）都走
  /// 这一份，避免三处各写一遍后漏设某个 flag 导致真身双影或缩放残留。
  void _alignMorphEnds({required bool onPlayerPage}) {
    _morph.setPageDeckReveal(1);
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(onPlayerPage);
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
    if (_effectiveDestination != ShellDestination.nowPlaying) return;
    _nowPlaying.showLyricsTab();
  }

  /// 展开态翻转 → 重算 PopScope.canPop（`setState` 是 protected，扩展里
  /// 不能直接调用，壳层留一个 3 行的转发）。
  void _onNowPlayingExpandedChanged() {
    if (mounted) setState(() {});
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
      _alignMorphEnds(onPlayerPage: true);
      return;
    }
    _morph.setBarHeaderHidden(true);
    _morph.setPageHeaderHidden(true);
    // 进入首帧页中心就收起（飞行副本承接），侧邻位收回中心等飞行尾段展开。
    _morph.setPageDeckReveal(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_effectiveDestination != ShellDestination.nowPlaying) {
        // 一帧之内又离开了播放页：这次进入被撤销，两端状态按「不在播放页」
        // 对齐（两端真身都可见、侧槽落位）。
        _alignMorphEnds(onPlayerPage: false);
        return;
      }
      final pageCover = _morph.rectOf(_morph.pageCoverKey);
      if (pageCover == null) {
        // 终点不可用：不飞，页内封面与侧槽直接亮出（顶栏/底栏这一端不在场，
        // 无重影）。
        _alignMorphEnds(onPlayerPage: true);
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
    // 离开方向也从第一帧起收起页中心：飞行副本接管整段行程，页面真身
    // 不能先在原地亮着等副本飞过来。
    _morph.setPageHeaderHidden(true);
    // 侧邻位从稳态开始；飞行前 45% 由 tick 时间对称地收回中心。
    _morph.setPageDeckReveal(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_effectiveDestination == ShellDestination.nowPlaying) {
        // 一帧之内又回到播放页：这次离开被撤销，状态按「在播放页」对齐
        // （底栏封面仍收起，与启动就落在播放页时同一口径）。
        _alignMorphEnds(onPlayerPage: true);
        return;
      }
      _completeMorph();
      final geometry = _morph.captureGeometry(toPage: false);
      if (geometry == null) {
        // 锚点缺失（迷你态/首帧）：跳过飞行，两端真身可见。
        _alignMorphEnds(onPlayerPage: false);
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
    // 两个方向都收起页中心：副本精确承接整段几何，真身不参与飞行（进入时
    // 首帧就不能亮，离开时也不能留到最后才收）。
    _morph.setPageHeaderHidden(true);
    _morphGeometry = geometry;
    final url = nowPlayingCoverUrl(context, context.read<PlaybackProvider>());
    final token = ++_morphToken;
    _morphEntry = OverlayEntry(
      builder: (context) => PlayerMorphFlight(
        animation: _morphAnimation,
        geometry: geometry,
        url: url,
        fallback: (context, iconSize) =>
            buildFallbackArtwork(context, iconSize: iconSize),
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
    final geometry = _morphGeometry;
    if (geometry == null) return;
    final double progress = _morphAnimation.value.clamp(0.0, 1.0);
    // 侧邻位进入时尾段展开 / 离开时前段收回（不新增 ticker，复用同一条弹簧）。
    _morph.setPageDeckReveal(
      PlayerMorphController.pageDeckRevealAt(progress, toPage: geometry.toPage),
    );
    if (progress >= PlayerMorphFlight.flightPortion) {
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
    // 失败 / 落定都回到稳态展开：落位帧副本移除、真身与侧槽同一帧就位。
    _morph.setPageDeckReveal(1);
    if (geometry == null) {
      _removeMorphOverlay();
      return;
    }
    // 落位：目标端真身瞬时亮出（零时长 Opacity），同一帧移除飞行副本；
    // 播放页激活时顶栏收起（内容由页面承接）。
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
  /// 遮罩自体全屏呈现、搜索条居中，任何窗口宽下都是同一个落点
  /// （宽度判定只服务遮罩内的布局，不决定入口形态）。
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
    final selectedDestination = _effectiveDestination;
    final ordered = <ShellDestination>[
      for (final destination in ShellDestination.values)
        if (destination != selectedDestination) destination,
      selectedDestination,
    ];
    return Stack(
      children: [
        for (final destination in ordered)
          _ShellPageLayer(
            key: ValueKey(destination),
            selected: destination == selectedDestination,
            outgoing:
                destination == _previousDestination &&
                destination != selectedDestination,
            animation: _tabTransition,
            child: _pages[destination]!,
          ),
      ],
    );
  }

  /// 引导完成 / 跳过：先写设备本地标记（失败下次仍会显示），再切回壳层。
  Future<void> _finishOnboarding() async {
    await (widget.onboardingStore ?? OnboardingStore()).markCompleted();
    if (mounted) setState(() => _showOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_showOnboarding) {
      return OnboardingFlow(onFinished: _finishOnboarding);
    }
    final l10n = AppLocalizations.of(context)!;
    final visibleDestinations = context
        .watch<NavProvider>()
        .visibleDestinations;
    // 选中项被隐藏时回退到第一个可见目的地（重新显示后自动恢复）；
    // chrome、页面栈与点击判定共用同一 resolver。
    final selectedDestination = _effectiveDestination;
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
      // 长按收藏目的地：切到收藏页并定位当前播放曲目（页面在下一帧
      // 可见、列表布局完成后执行滚动）。
      destinationLongPress: {ShellDestination.favorites: _onFavoritesLongPress},
    );

    // 桌面骨架：顶栏瘦身 + 恒折叠侧栏 + 页面栈（底栏播放条在非播放页出现）
    // （结构见 `desktop/desktop_shell.dart`）；移动 / 平板骨架保持
    // PageView + 底栏版式。
    // 桌面布局值在这里解析一次（窗口宽 / 平台位），页面与骨架只消费
    // （见 `widgets/desktop_layout.dart`）。
    if (_desktopShell) {
      return _withBackScope(
        AdaptiveLayoutScope.scope(
          context,
          child: DesktopLayout.scope(
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
              // 由壳层持有控制器后分发；Esc 先过一遍层级返回。
              onOpenQueue: _openQueue,
              onCloseQueuePanel: _handleShellBackCommand,
            ),
          ),
        ),
      );
    }

    // 顶栏由 ShellChrome 统一构造（标题 / 动作 / 拖动区装配在 ShellAppBar）：
    // 整条顶栏是窗口拖动区（隐藏标题栏后唯一的拖动入口），高度 = 56 工具行
    // + 10 进度条槽，非桌面平台 WindowDragArea 是纯透传。
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
        // 顶栏进度条槽高（见 `_shellBarProgressHeight`）。
        preferredSize: const Size.fromHeight(_shellBarProgressHeight),
        child: _ShellBarProgress(morph: _morph),
      ),
    );

    final adaptive = AdaptiveLayoutScope.of(context);
    final useRail = adaptive.usesNavigationRail;
    return _withBackScope(
      AdaptiveLayoutScope.scope(
        context,
        child: DesktopLayout.scope(
          context,
          child: Scaffold(
            appBar: appBar,
            // 短横屏的发现页不随键盘缩正文：手机横屏可用高本就只有 ~290，
            // 键盘再占一半后页头（渠道 + tab）与 200% 字号会直接溢出。
            // 搜索框在页面顶部始终可见，结果列表让键盘覆盖、继续可滚动。
            resizeToAvoidBottomInset:
                !(adaptive.isShortViewport &&
                    selectedDestination == ShellDestination.library),
            // 横屏时左右安全区（刘海 / 侧边系统栏）要留给正文：应用开了
            // drawUnderSystemBars，Android 又用 shortEdges，不避让时导航轨会
            // 直接压到摄像头挖孔下面。顶栏的左右留白在 ShellAppBar 内容层处理，
            // 这里只管正文；bottom 由底栏自己的 SafeArea 承担。
            body: SafeArea(
              top: false,
              bottom: false,
              child: Row(
                children: [
                  if (useRail)
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
            ),
            bottomNavigationBar: useRail
                ? null
                : SafeArea(
                    bottom: false,
                    child: M3ENavigationBar(
                      // iOS 使用紧凑高度（M3E 最小档 64）。
                      size: defaultTargetPlatform == TargetPlatform.iOS
                          ? M3ENavBarSize.small
                          : M3ENavBarSize.medium,
                      labelBehavior: M3ENavBarLabelBehavior.alwaysShow,
                      selectedIndex: selectedIndex,
                      onDestinationSelected: chrome.selectDestinationAt,
                      destinations: chrome.barDestinations(),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
