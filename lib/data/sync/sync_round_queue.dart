/// 同步轮次的唯一排队 / 串行 / 交付台账。
///
/// 职责边界：
/// - **排队**：待跑请求（触发原因 / 外发 / anti-entropy / 类别范围）与在途
///   轮次；请求落在在途轮次上时合并成至多一个补跑轮，绝不并发两轮；
/// - **交付**：唯一的 delivered 判据（见 [SyncRoundQueue.classify]）与按类别
///   清待发标记；
/// - **调度器只管「何时」**：定时器 / 退避 / 重连阶梯仍在 `SyncScheduler`，
///   它把「跑一轮」交给宿主（生产 = `SyncEngine`），而宿主把请求交给本队列。
///
/// 这里不碰状态持久化：轮末提交仍由引擎完成，`SyncStateStore` 依旧是唯一
/// 状态所有者；队列只是内存中的执行顺序与交付事实。
library;

import 'dart:async';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';

/// 跑一轮的实际实现（生产 = `SyncEngine` 的轮次编排 + 轮末提交）。
typedef SyncRoundExecutor = Future<SyncRoundReport> Function(
  SyncQueuedRound round,
);

/// 一轮的实际执行参数（首轮与补跑轮同形）。
///
/// 每个请求各自携带 [push] 与 [onlyCategories]：请求并入补跑时按
/// [SyncRoundQueue] 的合并规则求出补跑轮的参数，同一段链里的不同轮可以
/// 有不同的外发范围（例如入站轮只拉不推，随后补跑的手动轮要推送全部类别）。
class SyncQueuedRound {
  const SyncQueuedRound({
    required this.trigger,
    required this.push,
    required this.antiEntropy,
    required this.onlyCategories,
  });

  final SyncTrigger trigger;
  final bool push;
  final bool antiEntropy;
  final Set<SyncCategory>? onlyCategories;
}

/// 一轮的交付事实（全仓唯一的 delivered 定义）。
///
/// `delivered` 只表示「这一轮真的把范围内的改动交给了可用的传输，且没有一路
/// 启用的传输报告失败」：
/// - 结论是 `ok` / `noChanges`（`partial` / `failed` 保守地不算交付：传输
///   报告是逐对端收敛证据，部分失败时无法确认改动已到达每个对端）；
/// - 本轮确实外发（`push: false` 的入站 / 只拉轮不算交付）；
/// - 至少一路**启用**传输有真实传输证据：本轮开始时有待发类别时，要求一路
///   启用传输 `pushed > 0 || skippedUnchanged > 0`（纯 `peersSeen` 不算，避免
///   空轮吞掉本地变更）；没有待发类别时，`succeeded` 的接触就足够（没有要清
///   的标记）。未启用的传输不提供成功证据，也不参与判据；
/// - **没有一路启用的传输**带失败 / 不可用证据（未运行、`unavailableReason`、
///   失败计数或 `error`）：局域网成功 + WebDAV 推送失败、或 WebDAV 成功 +
///   局域网不可用，都不能清掉待发。
///
/// `noPeers` 没有接触任何对端，因此**不是**交付；`categories` 为本轮类别范围
/// （协议只有逐对端回执，类别范围是可得的最细粒度）。
class SyncRoundDelivery {
  const SyncRoundDelivery({
    required this.categories,
    required this.contacted,
    required this.contactedLan,
  });

  /// 本轮真正交付的类别范围（未交付 = 空集）。清待发标记只清这些类别。
  final Set<SyncCategory> categories;

  /// 本轮是否探测到任何对端（重连阶梯用；与交付判据不同）。
  final bool contacted;

  /// 本轮是否探测到局域网对端（重连阶梯据此立即取消）。
  final bool contactedLan;

  /// 本轮是否交付了任何类别。
  bool get delivered => categories.isNotEmpty;
}

/// 同步轮次队列：待跑请求、在途轮次、补跑合并与待外发类别台账。
///
/// 引擎只保留公共门面与轮末提交；调度器只保留「何时跑」。两处对「下一轮跑
/// 什么」「哪些类别已经交付」的问题都问这个对象。
class SyncRoundQueue {
  SyncRoundQueue({
    required this._runRound,
    required this._enabledCategories,
    this._onChanged,
  });

  final SyncRoundExecutor _runRound;
  final Set<SyncCategory> Function() _enabledCategories;
  final void Function()? _onChanged;

  /// 待外发的类别（空 = 没有本地变更待发）。
  final Set<SyncCategory> _dirty = {};

