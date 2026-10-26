import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/settings/settings_subpage.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

/// 设置子页共享 chrome：标题 / 动作 / 正文与统一内边距。
void main() {
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData()),
        theme: ThemeData(),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('常规子页：标题 / 动作 / children 与统一 ListView 内边距', (tester) async {
    await pumpPage(
      tester,
      SettingsSubPage(
        title: 'Settings title',
        actions: [
          M3EIconButton(
            key: const Key('subpageAction'),
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.refresh_rounded),
            semanticLabel: 'Refresh',
            onPressed: () {},
          ),
        ],
        children: const [Text('Body child')],
      ),
    );

    expect(find.text('Settings title'), findsOneWidget);
    expect(find.byKey(const Key('subpageAction')), findsOneWidget);
    expect(find.text('Body child'), findsOneWidget);
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.all(kSettingsPadding),
    );
  });

  testWidgets('自定义正文：body 原样渲染，不再自动套 ListView', (tester) async {
    await pumpPage(
      tester,
      const SettingsSubPage.body(
        title: 'Custom title',
        body: Center(child: Text('Custom body')),
      ),
    );

    expect(find.text('Custom title'), findsOneWidget);
    expect(find.text('Custom body'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('safeArea：标准正文外层补系统 inset（缓存管理页）', (tester) async {
    await pumpPage(
      tester,
      const SettingsSubPage(
        title: 'Cache',
        safeArea: true,
        children: [Text('Cache body')],
      ),
    );

    expect(
      find.ancestor(of: find.byType(ListView), matching: find.byType(SafeArea)),
      findsOneWidget,
    );
  });
}
