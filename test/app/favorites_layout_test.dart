import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';

import '../support/perf_app_harness.dart';

/// 收藏页收敛：标题只留随机 / 搜索 / ⋮，不再有模式切换行、表格列或合集左栏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  Future<void> pumpFavorites(
    WidgetTester tester, {
    Size size = const Size(500, 900),
  }) => pumpPerfApp(tester, desktopShell: false, favoritesCount: 5, size: size);

  testWidgets('标题常态只有随机 / 搜索 / 更多，排序与封面收在 ⋮', (tester) async {
    await pumpFavorites(tester);

    expect(find.byKey(const Key('favoritesShuffleButton')), findsOneWidget);
    expect(find.byKey(const Key('favoritesSearchButton')), findsOneWidget);
    expect(find.byKey(const Key('favoritesHeaderOverflow')), findsOneWidget);
    expect(find.byKey(const Key('libraryBrowseModeSwitch')), findsNothing);
    expect(find.byIcon(Icons.ios_share_rounded), findsNothing);
    expect(find.text(l10n.collectionModeAlbums), findsNothing);

    await tester.tap(find.byKey(const Key('favoritesHeaderOverflow')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.sortDefaultOrder), findsOneWidget);
    expect(find.text(l10n.sortByTitle), findsOneWidget);
    expect(find.text(l10n.sortByArtist), findsOneWidget);
    expect(find.text(l10n.playlistCoverChange), findsOneWidget);
  });

  testWidgets('合集弹层：曲库固定入口 + 智能列表默认收起', (tester) async {
    await pumpFavorites(tester);

    await tester.tap(find.byKey(const Key('favoritesTitleSwitcher')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryBrowseTitle), findsOneWidget);
    expect(find.text(l10n.smartListsSection), findsOneWidget);
    expect(find.text(l10n.smartMissingFiles), findsNothing);
    // 固定入口不参与拖动排序；当前没有自建列表，因此没有拖动把手。
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
  });

  testWidgets('840 宽也只用标题弹层，不再出合集左栏或表格头', (tester) async {
    await pumpFavorites(tester, size: const Size(840, 900));

    expect(find.byKey(const Key('collectionSplitView')), findsNothing);
    expect(find.byKey(const Key('favoritesHeaderOverflow')), findsOneWidget);
    expect(find.byKey(const Key('favoritesModeSwitch')), findsNothing);
  });
}
