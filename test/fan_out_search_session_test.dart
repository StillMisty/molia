/// 跨来源扇出搜索协议：查询代际、失败重试、不可用来源、稳定排序、选中失效、
/// 通知合并与 dispose 安全。两个消费面（换源 / 手动歌词换源）共用这份实现。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/providers/fan_out_search_session.dart';

/// 最简结果类型：只带来源 key 与平台内 id。
class _Hit {
  const _Hit(this.source, this.id);

  final String source;
  final String id;

  @override
  String toString() => '$source:$id';
}

/// 可控来源：按测试需要立即返回、挂起或抛错。
class _Source {
  _Source(this.key, {this.available = true});

  final String key;
  bool available;
  int calls = 0;
  Future<List<_Hit>> Function(String query)? onSearch;
  final List<Completer<List<_Hit>>> pending = [];

  FanOutSource<_Hit> get adapter => FanOutSource<_Hit>(
    key: key,
    isAvailable: () => available,
    search: (query) {
      calls++;
      return onSearch!(query);
    },
    sourceKeyOf: (hit) => hit.source,
  );

  /// 挂起本次调用，等测试放行。
  Future<List<_Hit>> queue(String query) {
    final completer = Completer<List<_Hit>>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FanOutSearchSession<_Hit> buildSession(List<_Source> sources) {
    final session = FanOutSearchSession<_Hit>(
      sources: () => [for (final source in sources) source.adapter],
    );
    addTearDown(session.dispose);
    return session;
  }

  test('旧查询晚到的结果被丢弃，不覆盖新查询', () async {
    final first = _Source('a');
    final second = _Source('b');
    first.onSearch = first.queue;
    second.onSearch = second.queue;
    final session = buildSession([first, second]);

    final stale = session.search('旧查询');
    final current = session.search('新查询');
    expect(first.pending, hasLength(2));
    expect(second.pending, hasLength(2));

    first.pending[1].complete([const _Hit('a', 'new-a')]);
    second.pending[1].complete([const _Hit('b', 'new')]);
    await current;
    expect(session.resultsOf('a').single.id, 'new-a');
    expect(session.resultsOf('b').single.id, 'new');
    expect(session.query, '新查询');

    first.pending[0].complete([const _Hit('a', 'old')]);
    second.pending[0].complete([const _Hit('b', 'old')]);
    await stale;

    expect(session.resultsOf('a').single.id, 'new-a', reason: '旧查询结果不能落回列表');
    expect(session.resultsOf('b').single.id, 'new', reason: '旧查询晚到不能覆盖新查询');
  });

  test('retryFailed 只重搜失败源，成功源不重复请求', () async {
    var flakyFails = true;
    final good = _Source('good')
      ..onSearch = (_) async => [const _Hit('good', 'g-1')];
    final flaky = _Source('flaky')
      ..onSearch = (_) async {
        if (flakyFails) throw StateError('network down');
        return [const _Hit('flaky', 'f-1')];
      };
    final session = buildSession([good, flaky]);

    await session.search('晴天');
    expect(session.statusOf('good'), FanOutSourceStatus.loaded);
    expect(session.statusOf('flaky'), FanOutSourceStatus.error);
    expect(session.failedKeys, {'flaky'});
    expect(good.calls, 1);

    flakyFails = false;
    await session.retryFailed();

    expect(flaky.calls, 2);
    expect(good.calls, 1, reason: '重试不重搜成功来源');
    expect(session.failedKeys, isEmpty);
    expect(session.statusOf('flaky'), FanOutSourceStatus.loaded);
    expect(session.resultsOf('flaky').single.id, 'f-1');
    expect(session.query, '晴天', reason: '重试不改变查询');
  });

  test('不可用来源不发请求但保留状态；空结果是成功', () async {
    final qq = _Source('qq')..onSearch = (_) async => [];
    final bili = _Source('bili', available: false)
      ..onSearch = (_) async => [const _Hit('bili', 'never')];
    final session = buildSession([qq, bili]);

    await session.search('晴天');

    expect(bili.calls, 0, reason: '不可用来源不发请求');
    expect(session.statusOf('bili'), FanOutSourceStatus.unavailable);
    expect(session.resultsOf('bili'), isEmpty);
    expect(
      session.statusOf('qq'),
      FanOutSourceStatus.loaded,
      reason: '空结果是成功而不是失败',
    );
    expect(session.failedKeys, isEmpty);
    expect(session.isSearching, isFalse);
  });

  test('结果按来源声明顺序拼接，不随完成顺序变化', () async {
    final a = _Source('a');
    final b = _Source('b');
    final c = _Source('c');
    a.onSearch = a.queue;
    b.onSearch = b.queue;
    c.onSearch = c.queue;
    final session = buildSession([a, b, c]);

    final pending = session.search('排序');
    c.pending.single.complete([const _Hit('c', '3')]);
    b.pending.single.complete([const _Hit('b', '2')]);
    a.pending.single.complete([const _Hit('a', '1')]);
    await pending;

    expect(session.sources.map((source) => source.key), ['a', 'b', 'c']);
    expect(session.allResults.map((hit) => '${hit.source}:${hit.id}'), [
      'a:1',
      'b:2',
      'c:3',
    ], reason: '完成顺序 c → b → a 不能改变展示顺序');
    expect(session.failedKeys, isEmpty, reason: '全部成功时不应留下失败来源');
  });

  test('选中项随查询替换失效；重试其它来源不误清选中', () async {
    var bFails = true;
    final a = _Source('a')..onSearch = (_) async => [const _Hit('a', '1')];
    final b = _Source('b')
      ..onSearch = (_) async {
        if (bFails) throw StateError('boom');
        return [const _Hit('b', '2')];
      };
    final session = buildSession([a, b]);

    await session.search('晴天');
    final selected = session.resultsOf('a').single;
    session.select(selected);
    expect(session.selected, same(selected));

    // b 失败后重试成功：a 的选中项不属于被重试来源，必须保留。
    bFails = false;
    await session.retryFailed();
    expect(session.resultsOf('b'), hasLength(1));
    expect(session.selected, same(selected), reason: '其它来源重试成功不能清掉当前选中项');

    await session.search('另一首');
    expect(session.selected, isNull, reason: '查询变化要同步清掉旧选中项');

    session.select(session.resultsOf('a').single);
    session.clear();
    expect(session.selected, isNull, reason: '清空结果时选中项一起失效');
    expect(session.query, isEmpty);
    expect(session.resultsOf('a'), isEmpty);
    expect(session.statusOf('a'), FanOutSourceStatus.idle);
  });

  test('同一轮事件循环内的来源完成合并为一次通知', () async {
    final a = _Source('a');
    final b = _Source('b');
    a.onSearch = a.queue;
    b.onSearch = b.queue;
    final session = buildSession([a, b]);
    var notifications = 0;
    session.addListener(() => notifications++);

    final pending = session.search('合并');
    expect(notifications, 1, reason: '查询开始立即通知');

    // 两个来源在同一轮微任务里完成：只合并出一次重建。
    a.pending.single.complete([const _Hit('a', '1')]);
    b.pending.single.complete([const _Hit('b', '2')]);
    await pending;
    await pumpEventQueue();

    expect(notifications, 2, reason: '开始 1 次 + 两个完成合并 1 次');
    expect(session.allResults, hasLength(2));

    session.select(session.resultsOf('a').single);
    expect(notifications, 3, reason: '选中变化立即通知');
  });

  test('dispose 后到达的结果与后续调用都安全', () async {
    final gate = _Source('slow');
    gate.onSearch = gate.queue;
    final session = FanOutSearchSession<_Hit>(sources: () => [gate.adapter]);
    var notifications = 0;
    session.addListener(() => notifications++);

    final pending = session.search('迟到');
    expect(notifications, 1);
    session.dispose();

    gate.pending.single.complete([const _Hit('slow', '1')]);
    await pending;
    await pumpEventQueue();

    expect(notifications, 1, reason: 'dispose 后不能再通知');
    await session.search('另一首');
    session.select(const _Hit('slow', '1'));
    session.clear();
    session.notifyNow();
    expect(session.selected, isNull);
    expect(session.resultsOf('slow'), isEmpty);
  });
}
