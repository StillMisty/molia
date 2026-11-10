import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/ai_dj_carousel.dart';

/// AI 推荐卡片流：封面解码有上界（256 逻辑像素 × DPR），避免按原图解码。
///
/// 完整的 carousel 渲染依赖 AI provider / 播放 provider / 封面存储与真实
/// 异步初始化，单测里收益低于维护成本；这里直接锁住解码宽度的计算口径，
/// carousel 的封面参数只调用这一个入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('封面解码宽度 = 256 逻辑像素 × DPR', (tester) async {
    for (final entry in const [(1.0, 256), (2.0, 512), (3.0, 768)]) {
      late int actual;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(devicePixelRatio: entry.$1),
          child: Builder(
            builder: (context) {
              actual = AiDjCarousel.coverMemCacheWidth(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        actual,
        entry.$2,
        reason: 'DPR ${entry.$1} 时按 ${entry.$2}px 解码，而不是原图',
      );
    }
  });
}
