import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/providers/paged_list_controller.dart';

/// 分页列表状态机的单一测试面。
void main() {
  test('首屏加载：填充 items/total/hasMore', () async {
    final controller = PagedListController<String>(
      fetchPage: (page) async => PagedResult(
        items: ['p$page-a', 'p$page-b'],
        hasMore: page < 2,
        total: 4,
      ),
    );
    await controller.loadFirstPage();
    expect(controller.items, ['p1-a', 'p1-b']);
    expect(controller.hasMore, isTrue);
    expect(controller.total, 4);
    expect(controller.isLoading, isFalse);
    expect(controller.failed, isFalse);
  });

  test('loadMore 追加并按 key 去重；hasMore=false 后不再请求', () async {
    var requestedPage = 0;
    final controller = PagedListController<String>(
      fetchPage: (page) async {
        requestedPage = page;
        return PagedResult(
          items: page == 1 ? ['a', 'b'] : ['b', 'c'],
          hasMore: page < 2,
        );
      },
      keyOf: (item) => item,
    );
    await controller.loadFirstPage();
    await controller.loadMore();
    expect(requestedPage, 2);
    expect(controller.items, ['a', 'b', 'c']);
    expect(controller.hasMore, isFalse);
    await controller.loadMore();
    expect(requestedPage, 2);
  });

  test('首屏失败：置 failed 并清空；重试可恢复', () async {
    var calls = 0;
    final controller = PagedListController<String>(
      fetchPage: (_) async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return const PagedResult(items: ['ok'], hasMore: false);
      },
    );
    await controller.loadFirstPage();
    expect(controller.failed, isTrue);
    expect(controller.items, isEmpty);
    expect(controller.error, isA<StateError>());
    expect(controller.page, 0);
    await controller.loadFirstPage();
    expect(controller.failed, isFalse);
    expect(controller.items, ['ok']);
    expect(controller.error, isNull);
    expect(controller.page, 1);
  });

  test('加载更多失败：保留已加载项，不进入 failed', () async {
    final controller = PagedListController<String>(
      fetchPage: (page) async {
        if (page == 1) return const PagedResult(items: ['a'], hasMore: true);
        throw StateError('boom');
      },
    );
    await controller.loadFirstPage();
    await controller.loadMore();
    expect(controller.items, ['a']);
    expect(controller.failed, isFalse);
    expect(controller.isLoadingMore, isFalse);
    // 追加失败也暴露原始异常（调用方按需归一化），页码停在 1。
    expect(controller.error, isA<StateError>());
    expect(controller.page, 1);
  });

  test('reset 丢弃在途响应（过期请求不覆盖新状态）', () async {
    final gate = Completer<void>();
    var calls = 0;
    final controller = PagedListController<String>(
      fetchPage: (_) async {
        calls++;
        if (calls == 1) {
          await gate.future;
          return const PagedResult(items: ['stale'], hasMore: false);
        }
        return const PagedResult(items: ['fresh'], hasMore: false);
      },
    );
    final first = controller.loadFirstPage();
    controller.reset();
    await controller.loadFirstPage();
    expect(controller.items, ['fresh']);

    gate.complete();
    await first;
    expect(controller.items, ['fresh']);
  });
}
