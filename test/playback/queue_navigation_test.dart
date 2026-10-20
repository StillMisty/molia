import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/queue_navigation.dart';

/// 列表循环 / 顺序播放的队列导航：区别只在于队尾（队首）是否回绕。
void main() {
  group('顺序播放', () {
    test('中间返回下一位，队尾返回 null', () {
      expect(nextQueueIndex(0, 3, wrap: false), 1);
      expect(nextQueueIndex(1, 3, wrap: false), 2);
      expect(nextQueueIndex(2, 3, wrap: false), isNull);
    });

    test('队首上一首返回 null，其余回退一位', () {
      expect(previousQueueIndex(0, 3, wrap: false), isNull);
      expect(previousQueueIndex(2, 3, wrap: false), 1);
    });
  });

  group('列表循环', () {
    test('队尾回到队首，单曲回到自己', () {
      expect(nextQueueIndex(0, 3, wrap: true), 1);
      expect(nextQueueIndex(2, 3, wrap: true), 0);
      expect(nextQueueIndex(0, 1, wrap: true), 0);
    });

    test('队首上一首回到队尾', () {
      expect(previousQueueIndex(0, 3, wrap: true), 2);
      expect(previousQueueIndex(1, 3, wrap: true), 0);
      expect(previousQueueIndex(0, 1, wrap: true), 0);
    });
  });

  test('空队列 / 越界下标返回 null', () {
    expect(nextQueueIndex(0, 0, wrap: true), isNull);
    expect(previousQueueIndex(0, 0, wrap: true), isNull);
    expect(nextQueueIndex(-1, 3, wrap: true), isNull);
    expect(nextQueueIndex(3, 3, wrap: true), isNull);
    expect(previousQueueIndex(-1, 3, wrap: true), isNull);
    expect(previousQueueIndex(3, 3, wrap: true), isNull);
  });
}
