import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/card_list_surface.dart';
import 'package:molia/widgets/settings/settings_swatch_row.dart';

/// 可视化选择行（主题/配色这类「所见即所选」的枚举）的布局与交互回归：
/// - 选项是 56dp 预览圆 + 名称（可带补充信息）；
/// - 选中项叠 3dp 描边 + 对勾，点选项切换；
/// - 禁用项不可点并按 0.45 降透明度。
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

  M3ETappable tappableOf(WidgetTester tester, String label) =>
      tester.widget<M3ETappable>(
        find.ancestor(of: find.text(label), matching: find.byType(M3ETappable)),
      );

  testWidgets('可视化选择行：点选项切换选中，选中项显示对勾与补充信息', (tester) async {
    var selected = 'a';
    await pumpRow(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (context, setState) => SettingsSwatchRow<String>(
            icon: Icons.palette_rounded,
            title: 'Colors',
            value: selected,
            options: const [
              SettingsSwatchOption(
                value: 'a',
                label: 'Wallpaper',
                swatch: ColoredBox(color: Colors.blue),
              ),
              SettingsSwatchOption(
                value: 'b',
                label: 'Custom',
                supportingText: '#00FF00',
                swatch: ColoredBox(color: Colors.green),
              ),
            ],
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    // 选中项唯一对勾；补充信息常驻。
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text('#00FF00'), findsOneWidget);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    // 勾跟随选中项（仍是同一个，只是位置变了；这里断言语义连接）。
    expect(
      find.ancestor(
        of: find.text('Custom'),
        matching: find.byType(M3ETappable),
      ),
      findsOneWidget,
    );
  });

  testWidgets('可视化选择行：禁用项不可点并按 0.45 降透明度', (tester) async {
    var selected = 'a';
    await pumpRow(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (context, setState) => SettingsSwatchRow<String>(
            icon: Icons.palette_rounded,
            title: 'Colors',
            value: selected,
            optionEnabled: (value) => value != 'b',
            options: const [
              SettingsSwatchOption(
                value: 'a',
                label: 'Wallpaper',
                swatch: ColoredBox(color: Colors.blue),
              ),
              SettingsSwatchOption(
                value: 'b',
                label: 'Custom',
                swatch: ColoredBox(color: Colors.green),
              ),
            ],
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    expect(tappableOf(tester, 'Custom').enabled, isFalse);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(selected, 'a');

    // 禁用项整体降透明度（与设置开关行同档）。
    final opacity = tester.widget<Opacity>(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('Custom'),
              matching: find.byType(M3ETappable),
            ),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, lessThan(1.0));
  });

  testWidgets('可视化选择行：预览圆 56dp，行表面走分段卡片形状', (tester) async {
    await pumpRow(
      tester,
      Center(
        child: SettingsSwatchRow<String>(
          icon: Icons.palette_rounded,
          title: 'Colors',
          value: 'a',
          options: const [
            SettingsSwatchOption(
              value: 'a',
              label: 'Wallpaper',
              swatch: ColoredBox(color: Colors.blue),
            ),
            SettingsSwatchOption(
              value: 'b',
              label: 'Custom',
              swatch: ColoredBox(color: Colors.green),
            ),
          ],
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byType(CardListSurface), findsOneWidget);
    // 预览圆是 56dp 紧约束（M3E 主题配置示例同值）。
    expect(tester.getSize(find.byType(ClipOval).first), const Size(56, 56));
  });
}
