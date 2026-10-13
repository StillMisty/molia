import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/icon_swap.dart';

/// 图标切换组件契约：换值交叉淡入、同值重建不重播、减弱动效时硬切。
void main() {
  /// 挂载一个可外部改值的宿主，返回改值入口。
  Future<Future<void> Function(bool)> pumpHost(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    late StateSetter setHostState;
    bool on = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: disableAnimations),
            child: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setHostState = setState;
                    return IconSwap<bool>(
                      value: on,
                      builder: (context, value) => Icon(
                        value ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return (bool next) async {
      on = next;
      setHostState(() {});
    };
  }

  testWidgets('换值：过渡期新旧图标并存，落定后只剩新图标', (tester) async {
    final setValue = await pumpHost(tester);
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await setValue(true);
    await tester.pump();

    // 交叉淡入期间两份都在树上（旧的一份逐渐淡出）。
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('同值重建：父级每帧重建不重播动画', (tester) async {
    final setValue = await pumpHost(tester);
    await tester.pump();
    await setValue(true);
    await tester.pumpAndSettle();

    // 逐帧空重建：不允许出现第二份（重播）图标。
    for (var i = 0; i < 3; i++) {
      await setValue(true);
      await tester.pump();
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    }
  });

  testWidgets('减弱动效：一帧内直接切换，无过渡副本', (tester) async {
    final setValue = await pumpHost(tester, disableAnimations: true);
    await tester.pump();

    await setValue(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });
}
