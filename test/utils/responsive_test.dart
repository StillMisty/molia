import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_3_expressive/components/bottom_sheets/components/m3e_bottom_sheet_surface.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/page_modal.dart';

void main() {
  Future<void> pumpResponsiveHarness(
    WidgetTester tester, {
    required double width,
    required Widget child,
  }) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 1200)),
          child: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('shell layout switches to two pane at tablet breakpoint',
      (tester) async {
    Future<bool> prefersTwoPane(double width) async {
      await pumpResponsiveHarness(
        tester,
        width: width,
        child: Builder(
          builder: (context) => Text(
            context.layoutType(ResponsivePageType.shell).preferTwoPane
                ? 'two-pane'
                : 'single-pane',
          ),
        ),
      );
      return find.text('two-pane').evaluate().isNotEmpty;
    }

    expect(await prefersTwoPane(390), isFalse);
    expect(await prefersTwoPane(600), isTrue);
    expect(await prefersTwoPane(900), isTrue);
    expect(await prefersTwoPane(1280), isTrue);
  });

  testWidgets('adaptiveColumns stays consistent across standard breakpoints',
      (tester) async {
    Future<int> columnsFor(double width) async {
      await pumpResponsiveHarness(
        tester,
        width: width,
        child: Builder(
          builder: (context) => Text(
            '${context.adaptiveColumns(minTileWidth: context.layoutType(ResponsivePageType.browse).defaultMinTileWidth, min: 3, max: 6)}',
          ),
        ),
      );

      final textWidget = tester.widget<Text>(find.byType(Text).first);
      return int.parse(textWidget.data!);
    }

    expect(await columnsFor(390), 3);
    expect(await columnsFor(600), 3);
    expect(await columnsFor(900), 4);
    expect(await columnsFor(1280), 6);
  });

  testWidgets('ResponsivePageContainer caps detail width on large screens',
      (tester) async {
    const contentKey = Key('detail-content');

    await pumpResponsiveHarness(
      tester,
      width: 1280,
      child: const ResponsivePageContainer(
        pageType: ResponsivePageType.detail,
        child: SizedBox(
          key: contentKey,
          width: double.infinity,
          height: 80,
        ),
      ),
    );

    final size = tester.getSize(find.byKey(contentKey));
    expect(size.width, 1080);
  });

  testWidgets('adaptive modal uses bottom sheet on mobile', (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 390,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showAdaptiveModalPage<void>(
                context: context,
                showCloseButton: false,
                child: const SizedBox(
                  height: 120,
                  child: Center(child: Text('modal-child')),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheetSize = tester.getSize(find.byType(M3EBottomSheetSurface));
    expect(find.byType(M3EBottomSheetSurface), findsOneWidget);
    expect(find.text('modal-child'), findsOneWidget);
    expect(sheetSize.height, lessThan(280));
  });

  testWidgets('adaptive modal can opt into fill-height on mobile',
      (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 390,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showAdaptiveModalPage<void>(
                context: context,
                showCloseButton: false,
                contentLayout: AdaptiveModalContentLayout.fillHeight,
                child: const SizedBox(
                  height: 120,
                  child: Center(child: Text('full-height-modal')),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheetSize = tester.getSize(find.byType(M3EBottomSheetSurface));
    expect(find.text('full-height-modal'), findsOneWidget);
    expect(sheetSize.height, greaterThan(700));
  });

  testWidgets('adaptive modal uses dialog on large screens', (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 1280,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showAdaptiveModalPage<void>(
                context: context,
                showCloseButton: false,
                child: const SizedBox(
                  height: 120,
                  child: Center(child: Text('modal-child')),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('modal-child'), findsOneWidget);
  });

  testWidgets('secondary page uses M3ESideSheet on large screens',
      (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 1280,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showSecondaryPage<void>(
                context: context,
                title: 'secondary-title',
                body: const Text('secondary-body'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(M3ESideSheet), findsOneWidget);
    // 标题进弹层自带 header，正文只构建一次（没有页面自带的第二层 AppBar）。
    expect(find.text('secondary-title'), findsOneWidget);
    expect(find.text('secondary-body'), findsOneWidget);
    expect(find.byType(M3EAppBar), findsNothing);
  });

  testWidgets('secondary page stays full screen on mobile', (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 390,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showSecondaryPage<void>(
                context: context,
                title: 'secondary-title',
                body: const Text('secondary-body'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 窄屏仍是全屏路由 + M3E AppBar，不出现侧边弹层。
    expect(find.byType(M3EAppBar), findsOneWidget);
    expect(find.byType(M3ESideSheet), findsNothing);
    expect(find.text('secondary-title'), findsOneWidget);
    expect(find.text('secondary-body'), findsOneWidget);
  });

  testWidgets(
      'page modal uses M3EDialog route with a page card on large screens',
      (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 1280,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showPageModal<void>(
                context: context,
                child: const Center(child: Text('page-modal-body')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 页面卡片是自定义外壳，不是 M3EDialog 本体：整页内容不能进它的
    // SingleChildScrollView。
    expect(find.byType(M3EDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(PageModalCard), findsOneWidget);
    expect(find.text('page-modal-body'), findsOneWidget);
  });

  testWidgets('page modal uses bottom sheet on mobile', (tester) async {
    await pumpResponsiveHarness(
      tester,
      width: 390,
      child: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              ResponsiveNavigation.showPageModal<void>(
                context: context,
                child: const Center(child: Text('page-modal-body')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EBottomSheetSurface), findsOneWidget);
    expect(find.text('page-modal-body'), findsOneWidget);
  });
}
