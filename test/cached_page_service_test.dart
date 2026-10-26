import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/cached_page_service.dart';
import 'package:molia/domain/models/failure.dart';

typedef _Query = ({String scope, String id});

const _query = (scope: 'album', id: '42');

String _prefixOf(_Query query) => '${query.scope}:${query.id}:';

CachedPageService<String, _Query> _build({
  required Future<String> Function(_Query query, int page, int limit) fetch,
}) => CachedPageService<String, _Query>(
  fetch: (query, {required page, required limit}) => fetch(query, page, limit),
  keyOf: (query, page, limit) => '${query.scope}:${query.id}:$page:$limit',
  maxEntries: 8,
);

/// 分页缓存服务：key 透传 / 缓存命中 / 失败归一化 / 前缀失效与计数。
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
}
