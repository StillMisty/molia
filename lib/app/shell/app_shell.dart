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
import '../../domain/models/update_check_notice.dart';
import '../../l10n/app_localizations.dart';
import '../../pages/favorites.dart';
import '../../pages/library.dart';
import '../../pages/nowplaying.dart';
import '../../pages/onboarding_flow.dart';
import '../../pages/sources_page.dart';
import '../../pages/sync_nearby_pairing_dialogs.dart';
import '../../pages/sync_notices.dart';
import '../../pages/update_settings_page.dart';
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
import '../../services/update/update_check_coordinator.dart';
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
import '../../widgets/update_available_dialog.dart';
import '../app_presence_ticker_mode.dart';
import '../desktop/desktop_shell.dart';
import '../shell_chrome.dart';
import '../tray_dormant_gate.dart';
import 'layout_skipping_offstage.dart';
import 'shell_page_layer_presentation.dart';
import 'shell_presentation.dart';

part 'app_keys.dart';
part 'pairing_queue.dart';
part 'shell_back_intent.dart';
part 'shell_bar.dart';
part 'shell_page_layer.dart';
part 'shell_progress.dart';
part 'player_flight.dart';
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
  /// （资料库 / 收藏 = 回到列表顶部），壳层不消费。
  ///
  /// 播放页也有一个实例保持 map 结构完整，但没有消费者：它的重复点击由
  /// [_requestPlayerExpansion] 直接切换展开态，避免共享飞行再绕页面一圈。
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

  /// 壳层展示决策的唯一所有者（目的地 / 展开 / 顶栏播放条 / 返回层级）。
  ///
  /// 壳层 State 只做渲染：跑弹簧、发共享封面飞行、搭骨架。页面在布局 /
  /// 动画落定时把 `expanded` / `miniCapable` 回写进来。
  late final ShellPresentation _presentation;

  /// 页面实例固定（key 稳定），顺序/显隐只影响底栏映射与分层透明度，
  /// 页面状态（滚动/搜索词等）天然保持。
  late final Map<ShellDestination, Widget> _pages = {
    ShellDestination.nowPlaying: NowPlaying(
      morph: _morph,
      controller: _nowPlaying,
      // 页面自己的展开 / 收起手势（圆点、内容下拉、播放器拖拽）只表达意图，
      // 由壳层同时发起顶栏 ⇄ 播放页的共享封面飞行。
      onRequestExpansion: _requestPlayerExpansion,
      // 展开态 / 布局能力由页面回写到展示模块，壳层只消费判定。
      onExpansionChanged: _presentation.setExpanded,
      onMiniCapableChanged: _presentation.setMiniCapable,
      // 桌面骨架的播放页换成「封面 + 控制 / 队列·歌词·信息」版式（无收起态）；
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

  @override
  void initState() {
    super.initState();
    // 托盘休眠会卸载并重建整棵界面，重建时拿到的仍是启动时的
    // `showOnboarding`；本次进程已完成 / 跳过时不能再引导一次。
    _showOnboarding =
        widget.showOnboarding && !OnboardingStore.completedInSession;
    WidgetsBinding.instance.addObserver(this);
    _morphAnimation.addListener(_onMorphTick);
    // 启动首页：导航偏好在首帧前已就绪（组合根 await 过 preferencesReady），
    // 这里同步读取即可；存储值不可见时 effectiveHomeDestination 已回退到
    // 第一个可见目的地。目的地 / 展开 / 顶栏判定统一交给展示模块。
    final nav = context.read<NavProvider>();
    _presentation = ShellPresentation(
      initialDestination: nav.effectiveHomeDestination,
      visibleDestinations: nav.visibleDestinations,
    )..addListener(_onPresentationChanged);
    // 顶栏 / 底栏的曲目信息区必须与「手动进入播放页」后的状态一致（播放页
    // 激活即收起封面）：否则恢复会话后顶栏会重复显示曲目封面/进度。
    _morph.setBarHeaderHidden(
      _presentation.effectiveDestination == ShellDestination.nowPlaying,
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

  /// 壳层重建转发：`player_flight.dart` 的 extension 不能直接调用
  /// protected 的 `setState`（Dart 限制），留一个私有转发。
  void _rebuildShell() => setState(() {});

  /// 展开态 / 布局能力翻转 → 重算 `PopScope.canPop` 与顶栏内容。
  ///
  /// 飞行中由 [PlayerMorphController.barHeaderHidden] 驱动顶栏文字 / 按钮 /
  /// 进度条的过渡；没有飞行时才直接对齐，避免与飞行副本抢节奏。
  void _onPresentationChanged() {
    if (!mounted) return;
    _rebuildShell();
    if (!_presentation.flightInProgress) {
      _morph.setBarHeaderHidden(!_presentation.showsPlayerBar);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 可见性变化（如同步隐藏当前目的地）会改写有效选中项，但没有经过
    // [_selectDestination]；把播放页 morph 状态对齐到新的有效选中项，
    // 避免页面栈已回退、顶栏却仍停留在播放页形态（曲目区/进度条收起）。
    final bool effectiveChanged = _presentation.syncVisibility(
      context.read<NavProvider>().visibleDestinations,
    );
    if (!effectiveChanged) return;
    _completeMorph();
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(!_presentation.showsPlayerBar);
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
    _presentation.removeListener(_onPresentationChanged);
    _presentation.dispose();
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
  /// - 已选中播放页 → 在展开 / 收起之间切换（顶栏 ⇄ 页内封面继续走同一套
  ///   飞行）；资料库 / 收藏回到列表顶部。
  ///
  /// 进入播放页的飞行期间忽略重复点击：此刻切换会与飞行副本抢封面，
  /// 等飞行落定（~0.4s）再切换。
  void _onDestinationSelected(ShellDestination destination) {
    if (destination != _presentation.effectiveDestination) {
      _selectDestination(destination);
      return;
    }
    if (destination == ShellDestination.nowPlaying) {
      if (_presentation.expansionVerdict != ShellExpansionVerdict.accepted) {
        return;
      }
      HapticsService.lightImpact();
      _requestPlayerExpansion(!_presentation.expanded);
      return;
    }
    // 重复点击是一次真实的点按（列表回顶是肉眼可见的动作），给一次轻震：
    // 壳层统一在此触发 —— 页面侧的重复点击响应不带触感，避免同一次点击
    // 两次震动（命中忽略分支时不震动）。
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
    if (_presentation.effectiveDestination != favorites) {
      _selectDestination(favorites);
    } else {
      HapticsService.lightImpact();
    }
    _locatePlaying.trigger();
  }

  void _selectDestination(ShellDestination destination) {
    final nav = context.read<NavProvider>();
    // 同一帧里可见集合可能刚变（导航偏好重载 / 同步应用）：先同步再判定，
    // 否则会拿旧可见集合切到一个已经隐藏的目的地。
    _presentation.syncVisibility(nav.visibleDestinations);
    // 隐藏目的地不参与导航（与 chrome / 页面栈同一可见集合）：否则 raw
    // 选中项会再次与有效选中项分叉，页面栈回退到另一个可见项。
    if (!_presentation.isVisible(destination)) return;
    // 过渡的起点必须是当前真正显示的页，而不是被隐藏的 raw 选中项。
    final current = _presentation.effectiveDestination;
    if (destination == current) return;
    if (!_presentation.select(destination)) return;
    HapticsService.lightImpact();
    final bool enteringPlayer = destination == ShellDestination.nowPlaying;
    final bool leavingPlayer = current == ShellDestination.nowPlaying;
    // 从其它一级页进入播放页：总是展开完整播放页。播放页可能停在收起态
    // （上一轮手动收起后离开），直接切过去会让用户落在一个「空的播放页」
    // 上。歌词请求先发；展开请求要等飞行起点抓好之后再发。
    if (enteringPlayer && nav.showLyricsOnEnter) {
      _nowPlaying.showLyricsTab();
    }
    // 目的地不是通知型状态（见 ShellPresentation 类注释）：切页这一帧由
    // 壳层自己推进，与下一行的封面飞行共用同一帧。
    setState(() {});
    if (reduceMotionOf(context)) {
      // 减弱动效：tab 淡入淡出与封面飞行都直达终态（不 forward(from: 0)、
      // 不插 Overlay 飞行副本）；两端状态仍按「谁在播放页」对齐。
      if (enteringPlayer) _nowPlaying.expand();
      _tabTransition.value = 1;
      _completeMorph();
      _alignMorphEnds(onPlayerPage: enteringPlayer);
      return;
    }
    _tabTransition.forward(from: 0);
    if (enteringPlayer) {
      // 先抓顶栏封面再发展开请求：expand 会立刻让顶栏隐藏，顺序反过来会
      // 先淡出再起飞（锚点还在，但观感上是两段）。
      _startMorphToPage();
      _nowPlaying.expand();
    } else if (leavingPlayer) {
      // 宽版式 / 桌面两栏没有收起态、expanded 恒为 false，但播放页是完整
      // 可见的，离开时同样要从页内封面飞回顶栏（否则共享飞行直接消失）。
      // 只有窄版式且已收起（高度 0）才没有可起飞的页内封面。
      if (!_presentation.miniCapable || _presentation.expanded) {
        _startMorphBackToBar();
      } else {
        _alignMorphEnds(onPlayerPage: false);
      }
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
    if (_presentation.effectiveDestination != ShellDestination.nowPlaying) {
      return;
    }
    _nowPlaying.showLyricsTab();
  }

  /// 播放页展开 / 收起的唯一入口（底栏重复点击、顶栏曲目区、页内手势、
  /// 歌词整页的系统返回共用）。
  ///
  /// 页面只消费 [NowPlayingController] 的意图并跑高度动画；共享封面飞行
  /// 在这里发起，保证「页内手势」与「进入播放页」走同一套 Spring / 副本，
  /// 不新增第二套动画系统。守卫（页面 / 布局能力 / 飞行）由
  /// [ShellPresentation.expansionVerdict] 裁决。
  void _requestPlayerExpansion(bool expand) {
    if (_presentation.expansionVerdict != ShellExpansionVerdict.accepted) {
      return;
    }
    final bool wasExpanded = _presentation.expanded;
    if (expand) {
      if (wasExpanded) {
        _nowPlaying.expand();
        return;
      }
      if (reduceMotionOf(context)) {
        _nowPlaying.expand();
        _completeMorph();
        _alignMorphEnds(onPlayerPage: true);
        return;
      }
      // 先抓顶栏封面再发展开请求：expand 会立刻让顶栏隐藏，顺序反过来会
      // 先淡出再起飞。目的地没有变化也要走正常撤销检查——同一帧切走时
      // post-frame 会按「已离开播放页」放弃这次飞行。
      _startMorphToPage();
      _nowPlaying.expand();
      return;
    }
    _nowPlaying.collapse();
    if (!wasExpanded) return;
    if (reduceMotionOf(context)) {
      _completeMorph();
      _alignMorphEnds(onPlayerPage: false);
      return;
    }
    _startMorphBackToBar(destinationChanged: false);
  }

  /// 顶栏曲目区点击：不在播放页走目的地切换（含歌词偏好 + 展开 + 飞行），
  /// 已在播放页收起态则就地展开。
  void _openPlayerFromBar() {
    if (_presentation.effectiveDestination != ShellDestination.nowPlaying) {
      _selectDestination(ShellDestination.nowPlaying);
      return;
    }
    if (_presentation.expanded) return;
    _requestPlayerExpansion(true);
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
    final selectedDestination = _presentation.effectiveDestination;
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
                destination == _presentation.previousDestination &&
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
    // 订阅导航偏好：可见集合变化要重建；渲染列表从展示模块取，与
    // selectedIndex 同一权威（didChangeDependencies 已同步）。
    context.watch<NavProvider>();
    final visibleDestinations = _presentation.visibleDestinations;
    // 选中项被隐藏时回退到第一个可见目的地（重新显示后自动恢复）；
    // chrome、页面栈与点击判定共用同一 resolver。
    final selectedDestination = _presentation.effectiveDestination;
    final selectedIndex = _presentation.selectedIndex;

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
    final bool showPlayerBar = _presentation.showsPlayerBar;
    final appBar = chrome.appBar(
      context: context,
      title: WindowDoubleTapMaximize(
        // 双击顶栏标题区（拖动区的非按钮部分）= 最大化 / 还原（桌面肌肉记忆）；
        // 按钮区不参与，避免双击按钮顺带改窗口状态。
        child: _ShellBarHeader(
          key: const Key('shellBarPlayerSummary'),
          morph: _morph,
          reveal: _barReveal,
          onOpenPlayer: _openPlayerFromBar,
        ),
      ),
      actions: [
        // 顶栏右侧：移动端顶栏是唯一迷你播放器 —— 不在播放页、或播放页
        // 收起时显示播放/下一首；展开后让位给品牌位。
        // 两个按钮与歌名/作者共用同一根入场弹簧（缩放 pop + 淡入）。
        if (showPlayerBar) ...[
          _BarPlayPauseButton(
            key: const Key('shellBarPlayPause'),
            reveal: _barReveal,
          ),
          _BarNextButton(key: const Key('shellBarNext'), reveal: _barReveal),
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
