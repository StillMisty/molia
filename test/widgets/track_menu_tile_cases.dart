import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/track_menu_tile.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目行本体 [TrackMenuTile] 的操作入口：触摸端行尾 ⋮ 常显可点；桌面端无 ⋮，
/// 行表面右键在落点弹出同一份菜单。
///
/// 菜单条目与领域接线由队列 / 搜索结果行的既有用例与各适配层测试覆盖，
/// 这里只钉住两条入口接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTile(
    WidgetTester tester, {
    VoidCallback? onToggleFavorite,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: Center(
            child: TrackMenuTile(
              row: const TrackRowModel(title: 'Title', artist: 'Artist'),
              position: M3ECardPosition.single,
              onTap: () {},
              favorite: false,
              onToggleFavorite: onToggleFavorite ?? () {},
              onAddToPlaylist: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '桌面：行内无 ⋮，右键在落点弹出菜单，动作走注入回调',
    (tester) async {
      var toggled = 0;
      await pumpTile(tester, onToggleFavorite: () => toggled++);

      expect(
        find.byIcon(Icons.more_vert_rounded),
        findsNothing,
        reason: '桌面入口是行表面右键，不再有行尾 ⋮',
      );

      // 右键行内某点 → 菜单出现（选中即关）。
      await tester.tapAt(
        tester.getRect(find.byType(TrackRow)).center,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('加入列表'), findsOneWidget);

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(toggled, 1);
      expect(find.text('加入列表'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    '桌面：菜单贴锚点左缘——左缘随右键落点平移，并从落点下方展开',
    (tester) async {
      await pumpTile(tester);

      final Rect rowRect = tester.getRect(find.byType(TrackRow));
      final double clickY = rowRect.center.dy;

      // 一次落点：右键 → 量菜单条目左上角 → 点空白关菜单，供下一个落点复用。
      Future<Offset> menuTopLeftAt(double x) async {
        await tester.tapAt(
          Offset(x, clickY),
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final Offset topLeft = tester.getTopLeft(find.text('收藏'));
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        return topLeft;
      }

      final Offset near = await menuTopLeftAt(rowRect.left + 40);
      final Offset far = await menuTopLeftAt(rowRect.left + 120);

      expect(
        far.dx - near.dx,
        moreOrLessEquals(80, epsilon: 2),
        reason: '菜单左缘=锚点左右跟随落点',
      );
      expect(
        near.dy,
        inInclusiveRange(clickY, clickY + 40),
        reason: '菜单在落点下方展开（菜单内边距容忍）',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('触摸端：⋮ 恒显可点，右键不接线', (tester) async {
    await pumpTile(tester);

    // 入口恒定可见可点（点击命中即证明未被隐藏）。
    expect(find.byIcon(Icons.more_vert_rounded).hitTestable(), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TrackRow), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('收藏'), findsNothing, reason: '触摸端无右键菜单');
  });
}
