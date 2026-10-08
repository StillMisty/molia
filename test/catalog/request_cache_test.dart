import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/cache/request_cache.dart';

void main() {
  group('RequestCache · single-flight', () {
    test('并发同 key 只执行一次 create，全部拿到同一结果', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      var calls = 0;
      final completer = Completer<String>();

      final futures = List.generate(
        5,
        (_) => cache.getOrCreate<String>('k', () {
          calls++;
          return completer.future;
        }),
      );

      expect(calls, 1, reason: 'create 应同步执行且仅一次');
      completer.complete('value');

      final results = await Future.wait(futures);
      expect(results, List.filled(5, 'value'));
      expect(calls, 1);
      expect(cache.length, 1);
    });

    test('完成后再次调用命中缓存（0 次 create）', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      var calls = 0;

      expect(await cache.getOrCreate('k', () async => ++calls), 1);
      expect(await cache.getOrCreate('k', () async => ++calls), 1);
      expect(calls, 1);
    });

    test('失败不缓存：下一次调用会重试', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      var calls = 0;

      await expectLater(
        cache.getOrCreate<int>('k', () async {
          calls++;
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(cache.containsKey('k'), isFalse);

      expect(
        await cache.getOrCreate('k', () async => ++calls),
        2,
      );
      expect(calls, 2);
    });

    test('并发失败共享同一错误，且后续可重试', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      final completer = Completer<int>();
      var calls = 0;

      final first = cache.getOrCreate<int>('k', () {
        calls++;
        return completer.future;
      });
      final second = cache.getOrCreate<int>('k', () {
        calls++;
        return completer.future;
      });
      expect(calls, 1);

      completer.completeError(StateError('shared'));
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(cache.containsKey('k'), isFalse);
    });
  });

  group('RequestCache · TTL', () {
    test('TTL 内命中、过期后重新执行', () async {
      var now = DateTime(2026, 1, 1);
      final cache = RequestCache(
        ttl: const Duration(minutes: 5),
        clock: () => now,
      );
      var calls = 0;

      expect(await cache.getOrCreate('k', () async => ++calls), 1);

      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(await cache.getOrCreate('k', () async => ++calls), 1);

      now = now.add(const Duration(seconds: 2)); // 累计 5min1s
      expect(await cache.getOrCreate('k', () async => ++calls), 2);
      expect(calls, 2);
    });

    test('TTL 从完成时刻起算（慢请求不立即过期）', () async {
      var now = DateTime(2026, 1, 1);
      final cache = RequestCache(
        ttl: const Duration(minutes: 5),
        clock: () => now,
      );
      var calls = 0;
      final completer = Completer<int>();

      final pending = cache.getOrCreate<int>('k', () {
        calls++;
        return completer.future;
      });
      now = now.add(const Duration(minutes: 10)); // 请求耗时超过 TTL
      completer.complete(1);
      expect(await pending, 1);

      expect(await cache.getOrCreate('k', () async => ++calls), 1,
          reason: '完成时刻才开始计时');
      expect(calls, 1);
    });
  });

  group('RequestCache · LRU', () {
    test('超容量淘汰最久未使用条目', () async {
      final cache = RequestCache(maxEntries: 2, ttl: const Duration(minutes: 5));
      final calls = <String, int>{};

      Future<String> create(String key) async {
        calls[key] = (calls[key] ?? 0) + 1;
        return key;
      }

      await cache.getOrCreate('a', () => create('a'));
      await cache.getOrCreate('b', () => create('b'));
      await cache.getOrCreate('a', () => create('a')); // touch a → b 最旧
      await cache.getOrCreate('c', () => create('c')); // 淘汰 b
      expect(cache.length, 2);

      expect(await cache.getOrCreate('a', () => create('a')), 'a');
      expect(await cache.getOrCreate('b', () => create('b')), 'b'); // miss
      expect(calls['a'], 1);
      expect(calls['b'], 2);
      expect(calls['c'], 1);
    });

    test('in-flight 条目不因容量压力被淘汰（单飞优先）', () async {
      final cache = RequestCache(maxEntries: 1, ttl: const Duration(minutes: 5));
      final completer = Completer<String>();
      var calls = 0;

      final pending = cache.getOrCreate<String>('pending', () {
        calls++;
        return completer.future;
      });
      // 容量 1：新条目进来时 pending 不可淘汰，允许短暂超出；
      // 'other' 完成后被容量回收，pending 保留。
      expect(await cache.getOrCreate('other', () async => 'other'), 'other');
      expect(cache.length, 1);
      expect(cache.containsKey('other'), isFalse);

      completer.complete('done');
      expect(await pending, 'done');
      expect(cache.length, 1);
      expect(calls, 1);
    });
  });

  group('RequestCache · invalidate', () {
    test('invalidate 单个 key', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      var calls = 0;

      await cache.getOrCreate('a', () async => ++calls);
      cache.invalidate('a');
      expect(cache.containsKey('a'), isFalse);
      await cache.getOrCreate('a', () async => ++calls);
      expect(calls, 2);
    });

    test('invalidatePrefix 只清理匹配前缀', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      final calls = <String, int>{};

      Future<String> create(String key) async {
        calls[key] = (calls[key] ?? 0) + 1;
        return key;
      }

      await cache.getOrCreate('search:kw:hello:1:30', () => create('s1'));
      await cache.getOrCreate('search:kw:world:1:30', () => create('s2'));
      await cache.getOrCreate('search:tx:hello:1:30', () => create('s3'));
      await cache.getOrCreate('url:kw:abc:320k', () => create('u1'));

      cache.invalidatePrefix('search:kw:');
      expect(cache.containsKey('search:kw:hello:1:30'), isFalse);
      expect(cache.containsKey('search:kw:world:1:30'), isFalse);
      expect(cache.containsKey('search:tx:hello:1:30'), isTrue);
      expect(cache.containsKey('url:kw:abc:320k'), isTrue);

      // 清理过的 key 重新执行，未清理的命中。
      await cache.getOrCreate('search:kw:hello:1:30', () => create('s1'));
      await cache.getOrCreate('search:tx:hello:1:30', () => create('s3'));
      expect(calls['s1'], 2);
      expect(calls['s3'], 1);
    });

    test('invalidate 命中 in-flight 条目后新请求独立执行', () async {
      final cache = RequestCache(ttl: const Duration(minutes: 5));
      var calls = 0;
      final completers = <Completer<String>>[];

      Future<String> create() {
        calls++;
        final completer = Completer<String>();
        completers.add(completer);
        return completer.future;
      }

      final first = cache.getOrCreate<String>('k', create);
      cache.invalidate('k');
      final second = cache.getOrCreate<String>('k', create);
      expect(calls, 2);

      completers[0].complete('first');
      completers[1].complete('second');
      expect(await first, 'first');
      expect(await second, 'second');
    });
  });
}
