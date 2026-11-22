import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/ai_dj_carousel.dart';
import 'package:molia/widgets/playing_indicator.dart';

/// AI 推荐卡片流：封面解码有上界（256 逻辑像素 × DPR），避免按原图解码。
///
/// 完整的 carousel 渲染依赖 AI provider / 播放 provider / 封面存储与真实
/// 异步初始化，单测里收益低于维护成本；这里直接锁住解码宽度的计算口径，
/// carousel 的封面参数只调用这一个入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => M3EMaterialApp(
    data: M3EThemeData.fromMaterial(ThemeData.light()),
    theme: ThemeData.light(),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('当前卡三柱内联在歌名行，非当前卡不构建', (tester) async {
    await tester.pumpWidget(
      host(
        const AiDjCarouselTitle(
          title: 'Song',
          isCurrent: true,
          isPlaying: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AnimatedPlayingIndicator), findsOneWidget);
    expect(tester.widget<Text>(find.text('Song')).style?.color, isNotNull);
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(
      host(
        const AiDjCarouselTitle(
          title: 'Song',
          isCurrent: false,
          isPlaying: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AnimatedPlayingIndicator), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
