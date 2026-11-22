import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/collection_track_list.dart';

/// 合集列表滚动条：切合集换控制器后仍能直接拖拇指定位。
///
/// 回归背景：收藏页切到播放历史 / 本地歌曲时，同一个 `Scrollbar` 元素换了
/// 控制器；`RawScrollbar` 在 build 时按 position 是否挂上决定安装手势，
/// 那时新列表还没挂上，之后只重绘不重建，拇指就一直拖不动，直到页面因其它
/// 原因重建（切到播放页再回来）才恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rows = List<String>.generate(60, (index) => 'row-$index');
  final theme = ThemeData.light().copyWith(platform: TargetPlatform.android);
  final themeData = M3EThemeData.fromMaterial(theme);

  /// 稳定的主题实例 + 局部的控制器切换：模拟收藏页原地换合集，不经过
  /// 应用 / 主题重建（否则主题动画会顺手把滚动条也重建一次，掩盖回归）。
  Widget host(ValueListenable<ScrollController> controller) => M3EMaterialApp(
    data: themeData,
    theme: theme,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          height: 400,
          width: 320,
          child: ValueListenableBuilder<ScrollController>(
            valueListenable: controller,
            builder: (context, current, _) => CollectionTrackList<String>(
              controller: current,
              rows: rows,
              keyOf: (row) => ValueKey<String>(row),
              itemBuilder: (context, row, index) =>
                  SizedBox(height: 72, child: Text(row)),
              empty: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('换控制器后滚动条拇指仍可拖动', (tester) async {
    final first = ScrollController();
    final second = ScrollController();
    final current = ValueNotifier<ScrollController>(first);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(current.dispose);

    await tester.pumpWidget(host(current));
    // 首帧布局后 position 才挂上；拇指出场动画 300ms，结束后才可命中。
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(find.byType(Scrollbar));
    Future<void> dragThumb() async {
      // 拇指停在顶部，右边缘：拖 120dp 相当于滚过列表的大部分内容，
      // 而普通列表拖动只会滚 120dp 左右，两者可以明确区分。
      await tester.timedDragFrom(
        Offset(rect.right - 2, rect.top + 24),
        const Offset(0, 120),
        const Duration(milliseconds: 400),
      );
    }

    await dragThumb();
    expect(
      first.offset,
      greaterThan(500),
      reason: '首屏拖拇指出发时应按轨道比例滚动，而不是像列表拖动那样只走 120',
    );

    // 同一个 CollectionTrackList 元素换成新控制器（合集切换的真实路径）。
    // 滚动位置复用同一个 ScrollPosition；先归零，才能用拖动距离区分
    // 「拖到拇指」和「拖到列表」。
    first.jumpTo(0);
    await tester.pump();
    current.value = second;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragThumb();
    expect(
      second.offset,
      greaterThan(500),
      reason: '换控制器后拇指仍必须可直接拖动（曾经只有重进页面才恢复）',
    );
  });
}
