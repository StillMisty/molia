import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/desktop_layout.dart';
import 'package:molia/widgets/track_row.dart';

/// 桌面布局判据（唯一阈值处，见 `desktop_layout.dart`）的钉子：
/// 四个窗口宽阈值 + 内容宽阈值（含「窗口宽 − 实际栏宽」的表格判定）+
/// 平台位 + 解析 / 消费路径。
///
/// 阈值边界逐个钉死：改常量会在这里显形。
void main() {
  DesktopLayout layout({
    required double windowWidth,
    bool desktopPlatform = true,
    double? railWidth,
  }) =>
      DesktopLayout(
        isDesktopPlatform: desktopPlatform,
        windowWidth: windowWidth,
        // 栏宽默认取 M3E 导航轨主题折叠宽（判定不写死数值）。
        railWidth: railWidth ?? M3ENavigationRailTheme.defaults.collapsedWidth,
        child: const SizedBox.shrink(),
      );

  group('窗口宽语义', () {
    test('masterDetail（收藏合集栏 / 设置两列共用）：899 关 / 900 开', () {
      expect(layout(windowWidth: 899).masterDetail, isFalse);
      expect(layout(windowWidth: 900).masterDetail, isTrue);
      expect(Breakpoints.desktop, 900, reason: '阈值常量是唯一来源');
    });

    test('searchCompact（顶栏搜索形态）：899 退化 / 900 完整', () {
      expect(layout(windowWidth: 899).searchCompact, isTrue);
      expect(layout(windowWidth: 900).searchCompact, isFalse);
    });

    test('railForceCollapsed：999 强制折叠 / 1000 按记忆值', () {
      expect(layout(windowWidth: 999).railForceCollapsed, isTrue);
      expect(layout(windowWidth: 1000).railForceCollapsed, isFalse);
    });

    test('queuePanelAvailable：1199 不渲染 / 1200 可用', () {
      expect(layout(windowWidth: 1199).queuePanelAvailable, isFalse);
      expect(layout(windowWidth: 1200).queuePanelAvailable, isTrue);
    });

    test('非桌面平台：再宽也不启用任何桌面增强', () {
      final mobile = layout(windowWidth: 1440, desktopPlatform: false);
      expect(mobile.masterDetail, isFalse);
      expect(mobile.tableColumns, isFalse);
      expect(mobile.tableColumnsAt(1440), isFalse);
      expect(mobile.channelRailAt(1440), isFalse);
    });
  });

  group('内容宽语义', () {
    test('contentWidth = 窗口宽 − 实际栏宽（栏宽来自导航轨主题）', () {
      expect(layout(windowWidth: 1280).contentWidth, 1184);
      expect(layout(windowWidth: 1280, railWidth: 200).contentWidth, 1080);
    });

    test('tableColumns：内容宽 719 单列 / 720 表格（阈值与行常量同源）', () {
      // 815 − 96 = 719；816 − 96 = 720。
      expect(layout(windowWidth: 815).tableColumns, isFalse);
      expect(layout(windowWidth: 816).tableColumns, isTrue);
      expect(TrackRowColumns.minWidth, 720, reason: '阈值常量是唯一来源');
      // 栏宽变宽 = 内容宽变窄：同一窗口宽下判定跟着栏宽走。
      expect(layout(windowWidth: 815, railWidth: 200).tableColumns, isFalse);
      expect(layout(windowWidth: 919, railWidth: 200).tableColumns, isFalse);
      expect(layout(windowWidth: 920, railWidth: 200).tableColumns, isTrue);
    });

    test('tableColumnsFor：按规范取阈值（历史档列多，阈值更高）', () {
      expect(TrackRowColumnSpec.standard.minContentWidth, 720);
      expect(TrackRowColumnSpec.history.minContentWidth, 812);
      // 907 − 96 = 811 / 908 − 96 = 812。
      expect(
        layout(windowWidth: 907).tableColumnsFor(TrackRowColumnSpec.history),
        isFalse,
      );
      expect(
        layout(windowWidth: 908).tableColumnsFor(TrackRowColumnSpec.history),
        isTrue,
      );
      // 同一窗口宽：默认档已进表格，历史档还没有。
      expect(
        layout(windowWidth: 816).tableColumnsFor(TrackRowColumnSpec.standard),
        isTrue,
      );
      expect(
        layout(windowWidth: 816).tableColumnsFor(TrackRowColumnSpec.history),
        isFalse,
      );
    });

    test('tableColumnsAt（显式内容宽）：719 单列 / 720 表格', () {
      expect(layout(windowWidth: 2000).tableColumnsAt(719), isFalse);
      expect(layout(windowWidth: 2000).tableColumnsAt(720), isTrue);
    });

    test('tableColumns 与 tableColumnsAt 同一判据（输入 = 窗口宽 − 栏宽）', () {
      final windowed = layout(windowWidth: 1300);
      expect(windowed.tableColumns,
          windowed.tableColumnsAt(windowed.contentWidth));
      expect(windowed.contentWidth, 1204);
      expect(windowed.tableColumns, isTrue);
    });

    test('channelRailAt：899 顶部下拉 / 900 左侧竖栏', () {
      expect(layout(windowWidth: 2000).channelRailAt(899), isFalse);
      expect(layout(windowWidth: 2000).channelRailAt(900), isTrue);
    });

    test('内容宽判定与窗口宽无关（宽度来源由 API 表达）', () {
      // 窄窗口但内容区宽：显式传入的内容宽仍可进表格 / 竖栏。
      expect(layout(windowWidth: 800).tableColumnsAt(900), isTrue);
      // 宽窗口但内容区窄（页内常驻栏 / 面板二次扣减）不启用。
      expect(layout(windowWidth: 2000).tableColumnsAt(600), isFalse);
    });
  });

  group('解析与消费', () {
    testWidgets(
      '无壳层：of 按当前 context 回退解析（窗口宽 + 平台位）',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        late DesktopLayout resolved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                resolved = DesktopLayout.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(resolved.windowWidth, 1200);
        expect(resolved.isDesktopPlatform, isTrue, reason: 'variant 覆盖为 linux');
        expect(resolved.masterDetail, isTrue);
        expect(
          resolved.railWidth,
          M3ENavigationRailTheme.defaults.collapsedWidth,
          reason: '无壳层回退：栏宽取 M3E 导航轨主题折叠宽',
        );
        expect(
          M3ENavigationRailTheme.defaults.collapsedWidth,
          96,
          reason: '主题默认值（判定不写死数值）',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      '无壳层：栏宽随 M3E 导航轨主题走（判定不硬编码 96）',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        late DesktopLayout resolved;
        await tester.pumpWidget(
          MaterialApp(
            home: M3ETheme(
              data: M3EThemeData(
                navigationRailTheme:
                    const M3ENavigationRailTheme(collapsedWidth: 200),
              ),
              child: Builder(
                builder: (context) {
                  resolved = DesktopLayout.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );

        // 1200 − 200 = 1000 ≥ 720：栏宽变化直接改变内容宽与判定输入。
        expect(resolved.railWidth, 200);
        expect(resolved.contentWidth, 1000);
        expect(resolved.tableColumns, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('壳层已解析：of 取最近 scope，不再看当前窗口宽', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late DesktopLayout consumed;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopLayout(
            // 壳层解析结果：窄窗口。
            isDesktopPlatform: true,
            windowWidth: 800,
            railWidth: M3ENavigationRailTheme.defaults.collapsedWidth,
            child: Builder(
              builder: (context) {
                consumed = DesktopLayout.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(consumed.windowWidth, 800);
      expect(consumed.masterDetail, isFalse, reason: '页面只消费壳层解析值');
    });

    testWidgets(
      'scope：按当前 context 解析一次并包住子树',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        late DesktopLayout consumed;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => DesktopLayout.scope(
                context,
                child: Builder(
                  builder: (inner) {
                    consumed = DesktopLayout.of(inner);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        );

        expect(consumed.windowWidth, 1440);
        expect(consumed.isDesktopPlatform, isTrue, reason: 'variant 覆盖为 linux');
        expect(consumed.masterDetail, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });
}
