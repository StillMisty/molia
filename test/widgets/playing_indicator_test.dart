import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/current_track_cover.dart';
import 'package:molia/widgets/playing_indicator.dart';
import 'package:material_ui/material_ui.dart';

/// 当前曲目封面角标：播放态是常驻自绘均衡器；暂停后保留同一图形并彻底静止。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCover(
    WidgetTester tester, {
    required bool isPlaying,
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
            ),
            child: Scaffold(
              body: Center(
                child: CurrentTrackCover(
                  cover: const SizedBox.square(dimension: 44),
                  size: 44,
                  isPlaying: isPlaying,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('播放中：出现 PlayingIndicator 且 ticker 在跑', (tester) async {
    await pumpCover(tester, isPlaying: true);

    expect(find.byType(PlayingIndicator), findsOneWidget);
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '播放角标应持续起伏',
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayingIndicator), findsOneWidget);
  });

  testWidgets('暂停：原地冻结，保留静态均衡器且不再有 ticker', (tester) async {
    await pumpCover(tester, isPlaying: true);
    await tester.pump(const Duration(milliseconds: 300));

    final frozenAt = tester
        .widget<PlayingIndicator>(find.byType(PlayingIndicator))
        .progress
        .value;

    await pumpCover(tester, isPlaying: false);
    // 等过一个图标切换周期：角标应始终留在原位。
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byType(PlayingIndicator), findsOneWidget);
    final pausedProgress = tester
        .widget<PlayingIndicator>(find.byType(PlayingIndicator))
        .progress;
    expect(
      pausedProgress.value,
      moreOrLessEquals(frozenAt),
      reason: '暂停应停在按下那一刻的相位，不跳回固定相位',
    );
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '暂停后共享 controller 已停住，角标不能再动',
    );
  });

  testWidgets('减弱动效：静态显示 PlayingIndicator，不启动 ticker', (tester) async {
    await pumpCover(tester, isPlaying: true, reduceMotion: true);

    expect(find.byType(PlayingIndicator), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'disableAnimations 下时间推进也不应唤醒角标动画',
    );
  });
}
