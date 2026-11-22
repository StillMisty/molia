import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/statistics/listening_heatmap.dart';

/// 热力图是网格级自绘（一个 `CustomPaint` + 一个指针区域 + 按需挂载的
/// `Tooltip`），交互仍必须和逐格实现一致：悬停 400ms 出 tooltip、离开
/// ~100ms 消失、点按回传日期、选中态可渲染、读屏逐格可读。
void main() {
  const weekdayGridKey = Key('weekdayHourHeatmapGrid');
  const calendarGridKey = Key('calendarHeatmapGrid');
  // 作息热力图的格子会被 clamp 到 maxCellSize = 24，间距 3。
  const weekdayPitch = 27.0;
  // 日历热力图默认 cellSize = 12、cellGap = 3。
  const calendarPitch = 15.0;

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

  /// 第 [index] 格的屏幕中心（行优先，[pitch] = cell + gap）。
  Offset cellCenter(
    WidgetTester tester,
    Key gridKey,
    int index, {
    required int columns,
    required double pitch,
  }) {
    final origin = tester.getTopLeft(find.byKey(gridKey));
    final col = index % columns;
    final row = index ~/ columns;
    return origin + Offset((col + 0.5) * pitch, (row + 0.5) * pitch);
  }

  Future<TestGesture> hoverAt(
    WidgetTester tester,
    Offset position, {
    Duration dwell = const Duration(milliseconds: 500),
  }) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(position);
    await tester.pump();
    await tester.pump(dwell);
    await tester.pump(const Duration(milliseconds: 200));
    return gesture;
  }

  List<List<int>> weekdayValues() => [
    for (var weekday = 0; weekday < 7; weekday++)
      [for (var hour = 0; hour < 24; hour++) weekday * 100 + hour],
  ];

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

    // 初始已滚到今天所在的最后一列；today = 周五 → row 4。
    final weeks =
        (tester.getSize(find.byKey(calendarGridKey)).width / calendarPitch)
            .round();
    final todayCell = cellCenter(
      tester,
      calendarGridKey,
      4 * weeks + (weeks - 1),
      columns: weeks,
      pitch: calendarPitch,
    );
    await hoverAt(tester, todayCell);
    expect(find.text('day 20 value 0'), findsOneWidget);

    await tester.tapAt(todayCell);
    await tester.pump();
    expect(tapped, today);
  });

  testWidgets('作息热力图：悬停按局部坐标命中正确格子', (tester) async {
    await pumpHeatmap(
      tester,
      WeekdayHourHeatmap(
        values: weekdayValues(),
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    // 静止时没有常驻 Tooltip：168 个常驻 OverlayPortal 是开页纯开销。
    expect(find.byType(Tooltip), findsNothing);

    // 第 3 行第 5 列（weekday 3 / hour 5），不是首格。
    await hoverAt(
      tester,
      cellCenter(
        tester,
        weekdayGridKey,
        3 * 24 + 5,
        columns: 24,
        pitch: weekdayPitch,
      ),
    );
    expect(find.text('w3 h5 v305'), findsOneWidget);
    // 同一时间只挂一个 Tooltip（网格级提示）。
    expect(find.byType(Tooltip), findsOneWidget);
  });

  testWidgets('桌面：tooltip 按需挂载，悬停 400ms 才出现', (tester) async {
    await pumpHeatmap(
      tester,
      platform: TargetPlatform.linux,
      WeekdayHourHeatmap(
        values: weekdayValues(),
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    expect(find.byType(Tooltip), findsNothing);
    // 整张图只有一个 CustomPaint 承载 168 格。
    expect(
      find.descendant(
        of: find.byType(WeekdayHourHeatmap),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );

    final target = cellCenter(
      tester,
      weekdayGridKey,
      0,
      columns: 24,
      pitch: weekdayPitch,
    );
    // 400ms 窗口内不应出现。
    await hoverAt(tester, target, dwell: const Duration(milliseconds: 150));
    expect(find.text('w0 h0 v0'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('w0 h0 v0'), findsOneWidget);
  });

  testWidgets('桌面：离开后 tooltip 保持约 100ms 再消失', (tester) async {
    await pumpHeatmap(
      tester,
      platform: TargetPlatform.linux,
      WeekdayHourHeatmap(
        values: weekdayValues(),
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    final gesture = await hoverAt(
      tester,
      cellCenter(tester, weekdayGridKey, 0, columns: 24, pitch: weekdayPitch),
    );
    expect(find.text('w0 h0 v0'), findsOneWidget);

    // 移出网格：Tooltip 默认 dismissDelay ≈100ms，不能瞬灭。
    await gesture.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('w0 h0 v0'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('w0 h0 v0'), findsNothing);
  });

  testWidgets('桌面：静止格逐格保留语义 tooltip（读屏可读数值）', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHeatmap(
      tester,
      platform: TargetPlatform.linux,
      WeekdayHourHeatmap(
        values: weekdayValues(),
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    // 每格一个纯语义节点（CustomPainter.semanticsBuilder），不是整图一个标签。
    final cells = find.semantics
        .byPredicate((node) => node.tooltip.startsWith('w'))
        .evaluate();
    expect(cells, hasLength(7 * 24));
    expect(
      find.semantics
          .byPredicate((node) => node.tooltip == 'w0 h0 v0')
          .evaluate(),
      hasLength(1),
    );
    semantics.dispose();
  });

  testWidgets('触摸端：长按出 tooltip，抬起后消失', (tester) async {
    await pumpHeatmap(
      tester,
      WeekdayHourHeatmap(
        values: weekdayValues(),
        tooltipFor: (weekday, hour, value) => 'w$weekday h$hour v$value',
      ),
    );

    final gesture = await tester.startGesture(
      cellCenter(
        tester,
        weekdayGridKey,
        2 * 24 + 7,
        columns: 24,
        pitch: weekdayPitch,
      ),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('w2 h7 v207'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('w2 h7 v207'), findsNothing);
  });
}
