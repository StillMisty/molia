import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/cache/request_cache.dart';
import 'package:molia/data/catalog/cached_page_service.dart';
import 'package:molia/domain/models/failure.dart';

typedef _Query = ({String scope, String id});

const _query = (scope: 'album', id: '42');

String _prefixOf(_Query query) => '${query.scope}:${query.id}:';

CachedPageService<String, _Query> _build({
  required Future<String> Function(_Query query, int page, int limit) fetch,
  RequestCache? cache,
  Duration ttl = const Duration(minutes: 10),
}) => CachedPageService<String, _Query>(
  fetch: (query, {required page, required limit}) => fetch(query, page, limit),
  keyOf: (query, page, limit) => '${query.scope}:${query.id}:$page:$limit',
  maxEntries: 8,
  ttl: ttl,
  cache: cache,
);

/// 分页缓存服务：缓存命中 / 单飞 / 失败不缓存 / TTL / 前缀失效 / 错误归一化。
void main() {
  test('同 query / page 命中缓存，不再取数', () async {
    var calls = 0;
    final service = _build(
      fetch: (query, page, limit) async {
        calls++;
        return '$page/$limit';
      },
    );

    expect(await service.load(_query, page: 1, limit: 20), '1/20');
    expect(await service.load(_query, page: 1, limit: 20), '1/20');
    expect(calls, 1);
    expect(service.countPrefix(_prefixOf(_query)), 1);
  });

  test('并发同 key 只取数一次（single-flight）', () async {
    var calls = 0;
    final gate = Completer<void>();
    final service = _build(
      fetch: (query, page, limit) async {
        calls++;
        await gate.future;
        return 'v$page';
      },
    );

    final first = service.load(_query, page: 1, limit: 20);
    final second = service.load(_query, page: 1, limit: 20);
    expect(calls, 1);

    gate.complete();
    expect(await Future.wait([first, second]), ['v1', 'v1']);
    expect(calls, 1);
  });

  test('失败不缓存：异常归一化，下一次调用重试', () async {
    var calls = 0;
    final service = _build(
      fetch: (query, page, limit) async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return 'ok';
      },
    );

    await expectLater(
      service.load(_query, page: 1, limit: 20),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.unknown),
      ),
    );
    expect(service.countPrefix(_prefixOf(_query)), 0);

    expect(await service.load(_query, page: 1, limit: 20), 'ok');
    expect(calls, 2);
  });

  test('SourceFailure 原样透传（归一化幂等）', () async {
    const failure = SourceFailure(
      kind: FailureKind.unsupported,
      message: '不支持',
    );
    final service = _build(
      fetch: (query, page, limit) => Future.error(failure),
    );

    await expectLater(
      service.load(_query, page: 1, limit: 20),
      throwsA(same(failure)),
    );
  });

  test('invalidate 只清同 query 的全部页', () async {
    var calls = 0;
    final service = _build(
      fetch: (query, page, limit) async {
        calls++;
        return '${query.id}:$page';
      },
    );
    const other = (scope: 'album', id: 'other');

    await service.load(_query, page: 1, limit: 20);
    await service.load(_query, page: 2, limit: 20);
    await service.load(other, page: 1, limit: 20);
    expect(service.countPrefix(_prefixOf(_query)), 2);
    expect(service.countPrefix(_prefixOf(other)), 1);

    service.invalidatePrefix(_prefixOf(_query));
    expect(service.countPrefix(_prefixOf(_query)), 0);
    expect(service.countPrefix(_prefixOf(other)), 1);

    await service.load(_query, page: 1, limit: 20);
    expect(calls, 4, reason: '失效后重新取数');
  });

  test('注入缓存：TTL 到期后重新取数', () async {
    var now = DateTime(2026, 1, 1);
    var calls = 0;
    final cache = RequestCache(
      maxEntries: 8,
      ttl: const Duration(minutes: 1),
      clock: () => now,
    );
    final service = _build(
      fetch: (query, page, limit) async => 'v${++calls}',
      cache: cache,
    );

    expect(await service.load(_query, page: 1, limit: 20), 'v1');
    now = now.add(const Duration(seconds: 59));
    expect(await service.load(_query, page: 1, limit: 20), 'v1');
    now = now.add(const Duration(seconds: 2));
    expect(await service.load(_query, page: 1, limit: 20), 'v2');
    expect(calls, 2);
  });

  test('ttl 参数控制自建缓存：零 TTL 不命中', () async {
    var calls = 0;
    final service = _build(
      fetch: (query, page, limit) async => 'v${++calls}',
      ttl: Duration.zero,
    );

    expect(await service.load(_query, page: 1, limit: 20), 'v1');
    expect(await service.load(_query, page: 1, limit: 20), 'v2');
    expect(calls, 2);
  });
}
