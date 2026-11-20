import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart' as shell;
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/pages/library.dart';
import 'package:molia/pages/nowplaying.dart';
import 'package:molia/services/back_claims.dart';
import 'package:molia/services/onboarding_store.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/player_morph.dart';

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

  testWidgets('Android 返回：非家目的地回上一页，播放页先收起不退出', (tester) async {
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

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(
      find.byType(FavoritesPage),
      findsOneWidget,
      reason: '非家目的地返回上一页（收藏是上一目的地 / 家）',
    );

    // 进入播放页（单栏默认展开）：第一次返回只收起播放器。
    final nav = find.byType(M3ENavigationBar);
    await tester.tap(
      find.descendant(of: nav, matching: find.byType(MoliaMark)),
    );
    await pumpFrames(tester, frames: 60);
    expect(find.byType(NowPlaying), findsOneWidget);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 100);
    expect(
      find.byType(NowPlaying),
      findsOneWidget,
      reason: '展开播放页的返回是收起，不是退出目的地',
    );

    // 收起后再返回：回上一目的地（收藏）。
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 60);
    expect(find.byType(FavoritesPage), findsOneWidget);
  });

  testWidgets('页面级返回占用时壳层让位，第二次返回才回上一目的地', (tester) async {
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

    pageClaimsBack = false;
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(find.byType(FavoritesPage), findsOneWidget);
  });

  testWidgets('桌面 Esc：先收队列，再逐级返回上一目的地', (tester) async {
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
    expect(
      find.byType(FavoritesPage),
      findsOneWidget,
      reason: '资料库按 Esc 回上一目的地',
    );

    // 底栏队列按钮：跳播放页并打开队列。
    await tester.tap(find.byKey(DesktopNowPlayingBar.openQueueKey));
    await pumpFrames(tester, frames: 60);
    expect(find.byType(NowPlaying), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 30);
    expect(
      find.byType(NowPlaying),
      findsOneWidget,
      reason: '队列打开时 Esc 仍优先收队列，不退回上一页',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, frames: 60);
    expect(
      find.byType(FavoritesPage),
      findsOneWidget,
      reason: '队列已收：下一次 Esc 才回上一目的地',
    );
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
