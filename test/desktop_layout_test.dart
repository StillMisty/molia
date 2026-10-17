import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/desktop_layout.dart';
import 'package:molia/widgets/track_row.dart';

/// 桌面布局判据（唯一阈值处，见 `desktop_layout.dart`）的钉子：
/// 四个窗口宽阈值 + 两个内容宽阈值 + 平台位 + 解析 / 消费路径。
///
/// 阈值边界逐个钉死：改常量会在这里显形。
void main() {
  DesktopLayout layout({
    required double windowWidth,
    bool desktopPlatform = true,
  }) =>
      DesktopLayout(
        isDesktopPlatform: desktopPlatform,
        windowWidth: windowWidth,
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
      expect(mobile.tableColumnsAt(1440), isFalse);
      expect(mobile.channelRailAt(1440), isFalse);
    });
  });

  group('内容宽语义', () {
    test('tableColumnsAt：899 单列 / 900 表格（阈值与行常量同源）', () {
      expect(layout(windowWidth: 2000).tableColumnsAt(899), isFalse);
      expect(layout(windowWidth: 2000).tableColumnsAt(900), isTrue);
      expect(TrackRowColumns.minWidth, 900, reason: '阈值常量是唯一来源');
    });

    test('channelRailAt：899 顶部下拉 / 900 左侧竖栏', () {
      expect(layout(windowWidth: 2000).channelRailAt(899), isFalse);
      expect(layout(windowWidth: 2000).channelRailAt(900), isTrue);
    });

    test('内容宽判定与窗口宽无关（宽度来源由 API 表达）', () {
      // 窄窗口但内容区宽（如独立挂载页面）仍可进表格 / 竖栏。
      expect(layout(windowWidth: 800).tableColumnsAt(900), isTrue);
      // 宽窗口但内容区窄（桌面侧栏 / 队列面板吃掉宽度）不启用。
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
