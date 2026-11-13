import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/app/app_presence_ticker_mode.dart';
import 'package:molia/app/app_shell.dart' as shell;
import 'package:molia/app/tray_dormant_gate.dart';
import 'package:molia/services/app_presence.dart';
import 'package:molia/widgets/current_track_cover.dart';
import 'package:molia/widgets/playing_indicator.dart';
import 'package:molia/widgets/seek_bar.dart';
import 'package:molia/widgets/seek_preview.dart';

/// 波浪只允许出现在播放页主场：列表 / 顶栏 / 迷你条 / 底栏常驻时必须是
/// 静态形态，避免整机按显示刷新率持续出帧。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => M3EMaterialApp(
    data: M3EThemeData.fromMaterial(ThemeData.light()),
    theme: ThemeData.light(),
    home: Scaffold(body: Center(child: child)),
  );

  group('SeekBar 波浪显式 opt-in', () {
    late ValueNotifier<Duration> position;
    late ChangeNotifier trackChanges;
    late SeekPreviewController controller;

    setUp(() {
      position = ValueNotifier<Duration>(Duration.zero);
      trackChanges = ChangeNotifier();
      controller = SeekPreviewController(
        position: position,
        trackChanges: trackChanges,
        currentTrackId: () => null,
        seek: (_) {},
      );
    });

    tearDown(() {
      controller.dispose();
      trackChanges.dispose();
      position.dispose();
    });

    Future<void> pumpSeekBar(
      WidgetTester tester, {
      required bool wavy,
      required bool isPlaying,
    }) {
      return tester.pumpWidget(
        host(
          SizedBox(
            width: 320,
            child: SeekBar(
              controller: controller,
              position: position,
              durationMs: 60000,
              isPlaying: isPlaying,
              hasTrack: true,
              timeLabels: SeekTimeLabels.below,
              wavy: wavy,
            ),
          ),
        ),
      );
    }

    testWidgets('默认平直；播放页传 wavy 才用波浪', (tester) async {
      await pumpSeekBar(tester, wavy: false, isPlaying: true);
      expect(tester.widget<M3ESlider>(find.byType(M3ESlider)).wavy, isFalse);

      await pumpSeekBar(tester, wavy: true, isPlaying: true);
      expect(tester.widget<M3ESlider>(find.byType(M3ESlider)).wavy, isTrue);
    });

    testWidgets('暂停时即使 opt-in 也回落到平直', (tester) async {
      await pumpSeekBar(tester, wavy: true, isPlaying: false);
      expect(tester.widget<M3ESlider>(find.byType(M3ESlider)).wavy, isFalse);
    });
  });

  group('顶栏进度条', () {
    testWidgets('播放中也是静态平直形态（不跑无限动画）', (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 320,
            child: shell.ProgressIndicator(
              position: Duration(seconds: 10),
              duration: 60,
            ),
          ),
        ),
      );

      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byType(M3EProgressIndicator), findsOneWidget);
    });
  });

  group('CurrentTrackCover 均衡器角标', () {
    Widget cover({required bool animate}) => host(
      Center(
        child: CurrentTrackCover(
          cover: const SizedBox.square(dimension: 44),
          size: 44,
          isPlaying: true,
          animate: animate,
        ),
      ),
    );

    testWidgets('列表默认不跑 ticker；显式 animate 才起伏', (tester) async {
      await tester.pumpWidget(cover(animate: false));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(cover(animate: true));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pumpWidget(cover(animate: false));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('AnimatedPlayingBadge', () {
    Widget badge({required bool isPlaying, bool animate = true}) => host(
      Center(
        child: AnimatedPlayingBadge(isPlaying: isPlaying, animate: animate),
      ),
    );

    testWidgets('播放中起伏，暂停原地冻结', (tester) async {
      await tester.pumpWidget(badge(isPlaying: true));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pumpWidget(badge(isPlaying: false));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('animate=false 只作静态状态标识', (tester) async {
      await tester.pumpWidget(badge(isPlaying: true, animate: false));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('TrayDormantGate', () {
    testWidgets('托盘隐藏时不构建整棵应用树，恢复后重新构建', (tester) async {
      final presence = AppPresence.instance;
      addTearDown(presence.markVisible);
      presence.markTrayHidden();

      var builds = 0;
      await tester.pumpWidget(
        TrayDormantGate(
          color: const Color(0xFF000000),
          childBuilder: (context) {
            builds++;
            return const SizedBox.shrink(key: ValueKey('app'));
          },
        ),
      );
      expect(builds, 0, reason: '隐藏期间不构造 MaterialApp 配置');
      expect(find.byKey(const ValueKey('app')), findsNothing);

      presence.markVisible();
      await tester.pump();
      expect(builds, 1);
      expect(find.byKey(const ValueKey('app')), findsOneWidget);
    });
  });

  group('AppPresenceTickerMode', () {
    testWidgets('最小化后播放角标不再调度帧', (tester) async {
      final presence = AppPresence.instance;
      presence.markVisible();
      addTearDown(presence.markVisible);

      await tester.pumpWidget(
        host(
          AppPresenceTickerMode(
            child: Center(child: AnimatedPlayingBadge(isPlaying: true)),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: '可见时角标应在跑 ticker',
      );

      presence.markMinimized();
      await tester.pump();
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: '最小化后 TickerMode 应静音角标，不再调度帧',
      );
    });

    testWidgets('最小化时静音子树 ticker，恢复可见后重新启用', (tester) async {
      final presence = AppPresence.instance;
      presence.markVisible();
      addTearDown(presence.markVisible);

      var enabled = false;
      await tester.pumpWidget(
        AppPresenceTickerMode(
          child: Builder(
            builder: (context) {
              enabled = TickerMode.valuesOf(context).enabled;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(enabled, isTrue);

      presence.markMinimized();
      await tester.pump();
      expect(enabled, isFalse);

      presence.markVisible();
      await tester.pump();
      expect(enabled, isTrue);
    });
  });
}
