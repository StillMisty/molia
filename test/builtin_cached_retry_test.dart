/// 传输层「缓存 + 重试」合并入口（[BuiltinTransport.cachedRetry]）的契约。
///
/// 它取代了发现适配器里 `transport.cached(...)` 套 `retryRequest(...)` 的两层
/// 写法；语义必须逐条保持：null = 本次失败继续重试、异常直接传播、用尽抛
/// [StateError]（message 是与上游约定的信号）、失败不进缓存。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

void main() {
  BuiltinTransport transport({int calls = 0, void Function()? onCall}) =>
      BuiltinTransport(client: MockClient((_) async {
        onCall?.call();
        return http.Response('{}', 200);
      }));

  test('成功即返回，不重试', () async {
    var calls = 0;
    final result = await transport(onCall: () => calls++).cachedRetry<int>(
      'k',
      maxTries: 3,
      attempt: (_) async {
        calls++;
        return 7;
      },
    );
    expect(result, 7);
    expect(calls, 1);
  });

  test('null 触发重试，直到成功', () async {
    var calls = 0;
    final result = await transport().cachedRetry<int>(
      'k',
      maxTries: 3,
      attempt: (tryNum) async {
        calls++;
        return tryNum == 1 ? 42 : null;
      },
    );
    expect(result, 42);
    expect(calls, 2);
  });

  test('用尽次数抛 StateError（message 可定制）', () async {
    await expectLater(
      transport().cachedRetry<int>(
        'k',
        maxTries: 3,
        attempt: (_) async => null,
      ),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', 'try max num')),
    );
    await expectLater(
      transport().cachedRetry<int>(
        'k2',
        maxTries: 2,
        message: 'link try max num',
        attempt: (_) async => null,
      ),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', 'link try max num')),
    );
  });

  test('异常直接向上抛（不吞错、不重试）', () async {
    var calls = 0;
    await expectLater(
      transport().cachedRetry<int>(
        'k',
        maxTries: 3,
        attempt: (_) async {
          calls++;
          throw UnsupportedError('nope');
        },
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(calls, 1);
  });

  test('命中缓存后不再执行 attempt（同一 transport 实例）', () async {
    var calls = 0;
    final instance = transport();
    Future<int> fetch() => instance.cachedRetry<int>(
          'same-key',
          maxTries: 2,
          attempt: (_) async {
            calls++;
            return 1;
          },
        );
    expect(await fetch(), 1);
    expect(await fetch(), 1);
    expect(calls, 1);
  });

  test('失败（重试耗尽）不缓存：下一次调用重新尝试', () async {
    var calls = 0;
    final instance = transport();
    Future<int> fetch() => instance.cachedRetry<int>(
          'fail-key',
          maxTries: 2,
          attempt: (_) async {
            calls++;
            return null;
          },
        );
    await expectLater(fetch(), throwsA(isA<StateError>()));
    await expectLater(fetch(), throwsA(isA<StateError>()));
    expect(calls, 4, reason: '失败不缓存：两次调用各重试 2 次');
  });
}
