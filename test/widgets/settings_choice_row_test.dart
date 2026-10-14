import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/widgets/card_list_surface.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

/// 设置行共享组件的布局回归：
/// - 分段行必须显式给紧约束宽度（`M3ESegmentedButton` 内部是
///   `Stack + Positioned.fill + Row(mainAxisSize.min)`，放松约束会零宽溢出）；
/// - 下拉行未选中时显示标题提示，不落包内英文兜底 `Select`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(WidgetTester tester, Widget parent) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData()),
        theme: ThemeData(),
        home: Scaffold(body: parent),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('分段行：放松约束父级下仍等宽铺满、可选中', (tester) async {
    var selected = 'a';
    // Center 只给 loose 约束：分段行也必须显式铺满，不能塌成零宽。
    await pumpRow(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (context, setState) => SettingsChoiceRow<String>(
            icon: Icons.tune_rounded,
            title: 'Range',
            value: selected,
            options: const [('a', 'One'), ('b', 'Two'), ('c', 'Three')],
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    final segmented = find.byType(M3ESegmentedButton<String>);
    final size = tester.getSize(segmented);
    expect(size.width, greaterThan(0), reason: '分段按钮塌成零宽');
    // 铺满行内容宽（屏幕 800 − 行左右 padding 24）。
    expect(size.width, 800 - 24);
    expect(size.height, greaterThan(0));

    await tester
        .tap(find.descendant(of: segmented, matching: find.text('Two')));
    await tester.pumpAndSettle();
    expect(selected, 'b');
  });

  testWidgets('多行分组：SettingsRows 逐行下发形状（首末 16dp、内行 4dp）', (tester) async {
    // 一个分组里「单个子项产出多行」时必须逐行覆盖行位置，否则整组按
    // single 画成四角 16dp（外观分区踩过：与其它分组的内行圆角不一致）。
    Widget tile(String title) => SettingsInfoTile(
          icon: Icons.info_rounded,
          title: title,
          subtitle: '',
        );
    await pumpRow(
      tester,
      Column(
        children: [
          SettingsSectionCard(
            title: 'Composite',
            children: [
              SettingsRows(children: [tile('A'), tile('B'), tile('C')]),
            ],
          ),
          const SizedBox(height: 24),
          SettingsSectionCard(
            title: 'Direct',
            children: [tile('D'), tile('E'), tile('F')],
          ),
        ],
      ),
    );

    final radii = tester
        .widgetList<M3ECard>(find.byType(M3ECard))
        .map((card) => card.borderRadius)
        .toList();
    expect(radii, hasLength(6));
    // 复合组（前 3 行）与直挂组（后 3 行）逐行同形。
    for (var i = 0; i < 3; i++) {
      expect(radii[i], radii[3 + i], reason: '第 ${i + 1} 行形状不一致');
    }
    // 首行外侧 16dp、内行 4dp、末行外侧 16dp。
    expect(
      radii[0],
      const BorderRadius.vertical(
        top: Radius.circular(16),
        bottom: Radius.circular(4),
      ),
    );
    expect(radii[1], BorderRadius.circular(4));
    expect(
      radii[2],
      const BorderRadius.vertical(
        top: Radius.circular(4),
        bottom: Radius.circular(16),
      ),
    );
  });

  testWidgets('分段行：短标签行上图标后选中段显示对勾（M3E 替换图标）', (tester) async {
    await pumpRow(
      tester,
      Center(
        child: SettingsChoiceRow<String>(
          icon: Icons.repeat_rounded,
          title: 'Mode',
          value: 'a',
          options: const [('a', 'One'), ('b', 'Two'), ('c', 'Three')],
          icons: const {
            'a': Icons.repeat_rounded,
            'b': Icons.shuffle_rounded,
            'c': Icons.repeat_one_rounded,
          },
          onChanged: (_) {},
        ),
      ),
    );

    // 短标签 + 逐项图标：上勾（替换图标、不额外占宽）；长标签行不配图标
    // （图标 + 文案会截断，见 settings_page_test 的播放模式用例）。
    final segmented =
        tester.widget<M3ESegmentedButton<String>>(find.byType(M3ESegmentedButton<String>));
    expect(segmented.showSelectedIcon, isTrue);
  });

  testWidgets('分段行：无逐项图标时保持无勾（勾会挤断长标签）', (tester) async {
    await pumpRow(
      tester,
      Center(
        child: SettingsChoiceRow<String>(
          icon: Icons.language_rounded,
          title: 'Language',
          value: 'a',
          options: const [('a', 'System'), ('b', 'English')],
          onChanged: (_) {},
        ),
      ),
    );

    final segmented =
        tester.widget<M3ESegmentedButton<String>>(find.byType(M3ESegmentedButton<String>));
    expect(segmented.showSelectedIcon, isFalse);
  });

  testWidgets('下拉行：未选中显示标题提示，不落英文兜底 Select', (tester) async {
    await pumpRow(
      tester,
      Center(
        child: SettingsDropdownRow<String>(
          icon: Icons.high_quality_rounded,
          title: 'Quality',
          value: 'unknown',
          options: const [('320k', '320K'), ('128k', '128K')],
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Select'), findsNothing);
    // 行标题 + 字段提示（hintText = title）两处。
    expect(find.text('Quality'), findsNWidgets(2));
  });

  testWidgets('标签行：标题 1 行、副标题 2 行封顶（长文案不再折 3 行）',
      (tester) async {
    const longSubtitle =
        'A deliberately long supporting text that would wrap to three or '
        'even four lines if the label column did not cap the line count for '
        'every settings row in this list.';
    await pumpRow(
      tester,
      Column(
        children: [
          const SettingsInfoTile(
            icon: Icons.info_rounded,
            title: 'Short',
            subtitle: 'One line',
          ),
          SettingsInfoTile(
            icon: Icons.info_rounded,
            title: 'Long',
            subtitle: longSubtitle,
          ),
        ],
      ),
    );

    // 标题 1 行 / 副标题 2 行（组件属性即规范）。
    final title = tester.widget<Text>(find.text('Long'));
    expect(title.maxLines, 1);
    final short = tester.widget<Text>(find.text('One line'));
    expect(short.maxLines, 2);
    final long = tester.widget<Text>(find.text(longSubtitle));
    expect(long.maxLines, 2);

    // 渲染高度：长副标题 = 恰好 2 行（单行高度的 2 倍），不随文案膨胀。
    final singleHeight = tester.getSize(find.text('One line')).height;
    final longHeight = tester.getSize(find.text(longSubtitle)).height;
    expect(longHeight, 2 * singleHeight);
  });

  testWidgets('行高取 M3E 列表 token：无副标题 56dp，有副标题 72dp', (tester) async {
    await pumpRow(
      tester,
      Builder(
        builder: (context) {
          final item = M3ETheme.of(context).listTheme.item;
          return Column(
            children: [
              SettingsInfoTile(
                icon: Icons.info_rounded,
                title: 'No subtitle',
                subtitle: '',
              ),
              const SettingsInfoTile(
                icon: Icons.info_rounded,
                title: 'With subtitle',
                subtitle: 'Supporting',
              ),
              // 参照物：token 值本身。
              SizedBox(height: item.twoLineHeight - item.minHeight),
            ],
          );
        },
      ),
    );

    final rows = find.byType(CardListSurface);
    final noSubtitle = tester.getSize(rows.at(0)).height;
    final withSubtitle = tester.getSize(rows.at(1)).height;
    final item = M3ETheme.of(
      tester.element(find.byType(SettingsInfoTile).first),
    ).listTheme.item;
    expect(noSubtitle, item.minHeight);
    expect(withSubtitle, item.twoLineHeight);
    expect(withSubtitle, greaterThan(noSubtitle));
  });
}
