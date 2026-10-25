import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';

/// 帧耗时统计（opt-in）。
///
/// 只在构建时打开 `--dart-define=MOLIA_PERF_TRACE=true` 才注册回调：正常包
/// 不产生任何 Timer / 日志 / 采样开销。`MOLIA_PERF_OUT` 可额外把每段汇总
/// 追加到 JSONL 文件，供 Windows / Android 这类控制台日志不易抓取的场景读取。
///
/// 为什么不用 DevTools 当唯一口径：体检需要在同一台机器上反复跑同一组场景，
/// 脚本要能直接读到 p50/p95/p99；DevTools 用于对最差帧做一次归因。
class FrameStats {
  FrameStats._();

  static final FrameStats instance = FrameStats._();

  static const bool enabled = bool.fromEnvironment('MOLIA_PERF_TRACE');

  static const String _outPath = String.fromEnvironment('MOLIA_PERF_OUT');

  static const Duration _reportInterval = Duration(seconds: 5);

  final Logger _logger = Logger('molia.frame');

  final FrameWindow _window = FrameWindow();

  bool _installed = false;
  String _scenario = 'app';
  Timer? _timer;

  /// 安装回调；未启用时直接返回（调用方无需判断）。
  void install() {
    if (!enabled || _installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(_reportInterval, (_) => reportNow());
  }

  /// 开始一个命名场景：丢弃暖场帧，后续帧都归到这个场景。
  ///
  /// 集成测试在每个场景前调用；不调用时默认 `app`（真实启动）。
  void beginScenario(String name) {
    if (!enabled) return;
    // 暖场窗口（首屏加载 / 上一场景尾巴）不计入本场景。
    _window.take();
    _scenario = name;
  }

  /// 立即汇总并输出当前窗口（空窗口不输出）。
  void reportNow([String? label]) {
    if (!enabled) return;
    final stats = _window.take();
    if (stats == null) return;
    final payload = <String, Object?>{
      'scenario': _scenario,
      'label': ?label,
      ...stats,
      'image_cache_mb': _imageCacheMb(),
    };
    final line = jsonEncode(payload);
    _logger.info(line);
    _appendToFile(payload);
  }

  /// 停止周期汇总（测试 / 调试用；正常应用不需要调用）。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      _window.add(
        buildMs: buildMs,
        rasterMs: rasterMs,
        vsyncMs: timing.vsyncOverhead.inMicroseconds / 1000,
        totalMs: timing.totalSpan.inMicroseconds / 1000,
      );
    }
  }

  double _imageCacheMb() {
    final bytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    return bytes / (1024 * 1024);
  }

  void _appendToFile(Map<String, Object?> payload) {
    if (_outPath.isEmpty) return;
    try {
      final file = File(_outPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${jsonEncode(payload)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // 观测失败不能影响应用；只打一次警告级别的日志。
      _logger.warning('帧统计写文件失败（继续运行）: $e');
    }
  }
}

/// 一个统计窗口：只保留分位数需要的样本，不逐帧留对象。
class FrameWindow {
  final List<double> _build = [];
  final List<double> _raster = [];
  final List<double> _work = [];
  final List<double> _vsync = [];
  final List<double> _total = [];
  int _jank16 = 0;
  int _jank33 = 0;
  int _latency16 = 0;
  double _worst = 0;

  void add({
    required double buildMs,
    required double rasterMs,
    required double vsyncMs,
    required double totalMs,
  }) {
    final workMs = buildMs + rasterMs;
    _build.add(buildMs);
    _raster.add(rasterMs);
    _work.add(workMs);
    _vsync.add(vsyncMs);
    _total.add(totalMs);
    // 判定「掉帧」看 build + raster（Flutter 官方口径）；totalSpan 还包含
    // vsync 等待 / 流水线延迟，正常 60Hz 帧也可能到 20ms，不能当卡顿。
    if (workMs > 16.7) _jank16++;
    if (workMs > 33.3) _jank33++;
    if (totalMs > 16.7) _latency16++;
    if (totalMs > _worst) _worst = totalMs;
  }

  /// 取走并清空；窗口内没有帧时返回 null。
  Map<String, Object?>? take() {
    if (_total.isEmpty) return null;
    final result = <String, Object?>{
      'frames': _total.length,
      'build_p50': _round(percentile(_build, 50)),
      'build_p95': _round(percentile(_build, 95)),
      'build_p99': _round(percentile(_build, 99)),
      'raster_p50': _round(percentile(_raster, 50)),
      'raster_p95': _round(percentile(_raster, 95)),
      'raster_p99': _round(percentile(_raster, 99)),
      'work_p50': _round(percentile(_work, 50)),
      'work_p95': _round(percentile(_work, 95)),
      'work_p99': _round(percentile(_work, 99)),
      'vsync_p95': _round(percentile(_vsync, 95)),
      'total_p50': _round(percentile(_total, 50)),
      'total_p95': _round(percentile(_total, 95)),
      'total_p99': _round(percentile(_total, 99)),
      'jank16': _jank16,
      'jank33': _jank33,
      'latency16': _latency16,
      'worst_ms': _round(_worst),
    };
    _build.clear();
    _raster.clear();
    _work.clear();
    _vsync.clear();
    _total.clear();
    _jank16 = 0;
    _jank33 = 0;
    _latency16 = 0;
    _worst = 0;
    return result;
  }

  /// 最近秩分位数（样本量小也不插值，避免报出实际不存在的帧耗时）。
  static double percentile(List<double> values, int p) {
    if (values.isEmpty) return 0;
    final ordered = List<double>.of(values)..sort();
    final rank = (p / 100 * ordered.length).ceil() - 1;
    return ordered[math.max(0, math.min(rank, ordered.length - 1))];
  }

  static double _round(double value) => (value * 100).roundToDouble() / 100;
}
