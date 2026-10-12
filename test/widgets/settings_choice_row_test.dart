import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/settings/settings_tiles.dart';

/// 设置行共享组件的布局回归：
/// - 分段行必须显式给紧约束宽度（`M3ESegmentedButton` 内部是
///   `Stack + Positioned.fill + Row(mainAxisSize.min)`，放松约束会零宽溢出）；
/// - 下拉行未选中时显示标题提示，不落包内英文兜底 `Select`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(WidgetTester tester, Widget parent) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData()),
        theme: ThemeData(),
        home: Scaffold(body: parent),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('分段行：放松约束父级下仍等宽铺满、可选中', (tester) async {
    var selected = 'a';
    // Center 只给 loose 约束：分段行也必须显式铺满，不能塌成零宽。
    await pumpRow(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (context, setState) => SettingsChoiceRow<String>(
            icon: Icons.tune_rounded,
            title: 'Range',
            value: selected,
            options: const [('a', 'One'), ('b', 'Two'), ('c', 'Three')],
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    final segmented = find.byType(M3ESegmentedButton<String>);
    final size = tester.getSize(segmented);
    expect(size.width, greaterThan(0), reason: '分段按钮塌成零宽');
    // 铺满行内容宽（屏幕 800 − 行左右 padding 24）。
    expect(size.width, 800 - 24);
    expect(size.height, greaterThan(0));

    await tester
        .tap(find.descendant(of: segmented, matching: find.text('Two')));
    await tester.pumpAndSettle();
    expect(selected, 'b');
  });

  testWidgets('下拉行：未选中显示标题提示，不落英文兜底 Select', (tester) async {
    await pumpRow(
      tester,
      Center(
        child: SettingsDropdownRow<String>(
          icon: Icons.high_quality_rounded,
          title: 'Quality',
          value: 'unknown',
          options: const [('320k', '320K'), ('128k', '128K')],
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Select'), findsNothing);
    // 行标题 + 字段提示（hintText = title）两处。
    expect(find.text('Quality'), findsNWidgets(2));
  });
}
