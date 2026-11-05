/// 单渠道搜索结果的深模块：关键词 / 分页 / 失败归一 / 迟到渠道补首屏。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/providers/paged_list_controller.dart';
import 'package:molia/providers/search_results.dart';

void main() {
  test('同一异常身份只归一化一次', () async {
    var currentError = StateError('first');
    final controller = SearchResultsController<int>(
      failureLogLabel: () => 'test',
      fetchPage: (keyword, page) async => throw currentError,
    );
    addTearDown(controller.dispose);

    await controller.search('晴天');
    final firstFailure = controller.value.failure;
    expect(firstFailure?.message, contains('first'));
    expect(firstFailure?.kind, FailureKind.unknown);

    await controller.retry();
    expect(
      identical(controller.value.failure, firstFailure),
      isTrue,
      reason: '同一个异常对象在多次状态发布中复用已归一化结果',
    );

    currentError = StateError('second');
    await controller.retry();
    expect(identical(controller.value.failure, firstFailure), isFalse);
    expect(controller.value.failure?.message, contains('second'));
  });

  test('首屏失败重试首屏，追加页失败重试下一页', () async {
    final calls = <int>[];
    var failFirstPage = true;
    var failSecondPage = true;
    final controller = SearchResultsController<int>(
      failureLogLabel: () => 'test',
      fetchPage: (keyword, page) async {
        calls.add(page);
        if (page == 1) {
          if (failFirstPage) {
            throw const SourceFailure(
              kind: FailureKind.network,
              message: 'first',
            );
          }
          return const PagedResult(items: [1, 2], hasMore: true, total: 3);
        }
        if (failSecondPage) {
          throw const SourceFailure(
            kind: FailureKind.network,
            message: 'second',
          );
        }
        return const PagedResult(items: [3], hasMore: false, total: 3);
      },
    );
    addTearDown(controller.dispose);

    await controller.search('x');
    expect(calls, [1]);
    expect(controller.value.failure?.message, 'first');
    expect(controller.value.page, 0);

    failFirstPage = false;
    await controller.retry();
    expect(calls, [1, 1], reason: '首屏失败重试第一页');
    expect(controller.value.page, 1);
    expect(controller.value.items, [1, 2]);

    await controller.loadMore();
    expect(calls, [1, 1, 2]);
    expect(controller.value.loadMoreFailed, isTrue);
    expect(controller.value.failure, isNull, reason: '追加页失败不是首屏失败');
    expect(controller.value.page, 1);

    failSecondPage = false;
    await controller.retry();
    expect(calls, [1, 1, 2, 2], reason: '追加页失败重试下一页');
    expect(controller.value.loadMoreFailed, isFalse);
    expect(controller.value.page, 2);
    expect(controller.value.items, [1, 2, 3]);

    await controller.retry();
    expect(calls, [1, 1, 2, 2], reason: '没有失败时重试是 no-op');
  });

  test('canSearch 为假只记关键词；ensureFirstPage 在渠道晚到后补一次', () async {
    var available = false;
    var calls = 0;
    final controller = SearchResultsController<int>(
      failureLogLabel: () => 'test',
      canSearch: () => available,
      fetchPage: (keyword, page) async {
        calls++;
        return const PagedResult(items: [1], hasMore: false);
      },
    );
    addTearDown(controller.dispose);

    await controller.search('  x  ');
    expect(controller.keyword, 'x');
    expect(calls, 0, reason: '渠道不可搜索时不发请求');
    expect(controller.value.page, 0);
    expect(controller.value.isEmpty, isFalse, reason: '未搜索不是空结果');

    available = true;
    await controller.ensureFirstPage();
    expect(calls, 1);
    expect(controller.value.items, [1]);

    await controller.ensureFirstPage();
    expect(calls, 1, reason: '已有首屏不重复请求');

    controller.clear();
    expect(controller.keyword, isEmpty);
    expect(controller.value.items, isEmpty);
    expect(controller.value.page, 0);
    expect(controller.value.hasMore, isTrue);

    await controller.ensureFirstPage();
    expect(calls, 1, reason: '空关键词不补搜');
  });

  test('换词丢弃旧响应，新查询只落自身结果', () async {
    final oldGate = Completer<PagedResult<int>>();
    final controller = SearchResultsController<int>(
      failureLogLabel: () => 'test',
      fetchPage: (keyword, page) {
        if (keyword == '旧词') return oldGate.future;
        return Future.value(const PagedResult(items: [2], hasMore: false));
      },
    );
    addTearDown(controller.dispose);

    final stale = controller.search('旧词');
    await controller.search('新词');
    expect(controller.keyword, '新词');
    expect(controller.value.items, [2]);

    oldGate.complete(const PagedResult(items: [1], hasMore: false));
    await stale;
    expect(controller.keyword, '新词');
    expect(controller.value.items, [2], reason: '旧查询晚到不能覆盖新查询');
  });
}
