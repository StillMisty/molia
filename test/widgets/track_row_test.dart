import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目行表面形状按 M3E 列表规范（Compose `ListTokens`）：
/// 静止内 4dp / 首末外侧 16dp，hover 12dp（shape medium），press / 选中
/// 16dp（shape large），且带弹簧 morph——防止回退到 `M3EListRowSurface`
/// 的「hover 瞬间跳到 16dp」（docs/pitfalls.md #20）。
///
/// 另覆盖桌面交互：行内操作 hover 显现（[HoverReveal]，触摸端原样显示）
/// 与行表面右键（`onSecondaryTap`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(
    WidgetTester tester, {
    M3ECardPosition position = M3ECardPosition.middle,
    bool selected = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackRow(
              title: 'Title',
              artist: 'Artist',
              position: position,
              selected: selected,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  M3ECard cardOf(WidgetTester tester) => tester.widget<M3ECard>(
        find.descendant(
          of: find.byType(TrackRow),
          matching: find.byType(M3ECard),
        ),
      );

  testWidgets('静止形状按位置：内行 4dp，首/末行外侧 16dp，单行 16dp', (tester) async {
    await pumpRow(tester, position: M3ECardPosition.middle);
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));

    await pumpRow(tester, position: M3ECardPosition.first);
    expect(
      cardOf(tester).borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(16),
        bottom: Radius.circular(4),
      ),
    );

    await pumpRow(tester, position: M3ECardPosition.last);
    expect(
      cardOf(tester).borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(4),
        bottom: Radius.circular(16),
      ),
    );

    await pumpRow(tester, position: M3ECardPosition.single);
    expect(cardOf(tester).borderRadius, BorderRadius.circular(16));
  });

  testWidgets('hover：弹簧 morph 到 12dp，移出回静止形状', (tester) async {
    await pumpRow(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(TrackRow)));
    await tester.pump(); // hover 生效，弹簧启动
    await tester.pump(const Duration(milliseconds: 50)); // 弹簧推进
    final double mid = cardOf(tester).borderRadius!.topLeft.x;
    expect(mid, greaterThan(4), reason: '不是瞬间跳变');
    expect(mid, lessThan(12));

    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(12));

    await gesture.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));
  });

  testWidgets('press：morph 到 16dp，松开回静止形状', (tester) async {
    await pumpRow(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TrackRow)));
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(16));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(cardOf(tester).borderRadius, BorderRadius.circular(4));
  });

  testWidgets('选中：16dp 圆角 + secondaryContainer 底色', (tester) async {
    await pumpRow(tester, selected: true);
    final card = cardOf(tester);
    expect(card.borderRadius, BorderRadius.circular(16));
    final M3EColorScheme scheme =
        M3ETheme.of(tester.element(find.byType(TrackRow))).colorScheme;
    expect(card.color, scheme.secondaryContainer);
  });

  testWidgets('行距取 M3E 列表卡片 token（默认 2dp）', (tester) async {
    await pumpRow(tester);
    expect(TrackRow.gapOf(tester.element(find.byType(TrackRow))), 2);
  });

  testWidgets('行尾元信息贴行右缘（回归：Flexible 曾与标题平分剩余宽度）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: TrackRow(
                title: 'A very long track title that should take the space',
                artist: 'Artist',
                trailingText: '03:45',
                position: M3ECardPosition.single,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 行尾文本（超时长的自定义文案）右缘 = 行右缘 − CardListSurface 内边距 16dp。
    final double rowRight = tester.getTopRight(find.byType(TrackRow)).dx;
    final Rect trailingRect = tester.getRect(find.text('03:45'));
    expect(trailingRect.right, rowRight - 16);

    // 标题列吃满剩余宽度：右缘紧邻行尾文本左侧的 12dp 间距。
    final double titleRight =
        tester.getTopRight(find.textContaining('A very long track')).dx;
    expect(titleRight, trailingRect.left - 12);
  });

  testWidgets('逐名可点的歌手：点击链接回调，不触发行播放；无回调的名字不可点', (tester) async {
    var rowTaps = 0;
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackRow(
              title: 'Title',
              artist: 'A、B',
              artists: [
                TrackRowArtist(name: 'A', onTap: () => tapped.add('A')),
                const TrackRowArtist(name: 'B'),
              ],
              position: M3ECardPosition.single,
              onTap: () => rowTaps++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('A'));
    await tester.pump();
    expect(tapped, ['A'], reason: '链接回调生效');
    expect(rowTaps, 0, reason: '不触发行播放');

    // 无回调的名字是纯文本：点击落到行本身（播放）。
    await tester.tapOnText(find.textRange.ofSubstring('B'));
    await tester.pump();
    expect(tapped, ['A']);
    expect(rowTaps, 1);
  });

  testWidgets('未传 artists：副标题保持整串纯文本', (tester) async {
    await pumpRow(tester);
    expect(find.text('Artist'), findsOneWidget);
  });

  testWidgets('宽屏表格列：三列按规范列宽渲染，副标题与歌手链接让位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackRow(
              title: 'Title',
              artist: 'Row Artist',
              artists: [
                TrackRowArtist(name: 'Link A', onTap: () {}),
              ],
              columns: const TrackRowColumns(
                artist: 'Col Artist',
                album: 'Col Album',
                duration: '3:05',
              ),
              position: M3ECardPosition.single,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三列文本各自出现（列宽来自行与表头共用的规范，见 track_table_header.dart）。
    expect(find.text('Col Artist'), findsOneWidget);
    expect(find.text('Col Album'), findsOneWidget);
    expect(find.text('3:05'), findsOneWidget);
    expect(
      tester.getSize(find.text('Col Artist')).width,
      TrackRowColumnSpec.standard.artistWidth,
    );
    expect(
      tester.getSize(find.text('Col Album')).width,
      TrackRowColumnSpec.standard.albumWidth,
    );
    expect(
      tester.getSize(find.text('3:05')).width,
      TrackRowColumnSpec.standard.durationWidth,
    );

    // 标题格只显示标题：副标题与逐名歌手链接不再渲染（让位给独立列）。
    expect(find.text('Row Artist'), findsNothing);
    expect(find.text('Link A'), findsNothing);

    // 表格档是单行：行高取 M3E 列表 token `minHeight`（56，与双行档 72 成对）。
    expect(
      tester.getSize(find.byType(TrackRow)).height,
      TrackRow.extentOf(
        tester.element(find.byType(TrackRow)),
        tableColumns: true,
      ),
    );
    expect(tester.getSize(find.byType(TrackRow)).height, 56, reason: '单行档');
  });

  testWidgets('行高两档取 M3E 列表 token：表格 56 / 非表格 72', (tester) async {
    await pumpRow(tester);
    final context = tester.element(find.byType(TrackRow));

    expect(TrackRow.extentOf(context, tableColumns: true), 56);
    expect(TrackRow.extentOf(context, tableColumns: false), 72);
    expect(
      TrackRow.extentOf(context, tableColumns: true),
      M3ETheme.of(context).listTheme.item.minHeight,
    );
    expect(
      TrackRow.extentOf(context, tableColumns: false),
      M3ETheme.of(context).listTheme.item.twoLineHeight,
    );

    // 常量为「无表格档」列表保留：值必须与双行 token 同值（防两处漂移）。
    expect(TrackRow.extent, 72);
    expect(TrackRow.extent, M3EListItemTheme.defaults.twoLineHeight);

    // 实际渲染高度：非表格行 = 双行 token。
    expect(tester.getSize(find.byType(TrackRow)).height, TrackRow.extent);
  });

  testWidgets('表格模式：标题列宽度受规范上限约束，右侧列缘不动', (tester) async {
    Future<void> pump(String title) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 1200,
                child: TrackRow(
                  // 长到一定超出上限，短到不触发上限。
                  title: title,
                  columns: const TrackRowColumns(
                    artist: 'Col Artist',
                    album: 'Col Album',
                    duration: '3:05',
                  ),
                  position: M3ECardPosition.single,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final cap = TrackRowColumnSpec.standard.titleMaxWidth;
    final longTitle = 'T' * 400;
    await pump(longTitle);
    final longRect = tester.getRect(find.text(longTitle));
    expect(longRect.width, lessThanOrEqualTo(cap), reason: '标题不超过规范上限');

    // 上限不挤动右侧固定列：标题格仍吃满剩余宽度（表头列缘因此不用重算）。
    final artistX = tester.getTopLeft(find.text('Col Artist')).dx;
    await pump('短标题');
    expect(tester.getTopLeft(find.text('Col Artist')).dx, artistX);
  });

  testWidgets('播放时间列：规范开启时才渲染，列宽取规范', (tester) async {
    Future<void> pump(TrackRowColumnSpec spec) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TrackRow(
                title: 'Title',
                columns: TrackRowColumns(
                  spec: spec,
                  artist: 'Col Artist',
                  album: 'Col Album',
                  time: '10-18 21:03',
                  duration: '3:05',
                ),
                position: M3ECardPosition.single,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 默认档没有这一列：时间文案不渲染，时长列宽不变。
    await pump(TrackRowColumnSpec.standard);
    expect(find.text('10-18 21:03'), findsNothing);
    expect(
      tester.getSize(find.text('3:05')).width,
      TrackRowColumnSpec.standard.durationWidth,
    );

    // 历史档：时间在专辑与时长之间，列宽取规范。
    await pump(TrackRowColumnSpec.history);
    expect(find.text('10-18 21:03'), findsOneWidget);
    expect(
      tester.getSize(find.text('10-18 21:03')).width,
      TrackRowColumnSpec.history.timeWidth,
    );
    expect(
      tester.getTopLeft(find.text('10-18 21:03')).dx,
      greaterThan(tester.getTopLeft(find.text('Col Album')).dx),
    );
    expect(
      tester.getTopLeft(find.text('10-18 21:03')).dx,
      lessThan(tester.getTopLeft(find.text('3:05')).dx),
    );
  });

  testWidgets('表格模式：行尾槽固定宽，列左缘不随行尾内容漂移', (tester) async {
    Future<void> pump({Widget? trailing}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 700,
                child: TrackRow(
                  title: 'Title',
                  columns: const TrackRowColumns(
                    artist: 'Col Artist',
                    album: 'Col Album',
                    duration: '3:05',
                  ),
                  trailing: trailing,
                  position: M3ECardPosition.single,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 无行尾内容：列左缘已按固定槽宽让位。
    await pump();
    final without = tester.getTopLeft(find.text('Col Artist')).dx;

    // 行尾放窄内容（缓存标签 / 拖动把手的形态）：列左缘不动。
    await pump(trailing: const Icon(Icons.drag_handle_rounded, size: 20));
    expect(tester.getTopLeft(find.text('Col Artist')).dx, without);

    // 行尾内容贴槽右缘 = 行右缘 − 表面内边距 16。
    final rowRight = tester.getTopRight(find.byType(TrackRow)).dx;
    expect(
      tester.getTopRight(find.byIcon(Icons.drag_handle_rounded)).dx,
      rowRight - 16,
    );
  });

  testWidgets(
    '桌面：行内操作默认透明不可点，行 hover 后显现可点',
    (tester) async {
      var rowTaps = 0;
      var actionTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TrackRow(
                title: 'Title',
                artist: 'Artist',
                position: M3ECardPosition.single,
                onTap: () => rowTaps++,
                trailing: HoverReveal(
                  child: M3EIconButton(
                    variant: M3EIconButtonVariant.standard,
                    tooltip: 'actions',
                    icon: const Icon(Icons.more_vert_rounded),
                    onPressed: () => actionTaps++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // HoverReveal 自身的透明度包装（子组件内部的同类包装在遍历序里更靠后）。
      Finder revealOpacity() => find
          .descendant(
            of: find.byType(HoverReveal),
            matching: find.byType(AnimatedOpacity),
          )
          .first;

      // 未 hover：透明（目标值 0），点击穿透到行表面。
      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 0);
      await tester.tap(
        find.byIcon(Icons.more_vert_rounded),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(actionTaps, 0, reason: '隐藏时行内操作不可点');
      expect(rowTaps, 1, reason: '点击穿透到行（播放）');

      // 悬停整行即可显现：不要求指针先精确落在按钮上。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(TrackRow)));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 1);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(actionTaps, 1, reason: '显现后可点');
      expect(rowTaps, 1, reason: '按钮吃掉点击，不再穿透');

      // 指针移出：重新隐藏。
      await gesture.moveTo(const Offset(0, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 0);

      // 键盘焦点（Tab）同样显现：焦点落进行 / 行内按钮即显。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(revealOpacity()).opacity, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('触摸端：行内操作原样显示（不藏入口），右键不接线', (tester) async {
    var actionTaps = 0;
    var secondaryTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackRow(
              title: 'Title',
              position: M3ECardPosition.single,
              onTap: () {},
              onSecondaryTap: () => secondaryTaps++,
              trailing: HoverReveal(
                child: M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  tooltip: 'actions',
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () => actionTaps++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 非桌面：不引入显隐包装，入口恒定可见可点。
    expect(
      find.descendant(
        of: find.byType(HoverReveal),
        matching: find.byType(AnimatedOpacity),
      ),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(actionTaps, 1);

    // 右键是桌面专属：触摸端不接（也不吞掉行自己的手势）。
    await tester.tap(find.byType(TrackRow), buttons: kSecondaryButton);
    await tester.pump();
    expect(secondaryTaps, 0);
  });

  testWidgets(
    '桌面：行表面右键触发 onSecondaryTap，主键仍是行点击',
    (tester) async {
      var rowTaps = 0;
      var secondaryTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TrackRow(
                title: 'Title',
                position: M3ECardPosition.single,
                onTap: () => rowTaps++,
                onSecondaryTap: () => secondaryTaps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TrackRow), buttons: kSecondaryButton);
      await tester.pump();
      expect(secondaryTaps, 1);
      expect(rowTaps, 0, reason: '右键不触发行播放');

      await tester.tap(find.byType(TrackRow));
      await tester.pump();
      expect(rowTaps, 1, reason: '主键仍归行表面');
      expect(secondaryTaps, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  group('列规范', () {
    const specs = [TrackRowColumnSpec.standard, TrackRowColumnSpec.history];

    test('预设列宽对蓝图：默认一档 200/200/64，历史档 180/180/120/64', () {
      const standard = TrackRowColumnSpec.standard;
      expect(standard.titleMaxWidth, 480);
      expect(standard.artistWidth, 200);
      expect(standard.albumWidth, 200);
      expect(standard.durationWidth, 64);
      expect(standard.hasTimeColumn, isFalse);
      expect(standard.minContentWidth, TrackRowColumns.minWidth);

      const history = TrackRowColumnSpec.history;
      expect(history.titleMaxWidth, 400);
      expect(history.artistWidth, 180);
      expect(history.albumWidth, 180);
      expect(history.timeWidth, 120);
      expect(history.durationWidth, 64);
      expect(history.hasTimeColumn, isTrue);
    });

    test('唯一阈值：默认一档的规范最小值就是 TrackRowColumns.minWidth', () {
      expect(TrackRowColumns.minWidth, 720);
      expect(TrackRowColumnSpec.standard.minContentWidth, 720);
      expect(TrackRow.defaultCoverSize, 44);
      expect(TrackRowColumns.trailingSlotWidth, 56);
    });

    test('最小内容宽容得下自己的固定列（阈值处不横向溢出）', () {
      const item = M3EListItemTheme.defaults;
      for (final spec in specs) {
        // 封面之后的槽位：标题 / 歌手 / 专辑 /（时间）/ 时长 / 行尾。
        final cells = spec.hasTimeColumn ? 6.0 : 5.0;
        final columns = spec.artistWidth +
            spec.albumWidth +
            spec.durationWidth +
            (spec.hasTimeColumn ? spec.timeWidth : 0) +
            TrackRowColumns.trailingSlotWidth;
        // 行内网格：封面位 + 每个槽前的列间距（表头同源复刻）。
        final grid = TrackRow.defaultCoverSize + cells * item.gap;
        // 判定输入是「内容宽」：行表面内边距 + 桌面页横向留白（32×2，见
        // responsive.dart 的 browse 档）也在内容宽里。
        expect(
          spec.minContentWidth,
          greaterThanOrEqualTo(
            grid + columns + item.horizontalPadding * 2 + 32 * 2,
          ),
          reason: '阈值低于固定列需求时，表格在阈值处就会溢出',
        );
      }
    });
  });
}
