import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/perf/frame_stats.dart';

void main() {
  test('FrameWindow 输出最近秩分位数并清空窗口', () {
    final window = FrameWindow();
    for (var i = 1; i <= 100; i++) {
      window.add(
        buildMs: i.toDouble(),
        rasterMs: i / 2,
        vsyncMs: 1,
        totalMs: i.toDouble(),
      );
    }

    final stats = window.take()!;
    expect(stats['frames'], 100);
    expect(stats['build_p50'], 50);
    expect(stats['build_p95'], 95);
    expect(stats['build_p99'], 99);
    expect(stats['jank16'], 89); // work = 1.5i > 16.7
    expect(stats['jank33'], 78); // work = 1.5i > 33.3
    expect(stats['latency16'], 84); // total = i > 16.7
    expect(stats['worst_ms'], 100);
    expect(window.take(), isNull);
  });

  test('小样本分位数不越界', () {
    final window = FrameWindow();
    window.add(buildMs: 8, rasterMs: 4, vsyncMs: 1, totalMs: 12);
    window.add(buildMs: 20, rasterMs: 10, vsyncMs: 2, totalMs: 30);

    final stats = window.take()!;
    expect(stats['build_p50'], 8);
    expect(stats['build_p95'], 20);
    expect(stats['build_p99'], 20);
    expect(stats['jank16'], 1);
    expect(stats['jank33'], 0);
  });
}
