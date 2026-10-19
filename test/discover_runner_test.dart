/// 发现端点 runner（[runDiscoverCall]）的契约。
///
/// 钉住四件事：缓存命中 / key 隔离、无效响应触发重试、异常不重试直接上抛、
/// 预算与 message 转发；以及无 key 端点只重试不缓存、多步尝试的 tryNum 透传。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/discover_runner.dart';
import 'support/mock_dio.dart';

void main() {
  late BuiltinTransport original;

  setUp(() {
    original = BuiltinSearch.transport;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse('{}', statusCode: 200)),
    );
  });

  tearDown(() {
    BuiltinSearch.transport = original;
  });

  test('有 key：命中缓存，不再执行 request', () async {
    var requests = 0;
    Future<int> run() => runDiscoverCall(DiscoverRequestCall<int>(
          key: 'test:cache',
          request: () async {
            requests++;
            return 'payload';
          },
          isInvalid: (_) => false,
          parse: (_) => 7,
        ));

    expect(await run(), 7);
    expect(await run(), 7);
    expect(requests, 1);
  });

  test('缓存按 key 隔离：不同 key 各自请求', () async {
    var requests = 0;
    Future<int> run(String key) => runDiscoverCall(DiscoverRequestCall<int>(
          key: key,
          request: () async {
            requests++;
            return requests;
          },
          isInvalid: (_) => false,
          parse: (response) => response as int,
        ));

    expect(await run('test:key-a'), 1);
    expect(await run('test:key-b'), 2);
    expect(await run('test:key-a'), 1, reason: 'a 应命中缓存');
    expect(requests, 2);
  });

  test('无效响应触发重试，直到解析成功', () async {
    var requests = 0;
    final result = await runDiscoverCall(DiscoverRequestCall<int>(
      key: 'test:invalid',
      request: () async {
        requests++;
        return requests;
      },
      isInvalid: (response) => response == 1,
      parse: (response) => response as int,
    ));

    expect(result, 2);
    expect(requests, 2);
  });

  test('parse 返回 null 也视为本次失败并重试', () async {
    var requests = 0;
    final result = await runDiscoverCall(DiscoverRequestCall<int>(
      key: 'test:parse-null',
      request: () async {
        requests++;
        return requests;
      },
      isInvalid: (_) => false,
      parse: (response) => response == 1 ? null : response as int,
    ));

    expect(result, 2);
    expect(requests, 2);
  });

  test('request / parse 异常直接上抛，不重试', () async {
    var requestCalls = 0;
    await expectLater(
      runDiscoverCall(DiscoverRequestCall<int>(
        key: 'test:request-error',
        request: () async {
          requestCalls++;
          throw UnsupportedError('request failed');
        },
        isInvalid: (_) => false,
        parse: (_) => 1,
      )),
      throwsA(isA<UnsupportedError>()),
    );
    expect(requestCalls, 1);

    var parseCalls = 0;
    await expectLater(
      runDiscoverCall(DiscoverRequestCall<int>(
        key: 'test:parse-error',
        request: () async => 'ok',
        isInvalid: (_) => false,
        parse: (_) {
          parseCalls++;
          throw UnsupportedError('parse failed');
        },
      )),
      throwsA(isA<UnsupportedError>()),
    );
    expect(parseCalls, 1);
  });

  test('预算与 message 原样转发给共享尝试循环', () async {
    var requests = 0;
    await expectLater(
      runDiscoverCall(DiscoverRequestCall<int>(
        key: 'test:budget',
        budget: BuiltinRetryBudget.leaderboard,
        message: 'custom max num',
        request: () async {
          requests++;
          return null;
        },
        isInvalid: (_) => true,
        parse: (_) => 1,
      )),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', 'custom max num')),
    );
    expect(requests, BuiltinRetryBudget.leaderboard);
  });

  test('无 key：只重试不缓存，每次调用都重新请求', () async {
    var requests = 0;
    Future<int> run() => runDiscoverCall(DiscoverRequestCall<int>(
          key: null,
          request: () async {
            requests++;
            return 1;
          },
          isInvalid: (_) => false,
          parse: (_) => 1,
        ));

    expect(await run(), 1);
    expect(await run(), 1);
    expect(requests, 2, reason: '无稳定 key 时不套缓存');
  });

  test('多步尝试拿到 tryNum，null 继续重试', () async {
    final tries = <int>[];
    final result = await runDiscoverCall(DiscoverAttemptCall<int>(
      key: 'test:attempt',
      attempt: (tryNum) async {
        tries.add(tryNum);
        return tryNum == 1 ? 5 : null;
      },
    ));

    expect(result, 5);
    expect(tries, [0, 1]);
  });
}
