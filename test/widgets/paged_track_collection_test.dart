import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/providers/paged_list_controller.dart';
import 'package:molia/widgets/paged_track_collection.dart';

/// 分页曲目集合：页实体捕获与 [PagedListController] 语义的接线。
void main() {
  test('首屏加载：实体与列表同步捕获，状态通知经集合转发', () async {
    final collection = PagedTrackCollection<String, String>(
      keyOf: (item) => item,
      loadPage: (page) async => PagedTrackPage(
        entity: 'entity-$page',
        items: ['p$page-a', 'p$page-b'],
        hasMore: page < 2,
        total: 4,
      ),
    );
    addTearDown(collection.dispose);
    final states = <PagedListState<String>>[];
    collection.addListener(() => states.add(collection.state));

    expect(collection.entity, isNull);
    await collection.loadFirstPage();

    expect(collection.entity, 'entity-1');
    expect(collection.items, ['p1-a', 'p1-b']);
    expect(collection.state.page, 1);
    expect(collection.state.total, 4);
    expect(collection.state.hasMore, isTrue);
    expect(collection.state.failed, isFalse);
    expect(states, isNotEmpty, reason: '控制器通知必须转发到集合');
    expect(states.last, collection.state);
  });

  test('loadMore：追加并按 key 去重，实体跟随最新成功页', () async {
    final requested = <int>[];
    final collection = PagedTrackCollection<String, String>(
      keyOf: (item) => item,
      loadPage: (page) async {
        requested.add(page);
        return PagedTrackPage(
          entity: 'entity-$page',
          items: page == 1 ? ['a', 'b'] : ['b', 'c'],
          hasMore: page < 2,
        );
      },
    );
    addTearDown(collection.dispose);

    await collection.loadFirstPage();
    expect(collection.entity, 'entity-1');
    expect(collection.items, ['a', 'b']);

    await collection.loadMore();
    expect(requested, [1, 2]);
    expect(collection.items, ['a', 'b', 'c'], reason: '跨页按 key 去重');
    expect(collection.entity, 'entity-2');
    expect(collection.state.hasMore, isFalse);

    await collection.loadMore();
    expect(requested, [1, 2], reason: '到底后不再请求');
  });

  test('首屏失败：failed 且无实体；重试恢复并捕获实体', () async {
    var calls = 0;
    final collection = PagedTrackCollection<String, String>(
      keyOf: (item) => item,
      loadPage: (_) async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return const PagedTrackPage(
          entity: 'entity-1',
          items: ['ok'],
          hasMore: false,
        );
      },
    );
    addTearDown(collection.dispose);

    await collection.loadFirstPage();
    expect(collection.state.failed, isTrue);
    expect(collection.items, isEmpty);
    expect(collection.entity, isNull);
    expect(collection.state.error, isA<StateError>());

    await collection.loadFirstPage();
    expect(collection.state.failed, isFalse);
    expect(collection.items, ['ok']);
    expect(collection.entity, 'entity-1');
    expect(collection.state.error, isNull);
  });

  test('加载更多失败：保留已加载项与实体，只置 loadMoreFailed', () async {
    final collection = PagedTrackCollection<String, String>(
      keyOf: (item) => item,
      loadPage: (page) async {
        if (page == 1) {
          return const PagedTrackPage(
            entity: 'entity-1',
            items: ['a'],
            hasMore: true,
          );
        }
        throw StateError('boom');
      },
    );
    addTearDown(collection.dispose);

    await collection.loadFirstPage();
    await collection.loadMore();

    expect(collection.items, ['a']);
    expect(collection.entity, 'entity-1', reason: '追加失败不覆盖头部实体');
    expect(collection.state.loadMoreFailed, isTrue);
    expect(collection.state.failed, isFalse);
    expect(collection.state.isLoadingMore, isFalse);
    expect(collection.state.page, 1);
    expect(collection.state.error, isA<StateError>());
  });

  test('reset：清空实体并丢弃在途响应（旧页不得覆盖新页）', () async {
    final gate = Completer<void>();
    var calls = 0;
    final collection = PagedTrackCollection<String, String>(
      keyOf: (item) => item,
      loadPage: (_) async {
        calls++;
        switch (calls) {
          case 1:
            return const PagedTrackPage(
              entity: 'entity-1',
              items: ['one'],
              hasMore: true,
            );
          case 2:
            await gate.future;
            return const PagedTrackPage(
              entity: 'stale',
              items: ['stale'],
              hasMore: false,
            );
          default:
            return const PagedTrackPage(
              entity: 'fresh',
              items: ['fresh'],
              hasMore: false,
            );
        }
      },
    );
    addTearDown(collection.dispose);

    await collection.loadFirstPage();
    expect(collection.entity, 'entity-1');

    final pending = collection.loadFirstPage();
    collection.reset();
    expect(collection.entity, isNull, reason: 'reset 同时清空页实体');
    expect(collection.items, isEmpty);

    await collection.loadFirstPage();
    expect(collection.entity, 'fresh');
    expect(collection.items, ['fresh']);

    gate.complete();
    await pending;
    expect(collection.entity, 'fresh', reason: '过期响应不得回写实体');
    expect(collection.items, ['fresh'], reason: '过期响应不得覆盖列表');
  });
}
