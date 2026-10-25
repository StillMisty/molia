import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/paged_list_auto_load.dart';

/// 分页列表通用自动加载 / 页脚的独立用例（不依赖具体页面）。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 300, height: 300, child: child),
        ),
      );

  Widget shortList() =>
      ListView(children: const [SizedBox(height: 20, child: Text('唯一一条'))]);

  testWidgets('首屏不满一屏：布局后自动取下一页', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        PagedListAutoLoad(
          hasMore: true,
          isLoadingMore: false,
          loadMoreFailed: false,
          onLoadMore: () => calls++,
          child: shortList(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '没有滚动事件时也要续取，否则去掉按钮后没有入口');
  });

  testWidgets('加载中 / 失败 / 已到底 / 首屏失败：不自动取页', (tester) async {
    for (final (label, hasMore, isLoadingMore, loadMoreFailed, failed) in [
      ('已到底', false, false, false, false),
      ('加载中', true, true, false, false),
      ('加载更多失败', true, false, true, false),
      ('首屏失败', true, false, false, true),
    ]) {
      var calls = 0;
      await tester.pumpWidget(
        host(
          PagedListAutoLoad(
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            loadMoreFailed: loadMoreFailed,
            failed: failed,
            onLoadMore: () => calls++,
            child: shortList(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, 0, reason: label);
    }
  });

  testWidgets('滚动到距底 400px 内自动取下一页', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        PagedListAutoLoad(
          hasMore: true,
          isLoadingMore: false,
          loadMoreFailed: false,
          onLoadMore: () => calls++,
          child: ListView.builder(
            itemExtent: 40,
            itemCount: 100,
            itemBuilder: (context, index) => Text('行 $index'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls, 0, reason: '初始位置远离底部');

    await tester.fling(find.byType(ListView), const Offset(0, -4000), 4000);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('页脚：加载中显示进度圈', (tester) async {
    await tester.pumpWidget(
      host(
        PagedListFooter(
          isLoadingMore: true,
          loadMoreFailed: false,
          onRetry: () {},
        ),
      ),
    );

    expect(find.byType(M3EProgressIndicator), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('页脚：失败文案 + 重试按钮可点', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      host(
        PagedListFooter(
          isLoadingMore: false,
          loadMoreFailed: true,
          failureLabel: '加载更多结果失败',
          retryKey: const Key('pagedListRetry'),
          onRetry: () => retries++,
        ),
      ),
    );

    expect(find.text('加载更多结果失败'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pagedListRetry')));
    expect(retries, 1);
  });

  testWidgets('页脚：已到底显示结束文案', (tester) async {
    await tester.pumpWidget(
      host(
        PagedListFooter(
          hasMore: false,
          isLoadingMore: false,
          loadMoreFailed: false,
          endLabel: '没有更多评论了',
          onRetry: () {},
        ),
      ),
    );

    expect(find.text('没有更多评论了'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('页脚：还有下一页时不显示结束文案', (tester) async {
    await tester.pumpWidget(
      host(
        PagedListFooter(
          isLoadingMore: false,
          loadMoreFailed: false,
          endLabel: '没有更多评论了',
          onRetry: () {},
        ),
      ),
    );

    expect(find.text('没有更多评论了'), findsNothing);
  });
}
