import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 热力图格子的形状裁剪基准（手动运行，不进默认套件）：
///
/// ```bash
/// flutter drive --profile -d linux \
///   --driver=test_driver/integration_test.dart \
///   --target=integration_test/morph_benchmark_test.dart
/// ```
///
/// 口径：单次调用用 `Stopwatch` 计时（微秒），预热后取中位 / P99。profile
/// （AOT）才有意义：debug / 单测 JIT 会整体放大，不能外推到用户帧预算。
/// `Morph.toPath` 的成本 = 每帧每个可见格子一次；168 格（7×24）只是下限，
/// 日历热力图还会乘可见周列数 × 7。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const iterations = 2000;
  const warmup = 200;

  // 与 `_MorphCellClipper` 同配方：Morph → Path → 适配格子尺寸。
  final morph = Morph(M3EMaterialNewShapes.square, M3EMaterialNewShapes.puffy);

  Path clipFor(double progress, Size size) {
    final source = morph.toPath(progress: progress);
    final bounds = source.getBounds();
    if (bounds.isEmpty) return Path();
    final matrix = Matrix4.identity()
      ..scaleByDouble(
        size.width / bounds.width,
        size.height / bounds.height,
        1,
        1,
      )
      ..translateByDouble(-bounds.left, -bounds.top, 0, 1);
    return source.transform(matrix.storage);
  }

  List<int> measure(int count, int skip, void Function(int index) action) {
    final samples = <int>[];
    final watch = Stopwatch();
    for (var i = 0; i < count + skip; i++) {
      watch
        ..reset()
        ..start();
      action(i);
      watch.stop();
      if (i >= skip) samples.add(watch.elapsedMicroseconds);
    }
    return samples;
  }

  ({double p50, double p99, double mean}) stats(List<int> samples) {
    final ordered = [...samples]..sort();
    double at(double p) =>
        ordered[math.min(ordered.length - 1, (ordered.length * p).floor())]
            .toDouble();
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    return (p50: at(0.5), p99: at(0.99), mean: mean);
  }

  void report(String label, ({double p50, double p99, double mean}) value) {
    debugPrint(
      'MOLIA_BENCH $label p50=${value.p50.toStringAsFixed(2)}us '
      'p99=${value.p99.toStringAsFixed(2)}us '
      'mean=${value.mean.toStringAsFixed(2)}us',
    );
  }

  testWidgets('Morph.toPath 与格子裁剪单次成本', (tester) async {
    // 真实动画会落在 0..1 的任意值；这里按 1/64 量化取值，覆盖整段。
    final progressValues = [for (var i = 0; i <= 64; i++) i / 64];
    double progressAt(int i) => progressValues[i % progressValues.length];

    // 只测温：Path 不参与后续绘制，避免闭包被优化掉。
    var sink = 0.0;
    final toPath = measure(
      iterations,
      warmup,
      (i) => sink += morph.toPath(progress: progressAt(i)).getBounds().width,
    );
    report('morph.toPath(progress)', stats(toPath));

    const size = Size(14, 14);
    final clip = measure(
      iterations,
      warmup,
      (i) => sink += clipFor(progressAt(i), size).getBounds().width,
    );
    report('cell clip (toPath+transform)', stats(clip));

    // 基准：只做一次 Path.transform（记忆化后每次裁剪只剩这一步）。
    final basePath = morph.toPath(progress: 0);
    final bounds = basePath.getBounds();
    final matrix = Matrix4.identity()
      ..scaleByDouble(
        size.width / bounds.width,
        size.height / bounds.height,
        1,
        1,
      )
      ..translateByDouble(-bounds.left, -bounds.top, 0, 1);
    final matrixStorage = matrix.storage;
    final transformOnly = measure(
      iterations,
      warmup,
      (i) => sink += basePath.transform(matrixStorage).getBounds().width,
    );
    report('path.transform only', stats(transformOnly));

    // 记忆化命中路径（与 `_MorphCellClipCache` 同一配方：LRU + 精确键）：
    // 生产实现里静止格子都命中这条分支，每次裁剪只剩一次查表。
    const cachedSize = Size(14, 14);
    final cachedKey = (0.0, cachedSize.width, cachedSize.height);
    final cache = <(double, double, double), Path>{cachedKey: basePath};
    final cached = measure(iterations, warmup, (i) {
      final hit = cache.remove(cachedKey)!;
      cache[cachedKey] = hit;
      sink += identical(hit, basePath) ? 1 : 0;
    });
    report('memoized clip lookup', stats(cached));

    debugPrint('MOLIA_BENCH sink=$sink');

    // 一帧里 168 个格子（作息热力图）的换算，便于直接对照 8.33ms 预算。
    final perCell = stats(clip).p50;
    debugPrint(
      'MOLIA_BENCH 168 cells @ clip p50 = '
      '${(perCell * 168 / 1000).toStringAsFixed(2)}ms',
    );
    expect(sink.isNaN, isFalse);
  });
}
