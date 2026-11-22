/// 最近失败记录的设备内历史：跨重启可见，写入去抖。
///
/// 只序列化类型化字段（时间、渠道 key / 展示名、类别、l10n key、retryable）。
/// `DiagnosticFailureRecord` 本身不含 message / payload / URL，所以这里不需要
/// 额外的脱敏；写入失败静默降级，历史只是排障辅助，不能阻断播放或退出。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../domain/models/diagnostics.dart';

final _logger = Logger('molia.diagnostics.history');

class DiagnosticsHistoryStore {
  DiagnosticsHistoryStore({
    DeviceSettings? settings,
    this.capacity = 20,
    this.debounce = const Duration(seconds: 2),
  }) : assert(capacity > 0),
       _settings = settings ?? DeviceSettings();

  final DeviceSettings _settings;
  final int capacity;

  /// 失败可能短时间连发；合并写入，避免每条都重写整个偏好 JSON。
  final Duration debounce;

  List<DiagnosticFailureRecord>? _pending;
  Timer? _timer;
  Future<void>? _drainFuture;
  bool _disposed = false;

  /// 读取历史（旧 → 新）；缺键 / 损坏 / 读取失败都返回空列表。
  Future<List<DiagnosticFailureRecord>> load() async {
    try {
      final stored =
          await _settings.readJsonList(kDiagnosticFailureHistoryKey) ??
          const [];
      final trimmed = stored.length > capacity
          ? stored.sublist(stored.length - capacity)
          : stored;
      return List<DiagnosticFailureRecord>.unmodifiable(trimmed);
    } catch (error) {
      _logger.warning('读取问题历史失败，按空历史处理: $error');
      return const [];
    }
  }

  /// 用最新快照排队写入；只保留 [capacity] 条且总是保留最新。
  ///
  /// 已有待写定时器时不重置：连续失败最多等 [debounce] 就落一次盘，不会因为
  /// 失败一直到来而永远推迟。
  void persist(Iterable<DiagnosticFailureRecord> records) {
    if (_disposed) return;
    final list = List<DiagnosticFailureRecord>.of(records);
    _pending = list.length > capacity
        ? list.sublist(list.length - capacity)
        : list;
    _schedule();
  }

  void _schedule() {
    if (_disposed || _pending == null) return;
    if (debounce <= Duration.zero) {
      unawaited(_drain());
      return;
    }
    if (_timer != null) return;
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_drain());
    });
  }

  /// 立即写完待写快照（导出 / 释放前调用）；失败不抛异常。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _drain();
  }

  Future<void> _drain() {
    final running = _drainFuture;
    if (running != null) return running;
    final future = _doDrain().whenComplete(() {
      _drainFuture = null;
      // 写入期间到达的新快照：继续排队（去抖 > 0 时重新起一个定时器）。
      _schedule();
    });
    _drainFuture = future;
    return future;
  }

  Future<void> _doDrain() async {
    while (_pending != null) {
      final pending = _pending!;
      _pending = null;
      try {
        await _settings.writeJsonList(kDiagnosticFailureHistoryKey, pending);
      } catch (error) {
        // DeviceSettings 自己已吞掉写失败；这里兜住极端实现，保持静默降级。
        _logger.warning('写入问题历史失败: $error');
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await flush();
  }
}
