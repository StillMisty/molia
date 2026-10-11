import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/statistics/listening_heatmap.dart';

/// 热力图组件测试：日历格渲染/点按回调、选中态、作息矩阵与图例。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: Center(child: SizedBox(width: 420, child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('日历热力图渲染范围内格子并回传点按日期', (tester) async {
    final firstDay = DateTime(2026, 3, 2); // 周一
    final lastDay = DateTime(2026, 3, 8);
    final values = {DateTime(2026, 3, 3): 60000, DateTime(2026, 3, 6): 30000};
    DateTime? tapped;

    await pump(
      tester,
      CalendarHeatmap(
        values: values,
        firstDay: firstDay,
        lastDay: lastDay,
        selectedDay: DateTime(2026, 3, 3),
        tooltipFor: (day, value) => 'cell-$day-$value',
        onDayTap: (day) => tapped = day,
      ),
    );

    // 范围内每一天都有格子键；范围外不渲染。
    for (var i = 0; i < 7; i++) {
      final day = firstDay.add(Duration(days: i));
      expect(
        find.byKey(ValueKey<int>(day.millisecondsSinceEpoch)),
        findsOneWidget,
        reason: '格子 $day 应在范围内',
      );
    }

    await tester.tap(find.byKey(ValueKey<int>(lastDay.millisecondsSinceEpoch)));
    expect(tapped, lastDay);
  });

  testWidgets('日历热力图：全部日期均无数据也安全渲染（空态）', (tester) async {
    await pump(
      tester,
      CalendarHeatmap(
        values: const {},
        firstDay: DateTime(2026, 3, 2),
        lastDay: DateTime(2026, 3, 8),
        tooltipFor: (day, value) => '',
        onDayTap: null,
      ),
    );

    expect(find.byType(CalendarHeatmap), findsOneWidget);
  });

  testWidgets('数据前的补位日渲染为空方格且不可点', (tester) async {
    final day = DateTime(2026, 3, 5);
    DateTime? tapped;

    await pump(
      tester,
      CalendarHeatmap(
        values: {day: 60000},
        firstDay: day,
        lastDay: day,
        tooltipFor: (day, value) => 'cell-$day-$value',
        onDayTap: (value) => tapped = value,
      ),
    );

    // 最少填满卡片宽度 → 数据前补位日有键（GitHub 式底格）。
    final padded = day.subtract(const Duration(days: 42));
    expect(
      find.byKey(ValueKey<int>(padded.millisecondsSinceEpoch)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ValueKey<int>(padded.millisecondsSinceEpoch)));
    expect(tapped, isNull, reason: '首播之前的补位日不可点');
  });

  testWidgets('作息热力图按 7×24 渲染；图例 5 档', (tester) async {
    final values = [
      for (var weekday = 0; weekday < 7; weekday++)
        [for (var hour = 0; hour < 24; hour++) weekday * hour],
    ];
    await pump(
      tester,
      Column(
        children: [
          const HeatmapLegend(),
          const SizedBox(height: 12),
          WeekdayHourHeatmap(
            values: values,
            tooltipFor: (weekday, hour, value) => 'w$weekday-h$hour-$value',
          ),
        ],
      ),
    );

    expect(find.byType(WeekdayHourHeatmap), findsOneWidget);
    expect(find.byType(HeatmapLegend), findsOneWidget);
    // 星期标签隔行（一/三/五/日）：en narrowWeekdays = S M T W T F S，
    // 行 0/2/4/6 → M / W / F / S；T 不出现。
    expect(find.text('M'), findsOneWidget);
    expect(find.text('T'), findsNothing);
  });
}
