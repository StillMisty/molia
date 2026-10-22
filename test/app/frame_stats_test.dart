import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/perf/frame_stats.dart';

void main() {
  test('FrameWindow 输出最近秩分位数并清空窗口', () {
    final window = FrameWindow();
    for (var i = 1; i <= 100; i++) {
      window.add(
        buildMs: i.toDouble(),
        rasterMs: i / 2,
        totalMs: i.toDouble(),
      );
    }

    final stats = window.take()!;
    expect(stats['frames'], 100);
    expect(stats['build_p50'], 50);
    expect(stats['build_p95'], 95);
    expect(stats['build_p99'], 99);
    expect(stats['jank16'], 84); // 17..100
    expect(stats['jank33'], 67); // 34..100
    expect(stats['worst_ms'], 100);
    expect(window.take(), isNull);
  });

  test('小样本分位数不越界', () {
    final window = FrameWindow();
    window.add(buildMs: 8, rasterMs: 4, totalMs: 12);
    window.add(buildMs: 20, rasterMs: 10, totalMs: 30);

    final stats = window.take()!;
    expect(stats['build_p50'], 8);
    expect(stats['build_p95'], 20);
    expect(stats['build_p99'], 20);
    expect(stats['jank16'], 1);
    expect(stats['jank33'], 0);
  });
}
