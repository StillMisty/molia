import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/perf/frame_stats.dart';

void main() {
  test('jank8 按 120Hz 帧预算（8.33ms）判定 work', () {
    final window = FrameWindow()
      ..add(buildMs: 6, rasterMs: 3, vsyncMs: 0, totalMs: 9) // work=9 → jank8
      ..add(buildMs: 4, rasterMs: 3, vsyncMs: 0, totalMs: 7); // work=7 → 不 jank

    final stats = window.take()!;
    expect(stats['jank8'], 1);
    expect(stats['jank16'], 0);
    expect(stats['jank33'], 0);
  });

  test('take() 输出 jank8 并清零', () {
    final window = FrameWindow()
      ..add(buildMs: 5, rasterMs: 5, vsyncMs: 0, totalMs: 10);

    expect(window.take()!['jank8'], 1);
    expect(window.take(), isNull);

    window.add(buildMs: 1, rasterMs: 1, vsyncMs: 0, totalMs: 2);
    expect(window.take()!['jank8'], 0);
  });
}
