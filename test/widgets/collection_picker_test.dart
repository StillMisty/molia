import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/widgets/collection_picker.dart';
import 'package:material_3_expressive/components/bottom_sheets/components/m3e_bottom_sheet_surface.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 合集切换弹层（收藏页 / 其它合集入口共用）：
/// 顺序回传、新建/重命名/删除的成功与失败语义。
///
/// 弹层只做本地乐观更新：成功才改副本，失败保留旧行并提示；
/// 新建成功后直接返回新列表 id（调用方据此切换合集）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const favoritesKey = 'favorites';
  const historyKey = 'history';
  const loveKey = 'playlist:7';

  late CollectionPickerOutcome? outcome;
  late List<List<String>> orderChanges;
  late List<String> createdNames;
  late List<({int id, String name})> renames;
  late List<int> deletedIds;

  List<CollectionPickerEntry> entries() => [
        const CollectionPickerEntry(
          key: favoritesKey,
          id: -1,
          name: '我的收藏',
          icon: Icons.favorite_rounded,
          trackCount: 3,
          selected: true,
        ),
        const CollectionPickerEntry(
          key: historyKey,
          id: -3,
          name: '播放历史',
          icon: Icons.history_rounded,
          trackCount: 0,
          selected: false,
        ),
        const CollectionPickerEntry(
          key: loveKey,
          id: 7,
          name: 'love',
          icon: Icons.queue_music_rounded,
          trackCount: 3,
          selected: false,
          playlistId: 7,
        ),
      ];

  /// 弹层内的合集行（限定在弹层 surface 内，避免与页面其它列表混淆）。
  Finder pickerRow(String name) => find.descendant(
        of: find.byType(M3EBottomSheetSurface),
        matching: find.byWidgetPredicate(
          (widget) => widget is M3EListItem && widget.headline == name,
        ),
      );

  List<String> pickerHeadlines(WidgetTester tester) => tester
      .widgetList<M3EListItem>(
        find.descendant(
          of: find.byType(M3EBottomSheetSurface),
          matching: find.byType(M3EListItem),
        ),
      )
      .map((item) => item.headline)
      .toList();

  Future<void> pumpHost(
    WidgetTester tester, {
    bool failCreate = false,
    bool failRename = false,
    bool failDelete = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    outcome = null;
    orderChanges = [];
    createdNames = [];
    renames = [];
    deletedIds = [];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: M3EButton.filled(
                onPressed: () async {
                  outcome = await showCollectionPicker(
                    context,
                    title: '切换合集',
                    entries: entries(),
                    onOrderChanged: orderChanges.add,
                    onCreate: (name) async {
                      createdNames.add(name);
                      if (failCreate) throw StateError('create failed');
                      return 42;
                    },
                    onDelete: (playlistId) async {
                      deletedIds.add(playlistId);
                      if (failDelete) {
                        return LibraryMutationOutcome.failed(
                          StateError('delete failed'),
                        );
                      }
                      return const LibraryMutationOutcome.applied();
                    },
                    onRename: (playlistId, name) async {
                      renames.add((id: playlistId, name: name));
                      if (failRename) {
                        return LibraryMutationOutcome.failed(
                          StateError('rename failed'),
                        );
                      }
                      return const LibraryMutationOutcome.applied();
                    },
                  );
                },
                child: const Text('打开合集弹层'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开合集弹层'));
    await tester.pumpAndSettle();
  }

  testWidgets('拖动把手把新顺序回传给调用方', (tester) async {
    await pumpHost(tester);
    expect(pickerHeadlines(tester), ['我的收藏', '播放历史', 'love']);

    // 把 love 的把手向上拖到「播放历史」之前。必须小步移动：
    // 单步位移过大时 ReorderableListView 的目标索引计算会跳过（实测）。
    final handle = find.byIcon(Icons.drag_handle_rounded).last;
    final start = tester.getCenter(handle);
    final rowDelta = tester.getCenter(pickerRow('播放历史')).dy -
        tester.getCenter(pickerRow('love')).dy;
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(Offset(0, rowDelta / 4));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(pickerHeadlines(tester), ['我的收藏', 'love', '播放历史']);
    expect(orderChanges.last, [favoritesKey, loveKey, historyKey]);
  });

  testWidgets('重命名成功：只改弹层本地副本，不关闭弹层', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名列表'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '跑步');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(renames.single, (id: 7, name: '跑步'));
    expect(pickerRow('跑步'), findsOneWidget);
    expect(pickerRow('love'), findsNothing);
    expect(outcome, isNull, reason: '重命名不关闭弹层');
    expect(find.byType(M3EBottomSheetSurface), findsOneWidget);
  });

  testWidgets('删除成功：只移除弹层本地副本，不关闭弹层', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedIds.single, 7);
    expect(pickerHeadlines(tester), ['我的收藏', '播放历史']);
    expect(outcome, isNull, reason: '删除不关闭弹层');
  });

  testWidgets('新建成功：返回新列表 id，弹层关闭', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.byKey(const Key('favoritesCreatePlaylist')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '路上听');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(createdNames.single, '路上听');
    expect(outcome?.selectedId, 42);
    expect(outcome?.importRequested, isFalse);
    expect(find.byType(M3EBottomSheetSurface), findsNothing);
  });

  testWidgets('重命名失败：保留旧名、弹层不关并提示', (tester) async {
    await pumpHost(tester, failRename: true);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名列表'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '跑步');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(pickerRow('跑步'), findsNothing, reason: '失败不改本地副本');
    expect(pickerRow('love'), findsOneWidget, reason: '旧名仍在');
    expect(find.byType(M3EBottomSheetSurface), findsOneWidget);
  });

  testWidgets('删除失败：保留行、弹层不关并提示', (tester) async {
    await pumpHost(tester, failDelete: true);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(pickerRow('love'), findsOneWidget, reason: '失败不做乐观删除');
    expect(outcome, isNull);
  });

  testWidgets('新建失败：留在弹层、不返回 id 并提示', (tester) async {
    await pumpHost(tester, failCreate: true);

    await tester.tap(find.byKey(const Key('favoritesCreatePlaylist')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '路上听');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(pickerRow('路上听'), findsNothing);
    expect(pickerRow('我的收藏'), findsOneWidget, reason: '仍停在合集弹层');
    expect(outcome, isNull);
  });
}
