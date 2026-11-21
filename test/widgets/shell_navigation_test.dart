import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart' as shell;
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/pages/library.dart';
import 'package:molia/pages/nowplaying.dart';
import 'package:molia/services/back_claims.dart';
import 'package:molia/services/onboarding_store.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/now_playing_controller.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/shell_page_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/perf_app_harness.dart';

/// 壳层导航的特征测试：切页后页面状态保持、两套导航骨架都能切页、
/// 首次引导完成 / 跳过进入正常壳层、配对请求串行队列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 页面上第一个可纵向滚动的列表（收藏页标题里的横向筛选条不算）。
  ScrollableState verticalList(WidgetTester tester, Type page) {
    final finder = find.descendant(
      of: find.byType(page, skipOffstage: false),
      matching: find.byType(Scrollable, skipOffstage: false),
    );
    final count = finder.evaluate().length;
    for (var i = 0; i < count; i++) {
      final state = tester.state<ScrollableState>(finder.at(i));
      if (state.position.axis == Axis.vertical &&
          state.position.maxScrollExtent > 0) {
        return state;
      }
    }
    fail('页面 $page 没有可滚动的纵向列表');
  }

  /// Linux 测试宿主上窗口三键会随移动骨架一起进顶栏（真机没有窗口按钮），
  /// 360 宽时迷你播放器的 40dp 封面放不下，顶栏必然报 RenderFlex 溢出。
  /// 该溢出与导航无关、也不出现在真机装配里：用例只消费「左右方向的
  /// RenderFlex 溢出」这一类错误（`takeException` 只带首行，方向看文案），
  /// 其它异常（含页面自身溢出）照旧抛出。
  void drainHostTopBarOverflow(WidgetTester tester) {
    final error = tester.takeException();
    if (error == null) return;
    expect(
      '$error',
      matches(
        RegExp(
          r'A RenderFlex overflowed by [\d.]+ pixels on the (left|right)\.',
        ),
      ),
      reason: '只忽略顶栏的水平 RenderFlex 溢出',
    );
  }

  /// 点导航条目（底栏或导航轨，按当前档位只有一个在树里）。
  Future<void> tapDestination(
    WidgetTester tester,
    IconData icon, {
    int frames = 60,
    bool drainOverflow = false,
  }) async {
    final nav = find.byType(M3ENavigationBar).evaluate().isNotEmpty
        ? find.byType(M3ENavigationBar)
        : find.byType(M3ENavigationRail);
    await tester.tap(find.descendant(of: nav, matching: find.byIcon(icon)));
    // tab 淡入淡出是弹簧过渡：多推几帧让出场页真正 Offstage。
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (drainOverflow) drainHostTopBarOverflow(tester);
    }
  }

  /// 壳层 PopScope 是否允许系统退出（true = 一级页，不拦返回）。
  bool shellCanPop(WidgetTester tester) {
    final scope = tester.widget<PopScope<dynamic>>(
      find.byKey(const Key('shellBackScope')),
    );
    return scope.canPop;
  }

  /// 页面是否是壳层当前选中页（常驻页面不会离树，不能用 finder 判断切页）。
  bool pageIsVisible(WidgetTester tester, Type page) {
    final scope = tester.widget<ShellPageVisibility>(
      find
          .ancestor(
            of: find.byType(page, skipOffstage: false),
            matching: find.byType(ShellPageVisibility, skipOffstage: false),
          )
          .first,
    );
    return scope.visible;
  }

  /// 点底栏 / 导航轨的播放目的地（唯一一颗 Molia 标志图标）。
  Future<void> openNowPlaying(WidgetTester tester, {int frames = 90}) async {
    final nav = find.byType(M3ENavigationBar).evaluate().isNotEmpty
        ? find.byType(M3ENavigationBar)
        : find.byType(M3ENavigationRail);
    await tester.tap(
      find.descendant(of: nav, matching: find.byType(MoliaMark)),
    );
    await pumpFrames(tester, frames: frames);
  }

  /// 播放器高度：收起态为 0，展开态是内容高度。
  double playerHeight(WidgetTester tester) =>
      tester.getSize(find.byType(Player)).height;

  /// 播放页当前落定的内容页（队列 / 歌词 / 信息）。
  int nowPlayingPage(WidgetTester tester) {
    final pageView = tester.widget<PageView>(
      find.descendant(
        of: find.byType(NowPlaying),
        matching: find.byType(PageView),
      ),
    );
    return pageView.controller!.page!.round();
  }

  Future<void> jumpNowPlayingPage(WidgetTester tester, int index) async {
    final pageView = tester.widget<PageView>(
      find.descendant(
        of: find.byType(NowPlaying),
        matching: find.byType(PageView),
      ),
    );
    pageView.controller!.jumpToPage(index);
    await pumpFrames(tester, frames: 3);
  }

  testWidgets('底栏切走再切回：收藏页仍挂载且滚动位置保持', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 60,
      size: const Size(500, 900),
    );
    expect(find.byType(FavoritesPage), findsOneWidget);

    final list = verticalList(tester, FavoritesPage);
    await tester.drag(find.byWidget(list.widget), const Offset(0, -600));
    await pumpFrames(tester, frames: 20);
    final before = list.position.pixels;
    expect(before, greaterThan(0), reason: '收藏列表应已滚动');

    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);
    // 切页后收藏页仍挂载（上层页面层不销毁页面）：同一份 State 与滚动位置。
    expect(find.byType(FavoritesPage, skipOffstage: false), findsOneWidget);
    expect(identical(verticalList(tester, FavoritesPage), list), isTrue);

    await tapDestination(tester, Icons.favorite_border_rounded);
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(identical(verticalList(tester, FavoritesPage), list), isTrue);
    expect(list.position.pixels, before, reason: '切页不应重置滚动位置');
  });

  testWidgets('360 宽走底栏并可以切页', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(360, 800),
      waitForHome: false,
    );
    drainHostTopBarOverflow(tester);
    expect(find.byType(M3ENavigationBar), findsOneWidget);
    expect(find.byType(M3ENavigationRail), findsNothing);

    await tapDestination(
      tester,
      Icons.library_music_outlined,
      frames: 3,
      drainOverflow: true,
    );
    expect(find.byType(Library), findsOneWidget);

    await tapDestination(
      tester,
      Icons.favorite_border_rounded,
      frames: 3,
      drainOverflow: true,
    );
    expect(find.byType(FavoritesPage), findsOneWidget);
  });

  testWidgets('640 宽走导航轨并可以切页', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(640, 900),
    );
    expect(find.byType(M3ENavigationRail), findsOneWidget);
    expect(find.byType(M3ENavigationBar), findsNothing);

    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);

    await tapDestination(tester, Icons.favorite_border_rounded);
    expect(find.byType(FavoritesPage), findsOneWidget);
  });

  testWidgets('减弱动效：切页一帧到终态且不插封面飞行副本', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
      disableAnimations: true,
    );
    expect(find.byType(FavoritesPage), findsOneWidget);

    final nav = find.byType(M3ENavigationBar);
    await tester.tap(
      find.descendant(of: nav, matching: find.byType(MoliaMark)),
    );
    // 单帧即终态：没有 Overlay 飞行副本，出场页已经透明。
    await tester.pump();

    expect(find.byType(PlayerMorphFlight), findsNothing);
    expect(find.byType(NowPlaying), findsOneWidget);
    final outgoingOpacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(FavoritesPage),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(outgoingOpacity.opacity, 0, reason: '减弱动效时出场页不保留淡出中间帧');
    final incomingOpacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.byType(NowPlaying), matching: find.byType(Opacity))
          .first,
    );
    expect(incomingOpacity.opacity, 1);
  });

  testWidgets('出场页在过渡期间仍可 tick（TickerMode 不提前静音）', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    expect(find.byType(FavoritesPage), findsOneWidget);

    await tapDestination(tester, Icons.library_music_outlined, frames: 2);
    final tickerMode = tester.widget<TickerMode>(
      find
          .ancestor(
            of: find.byType(FavoritesPage),
            matching: find.byType(TickerMode),
          )
          .first,
    );
    expect(
      tickerMode.enabled,
      isTrue,
      reason: '出场页的淡出 / 微缩需要 ticker，过渡第一帧不能静音',
    );

    // 淡出结束后上一目的地仍保留 outgoing 标记（Offstage 语义不变），
    // 但 ticker 必须恢复静音，避免隐藏页常驻动画空转。
    await pumpFrames(tester, frames: 60);
    final settled = tester.widget<TickerMode>(
      find
          .ancestor(
            of: find.byType(FavoritesPage),
            matching: find.byType(TickerMode),
          )
          .first,
    );
    expect(settled.enabled, isFalse);
  });

  testWidgets('Android 返回：一级页允许系统退出，播放页先收起不退出', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    // 首屏 = 收藏（家目的地）。
    expect(find.byType(FavoritesPage), findsOneWidget);

    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);

    // 资料页按返回不再回收藏：一级页直接交给系统退出。
    expect(shellCanPop(tester), isTrue, reason: '一级页不拦系统返回');
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(find.byType(Library), findsOneWidget, reason: '不再回上一目的地');
    expect(pageIsVisible(tester, Library), isTrue);
    expect(pageIsVisible(tester, FavoritesPage), isFalse);
    expect(shellCanPop(tester), isTrue, reason: '根路由退出行为不可靠，用 canPop 表达「允许退出」');

    // 进入播放页（单栏默认展开）：第一次返回只收起播放器。
    final nav = find.byType(M3ENavigationBar);
    await tester.tap(
      find.descendant(of: nav, matching: find.byType(MoliaMark)),
    );
    await pumpFrames(tester, frames: 60);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(shellCanPop(tester), isFalse, reason: '展开播放页由壳层拦返回');

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 100);
    expect(
      find.byType(NowPlaying),
      findsOneWidget,
      reason: '展开播放页的返回是收起，不是退出目的地',
    );
    expect(pageIsVisible(tester, NowPlaying), isTrue);
    expect(pageIsVisible(tester, FavoritesPage), isFalse);
    expect(shellCanPop(tester), isTrue, reason: '收起后回到一级页语义：允许系统退出');
  });

  testWidgets('移动端顶栏条是唯一迷你播放器：进入展开、返回收起、顶栏再展开', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    expect(find.byType(FavoritesPage), findsOneWidget);
    // 收藏首屏：顶栏播放条（封面 + 歌名 + 播放 / 下一首）可见。
    expect(find.byKey(const Key('shellBarPlayerSummary')), findsOneWidget);
    expect(find.byKey(const Key('shellBarPlayPause')), findsOneWidget);
    expect(find.byKey(const Key('shellBarNext')), findsOneWidget);

    // 进入播放页总是展开：页内播放器有高度，顶栏播放条让位给品牌位。
    await openNowPlaying(tester);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(playerHeight(tester), greaterThan(0));
    expect(find.byKey(const Key('shellBarPlayPause')), findsNothing);
    expect(find.byKey(const Key('shellBarNext')), findsNothing);
    expect(shellCanPop(tester), isFalse);

    // 返回键先收起：页内高度归零、顶栏播放条在飞行落点回来。
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 150);
    expect(playerHeight(tester), closeTo(0, 0.5));
    expect(find.byKey(const Key('shellBarPlayPause')), findsOneWidget);
    expect(find.byKey(const Key('shellBarNext')), findsOneWidget);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(pageIsVisible(tester, NowPlaying), isTrue);
    expect(shellCanPop(tester), isTrue, reason: '收起后一级页允许系统退出');

    // 顶栏曲目区点击：已在播放页收起态，就地展开。
    await tester.tap(find.byKey(const Key('shellBarPlayerSummary')));
    await pumpFrames(tester, frames: 150);
    expect(playerHeight(tester), greaterThan(0));
    expect(find.byKey(const Key('shellBarPlayPause')), findsNothing);
    expect(shellCanPop(tester), isFalse);

    // 底栏重复点击播放目的地：再收回到 0 高度，顶栏播放条回来。
    await openNowPlaying(tester, frames: 150);
    expect(playerHeight(tester), closeTo(0, 0.5));
    expect(find.byKey(const Key('shellBarPlayPause')), findsOneWidget);
    expect(find.byType(NowPlaying), findsOneWidget);
  });

  testWidgets('从资料页进入播放页总是展开（即使上一轮收起过）', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    await openNowPlaying(tester);
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 150);
    expect(playerHeight(tester), closeTo(0, 0.5));

    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);

    await openNowPlaying(tester);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(playerHeight(tester), greaterThan(0));
    expect(find.byKey(const Key('shellBarPlayPause')), findsNothing);
  });

  testWidgets('设置开：从其它一级页进入播放页固定落歌词页', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shell_home_destination': 'favorites',
      kShellNowPlayingLyricsOnEnter.name: true,
    });
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
      resetPreferences: false,
    );
    await openNowPlaying(tester);
    // 手动切到队列，模拟用户上次停留在别的 tab。
    await jumpNowPlayingPage(tester, nowPlayingQueueTabIndex);
    expect(nowPlayingPage(tester), nowPlayingQueueTabIndex);

    await tapDestination(tester, Icons.favorite_border_rounded);
    await pumpFrames(tester, frames: 60);
    expect(pageIsVisible(tester, NowPlaying), isFalse);

    await openNowPlaying(tester);
    expect(
      nowPlayingPage(tester),
      nowPlayingLyricsTabIndex,
      reason: '设置开启时，进入播放页应落到歌词页',
    );
    // 歌词页在可见时也应是当前 tab（隐藏页收到请求走 jump）。
    expect(find.byKey(const Key('nowPlayingLyricsPage')), findsOneWidget);
  });

  testWidgets('设置关：回播放页保留上次停留的 tab', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shell_home_destination': 'favorites',
      kShellNowPlayingLyricsOnEnter.name: false,
    });
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
      resetPreferences: false,
    );
    await openNowPlaying(tester);
    await jumpNowPlayingPage(tester, nowPlayingQueueTabIndex);
    expect(nowPlayingPage(tester), nowPlayingQueueTabIndex);

    await tapDestination(tester, Icons.favorite_border_rounded);
    await pumpFrames(tester, frames: 60);
    await openNowPlaying(tester);
    expect(
      nowPlayingPage(tester),
      nowPlayingQueueTabIndex,
      reason: '设置关闭时不应强制切回歌词页',
    );
  });

  testWidgets('桌面宽版式离开播放页仍从页内封面飞回底栏', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(1280, 900),
    );
    await openNowPlaying(tester);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(pageIsVisible(tester, NowPlaying), isTrue);

    // 桌面两栏没有收起态（miniCapable=false / expanded=false），但离开时
    // 页内封面是完整可见的，必须仍然起飞回底栏。
    final rail = find.byType(M3ENavigationRail);
    await tester.tap(
      find.descendant(
        of: rail,
        matching: find.byIcon(Icons.favorite_border_rounded),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(PlayerMorphFlight).evaluate().isNotEmpty) break;
    }
    expect(
      find.byType(PlayerMorphFlight),
      findsOneWidget,
      reason: '桌面两栏离开播放页丢失了封面回飞',
    );
    await pumpFrames(tester, frames: 80);
    expect(find.byType(PlayerMorphFlight), findsNothing);
    expect(pageIsVisible(tester, FavoritesPage), isTrue);
  });

  testWidgets('桌面单栏播放器向下拖拽不会停在半截高度', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(800, 700),
    );
    await openNowPlaying(tester);
    final before = playerHeight(tester);
    expect(before, greaterThan(0));

    // 800 宽桌面骨架走单栏播放页，但没有顶栏播放条可承接收起态：播放器
    // 区域不应接受下拉收起。拖拽后必须仍是完整高度。
    await tester.drag(find.byType(Player), const Offset(0, 220));
    await pumpFrames(tester, frames: 30);
    expect(
      playerHeight(tester),
      closeTo(before, 1),
      reason: '单栏桌面播放器被拖小后停在了半截',
    );
  });

  testWidgets('展开请求后同一帧切走：不再起飞到已离开的播放页', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    await openNowPlaying(tester);
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 150);
    expect(playerHeight(tester), closeTo(0, 0.5));
    expect(find.byKey(const Key('shellBarPlayPause')), findsOneWidget);

    // 顶栏曲目区发起展开，紧接着同一帧切到资料库：to-page 的 post-frame
    // 必须按「已经离开播放页」放弃，不能飞向不可见的页内封面。
    await tester.tap(find.byKey(const Key('shellBarPlayerSummary')));
    final nav = find.byType(M3ENavigationBar);
    await tester.tap(
      find.descendant(
        of: nav,
        matching: find.byIcon(Icons.library_music_outlined),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      for (final element in find.byType(PlayerMorphFlight).evaluate()) {
        final flight = element.widget as PlayerMorphFlight;
        expect(flight.geometry.toPage, isFalse, reason: '已离开播放页后仍在飞向页内封面');
      }
    }
    await pumpFrames(tester, frames: 80);
    expect(pageIsVisible(tester, Library), isTrue);
  });

  testWidgets('页面级返回占用时壳层让位，清除后返回仍停在资料页', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
    );
    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);

    // 合成一个页面级占用（真实登记方是收藏页多选 / 搜索 / 排序；本用例只
    // 验证 PopScope 广播不裁决时壳层按 BackClaims 让位）。
    var pageClaimsBack = true;
    bool claim() => pageClaimsBack;
    BackClaims.add(claim);
    addTearDown(BackClaims.reset);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(
      find.byType(Library),
      findsOneWidget,
      reason: '页面接管这次返回时，壳层不能同时回上一目的地',
    );
    expect(pageIsVisible(tester, Library), isTrue);

    // 清除占用后再返回：一级页不再回上一目的地，直接允许系统退出。
    pageClaimsBack = false;
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(find.byType(Library), findsOneWidget, reason: '不再回收藏');
    expect(pageIsVisible(tester, Library), isTrue);
    expect(shellCanPop(tester), isTrue);

    // 播放页展开时页面占用仍优先：壳层让位、播放器不收起。
    pageClaimsBack = true;
    final nav = find.byType(M3ENavigationBar);
    await tester.tap(
      find.descendant(of: nav, matching: find.byType(MoliaMark)),
    );
    await pumpFrames(tester, frames: 60);
    expect(shellCanPop(tester), isFalse);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(shellCanPop(tester), isFalse, reason: '页面占用时壳层不能同时收起播放器');

    pageClaimsBack = false;
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 100);
    expect(shellCanPop(tester), isTrue, reason: '占用解除后返回才真正收起播放器');
  });

  testWidgets('桌面 Esc：一级页不逐级返回，播放页先收队列', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 3,
      size: const Size(1280, 900),
    );
    await tapDestination(tester, Icons.library_music_outlined);
    expect(find.byType(Library), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 30);
    expect(find.byType(Library), findsOneWidget, reason: '资料库按 Esc 不再回上一目的地');
    expect(pageIsVisible(tester, Library), isTrue);
    expect(pageIsVisible(tester, FavoritesPage), isFalse);

    // 底栏队列按钮：跳播放页并打开队列。
    await tester.tap(find.byKey(DesktopNowPlayingBar.openQueueKey));
    await pumpFrames(tester, frames: 60);
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(pageIsVisible(tester, NowPlaying), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 30);
    expect(
      find.byType(NowPlaying),
      findsOneWidget,
      reason: '队列打开时 Esc 仍优先收队列，不退回上一页',
    );
    expect(pageIsVisible(tester, NowPlaying), isTrue);
    expect(pageIsVisible(tester, FavoritesPage), isFalse);

    // 队列已收、桌面无展开态：再一次 Esc 保持原命令落点（停在播放页），
    // 不再回收藏。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 60);
    expect(
      find.byType(NowPlaying),
      findsOneWidget,
      reason: '没有层级可退时 Esc 不再逐级返回',
    );
    expect(pageIsVisible(tester, NowPlaying), isTrue);
    expect(pageIsVisible(tester, FavoritesPage), isFalse);
  });

  testWidgets('引导完成（开始使用）后进入正常壳层', (tester) async {
    OnboardingStore.resetSessionForTest();
    addTearDown(OnboardingStore.resetSessionForTest);
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 3,
      size: const Size(500, 900),
      showOnboarding: true,
      waitForHome: false,
    );
    expect(find.text('音乐留在本机'), findsOneWidget);
    expect(find.byType(M3ENavigationBar), findsNothing);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('onboardingNext')));
      await tester.pump();
    }
    expect(find.text('开始使用'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboardingNext')));
    await waitForFinder(
      tester,
      find.text('Performance Track 0'),
      reason: '完成引导后未进入壳层',
    );

    expect(find.byKey(const Key('onboardingNext')), findsNothing);
    expect(find.byType(M3ENavigationBar), findsOneWidget);
    expect(await OnboardingStore().isCompleted(), isTrue);
  });

  group('IncomingPairingQueue', () {
    SyncPairingRequest request(String id) => SyncPairingRequest(
      requestId: id,
      peerDeviceId: 'peer-$id',
      peerName: 'Peer $id',
      intent: SyncPairingIntent.join,
      code: '123456',
      expiresAt: 0,
    );

    test('逐条展示；宿主不可用时拒绝当前与剩余请求', () async {
      final queue = shell.IncomingPairingQueue();
      final presented = <String>[];
      final rejected = <String>[];

      queue.add(request('a'));
      queue.add(request('b'));
      await queue.drain(
        present: (request) async {
          presented.add(request.requestId);
          return true;
        },
        reject: (request) async => rejected.add(request.requestId),
      );
      expect(presented, ['a', 'b']);
      expect(rejected, isEmpty);
      expect(queue.isEmpty, isTrue);
      expect(queue.isDraining, isFalse);

      queue.add(request('c'));
      queue.add(request('d'));
      await queue.drain(
        present: (request) async {
          if (request.requestId == 'd') return false;
          presented.add(request.requestId);
          return true;
        },
        reject: (request) async => rejected.add(request.requestId),
      );
      expect(presented, ['a', 'b', 'c']);
      expect(rejected, ['d']);
      expect(queue.isEmpty, isTrue);
    });

    test('drain 期间重入直接返回，新请求由当前循环接续', () async {
      final queue = shell.IncomingPairingQueue();
      final gate = Completer<void>();
      final presented = <String>[];

      queue.add(request('a'));
      final first = queue.drain(
        present: (request) async {
          presented.add(request.requestId);
          await gate.future;
          return true;
        },
        reject: (request) async {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(queue.isDraining, isTrue);

      queue.add(request('b'));
      final second = queue.drain(
        present: (request) async {
          presented.add(request.requestId);
          return true;
        },
        reject: (request) async {},
      );
      gate.complete();
      await Future.wait([first, second]);

      expect(presented, ['a', 'b']);
      expect(queue.isEmpty, isTrue);
      expect(queue.isDraining, isFalse);
    });
  });
}