  /// 其中「需要即时外发」的类别（高优先级变更；低优先级只标记不排轮次）。
  final Set<SyncCategory> _immediate = {};

  /// 本轮执行期间又被标记的类别：本轮交付不能清掉它们（用户的改动发生在本轮
  /// 快照之后，必须留给下一轮）。
  final Set<SyncCategory> _changedDuringRound = {};

  bool _running = false;

  /// 在途轮次期间到达的请求：合并成一次补跑（见 [_PendingRound.mergedWith]）。
  _PendingRound? _pending;

  /// 补跑请求的等待者：每个请求都在**补跑轮**跑完后拿到该轮报告。
  final List<Completer<SyncRoundReport?>> _waiters = [];

  /// 是否已有一段轮次链在跑（同一时刻至多一段）。
  bool get running => _running;

  /// 是否还有未外发的本地变更（关闭的类别不算）。
  bool get dirty {
    final enabled = _enabledCategories();
    return _dirty.any(enabled.contains);
  }

  /// 待外发的类别（观测与测试用；已关闭类别动态过滤）。
  Set<SyncCategory> get dirtyCategories {
    final enabled = _enabledCategories();
    return Set.unmodifiable(_dirty.where(enabled.contains));
  }

  /// 是否存在高优先级待发变更（调度器据此排去抖轮次；关闭的类别不算）。
  bool get hasImmediate {
    final enabled = _enabledCategories();
    return _immediate.any(enabled.contains);
  }

  /// 标记本地变更：只记类别，不直接跑轮次（何时跑由调度器决定）。
  ///
  /// [categories] 省略时标记全部启用类别；[immediate] 为 false 时只标记、
  /// 不进入即时集合（高频写入如播放会话进度用）。在途轮次期间标记的类别会
  /// 记进 [_changedDuringRound]，本轮交付不会清掉它们。
  void markLocalChange({Set<SyncCategory>? categories, bool immediate = true}) {
    final enabled = _enabledCategories();
    final pending = categories == null
        ? enabled
        : categories.intersection(enabled);
    _dirty.addAll(pending);
    if (immediate) _immediate.addAll(pending);
    if (_running) _changedDuringRound.addAll(pending);
  }

  /// 丢弃已关闭类别的待发标记（关闭后不再外发，不必等下一轮失败）。
  ///
  /// 公开读接口已经动态过滤关闭类别；这里只清理内部集合（调度器在环境刷新
  /// 与每轮结束后调用）。
  void pruneDisabledCategories() {
    final enabled = _enabledCategories();
    _dirty.removeWhere((category) => !enabled.contains(category));
    _immediate.removeWhere((category) => !enabled.contains(category));
  }

  /// 发起一段轮次链；已有轮次在跑时改为加入补跑（绝不并发）。
  ///
  /// 返回**这次请求所加入的那一轮**的报告：没有在途轮次时是这段链的最后一轮；
  /// 有在途轮次时是补跑轮的报告。同步关闭 / 没有可跑轮次由调用方在进队列前
  /// 判断并返回 null。
  Future<SyncRoundReport?> run({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  }) {
    final request = _PendingRound.request(
      trigger: trigger,
      push: push,
      antiEntropy: antiEntropy,
      onlyCategories: onlyCategories,
    );
    if (_running) return _enqueue(request);
    _running = true;
    _onChanged?.call();
    return _drain(request);
  }

  /// 把请求并入下一次补跑，返回补跑轮的报告（供调用方等待）。
  ///
  /// 没有在途轮次时抛 [StateError]：释放模式里 assert 不生效，静默排队会让
  /// 请求永远没有轮次来消费。
  Future<SyncRoundReport?> enqueue({
    required SyncTrigger trigger,
    required bool push,
    bool antiEntropy = false,
    Set<SyncCategory>? onlyCategories,
  }) {
    if (!_running) {
      throw StateError('同步轮次队列没有在途轮次：请求必须由宿主在轮次内并入');
    }
    return _enqueue(
      _PendingRound.request(
        trigger: trigger,
        push: push,
        antiEntropy: antiEntropy,
        onlyCategories: onlyCategories,
      ),
    );
  }

