import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/pages/sources_page.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/source_manager.dart';

/// 回归：默认音质 chip 换行时必须有行距。
///
/// `Wrap` 的 `runSpacing` 缺省为 0，两行 chip 竖直贴边会被看成「叠在一起」。
/// 本测试在会触发换行的窗口宽度下量取每个 chip 的实际矩形，断言水平区间
/// 相交（同列换行）的 chip 之间垂直间距 ≥ 8。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('默认音质 chip 换行后行距 8px，不相互贴边', (tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late final SourceManager manager;
    await tester.runAsync(() async {
      manager = SourceManager();
      await manager.init();
      for (final existing in manager.scripts.toList()) {
        await manager.removeScript(existing.id);
      }
    });
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceManager>.value(value: manager),
          ChangeNotifierProvider<SourcesProvider>(
            create: (_) => SourcesProvider(manager),
          ),
        ],
        child: const MaterialApp(home: SourcesPage()),
      ),
    );
    await tester.pumpAndSettle();

    final rects = <Rect>[
      for (final element in find.byType(M3EChip).evaluate())
        tester.getRect(find.byWidget(element.widget)),
    ];
    expect(rects.length, greaterThan(1));

    var wrapped = false;
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final a = rects[i];
        final b = rects[j];
        final xOverlap = a.left < b.right && b.left < a.right;
        if (!xOverlap) continue;
        final gap = a.bottom <= b.top
            ? b.top - a.bottom
            : (b.bottom <= a.top ? a.top - b.bottom : 0.0);
        if (gap > 0) wrapped = true;
        expect(gap, greaterThanOrEqualTo(8.0),
            reason: '同列 chip 换行后行距缺失：$a 与 $b');
      }
    }
    expect(wrapped, isTrue, reason: '该窗口宽度应触发音质 chip 换行，否则本测试无效');
  });
}
