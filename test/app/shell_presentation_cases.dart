import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/shell/shell_page_layer_presentation.dart';
import 'package:molia/app/shell/shell_presentation.dart';
import 'package:molia/domain/models/shell_destination.dart';

/// `ShellPresentation` 的接口级用例：不挂载 `MyApp`、不 pump 壳层帧。
///
/// 覆盖 ADR-0039 的判定矩阵——目的地回退 / 恢复、顶栏播放条可见性、展开
/// 守卫、返回层级与页面淡入淡出纯函数。行为若在这些用例里变了，说明改到了
/// 壳层的决策语义，而不是渲染细节。
void main() {
  const nowPlaying = ShellDestination.nowPlaying;
  const favorites = ShellDestination.favorites;
  const library = ShellDestination.library;

  ShellPresentation build({
    ShellDestination selected = favorites,
    List<ShellDestination>? visible,
  }) => ShellPresentation(
    initialDestination: selected,
    visibleDestinations: visible ?? ShellDestination.values,
  );

  group('目的地解析', () {
    test('选中项被隐藏时回退首个可见项，恢复后回到原选中项', () {
      final presentation = build(selected: favorites);
      expect(presentation.state.effectiveDestination, favorites);
      expect(presentation.state.selectedIndex, 1);

      // 隐藏收藏（同步应用远端导航设置）：有效项回退到首个可见项，
      // 存储的选中项不能被改写——否则恢复后回不来。
      expect(presentation.syncVisibility([nowPlaying, library]), isTrue);
      expect(presentation.state.effectiveDestination, nowPlaying);
      expect(presentation.state.selectedDestination, favorites);
      expect(presentation.state.previousDestination, favorites);
      expect(presentation.state.selectedIndex, 0);

      // 同一份可见集合重复同步不算变化（不触发壳层的 morph 对齐）。
      expect(presentation.syncVisibility([nowPlaying, library]), isFalse);

      // 重新可见：原选中项天然恢复。
      expect(
        presentation.syncVisibility([nowPlaying, favorites, library]),
        isTrue,
      );
      expect(presentation.state.effectiveDestination, favorites);
      expect(presentation.state.selectedIndex, 1);
    });

    test('切页只接受可见且不同的目的地，并记录上一页', () {
      final presentation = build(selected: favorites);
      expect(presentation.select(library), isTrue);
      expect(presentation.state.effectiveDestination, library);
      expect(presentation.state.previousDestination, favorites);

      // 重复选中当前页不是切页（壳层据此走重复点击 / 展开语义）。
      expect(presentation.select(library), isFalse);
      expect(presentation.state.previousDestination, favorites);

      presentation.syncVisibility([nowPlaying, favorites]);
      expect(presentation.state.effectiveDestination, nowPlaying);
      // 隐藏目的地不参与导航，也不能改写上一页。
      expect(presentation.select(library), isFalse);
      expect(presentation.state.previousDestination, favorites);
      expect(presentation.state.isVisible(library), isFalse);
    });

    test('空可见集合按存储选中项兜底', () {
      final presentation = build(selected: favorites);
      presentation.syncVisibility(const []);
      expect(presentation.state.effectiveDestination, favorites);
      expect(presentation.state.selectedIndex, -1);
    });
  });

  group('顶栏播放条', () {
    test('(播放页/其它) × (可收起/不可) × (展开/收起) 矩阵', () {
      final cases =
          <
            ({
              String name,
              ShellDestination destination,
              bool miniCapable,
              bool expanded,
              bool showsPlayerBar,
            })
          >[
            (
              name: '其它页 + 无收起态 + 收起',
              destination: favorites,
              miniCapable: false,
              expanded: false,
              showsPlayerBar: true,
            ),
            (
              name: '其它页 + 无收起态 + 展开',
              destination: favorites,
              miniCapable: false,
              expanded: true,
              showsPlayerBar: true,
            ),
            (
              name: '其它页 + 可收起 + 收起',
              destination: library,
              miniCapable: true,
              expanded: false,
              showsPlayerBar: true,
            ),
            (
              name: '其它页 + 可收起 + 展开',
              destination: library,
              miniCapable: true,
              expanded: true,
              showsPlayerBar: true,
            ),
            (
              name: '播放页 + 可收起 + 收起（唯一迷你播放器）',
              destination: nowPlaying,
              miniCapable: true,
              expanded: false,
              showsPlayerBar: true,
            ),
            (
              name: '播放页 + 可收起 + 展开（让位品牌位）',
              destination: nowPlaying,
              miniCapable: true,
              expanded: true,
              showsPlayerBar: false,
            ),
            (
              name: '播放页 + 无收起态 + 收起（桌面 / 宽版式）',
              destination: nowPlaying,
              miniCapable: false,
              expanded: false,
              showsPlayerBar: false,
            ),
            (
              name: '播放页 + 无收起态 + 展开',
              destination: nowPlaying,
              miniCapable: false,
              expanded: true,
              showsPlayerBar: false,
            ),
          ];

      for (final testCase in cases) {
        final presentation = build(selected: testCase.destination);
        presentation
          ..setMiniCapable(testCase.miniCapable)
          ..setExpanded(testCase.expanded);
        expect(
          presentation.state.showsPlayerBar,
          testCase.showsPlayerBar,
          reason: testCase.name,
        );
      }
    });
  });

  group('展开守卫', () {
    test('播放页 + 可收起 + 无飞行才接受请求', () {
      final presentation = build(selected: nowPlaying);
      presentation.setMiniCapable(true);
      expect(
        presentation.state.expansionVerdict,
        ShellExpansionVerdict.accepted,
      );

      presentation.setFlightInProgress(true);
      expect(
        presentation.state.expansionVerdict,
        ShellExpansionVerdict.flightInProgress,
      );
      presentation.setFlightInProgress(false);
      expect(
        presentation.state.expansionVerdict,
        ShellExpansionVerdict.accepted,
      );
    });

    test('不在播放页优先于布局能力与飞行', () {
      final presentation = build(selected: favorites);
      presentation
        ..setMiniCapable(true)
        ..setFlightInProgress(true);
      expect(
        presentation.state.expansionVerdict,
        ShellExpansionVerdict.notOnPlayerPage,
      );
    });

    test('没有收起态时拒绝（桌面 / 宽版式）', () {
      final presentation = build(selected: nowPlaying);
      expect(
        presentation.state.expansionVerdict,
        ShellExpansionVerdict.layoutCannotCollapse,
      );
    });

    test('只有展开态 / 布局能力变化才通知，飞行守卫不触发重建', () {
      final presentation = build(selected: nowPlaying);
      var notifications = 0;
      presentation.changes.addListener(() => notifications++);

      presentation.setExpanded(true);
      presentation.setExpanded(true);
      expect(notifications, 1, reason: '相同展开态不重复通知');
      presentation.setMiniCapable(true);
      expect(notifications, 2);
      presentation.setFlightInProgress(true);
      presentation.setFlightInProgress(false);
      expect(notifications, 2, reason: '飞行守卫不参与渲染，不应 setState');
    });
  });

  group('返回层级', () {
    test('正常播放页 / 其它页 / 无收起态都不拦返回', () {
      // 正常播放页（歌词在下方）是播放 tab 的终态：返回交给系统退出。
      final normal = build(selected: nowPlaying);
      normal
        ..setMiniCapable(true)
        ..setExpanded(true);
      expect(normal.state.interceptsBack, isFalse);
      expect(normal.handleBack(pageClaimsBack: false), ShellBackIntent.exit);

      // 其它一级页即使残留展开态（异常顺序）也不拦：平级页返回即退出。
      final otherPage = build(selected: favorites);
      otherPage.setExpanded(true);
      expect(otherPage.state.interceptsBack, isFalse);
      expect(otherPage.handleBack(pageClaimsBack: false), ShellBackIntent.exit);

      // 桌面 / 宽版式没有歌词整页状态：残留的未展开态不能吞掉返回。
      final noCollapse = build(selected: nowPlaying);
      expect(noCollapse.state.interceptsBack, isFalse);
      expect(
        noCollapse.handleBack(pageClaimsBack: false),
        ShellBackIntent.exit,
      );
    });

    test('歌词整页先恢复完整播放页，页面级占用优先', () {
      final presentation = build(selected: nowPlaying);
      presentation.setMiniCapable(true);
      expect(presentation.state.interceptsBack, isTrue);
      expect(
        presentation.handleBack(pageClaimsBack: false),
        ShellBackIntent.restorePlayer,
      );

      // 页面级临时状态（多选 / 搜索 / 排序 / 弹层）接管时壳层让位。
      expect(
        presentation.handleBack(pageClaimsBack: true),
        ShellBackIntent.exit,
      );
    });
  });

  group('页面分层纯函数', () {
    test('选中页淡入不做缩放', () {
      expect(
        shellPageLayerPresentation(
          selected: true,
          outgoing: false,
          progress: 1,
        ),
        (opacity: 1.0, scale: 1.0),
      );
      expect(
        shellPageLayerPresentation(
          selected: true,
          outgoing: false,
          progress: 0,
        ),
        (opacity: 0.0, scale: 1.0),
      );

      final midway = shellPageLayerPresentation(
        selected: true,
        outgoing: false,
        progress: 0.5,
      );
      expect(midway.opacity, inExclusiveRange(0.0, 1.0));
      expect(midway.scale, 1.0, reason: '入场微缩会让共享飞行锚点落错位置');
    });

    test('出场页过渡中淡出微缩，落定后缩放必须回到 1', () {
      final fading = shellPageLayerPresentation(
        selected: false,
        outgoing: true,
        progress: 0.1,
      );
      expect(fading.opacity, inExclusiveRange(0.0, 1.0));
      expect(fading.scale, lessThan(1.0));

      expect(
        shellPageLayerPresentation(
          selected: false,
          outgoing: true,
          progress: 1,
        ),
        (opacity: 0.0, scale: 1.0),
      );
    });

    test('隐藏页不绘制、不缩放', () {
      expect(
        shellPageLayerPresentation(
          selected: false,
          outgoing: false,
          progress: 0.5,
        ),
        (opacity: 0.0, scale: 1.0),
      );
    });
  });
}