  /// 只合并补跑请求、不等待报告（入站推送 / 公告唤醒这类 fire-and-forget）。
  ///
  /// 没有在途轮次时抛 [StateError]（原因同 [enqueue]）。
  void schedule({
    required SyncTrigger trigger,
    required bool push,
    bool antiEntropy = false,
    Set<SyncCategory>? onlyCategories,
  }) {
    if (!_running) {
      throw StateError('同步轮次队列没有在途轮次：请求必须由宿主在轮次内并入');
    }
    _merge(
      _PendingRound.request(
        trigger: trigger,
        push: push,
        antiEntropy: antiEntropy,
        onlyCategories: onlyCategories,
      ),
    );
  }

  /// 唯一的交付判定：把一轮报告翻译成「哪些类别真的交付了」。
  ///
  /// [dirtyAtStart] 是本轮开始时的待发类别快照；非空时要求真实的推送 / 未变
  /// 跳过证据（纯 `peersSeen` 不算），避免「看到了对端但没传任何东西」把待发
  /// 标记清掉。成功证据只认**启用**传输；任何一路启用传输有失败 / 不可用证据，
  /// 本轮整体不算交付（见 [SyncRoundDelivery]）。传输报告只有对端粒度（协议
  /// 没有逐类别回执），因此「本轮类别范围」就是可得的最细粒度：范围外（例如
  /// 蜂窝小类别轮之外的历史 / 统计）继续保留待发。
  SyncRoundDelivery classify(
    SyncRoundReport report, {
    required bool push,
    Set<SyncCategory>? onlyCategories,
    Set<SyncCategory> dirtyAtStart = const {},
  }) => _classifyInScope(
    report,
    push: push,
    scope: _scopeOf(onlyCategories),
    dirtyAtStart: dirtyAtStart,
  );

