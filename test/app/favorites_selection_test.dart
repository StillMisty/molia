import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/collection_track_list.dart';

import '../support/perf_app_harness.dart';

/// 收藏页多选：范围选择走长按（桌面等价 Shift 点击），多选栏只保留
/// 计数 / 全选 / 两个高频动作 / ⋮，不再有浮动的范围模式入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  Finder countText(int count) => find.text(l10n.selectionCountSelected(count));

  Future<void> pumpFavorites(WidgetTester tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 5,
      size: const Size(500, 900),
    );
  }

  testWidgets('长按起点后再长按终点选中闭区间', (tester) async {
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countText(1), findsOneWidget);

    await tester.longPress(find.text('Performance Track 3'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(countText(3), findsOneWidget, reason: '起点到终点含两端共 3 行');
    expect(
      find.byKey(const Key('collectionSelectionRangeAction')),
      findsNothing,
      reason: '浮动范围模式入口已删除',
    );
  });

  testWidgets('多选栏组成：✕ / 已选 N / 全选 / 两个高频动作 / ⋮', (tester) async {
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('collectionSelectionClose')), findsOneWidget);
    expect(countText(1), findsOneWidget);
    expect(
      find.byKey(const Key('collectionSelectionSelectAll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('collectionSelectionFavorite')),
      findsOneWidget,
      reason: '收藏合集：收藏开关是高频动作',
    );
    expect(
      find.byKey(const Key('collectionSelectionAddToPlaylist')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
  });

  testWidgets('多选行给读屏暴露「选中到这里」动作', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));

    final data = tester
        .getSemantics(find.byType(CollectionTrackRow).first)
        .getSemanticsData();
    final labels = (data.customSemanticsActionIds ?? const <int>[])
        .map(CustomSemanticsAction.getAction)
        .whereType<CustomSemanticsAction>()
        .map((action) => action.label);
    expect(labels, contains(l10n.selectionRangeToHere));
    semantics.dispose();
  });

  testWidgets('全选只选中，不清空；✕ 才退出多选', (tester) async {
    await pumpFavorites(tester);

    await tester.longPress(find.text('Performance Track 1'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('collectionSelectionSelectAll')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countText(5), findsOneWidget);

    // 再次点击全选不会清空 / 退出（已全选时按钮禁用）。
    await tester.tap(find.byKey(const Key('collectionSelectionSelectAll')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countText(5), findsOneWidget);

    await tester.tap(find.byKey(const Key('collectionSelectionClose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collectionSelectionClose')), findsNothing);
  });
}
