/// 封面外观与飞行求值（[CoverAppearance] / [CoverFlight] / [CoverCard]）的契约。
///
/// 原先「圆角/描边/阴影/裁剪/图标」在三处真身与两个飞行里各抄一份，只能靠
/// 三条 pump 测试与文档散文钉住；这里对唯一实现钉端点、中段与两条代数不变量：
/// 描边透明度 = 描边宽度、裁剪半径 = 外圆角 − 描边宽度。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('CoverAppearance 端点', () {
    test('三端命名值：圆角 / 描边 / 阴影 / 回退图标', () {
      expect(CoverAppearance.bar.radius, 8);
      expect(CoverAppearance.bar.stroke, 0);
      expect(CoverAppearance.bar.shadow, 0);
      expect(CoverAppearance.bar.iconSizeFor(40), barCoverFallbackIconSize);

      expect(CoverAppearance.mini.radius, 8);
      expect(CoverAppearance.mini.stroke, 0);
      expect(CoverAppearance.mini.shadow, 0);
      expect(CoverAppearance.mini.iconSizeFor(48), miniCoverFallbackIconSize);

      expect(CoverAppearance.page.radius, 18);
      expect(CoverAppearance.page.stroke, 1);
      expect(CoverAppearance.page.shadow, 1);
      expect(
        CoverAppearance.page.iconSizeFor(240),
        closeTo(240 * playerCoverFallbackIconRatio, 1e-9),
      );
    });

    test('裁剪半径 = 外圆角 − 描边宽度（顶栏 8、播放页 17）', () {
      expect(CoverAppearance.bar.clip, BorderRadius.circular(8));
      expect(CoverAppearance.mini.clip, BorderRadius.circular(8));
      expect(CoverAppearance.page.clip, BorderRadius.circular(17));
    });

    test('lerp：端点原样返回，中段线性', () {
      expect(
        CoverAppearance.lerp(CoverAppearance.bar, CoverAppearance.page, 0),
        CoverAppearance.bar,
      );
      expect(
        CoverAppearance.lerp(CoverAppearance.bar, CoverAppearance.page, 1),
        CoverAppearance.page,
      );
      final mid = CoverAppearance.lerp(
        CoverAppearance.bar,
        CoverAppearance.page,
        0.5,
      );
      expect(mid.radius, 13);
      expect(mid.stroke, 0.5);
      expect(mid.stroke, mid.shadow);
      // 不变量在中段同样成立：裁剪半径恰好等于外圆角减描边宽度。
      expect(mid.clip, BorderRadius.circular(13 - 0.5));
    });
  });

  group('CoverFlight', () {
    const barRect = Rect.fromLTWH(16, 8, 40, 40);
    const pageRect = Rect.fromLTWH(40, 80, 280, 280);

    test('前进（其他端 → 播放页）：端点外观与图标精确落位', () {
      const flight = CoverFlight(
        otherRect: barRect,
        pageRect: pageRect,
        toPage: true,
      );

      final atStart = flight.appearanceAt(0);
      expect(atStart.radius, 8);
      expect(atStart.stroke, 0);
      expect(atStart.shadow, 0);
      expect(flight.iconSizeAt(0), barCoverFallbackIconSize);

      final atEnd = flight.appearanceAt(1);
      expect(atEnd.radius, 18);
      expect(atEnd.stroke, 1);
      expect(atEnd.shadow, 1);
      expect(
        flight.iconSizeAt(1),
        closeTo(pageRect.width * playerCoverFallbackIconRatio, 1e-9),
      );
    });

    test('反向（播放页 → 其他端）：起飞帧 t=0 即播放页外观（不跳变）', () {
      // 回归：外观若按几何进度而不是「播放页端进度」插值，反向起飞瞬间
      // 大封面圆角会从 18 掉到 8（圆角消失），落点还与顶栏真身不匹配。
      const flight = CoverFlight(
        otherRect: barRect,
        pageRect: pageRect,
        toPage: false,
      );

      final atStart = flight.appearanceAt(0);
      expect(atStart.radius, 18);
      expect(atStart.stroke, 1);
      expect(flight.iconSizeAt(0),
          closeTo(pageRect.width * playerCoverFallbackIconRatio, 1e-9));

      final atEnd = flight.appearanceAt(1);
      expect(atEnd.radius, 8);
      expect(atEnd.stroke, 0);
      expect(flight.iconSizeAt(1), barCoverFallbackIconSize);
    });

    test('迷你端飞行：起点外观取迷你真身（图标 24），终点取播放页真身', () {
      const miniRect = Rect.fromLTWH(16, 12, 48, 48);
      const flight = CoverFlight(
        otherRect: miniRect,
        pageRect: pageRect,
        otherAppearance: CoverAppearance.mini,
        toPage: true,
      );

      expect(flight.appearanceAt(0), CoverAppearance.mini);
      expect(flight.iconSizeAt(0), miniCoverFallbackIconSize);
      expect(flight.appearanceAt(1), CoverAppearance.page);
      expect(
        flight.iconSizeAt(1),
        closeTo(pageRect.width * playerCoverFallbackIconRatio, 1e-9),
      );
    });

    test('几何插值：rectAt 按方向线性，pageProgressAt 截断', () {
      const flight = CoverFlight(
        otherRect: barRect,
        pageRect: pageRect,
        toPage: true,
      );
      expect(flight.fromRect, barRect);
      expect(flight.toRect, pageRect);
      expect(flight.rectAt(0), barRect);
      expect(flight.rectAt(1), pageRect);
      expect(flight.rectAt(0.5), Rect.lerp(barRect, pageRect, 0.5));

      const reverse = CoverFlight(
        otherRect: barRect,
        pageRect: pageRect,
        toPage: false,
      );
      expect(reverse.fromRect, pageRect);
      expect(reverse.toRect, barRect);
      expect(reverse.pageProgressAt(0), 1);
      expect(reverse.pageProgressAt(1), 0);
      expect(reverse.pageProgressAt(-1), 1);
      expect(reverse.pageProgressAt(2), 0);
    });
  });

  group('CoverCard', () {
    Future<void> pumpCard(
      WidgetTester tester,
      CoverAppearance appearance, {
      double size = 240,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: CoverCard(
              size: size,
              appearance: appearance,
              content: (context, clip, iconSize) =>
                  MoliaMark(size: iconSize),
            ),
          ),
        ),
      );
    }

    BoxDecoration decorationOf(WidgetTester tester) {
      final container = tester.widget<Container>(
        find.byWidgetPredicate((widget) =>
            widget is Container && widget.decoration is BoxDecoration),
      );
      return container.decoration! as BoxDecoration;
    }

    BorderRadius clipOf(WidgetTester tester) {
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      return clip.borderRadius as BorderRadius;
    }

    testWidgets('播放页端：r18 + 1px 描边 + 0.28 阴影、裁剪 17、图标 0.35×边长',
        (tester) async {
      await pumpCard(tester, CoverAppearance.page);
      final decoration = decorationOf(tester);
      expect(decoration.borderRadius, BorderRadius.circular(18));
      expect(decoration.border!.top.width, 1);
      expect(decoration.border!.top.color.a, closeTo(1, 1e-6));
      expect(decoration.boxShadow!.first.color.a, closeTo(0.28, 1e-6));
      expect(clipOf(tester), BorderRadius.circular(17));
      expect(
        tester.widget<MoliaMark>(find.byType(MoliaMark)).size,
        closeTo(240 * playerCoverFallbackIconRatio, 1e-9),
      );
    });

    testWidgets('顶栏端：r8、零描边零阴影、图标走固定尺寸', (tester) async {
      await pumpCard(tester, CoverAppearance.bar, size: 40);
      final decoration = decorationOf(tester);
      expect(decoration.borderRadius, BorderRadius.circular(8));
      expect(decoration.border!.top.width, 0);
      expect(decoration.border!.top.color.a, 0);
      expect(decoration.boxShadow!.first.color.a, 0);
      expect(clipOf(tester), BorderRadius.circular(8));
      expect(
        tester.widget<MoliaMark>(find.byType(MoliaMark)).size,
        barCoverFallbackIconSize,
      );
    });

    testWidgets('图标尺寸覆盖：飞行副本按两端真身插值，不跟随所在边长', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: CoverCard(
              size: 240,
              appearance: CoverAppearance.page,
              iconSize: 33,
              content: (context, clip, iconSize) => MoliaMark(size: iconSize),
            ),
          ),
        ),
      );
      expect(tester.widget<MoliaMark>(find.byType(MoliaMark)).size, 33);
    });
  });
}
