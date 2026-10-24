import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/card_list_surface.dart';
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

  testWidgets('字体行是 M3E 分段卡片：预览字体 / 位置 / 键盘 Enter 可选中', (tester) async {
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

    // 三段（系统默认 + 两款设备字体）：首/中/末位置来自实际选项数，
    // 搜索过滤后仍按剩余项重算。
    final surfaces = tester
        .widgetList<CardListSurface>(find.byType(CardListSurface))
        .toList();
    expect(surfaces, hasLength(3));
    expect(
      [for (final surface in surfaces) surface.position],
      [
        M3ECardPosition.first,
        M3ECardPosition.middle,
        M3ECardPosition.last,
      ],
    );

    // 字体名用自身字体预览；字阶来自 M3E typeScale，选中态 primary + w500。
    final preview = tester.widget<Text>(find.text('Alpha Sans'));
    final m3e = M3EThemeData.fromMaterial(themedData);
    expect(preview.style?.fontFamily, 'Alpha Sans');
    expect(preview.style?.fontSize, m3e.typeScale.bodyLarge.fontSize);
    expect(preview.style?.fontWeight, FontWeight.w500);
    expect(preview.style?.color, m3e.colorScheme.primary);

    // CardListSurface / M3ECard 自带键盘语义：聚焦后 Enter 直接选中
    // （裸 InkWell 没有这条路径）。
    final cardFinder = find
        .ancestor(
          of: find.text('Alpha Sans'),
          matching: find.byType(M3ECard),
        )
        .first;
    final detector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: cardFinder,
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    detector.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.family, 'Alpha Sans');
  });
}
