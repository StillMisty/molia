import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/row_actions.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 行操作模块（动作词汇 + 两平台入口编译）的契约：条目映射只有一份，
/// 触摸端 ⋮ 与桌面右键消费的是同一组动作。
void main() {
  List<RowAction> sample({
    void Function()? onAdd,
    void Function()? onRemove,
  }) =>
      [
        RowAction(
          icon: Icons.playlist_add_rounded,
          label: '加入列表',
          onPressed: onAdd ?? () {},
        ),
        RowAction(
          icon: Icons.delete_rounded,
          label: '删除',
          destructive: true,
          onPressed: onRemove ?? () {},
        ),
      ];

  test('动作 → 菜单条目：顺序 / 图标 / 文案 / 移除类，value = 动作下标', () {
    final entries = rowMenuEntries(sample());

    expect(entries.map((entry) => entry.label), ['加入列表', '删除']);
    expect(entries.map((entry) => entry.value), [0, 1]);
    expect((entries[0].leading as Icon).icon, Icons.playlist_add_rounded);
    expect((entries[1].leading as Icon).icon, Icons.delete_rounded);
    expect(entries[0].isDestructive, isFalse);
    expect(entries[1].isDestructive, isTrue);
  });

  test('条目选中：值 = 动作下标，只触发对应回调；非法值不执行', () {
    var add = 0;
    var remove = 0;
    final onSelected = rowMenuSelection(
      sample(onAdd: () => add++, onRemove: () => remove++),
    );

    onSelected(1);
    expect(remove, 1);
    expect(add, 0);

    // 菜单值只可能来自 rowMenuEntries；越界 / 非 int 一律忽略，不越界取动作。
    onSelected(null);
    onSelected('1');
    onSelected(-1);
    onSelected(2);
    expect(add, 0);
    expect(remove, 1);
  });

  testWidgets('触摸端 ⋮：条目与选中都走同一份动作', (tester) async {
    var add = 0;
    var remove = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RowActionMenuButton(
              actions: sample(
                onAdd: () => add++,
                onRemove: () => remove++,
              ),
              semanticLabel: '曲目操作',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('加入列表'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(remove, 1);
    expect(add, 0);
  });

  testWidgets('触摸端 ⋮：空动作不渲染锚点', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: RowActionMenuButton(actions: [], semanticLabel: '曲目操作'),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(find.byType(M3EIconButton), findsNothing);
  });

  testWidgets(
    '桌面右键入口：有动作才返回回调，空动作不接次级手势',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));

      expect(rowActionsAtPointer(context, sample()), isNotNull);
      expect(rowActionsAtPointer(context, const []), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('触摸端不接次级手势（右键入口恒为 null）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));

    expect(rowActionsAtPointer(context, sample()), isNull);
  });
}
