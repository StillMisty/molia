import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/statistics/listening_heatmap.dart';

/// 热力图格子是自绘的（`CustomPaint` + 缓存 morph 路径），交互仍必须和
/// 之前一致：悬停 400ms 出 tooltip、点按回调、选中态可渲染。
void main() {
  Future<void> pumpHeatmap(
    WidgetTester tester,
    Widget heatmap, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = ThemeData.light().copyWith(platform: platform);
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(theme),
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: Center(child: SizedBox(width: 720, child: heatmap)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 把鼠标移到 [target] 中心并停留 [dwell]，等 Tooltip 的 400ms 等待。
  Future<TestGesture> hover(
    WidgetTester tester,
    Finder target, {
    Duration dwell = const Duration(milliseconds: 500),
  }) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await tester.pump(dwell);
    await tester.pump(const Duration(milliseconds: 200));
    return gesture;
  }

  testWidgets('日历热力图：悬停出 tooltip、点按回传日期', (tester) async {
    final today = DateUtils.dateOnly(DateTime(2026, 11, 20));
    DateTime? tapped;
    await pumpHeatmap(
      tester,
      CalendarHeatmap(
        values: {
          for (var i = 0; i < 14; i++)
            today.subtract(Duration(days: i)): i * 1000,
        },
        firstDay: today.subtract(const Duration(days: 13)),
        lastDay: today,
        tooltipFor: (day, value) => 'day ${day.day} value $value',
        onDayTap: (day) => tapped = day,
      ),
    );

    final cells = find.byType(Tooltip);
    expect(cells, findsWidgets);

    await hover(tester, cells.last);
    // 最后一格 = 今天。
    expect(find.text('day 20 value 0'), findsOneWidget);

    await tester.tap(cells.first);
    await tester.pump();
    expect(tapped, isNotNull);
  });

  testWidgets('作息热力图：悬停出 tooltip（星期 + 时段）', (tester) async {
    await pumpHeatmap(
      tester,
      WeekdayHourHeatmap(
        values: [
          for (var weekday = 0; weekday < 7; weekday++)
            [for (var hour = 0; hour < 24; hour++) weekday * 100 + hour],
        ],
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    final cells = find.byType(Tooltip);
    expect(cells, findsNWidgets(7 * 24));

    await hover(tester, cells.first);
    expect(find.text('w0 h0 v0'), findsOneWidget);
  });

  testWidgets('桌面：tooltip 按需挂载，悬停 400ms 才出现', (tester) async {
    await pumpHeatmap(
      tester,
      platform: TargetPlatform.linux,
      WeekdayHourHeatmap(
        values: [
          for (var weekday = 0; weekday < 7; weekday++)
            [for (var hour = 0; hour < 24; hour++) weekday * 100 + hour],
        ],
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    // 静止时没有常驻 Tooltip：这是开页首帧省下的那部分开销。
    expect(find.byType(Tooltip), findsNothing);

    final cells = find.descendant(
      of: find.byType(WeekdayHourHeatmap),
      matching: find.byType(CustomPaint),
    );
    expect(cells, findsNWidgets(7 * 24));
    await hover(tester, cells.first, dwell: const Duration(milliseconds: 150));
    // 400ms 窗口内不应出现。
    expect(find.text('w0 h0 v0'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('w0 h0 v0'), findsOneWidget);
  });
}
