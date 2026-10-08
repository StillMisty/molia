import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/discover_fetch.dart';

/// 发现适配器请求重试的显式策略测试面。
void main() {
  test('成功即返回，不重试', () async {
    var calls = 0;
    final result = await retryRequest<int>(
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
    final result = await retryRequest<int>(
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
    var calls = 0;
    await expectLater(
      retryRequest<int>(
        maxTries: 3,
        attempt: (_) async {
          calls++;
          return null;
        },
      ),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', 'try max num')),
    );
    expect(calls, 3);

    await expectLater(
      retryRequest<int>(
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
      retryRequest<int>(
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
}
