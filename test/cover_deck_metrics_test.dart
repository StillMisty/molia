import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/cover_deck_metrics.dart';

/// 封面堆叠尺寸预算：两轴同时约束 + 硬不变量（堆叠不越出可用区）。
///
/// 回归背景：预算原先手写在 `player.dart` 里（`可用宽 − 96` 直接当封面边长，
/// 堆叠再乘 1.38），1280×800 下堆叠需要 447 而列只有 420 —— 封面左右各越界
/// 约 32dp，压进侧栏与歌词列。
void main() {
  /// 真实版式的可用区三档 + 退化输入：宽高比从极扁到极窄。
  const cases = <(double, double)>[
    (420, 600), // 手机竖屏（容器扣掉标题/进度排后）
    (480, 900), // 桌面播放器列（480 宽）
    (900, 500), // 宽扁窗口：纵向成为约束
    (600, 400), // 平板两栏
    (200, 200), // 窄小
    (1, 1), // 极小
    (0, 0), // 无空间
    (double.infinity, 400), // 只受高度约束
    (400, double.infinity), // 只受宽度约束
    (double.infinity, double.infinity), // 两轴都无界
    (-40, -40), // 非法（负）输入
  ];

  test('不变量：堆叠宽 ≤ 可用宽、堆叠高 ≤ 可用高（且非负）', () {
    for (final (width, height) in cases) {
      final metrics = coverDeckMetricsFor(
        availableWidth: width,
        availableHeight: height,
      );
      final double maxWidth = max(0.0, width);
      final double maxHeight = max(0.0, height);
      final String reason = '可用区 = ($width, $height)';
      expect(metrics.artDimension, greaterThanOrEqualTo(0), reason: reason);
      expect(metrics.stackWidth, greaterThanOrEqualTo(0), reason: reason);
      expect(metrics.stackHeight, greaterThanOrEqualTo(0), reason: reason);
      if (maxWidth.isFinite) {
        expect(metrics.stackWidth, lessThanOrEqualTo(maxWidth), reason: reason);
      }
      if (maxHeight.isFinite) {
        expect(
          metrics.stackHeight,
          lessThanOrEqualTo(maxHeight),
          reason: reason,
        );
      }
      // 堆叠尺寸与封面边长同源：宿主两处取值不会漂移。
      expect(
        metrics.stackWidth,
        closeTo(metrics.artDimension * coverDeckHorizontalFactor, 1e-9),
        reason: reason,
      );
      expect(
        metrics.stackHeight,
        closeTo(metrics.artDimension * coverDeckVerticalFactor, 1e-9),
        reason: reason,
      );
    }
  });

  test('两轴约束取小者', () {
    // 480×900：按宽 320 < 按高 849 → 宽度约束。
    final byWidth = coverDeckMetricsFor(
      availableWidth: 480,
      availableHeight: 900,
    );
    expect(byWidth.artDimension, closeTo(480 / 1.5, 1e-9));
    expect(byWidth.stackHeight, lessThan(900));

    // 900×500：按宽 600 > 按高 471.7 → 高度约束。
    final byHeight = coverDeckMetricsFor(
      availableWidth: 900,
      availableHeight: 500,
    );
    expect(byHeight.artDimension, closeTo(500 / 1.06, 1e-9));
    expect(byHeight.stackHeight, closeTo(500, 1e-9));
    expect(byHeight.stackWidth, lessThan(900));
  });

  test('无限高的可用区只受宽度约束（含横向因子）', () {
    final metrics = coverDeckMetricsFor(
      availableWidth: 420,
      availableHeight: double.infinity,
    );
    expect(metrics.artDimension, closeTo(420 / 1.5, 1e-9));
    expect(metrics.stackWidth, closeTo(420, 1e-9));
  });

  test('退化输入：空间为零 / 为负 / 两轴都无界时不给尺寸', () {
    expect(
      coverDeckMetricsFor(availableWidth: 0, availableHeight: 0),
      (artDimension: 0.0, stackWidth: 0.0, stackHeight: 0.0),
    );
    expect(
      coverDeckMetricsFor(availableWidth: -40, availableHeight: -40),
      (artDimension: 0.0, stackWidth: 0.0, stackHeight: 0.0),
    );
    // 两轴都无界：无处安放，0 而不是无穷（无穷尺寸会炸布局）。
    expect(
      coverDeckMetricsFor(
        availableWidth: double.infinity,
        availableHeight: double.infinity,
      ),
      (artDimension: 0.0, stackWidth: 0.0, stackHeight: 0.0),
    );
  });

  test('回归：桌面列宽 480 的旧口径（可用宽 − 96 当封面边长）必然越界', () {
    const double column = 480;
    // 旧口径：预算里没除横向因子。列宽 480 时 art = 384、堆叠 = 530 > 480。
    const double legacyArt = column - 96;
    expect(legacyArt * 1.38, greaterThan(column), reason: '前提：旧口径越界');

    // 新口径：可用宽扣两侧内容内边距（24×2）后堆叠一定落在列内。
    final metrics = coverDeckMetricsFor(
      availableWidth: column - 24 * 2,
      availableHeight: 646,
    );
    expect(metrics.artDimension, closeTo(288, 0.5));
    expect(metrics.stackWidth, lessThanOrEqualTo(column));
  });
}
