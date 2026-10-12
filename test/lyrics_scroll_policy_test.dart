/// 歌词页滚动策略的纯函数测试：脱离 widget pump 直接驱动数学。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/lyrics_scroll_policy.dart';

void main() {
  group('effectiveAlignment（激活行锚点）', () {
    test('无遮挡无偏移：视口正中', () {
      expect(
        effectiveAlignment(
          viewport: 800,
          topOverlay: 0,
          bottomOverlay: 0,
          upwardBias: 0,
        ),
        0.5,
      );
    });

    test('顶 / 底遮挡 + 上移偏置：按可见区域中线再上移', () {
      // 可见中心 = (40 + (800-100)) / 2 = 370；锚点 = 370 - 80 = 290。
      expect(
        effectiveAlignment(
          viewport: 800,
          topOverlay: 40,
          bottomOverlay: 100,
          upwardBias: 0.10,
        ),
        closeTo(290 / 800, 1e-9),
      );
    });

    test('偏置过大时夹取到 [0, 1]', () {
      expect(
        effectiveAlignment(
          viewport: 800,
          topOverlay: 40,
          bottomOverlay: 0,
          upwardBias: 2.0,
        ),
        0.0,
      );
      expect(
        effectiveAlignment(
          viewport: 800,
          topOverlay: 0,
          bottomOverlay: 0,
          upwardBias: -1.0,
        ),
        1.0,
      );
    });

    test('视口无效（≤0）回退 0.5 - 偏置', () {
      expect(
        effectiveAlignment(
          viewport: 0,
          topOverlay: 40,
          bottomOverlay: 40,
          upwardBias: 0.10,
        ),
        closeTo(0.4, 1e-9),
      );
    });
  });

  group('tailSpace（尾部留白）', () {
    test('按可见高度一半 + 底栏遮挡 + 上移偏置反推', () {
      // 可见高度 = 800-40-100 = 660 → 330 + 100 + 80 + 8 = 518。
      expect(
        tailSpace(
          viewport: 800,
          topOverlay: 40,
          bottomOverlay: 100,
          upwardBias: 0.10,
        ),
        closeTo(518, 1e-9),
      );
    });

    test('底栏隐藏（bottomOverlay=0）时只留中线 + 偏置', () {
      expect(
        tailSpace(
          viewport: 800,
          topOverlay: 40,
          bottomOverlay: 0,
          upwardBias: 0.10,
        ),
        closeTo(380 + 80 + 8, 1e-9),
      );
    });

    test('视口无效回退固定 400', () {
      expect(
        tailSpace(
          viewport: 0,
          topOverlay: 0,
          bottomOverlay: 0,
          upwardBias: 0.10,
        ),
        400.0,
      );
    });
  });

  group('偏移夹取与死区', () {
    test('夹取到可滚动范围', () {
      expect(
        clampScrollOffset(target: -50, minScrollExtent: 0, maxScrollExtent: 1000),
        0,
      );
      expect(
        clampScrollOffset(target: 1200, minScrollExtent: 0, maxScrollExtent: 1000),
        1000,
      );
      expect(
        clampScrollOffset(target: 400, minScrollExtent: 0, maxScrollExtent: 1000),
        400,
      );
    });

    test('死区：位移 ≤1px 不跳转', () {
      expect(shouldScrollTo(current: 100, target: 100), isFalse);
      expect(shouldScrollTo(current: 100, target: 101), isFalse);
      expect(shouldScrollTo(current: 100, target: 101.5), isTrue);
      expect(shouldScrollTo(current: 100, target: 99), isFalse);
    });
  });
}