  Future<SyncRoundReport?> _drain(_PendingRound first) async {
    var next = first;
    SyncRoundReport? report;
    List<Completer<SyncRoundReport?>>? roundWaiters;
    try {
      while (true) {
        // 本轮开始前已排队的请求都归这一轮：轮次结束后用本轮报告完成它们。
        // 本轮执行期间到达的请求进入下一轮（循环继续由 `_pending` 保证）。
        roundWaiters = List<Completer<SyncRoundReport?>>.of(_waiters);
        _waiters.clear();
        // 类别范围与待发快照都在轮次开始前取：轮内改开关 / 标脏不能用新值
        // 反推「本轮交付了什么」。
        final scope = _scopeOf(next.onlyCategories);
        final dirtyAtStart = Set<SyncCategory>.of(_dirty);
        final immediateAtStart = Set<SyncCategory>.of(_immediate);
        _changedDuringRound.clear();
        report = await _runRound(
          SyncQueuedRound(
            trigger: next.trigger,
            push: next.push,
            antiEntropy: next.antiEntropy,
            onlyCategories: next.onlyCategories,
          ),
        );
        final delivery = _classifyInScope(
          report,
          push: next.push,
          scope: scope,
          dirtyAtStart: dirtyAtStart,
        );
        pruneDisabledCategories();
        // 只清「本轮开始时就脏、且轮内没有被重新标记」的类别。
        final clearable = delivery.categories.difference(_changedDuringRound);
        _dirty.removeAll(clearable.intersection(dirtyAtStart));
        _immediate.removeAll(clearable.intersection(immediateAtStart));
        final completed = roundWaiters;
        roundWaiters = null;
        for (final waiter in completed) {
          if (!waiter.isCompleted) waiter.complete(report);
        }
        final pending = _takePending();
        if (pending == null) break;
        next = pending;
      }
    } catch (error, stackTrace) {
      // 轮次链异常：本轮等待者与轮内新到达的请求都不能永远挂着。
      final failed = <Completer<SyncRoundReport?>>[
        ...?roundWaiters,
        ...List<Completer<SyncRoundReport?>>.of(_waiters),
      ];
      roundWaiters = null;
      _waiters.clear();
      _pending = null;
      for (final waiter in failed) {
        if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _running = false;
      _changedDuringRound.clear();
      _onChanged?.call();
    }
    return report;
  }

  Future<SyncRoundReport?> _enqueue(_PendingRound request) {
    _merge(request);
    final waiter = Completer<SyncRoundReport?>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _merge(_PendingRound request) {
    _pending = _pending?.mergedWith(request) ?? request;
  }

  /// 按请求求本轮实际类别范围：启用类别与请求范围的交集。
  Set<SyncCategory> _scopeOf(Set<SyncCategory>? onlyCategories) {
    final enabled = _enabledCategories();
    return Set.unmodifiable(
      onlyCategories == null ? enabled : onlyCategories.intersection(enabled),
    );
  }

  SyncRoundDelivery _classifyInScope(
    SyncRoundReport report, {
    required bool push,
    required Set<SyncCategory> scope,
    required Set<SyncCategory> dirtyAtStart,
  }) {
    final contacted = report.peersSeen > 0;
    final contactedLan = report.transports.any(
      (item) => item.kind == SyncTransportKind.lan && item.peersSeen > 0,
    );
    // 判据只覆盖**启用**的传输：关闭的传输不承载本轮外发，它的未配置 /
    // 未运行状态不能阻塞另一路已经交付的事实。
    final enabled = [
      for (final item in report.transports)
        if (item.enabled) item,
    ];
    // 任何一路启用传输有失败 / 不可用证据，就不能宣布交付：传输报告是逐对端
    // 收敛证据，没有逐类别回执，无法确认改动已到达每个对端。
    final transportFailed = enabled.any(_transportFailed);
    final needsTransfer = dirtyAtStart.intersection(scope).isNotEmpty;
    final transferred = needsTransfer
        ? enabled.any((item) => item.pushed > 0 || item.skippedUnchanged > 0)
        : enabled.any((item) => item.succeeded);
    // `noPeers`（五态里明确「一个对端都没接触」）与失败结论都不算交付：
    // 前者没有对端收到数据，后者下轮要重试。
    final contactedOutcome =
        report.outcome == SyncOutcome.ok ||
        report.outcome == SyncOutcome.noChanges;
    final delivered =
        push && contactedOutcome && !transportFailed && transferred;
    return SyncRoundDelivery(
      categories: delivered ? scope : const {},
      contacted: contacted,
      contactedLan: contactedLan,
    );
  }

  /// 单路传输是否有失败 / 不可用证据。
  ///
  /// 宁可保守：只要一路启用传输本轮没在跑、没有配置 / 启动失败、对某个对端
  /// 失败过或带回了错误，就无法确认本轮改动已到达每个对端。保留待发、下一轮
  /// 重试，比错误地清掉标记安全（协议没有逐类别回执，见 [SyncRoundDelivery]）。
  static bool _transportFailed(SyncTransportReport report) =>
      !report.running ||
      report.unavailableReason != null ||
      report.failedPulls > 0 ||
      report.failedPushes > 0 ||
      report.error != null;

  _PendingRound? _takePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}

/// 一次排队请求（首轮 / 补跑轮共用）。
class _PendingRound {
  const _PendingRound({
    required this.trigger,
    required this.push,
    required this.antiEntropy,
    required this.onlyCategories,
  });

  /// 由调用入参构造，并落实手动请求的固定语义：推送 + 全部启用类别。
  factory _PendingRound.request({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    required Set<SyncCategory>? onlyCategories,
  }) {
    final manual = trigger == SyncTrigger.manual;
    return _PendingRound(
      trigger: trigger,
      push: manual || push,
      antiEntropy: antiEntropy,
      onlyCategories: manual ? null : onlyCategories,
    );
  }

  final SyncTrigger trigger;
  final bool push;
  final bool antiEntropy;
  final Set<SyncCategory>? onlyCategories;

  /// 合并两个待跑请求：手动优先、外发取或、anti-entropy 取或、范围「全部」
  /// 优先（null）否则并集。手动请求的语义固定为「推送 + 全部启用类别」，
  /// 不因先到的自动轮范围而收窄。
  _PendingRound mergedWith(_PendingRound incoming) {
    final nextTrigger = _mergeTrigger(trigger, incoming.trigger);
    final nextPush = push || incoming.push;
    final nextAntiEntropy = antiEntropy || incoming.antiEntropy;
    final manual = nextTrigger == SyncTrigger.manual;
    final Set<SyncCategory>? scope;
    if (manual || onlyCategories == null || incoming.onlyCategories == null) {
      scope = null;
    } else {
      scope = Set.unmodifiable({
        ...onlyCategories!,
        ...incoming.onlyCategories!,
      });
    }
    return _PendingRound(
      trigger: nextTrigger,
      push: manual || nextPush,
      antiEntropy: nextAntiEntropy,
      onlyCategories: scope,
    );
  }

  /// 触发原因按「手动优先」合并：补跑轮不能被自动原因稀释掉用户动作。
  static SyncTrigger _mergeTrigger(SyncTrigger existing, SyncTrigger incoming) {
    if (existing == SyncTrigger.manual || incoming == SyncTrigger.manual) {
      return SyncTrigger.manual;
    }
    return existing;
  }
}
