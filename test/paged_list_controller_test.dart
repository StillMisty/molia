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

  test('追加页去重后无新增：hasMore 推断为 false 并停止请求', () async {
    var calls = 0;
    final controller = PagedListController<String>(
      // 平台忽略 page：每次都返回整表。
      fetchPage: (page) async {
        calls++;
        return const PagedResult(items: ['a', 'b'], hasMore: true);
      },
      keyOf: (item) => item,
    );
    await controller.loadFirstPage();
    expect(controller.hasMore, isTrue);

    await controller.loadMore();
    expect(calls, 2);
    expect(controller.items, ['a', 'b'], reason: '整表重复返回，去重后无新增');
    expect(controller.page, 2, reason: '页码按请求推进（与既有语义一致）');
    expect(controller.hasMore, isFalse, reason: '无新增即到底');

    await controller.loadMore();
    expect(calls, 2, reason: '推断到底后不再请求');
  });

  test('状态值：一个值读全（首屏加载 → 追加失败）', () async {
    final gate = Completer<void>();
    final controller = PagedListController<String>(
      fetchPage: (page) async {
        if (page == 1) {
          await gate.future;
          return const PagedResult(items: ['a'], hasMore: true, total: 9);
        }
        throw StateError('boom');
      },
    );
    final notifications = <PagedListState<String>>[];
    controller.addListener(() => notifications.add(controller.state));

    final first = controller.loadFirstPage();
    expect(controller.state.isLoading, isTrue);
    gate.complete();
    await first;

    final loaded = controller.state;
    expect(loaded.items, ['a']);
    expect(loaded.page, 1);
    expect(loaded.total, 9);
    expect(loaded.hasMore, isTrue);
    expect(loaded.isLoading, isFalse);
    expect(loaded.isEmpty, isFalse);
    expect(loaded.error, isNull);

    await controller.loadMore();
    final failed = controller.state;
    expect(failed.loadMoreFailed, isTrue);
    expect(failed.failed, isFalse, reason: '追加失败不进入首屏错误态');
    expect(failed.items, ['a'], reason: '保留已加载项');
    expect(failed.page, 1);
    expect(failed.error, isA<StateError>());
    // 每个状态值变化各通知一次（成功路径不额外发布中间态）。
    expect(
      [
        for (final state in notifications)
          (state.isLoading, state.isLoadingMore)
      ],
      [(true, false), (false, false), (false, true), (false, false)],
    );
  });

  test('首屏失败：状态值清空（items/total/page），hasMore 复位可重试', () async {
    var fail = false;
    final controller = PagedListController<String>(
      fetchPage: (_) async {
        if (fail) throw StateError('boom');
        return const PagedResult(items: ['a'], hasMore: true, total: 9);
      },
    );
    await controller.loadFirstPage();
    fail = true;
    await controller.loadFirstPage(); // 刷新失败：清空并标记失败

    final failed = controller.state;
    expect(failed.failed, isTrue);
    expect(failed.items, isEmpty);
    expect(failed.total, isNull);
    expect(failed.page, 0, reason: '回到「尚未加载成功」');
    expect(failed.hasMore, isTrue, reason: '失败可重试');
    expect(failed.error, isA<StateError>());
  });

  test('dispose 使在途请求过期：销毁后不再发布状态', () async {
    final gate = Completer<void>();
    final controller = PagedListController<String>(
      fetchPage: (_) async {
        await gate.future;
        return const PagedResult(items: ['late'], hasMore: false);
      },
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final pending = controller.loadFirstPage();
    expect(notifications, 1, reason: '进入加载态');

    controller.dispose();
    gate.complete();
    // ChangeNotifier 禁止 dispose 后通知：过期响应必须被丢弃而不是回写。
    await pending;
    expect(notifications, 1);
    expect(controller.items, isEmpty);
  });
}
