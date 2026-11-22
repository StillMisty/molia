import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/fade_envelope.dart';

void main() {
  group('fadeGainAt', () {
    test('端点精确：起点 / 终点不回弹', () {
      expect(
        fadeGainAt(
          elapsed: Duration.zero,
          duration: const Duration(milliseconds: 200),
          from: 0,
          to: 0.8,
        ),
        0,
      );
      expect(
        fadeGainAt(
          elapsed: const Duration(milliseconds: 200),
          duration: const Duration(milliseconds: 200),
          from: 0,
          to: 0.8,
        ),
        closeTo(0.8, 1e-9),
      );
      expect(
        fadeGainAt(
          elapsed: const Duration(milliseconds: 500),
          duration: const Duration(milliseconds: 200),
          from: 0,
          to: 0.8,
        ),
        closeTo(0.8, 1e-9),
        reason: '超时不越过目标',
      );
    });

    test('单调且两端平缓：中间点不与直线重合', () {
      const duration = Duration(milliseconds: 300);
      const from = 0.0;
      const to = 1.0;
      var previous = -1.0;
      for (var ms = 0; ms <= 300; ms += 5) {
        final value = fadeGainAt(
          elapsed: Duration(milliseconds: ms),
          duration: duration,
          from: from,
          to: to,
        );
        expect(value, greaterThanOrEqualTo(previous));
        expect(value, inInclusiveRange(0.0, 1.0));
        previous = value;
      }
      // smoothstep 在 25% 处约为 0.156，明显低于线性 0.25（起段更缓）。
      expect(
        fadeGainAt(
          elapsed: const Duration(milliseconds: 75),
          duration: duration,
          from: from,
          to: to,
        ),
        lessThan(0.2),
      );
    });

    test('反向淡出与中途起点：从当前电平出发，不先跳到端点', () {
      final value = fadeGainAt(
        elapsed: Duration.zero,
        duration: const Duration(milliseconds: 150),
        from: 0.6,
        to: 0,
      );
      expect(value, closeTo(0.6, 1e-9));
      final half = fadeGainAt(
        elapsed: const Duration(milliseconds: 75),
        duration: const Duration(milliseconds: 150),
        from: 0.6,
        to: 0,
      );
      expect(half, lessThan(0.6));
      expect(half, greaterThan(0));
    });

    test('短于可听窗口 / 零时长直接落到目标', () {
      expect(
        fadeGainAt(
          elapsed: Duration.zero,
          duration: const Duration(milliseconds: 30),
          from: 0.4,
          to: 1,
        ),
        1,
      );
      expect(
        fadeGainAt(
          elapsed: Duration.zero,
          duration: Duration.zero,
          from: 1,
          to: 0,
        ),
        0,
      );
      expect(
        const FadeRamp(
          from: 1,
          to: 0,
          duration: Duration(milliseconds: 30),
        ).isImmediate,
        isTrue,
      );
    });

    test('FadeRamp 固定自身时长并按已过时间取样', () {
      const ramp = FadeRamp(
        from: 1,
        to: 0,
        duration: Duration(milliseconds: 200),
      );
      expect(ramp.isImmediate, isFalse);
      expect(ramp.isComplete(const Duration(milliseconds: 199)), isFalse);
      expect(ramp.isComplete(const Duration(milliseconds: 200)), isTrue);
      expect(
        ramp.gainAt(const Duration(milliseconds: 100)),
        closeTo(0.5, 1e-9),
      );
    });
  });
}
