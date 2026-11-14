import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';

import '../support/perf_app_harness.dart';

/// 收藏页多选：范围选择是「长按起点 → 范围选择 → 点终点」的两段式手势，
/// 入口在列表右下角，不新增工具栏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  Finder countPill(String value) => find.descendant(
    of: find.byKey(const Key('collectionSelectionCount')),
    matching: find.text(value),
  );

  Future<void> pumpFavorites(WidgetTester tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 5,
      size: const Size(500, 900),
    );
  }

  testWidgets('范围选择：长按起点后点终点选中闭区间，并退出范围模式', (tester) async {
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countPill('1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('collectionSelectionRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeHint), findsOneWidget);
    expect(find.text(l10n.selectionRangeCancel), findsOneWidget);

    await tester.tap(find.text('Performance Track 3'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(countPill('3'), findsOneWidget, reason: '起点到终点含两端共 3 行');
    expect(
      find.text(l10n.selectionRangeAction),
      findsOneWidget,
      reason: '选完区间立即回到普通多选',
    );
  });

  testWidgets('再次点击范围选择取消模式：下一次点行恢复普通切换', (tester) async {
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('collectionSelectionRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeCancel), findsOneWidget);

    await tester.tap(find.byKey(const Key('collectionSelectionRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeAction), findsOneWidget);

    await tester.tap(find.text('Performance Track 3'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countPill('2'), findsOneWidget, reason: '普通切换：起点 + 终点两行');
  });
}
