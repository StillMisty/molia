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

  testWidgets('行尾元信息贴行右缘（回归：Flexible 曾与标题平分剩余宽度）',
      (tester) async {
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

  testWidgets('逐名可点的歌手：点击链接回调，不触发行播放；无回调的名字不可点',
      (tester) async {
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

  testWidgets('宽屏表格列：三列按常量列宽渲染，副标题与歌手链接让位', (tester) async {
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

    // 三列文本各自出现（列宽与表头共用的常量，见 track_table_header.dart）。
    expect(find.text('Col Artist'), findsOneWidget);
    expect(find.text('Col Album'), findsOneWidget);
    expect(find.text('3:05'), findsOneWidget);
    expect(
      tester.getSize(find.text('Col Artist')).width,
      TrackRowColumns.artistWidth,
    );
    expect(
      tester.getSize(find.text('Col Album')).width,
      TrackRowColumns.albumWidth,
    );
    expect(
      tester.getSize(find.text('3:05')).width,
      TrackRowColumns.durationWidth,
    );

    // 标题格只显示标题：副标题与逐名歌手链接不再渲染（让位给独立列）。
    expect(find.text('Row Artist'), findsNothing);
    expect(find.text('Link A'), findsNothing);

    // 密度不变：表格模式不改变固定行高。
    expect(tester.getSize(find.byType(TrackRow)).height, TrackRow.extent);
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
}
