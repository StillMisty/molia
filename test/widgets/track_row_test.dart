import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目行表面形状按 M3E 列表规范（Compose `ListTokens`）：
/// 静止内 4dp / 首末外侧 16dp，hover 12dp（shape medium），press / 选中
/// 16dp（shape large），且带弹簧 morph——防止回退到 `M3EListRowSurface`
/// 的「hover 瞬间跳到 16dp」（docs/pitfalls.md #20）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(
    WidgetTester tester, {
    M3ECardPosition position = M3ECardPosition.middle,
    bool selected = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackRow(
              title: 'Title',
              artist: 'Artist',
              position: position,
              selected: selected,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  M3ECard cardOf(WidgetTester tester) => tester.widget<M3ECard>(
        find.descendant(
          of: find.byType(TrackRow),
          matching: find.byType(M3ECard),
        ),
      );

  testWidgets('静止形状按位置：内行 4dp，首/末行外侧 16dp，单行 16dp', (tester) async {
    await pumpRow(tester, position: M3ECardPosition.middle);
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));

    await pumpRow(tester, position: M3ECardPosition.first);
    expect(
      cardOf(tester).borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(16),
        bottom: Radius.circular(4),
      ),
    );

    await pumpRow(tester, position: M3ECardPosition.last);
    expect(
      cardOf(tester).borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(4),
        bottom: Radius.circular(16),
      ),
    );

    await pumpRow(tester, position: M3ECardPosition.single);
    expect(cardOf(tester).borderRadius, BorderRadius.circular(16));
  });

  testWidgets('hover：弹簧 morph 到 12dp，移出回静止形状', (tester) async {
    await pumpRow(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(TrackRow)));
    await tester.pump(); // hover 生效，弹簧启动
    await tester.pump(const Duration(milliseconds: 50)); // 弹簧推进
    final double mid = cardOf(tester).borderRadius!.topLeft.x;
    expect(mid, greaterThan(4), reason: '不是瞬间跳变');
    expect(mid, lessThan(12));

    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(12));

    await gesture.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));
  });

  testWidgets('press：morph 到 16dp，松开回静止形状', (tester) async {
    await pumpRow(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TrackRow)));
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(16));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));
  });

  testWidgets('选中：16dp 圆角 + secondaryContainer 底色', (tester) async {
    await pumpRow(tester, selected: true);
    final card = cardOf(tester);
    expect(card.borderRadius, BorderRadius.circular(16));
    final M3EColorScheme scheme =
        M3ETheme.of(tester.element(find.byType(TrackRow))).colorScheme;
    expect(card.color, scheme.secondaryContainer);
  });

  testWidgets('行距取 M3E 列表卡片 token（默认 2dp）', (tester) async {
    await pumpRow(tester);
    expect(TrackRow.gapOf(tester.element(find.byType(TrackRow))), 2);
  });
}
