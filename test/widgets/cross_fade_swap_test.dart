import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/cross_fade_swap.dart';

/// 内容身份交叉淡化的硬约束：
/// - 过渡期间旧内容仍在场（不是「淡出空白再淡入」），落下后必须被丢掉；
/// - 同进度交叉的两层不透明度严格互补（合计恒为 1），不会叠出双倍亮度；
/// - fade-through（窄槽文本）任何一帧都不允许两层同时清晰可读；
/// - 系统减弱动效时直接交换，不留过渡层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(
    Object value, {
    bool reduceMotion = false,
    CrossFadeMode mode = CrossFadeMode.crossFade,
  }) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: CrossFadeSwap(
            value: value,
            mode: mode,
            child: Text('内容 $value'),
          ),
        ),
      ),
    );
  }

  /// 当前在场各层的 `Opacity`，按树序：离场层在前、入场层在后。
  List<double> layerOpacities(WidgetTester tester) => tester
      .widgetList<Opacity>(find.byType(Opacity))
      .map((widget) => widget.opacity)
      .toList();

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

  testWidgets('同进度交叉：两层不透明度互补，不叠出双倍亮度', (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b'));

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      final layers = layerOpacities(tester);
      if (layers.length < 2) break;
      expect(layers[0] + layers[1], closeTo(1, 0.001));
    }
    await tester.pumpAndSettle();
  });

  testWidgets('fade-through：旧层先淡出、新层后淡入，任何一帧都不叠字', (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b', mode: CrossFadeMode.fadeThrough));

    // 入场层在 35% 进度前不参与绘制，旧层仍完整在场（不掉字）。
    await tester.pump(const Duration(milliseconds: 16));
    var layers = layerOpacities(tester);
    expect(layers, hasLength(2));
    expect(layers[1], 0);
    expect(layers[0], greaterThan(0.9));

    // 逐帧采样剩余过渡：不允许两层同时高于 20%——那正是看得见的叠影。
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      layers = layerOpacities(tester);
      if (layers.length < 2) break;
      expect(
        layers[0] > 0.2 && layers[1] > 0.2,
        isFalse,
        reason: '第 $frame 帧两层同时可见：$layers',
      );
    }

    await tester.pumpAndSettle();
    expect(find.text('内容 a'), findsNothing);
    expect(find.text('内容 b'), findsOneWidget);
  });

  testWidgets('减弱动效直接交换，不留过渡层', (tester) async {
    await tester.pumpWidget(host('a', reduceMotion: true));
    await tester.pumpWidget(host('b', reduceMotion: true));
    await tester.pump();

    expect(find.text('内容 a'), findsNothing);
    expect(find.text('内容 b'), findsOneWidget);
  });
}
