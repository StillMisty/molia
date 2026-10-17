import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/track_menu_tile.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目行本体 [TrackMenuTile] 的桌面增强与触摸端行为：⋮ 随整行 hover / 焦点
/// 显现、行表面右键打开同一份菜单；触摸端入口恒显、无右键。
///
/// 菜单条目与领域接线由队列 / 搜索结果行的既有用例与各适配层测试覆盖，
/// 这里只钉住显隐与右键这两条交互。
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
              title: 'Title',
              artist: 'Artist',
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

  /// HoverReveal 自身的透明度包装（子组件内部的同类包装在遍历序里更靠后）。
  Finder revealOpacity() => find
      .descendant(
        of: find.byType(HoverReveal),
        matching: find.byType(AnimatedOpacity),
      )
      .first;

  testWidgets(
    '桌面：⋮ hover 前不可见，hover 后可见；右键打开同一份菜单',
    (tester) async {
      var toggled = 0;
      await pumpTile(tester, onToggleFavorite: () => toggled++);

      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 0);

      // 悬停整行即可显现：不要求指针先精确落在按钮上。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(TrackRow)));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 1);

      // 右键行表面 → 与 ⋮ 锚点同一份菜单（收藏 / 加入列表）。
      await tester.tap(find.byType(TrackRow), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('加入列表'), findsOneWidget);

      // 菜单动作仍走注入回调，选中即关菜单。
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(toggled, 1);
      expect(find.text('加入列表'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('触摸端：⋮ 恒显可点，右键不接线', (tester) async {
    await pumpTile(tester);

    // 非桌面 HoverReveal 原样返回：入口恒定可见可点（点击命中即证明未被隐藏）。
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
