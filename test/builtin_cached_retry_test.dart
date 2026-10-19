/// 内置端点「共享尝试循环 + 缓存包装」的契约。
///
/// [runBuiltinAttempts] 负责：成功即返回、null 重试、异常直接上抛、用尽抛
/// [StateError]、退避钩子；[BuiltinTransport.cachedRetry] 在其上叠加
/// single-flight 缓存（只有成功结果进缓存）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'support/mock_dio.dart';

void main() {
  BuiltinTransport transport() => BuiltinTransport(dio: mockDio((_) async {
        return textResponse('{}', statusCode: 200);
      }));

  group('共享尝试循环', () {
    test('成功即返回，不重试', () async {
      var calls = 0;
      final result = await runBuiltinAttempts<int>(
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
      final result = await runBuiltinAttempts<int>(
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
        runBuiltinAttempts<int>(
          maxTries: 3,
          attempt: (_) async => null,
        ),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'try max num')),
      );
      await expectLater(
        runBuiltinAttempts<int>(
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
        runBuiltinAttempts<int>(
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

    test('重试之间调用退避钩子，参数从 1 递增', () async {
      final delays = <int>[];
      final previous = BuiltinTransport.retryDelayOverride;
      BuiltinTransport.retryDelayOverride =
          (attempt) async => delays.add(attempt);
      addTearDown(() => BuiltinTransport.retryDelayOverride = previous);

      var calls = 0;
      final result = await runBuiltinAttempts<int>(
        maxTries: 3,
        attempt: (_) async => ++calls == 3 ? 7 : null,
      );
      expect(result, 7);
      expect(calls, 3);
      expect(delays, [1, 2]);
    });
  });

  group('cachedRetry', () {
    test('用尽次数抛 StateError（message 由包装层原样转发）', () async {
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

    test('实例注入的 retryDelay 参与重试（优先于全局钩子）', () async {
      final delays = <int>[];
      final instance = BuiltinTransport(
        dio: mockDio((_) async => textResponse('{}', statusCode: 200)),
        retryDelay: (attempt) async => delays.add(attempt),
      );
      var calls = 0;
      final result = await instance.cachedRetry<int>(
        'delay-key',
        maxTries: 3,
        attempt: (_) async => ++calls == 2 ? 1 : null,
      );
      expect(result, 1);
      expect(calls, 2);
      expect(delays, [1]);
    });
  });
}
