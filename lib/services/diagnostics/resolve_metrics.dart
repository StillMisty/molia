/// 取链会话指标：只在内存累计，进程重启清零（无持久化、无时间窗口）。
///
/// 只记数字与 [FailureKind]：**刻意不存** URL、payload、请求头或异常原文，
/// 因此可以安全地展示在设置页，也能随诊断包导出而不带出直链 / 凭证。
///
/// 线程模型：只在 UI isolate 内读写（LX 引擎、播放后端在自己的 isolate 里
/// 不计数），所以不加锁；计数器是单线程写、页面读的普通字段。
library;

import '../../domain/models/failure.dart';

/// 一份不可变计数快照：页面拿到的值不会被后续取链改写。
class ResolveMetricsSnapshot {
  const ResolveMetricsSnapshot({
    this.calls = 0,
    this.cacheHits = 0,
    this.retries = 0,
    this.successes = 0,
    this.failures = 0,
    this.timeouts = 0,
    this.failuresByKind = const {},
  });

  /// `resolve` 入口数（含缓存命中与单飞合并等待方）。
  final int calls;

  /// 入口中命中缓存的数量（含同 key 正在取链时的单飞等待）。
  final int cacheHits;

  /// 实际发起的重试次数（不含首次尝试）。
  final int retries;

  /// 真实取链成功次数（单飞合并的并发入口只算一次）。
  final int successes;

  /// 真实取链最终失败次数（重试后成功的不算失败）。
  final int failures;

  /// 预算硬截止触发次数（按真实取链计，不是按最终结果计）。
  ///
  /// 一次取链可能先被预算截断、重试后最终成功，所以它**不要求**落在 [failures]
  /// 里，可能大于 `failuresByKind[FailureKind.timeout]`；音源自己报的超时不计数。
  final int timeouts;

  /// 最终失败按类别计数（只含有失败记录的类别）。
  final Map<FailureKind, int> failuresByKind;

  /// 按次数降序（同次数按枚举声明顺序），页面直接按此顺序渲染。
  List<MapEntry<FailureKind, int>> get failureKinds {
    final entries = failuresByKind.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.index.compareTo(b.key.index);
      });
    return List.unmodifiable(entries);
  }
}

/// 取链指标累加器（目录服务写入，诊断页只读）。
class ResolveMetrics {
  ResolveMetrics();

  /// 组合根共享的「本次运行」实例。
  ///
  /// catalog 栈与诊断栈由组合根分开构造，两者之间只透传失败记录端口；
  /// 指标是进程级观测数据，用同一个默认实例承载，避免两个栈各持一份
  /// （那会让页面永远显示 0）。测试或自定义装配可以注入新实例，互不影响。
  static final ResolveMetrics session = ResolveMetrics();

  int _calls = 0;
  int _cacheHits = 0;
  int _retries = 0;
  int _successes = 0;
  int _failures = 0;
  int _timeouts = 0;
  final Map<FailureKind, int> _failuresByKind = {};

  /// 同步监听器：每次计数变化后立即回调（诊断页据此重建，不做节流）。
  ///
  /// 取链本身是低频操作（一次播放几次），回调里也只做一次通知，不需要
  /// 合并窗口；换成异步流反而会让页面在计数后多等一个事件循环。
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// `resolve` 被调用（未知音源这类编程错误不计）。
  void recordCall() {
    _calls++;
    _notify();
  }

  /// 入口命中取链缓存（含同 key 正在取链的单飞等待）。
  void recordCacheHit() {
    _cacheHits++;
    _notify();
  }

  /// 一次真实重试即将发起（退避等待之前调用）。
  void recordRetry() {
    _retries++;
    _notify();
  }

  /// 一次真实取链成功（重试后的成功也算，只记最终结果）。
  void recordSuccess() {
    _successes++;
    _notify();
  }

  /// 一次预算硬截止（不是音源自己报的超时）。
  ///
  /// 在截断发生时就记，不等最终结果：随后重试成功也保留这条「预算被用完过」的
  /// 信号，因此 [ResolveMetricsSnapshot.timeouts] 与失败计数不构成子集关系。
  void recordTimeout() {
    _timeouts++;
    _notify();
  }

  /// 一次取链最终失败；重试后成功的不调用。
  void recordFailure(FailureKind kind) {
    _failures++;
    _failuresByKind[kind] = (_failuresByKind[kind] ?? 0) + 1;
    _notify();
  }

  ResolveMetricsSnapshot snapshot() => ResolveMetricsSnapshot(
    calls: _calls,
    cacheHits: _cacheHits,
    retries: _retries,
    successes: _successes,
    failures: _failures,
    timeouts: _timeouts,
    failuresByKind: Map.unmodifiable(_failuresByKind),
  );

  /// 清空计数（测试 / 手动重置用；应用内没有调用点）。
  void reset() {
    _calls = 0;
    _cacheHits = 0;
    _retries = 0;
    _successes = 0;
    _failures = 0;
    _timeouts = 0;
    _failuresByKind.clear();
    _notify();
  }

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
