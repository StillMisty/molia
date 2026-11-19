import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:molia/platform/android/system_interop.dart';

/// Android 互操作基准（ADR-0038 阶段 2，手动运行，不进默认套件）：
///
/// ```bash
/// flutter test integration_test/interop_benchmark_test.dart -d <android-device>
/// ```
///
/// 口径：每次调用单独计时（含 Future 调度 / 通道往返），去掉前 100 次预热；
/// 报中位与 P99（微秒）。**不要**把首帧后的第一个通道调用算进来：引擎 / JVM /
/// 平台线程就绪约 400ms，那是固定成本，不是通道序列化成本。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const iterations = 10000;
  const warmup = 100;

  testWidgets('JNI vs MethodChannel 系统 getter 基准', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('MOLIA_BENCH skipped: 仅 Android 跑本基准');
      return;
    }

    const storageChannel = MethodChannel('top.stillmisty.molia/device_storage');

    // 只比较「读完就丢」的 getter 成本：JNI 侧走真实适配器（含平台守卫 /
    // 异常保护），通道侧走现有 device_storage handler。
    final jni = await _measure(iterations, warmup, () async {
      readTotalSpaceBytes();
    });
    final channel = await _measure(iterations, warmup, () async {
      await storageChannel.invokeMethod<num>('getTotalBytes');
    });

    _report('totalBytes jni', jni);
    _report('totalBytes channel', channel);
  });

  testWidgets('桌面歌词 4Hz 通道单次调用耗时（仅记录，不迁移）', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('MOLIA_BENCH skipped: 仅 Android 跑本基准');
      return;
    }

    // 4Hz 更新只发一次 `desktop.update`：这里测单次往返，判断是否值得改
    // direct interop。悬浮窗未显示时原生侧是 no-op，仍包含完整通道成本。
    const lyricsChannel = MethodChannel('top.stillmisty.molia/lyrics');
    try {
      final samples = await _measure(200, 20, () async {
        await lyricsChannel.invokeMethod<void>('desktop.update', const {
          'line': '基准',
          'next': '下一行',
          'progress': 0.5,
        });
      });
      _report('lyrics desktop.update', samples);
    } catch (error) {
      debugPrint('MOLIA_BENCH lyrics desktop.update unavailable: $error');
    }
  });
}

Future<List<int>> _measure(
  int iterations,
  int warmup,
  Future<void> Function() call,
) async {
  for (var i = 0; i < warmup; i++) {
    await call();
  }
  final samples = <int>[];
  final stopwatch = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    stopwatch
      ..reset()
      ..start();
    await call();
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds);
  }
  return samples;
}

void _report(String label, List<int> samples) {
  if (samples.isEmpty) return;
  final sorted = List<int>.of(samples)..sort();
  final median = sorted[sorted.length ~/ 2];
  final p99 = sorted[(sorted.length * 0.99).ceil() - 1];
  final mean = sorted.reduce((a, b) => a + b) / sorted.length;
  final maxIndex = math.min(sorted.length, 5);
  debugPrint(
    'MOLIA_BENCH $label n=${samples.length} '
    'median_us=$median p99_us=$p99 mean_us=${mean.toStringAsFixed(1)} '
    'min_us=${sorted.first} max_us=${sorted.last} '
    'slowest_top$maxIndex=${sorted.reversed.take(maxIndex).toList()}',
  );
}
