import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/font_picker_sheet.dart';

/// 字体选择弹层：设备字体列表（测试注入 loader）、内置「系统默认」与
/// 可选「继承」项，点击后返回对应 [FontChoice]。
void main() {
  testWidgets('选择设备字体返回 FontChoice.family', (tester) async {
    FontChoice? result;
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final themedData = ThemeData(colorScheme: scheme, useMaterial3: true);

    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(themedData),
        theme: themedData,
        darkTheme: themedData,
        autoTheming: false,
        dynamicColoring: false,
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Center(
            child: M3EButton.filled(
              onPressed: () async {
                result = await showFontPickerSheet(
                  context,
                  title: 'Font',
                  includeInherit: true,
                  inheritLabel: 'Follow app font',
                  loadFamilies: () async => ['Alpha Sans', 'Beta Serif'],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Follow app font'), findsOneWidget);
    expect(find.text('System default'), findsOneWidget);
    expect(find.text('Alpha Sans'), findsOneWidget);
    expect(find.text('Beta Serif'), findsOneWidget);

    await tester.tap(find.text('Beta Serif'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.inherit, isFalse);
    expect(result!.family, 'Beta Serif');
  });

  testWidgets('选择「系统默认」返回 FontChoice.system', (tester) async {
    FontChoice? result;
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final themedData = ThemeData(colorScheme: scheme, useMaterial3: true);

    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(themedData),
        theme: themedData,
        darkTheme: themedData,
        autoTheming: false,
        dynamicColoring: false,
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Center(
            child: M3EButton.filled(
              onPressed: () async {
                result = await showFontPickerSheet(
                  context,
                  title: 'Font',
                  selected: const FontChoice.family('Alpha Sans'),
                  loadFamilies: () async => ['Alpha Sans'],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.inherit, isFalse);
    expect(result!.family, isNull);
  });
}
