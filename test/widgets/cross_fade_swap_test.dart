import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/cross_fade_swap.dart';

/// 内容身份交叉淡化的两条硬约束：
/// - 过渡期间旧内容仍在场（不是「淡出空白再淡入」），落下后必须被丢掉；
/// - 系统减弱动效时直接交换，不留过渡层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Object value, {bool reduceMotion = false}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: CrossFadeSwap(value: value, child: Text('内容 $value')),
        ),
      ),
    );
  }

  testWidgets('换值时旧内容在场交叉淡化，落定后只剩新内容', (tester) async {
    await tester.pumpWidget(host('a'));
    expect(find.text('内容 a'), findsOneWidget);

    await tester.pumpWidget(host('b'));
    await tester.pump();
    // 过渡中：两层同时在场（顶栏固定高度槽不能出现「掉字」的空白帧）。
    expect(find.text('内容 a'), findsOneWidget);
    expect(find.text('内容 b'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('内容 a'), findsNothing);
    expect(find.text('内容 b'), findsOneWidget);
  });

  testWidgets('同值重建只更新内容，不重播过渡', (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('a'));
    await tester.pump();

    // 没有第二层：同值不产生离场副本。
    expect(find.text('内容 a'), findsOneWidget);
  });

  testWidgets('减弱动效直接交换，不留过渡层', (tester) async {
    await tester.pumpWidget(host('a', reduceMotion: true));
    await tester.pumpWidget(host('b', reduceMotion: true));
    await tester.pump();

    expect(find.text('内容 a'), findsNothing);
    expect(find.text('内容 b'), findsOneWidget);
  });
}
