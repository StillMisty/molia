/// 同步轮次的唯一排队 / 串行 / 交付台账。
///
/// 为什么需要这个模块：引擎与调度器此前各有一份「排队」状态——引擎持有
/// 在途轮次与补跑请求，调度器持有待外发类别与「是否已有轮次在跑」。手动轮
/// 不经调度器，因此它清不掉调度器的待发标记；而引擎把 `failedCount == 0`
/// 当成「已交付」，零对端轮也会清掉待发标记（对端根本没收到任何东西）。
///
/// 现在只有这一份队列：
/// - **排队**：待跑请求（触发原因 / anti-entropy / 类别范围）与在途轮次；
///   请求落在在途轮次上时合并成至多一个补跑轮，绝不并发两轮；
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

/// 补跑链里一轮的执行参数。
///
/// [push] 与 [onlyCategories] 属于整段轮次链的外发范围：由发起这段链的请求
/// 决定，补跑请求只合并触发原因与 anti-entropy（沿用既有语义，避免同一段链
/// 中途切换外发范围）。
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
/// `delivered` 只表示「这一轮真的把范围内的改动交给了至少一路传输」：
/// - 结论是 `ok` / `noChanges`（`noPeers` 与 `partial` / `failed` 都不算）；
/// - 传输报告至少一路 `succeeded`（探测到对端 / 拉到载荷 / 推送成功）；
/// - 本轮确实外发（`push: false` 的入站 / 只拉轮不算交付）。
///
/// `noPeers` 没有接触任何对端，因此**不是**交付；`categories` 为空。
class SyncRoundDelivery {
  const SyncRoundDelivery({
    required this.categories,
    required this.contacted,
    required this.contactedLan,
  });

  /// 本轮真正交付的类别（未交付 = 空集）。清待发标记只清这些类别。
  final Set<SyncCategory> categories;

  /// 本轮是否探测到任何对端（重连阶梯用；与交付判据不同）。
  final bool contacted;

  /// 本轮是否探测到局域网对端（重连阶梯据此立即取消）。
  final bool contactedLan;

  /// 本轮是否交付了任何类别。
  bool get delivered => categories.isNotEmpty;

  /// 某个类别是否在本轮真正交付。
  bool deliveredIn(SyncCategory category) => categories.contains(category);
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

  bool _running = false;

  /// 在途轮次期间到达的请求：合并成一次补跑（手动优先合并、anti-entropy 取或）。
  SyncTrigger? _pendingTrigger;
  bool _pendingAntiEntropy = false;

  /// 补跑请求的等待者：每个请求都在**补跑轮**跑完后拿到该轮报告。
  final List<Completer<SyncRoundReport?>> _waiters = [];

  /// 是否已有一段轮次链在跑（同一时刻至多一段）。
  bool get running => _running;

  /// 是否有已合并、等待补跑的请求。
  bool get hasPending => _pendingTrigger != null;

  /// 是否还有未外发的本地变更。
  bool get dirty => _dirty.isNotEmpty;

  /// 待外发的类别（观测与测试用）。
  Set<SyncCategory> get dirtyCategories => Set.unmodifiable(_dirty);

  /// 是否存在高优先级待发变更（调度器据此排去抖轮次）。
  bool get hasImmediate => _immediate.isNotEmpty;

  /// 标记本地变更：只记类别，不直接跑轮次（何时跑由调度器决定）。
  ///
  /// [categories] 省略时标记全部启用类别；[immediate] 为 false 时只标记、
  /// 不进入即时集合（高频写入如播放会话进度用）。
  void markLocalChange({Set<SyncCategory>? categories, bool immediate = true}) {
    final enabled = _enabledCategories();
    final pending = categories == null
        ? enabled
        : categories.intersection(enabled);
    _dirty.addAll(pending);
    if (immediate) _immediate.addAll(pending);
  }

  /// 丢弃已关闭类别的待发标记（关闭后不再外发，不必等下一轮失败）。
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
    if (_running) {
      return enqueue(trigger: trigger, antiEntropy: antiEntropy);
    }
    _running = true;
    _onChanged?.call();
    return _drain(
      trigger: trigger,
      push: push,
      antiEntropy: antiEntropy,
      onlyCategories: onlyCategories,
    );
  }

  /// 把请求并入下一次补跑，返回补跑轮的报告（供调用方等待）。
  ///
  /// 只在 [running] 为 true 时使用（引擎的入口已做闸门）；没有在途轮次时
  /// 没有补跑轮会消费这个等待者。
  Future<SyncRoundReport?> enqueue({
    required SyncTrigger trigger,
    bool antiEntropy = false,
  }) {
    assert(_running, '没有在途轮次时排队的请求不会被消费');
    _merge(trigger: trigger, antiEntropy: antiEntropy);
    final waiter = Completer<SyncRoundReport?>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// 只合并补跑请求、不等待报告（入站推送 / 公告唤醒这类 fire-and-forget）。
  ///
  /// 与 [enqueue] 同生命周期：先合并待跑原因，因此不会出现「有请求却没有
  /// 待跑轮次」的状态；同样只在 [running] 为 true 时使用。
  void schedule({required SyncTrigger trigger, bool antiEntropy = false}) {
    assert(_running, '没有在途轮次时排队的请求不会被消费');
    _merge(trigger: trigger, antiEntropy: antiEntropy);
  }

  /// 唯一的交付判定：把一轮报告翻译成「哪些类别真的交付了」。
  ///
  /// 判据刻意要求传输 `succeeded`：零对端（`noPeers`）没有接触任何传输，
  /// 即使没有失败也不交付；这样待发标记不会被空轮吞掉。`push: false` 的
  /// 轮次没有外发动作，同样不交付。
  ///
  /// 传输报告只有对端粒度（协议没有逐类别回执），因此「本轮类别范围」就是
  /// 可得的最细粒度：本轮确实接触 / 传输成功时，范围内类别视为已交付，
  /// 范围外（例如蜂窝小类别轮之外的历史 / 统计）继续保留待发。
  SyncRoundDelivery classify(
    SyncRoundReport report, {
    required bool push,
    Set<SyncCategory>? onlyCategories,
  }) {
    final enabled = _enabledCategories();
    final scope = onlyCategories == null
        ? enabled
        : onlyCategories.intersection(enabled);
    final contacted = report.peersSeen > 0;
    final contactedLan = report.transports.any(
      (item) => item.kind == SyncTransportKind.lan && item.peersSeen > 0,
    );
    final transferred = report.transports.any((item) => item.succeeded);
    // `noPeers`（五态里明确「一个对端都没接触」）与失败结论都不算交付：
    // 前者没有对端收到数据，后者下轮要重试。
    final contactedOutcome =
        report.outcome == SyncOutcome.ok ||
        report.outcome == SyncOutcome.noChanges;
    final delivered = push && contactedOutcome && transferred;
    return SyncRoundDelivery(
      categories: delivered ? Set.unmodifiable(scope) : const {},
      contacted: contacted,
      contactedLan: contactedLan,
    );
  }

  Future<SyncRoundReport?> _drain({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  }) async {
    var nextTrigger = trigger;
    var nextAntiEntropy = antiEntropy;
    SyncRoundReport? report;
    try {
      while (true) {
        // 本轮开始前已排队的请求都归这一轮：轮次结束后用本轮报告完成它们。
        // 本轮执行期间到达的请求进入下一轮（循环继续由 `_pendingTrigger` 保证）。
        final waiters = List<Completer<SyncRoundReport?>>.of(_waiters);
        _waiters.clear();
        report = await _runRound(
          SyncQueuedRound(
            trigger: nextTrigger,
            push: push,
            antiEntropy: nextAntiEntropy,
            onlyCategories: onlyCategories,
          ),
        );
        final delivery = classify(
          report,
          push: push,
          onlyCategories: onlyCategories,
        );
        // 先丢弃已关闭类别，再按本轮交付清标记：关闭的类别即使本轮「外发过」
        // 也不该留在待发集合里（旧口径同样如此）。
        pruneDisabledCategories();
        _dirty.removeAll(delivery.categories);
        _immediate.removeAll(delivery.categories);
        for (final waiter in waiters) {
          if (!waiter.isCompleted) waiter.complete(report);
        }
        final pending = _takePending();
        if (pending == null) break;
        nextTrigger = pending.trigger;
        nextAntiEntropy = pending.antiEntropy;
      }
    } catch (error, stackTrace) {
      // 轮次链异常：排队请求不能永远挂着，按同一异常结束（发起请求本身也
      // 会抛出，保持既有的失败行为）。
      _pendingTrigger = null;
      _pendingAntiEntropy = false;
      final waiters = List<Completer<SyncRoundReport?>>.of(_waiters);
      _waiters.clear();
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _running = false;
      _onChanged?.call();
    }
    return report;
  }

  void _merge({required SyncTrigger trigger, required bool antiEntropy}) {
    _pendingTrigger = _mergeTrigger(_pendingTrigger, trigger);
    _pendingAntiEntropy = _pendingAntiEntropy || antiEntropy;
  }

  ({SyncTrigger trigger, bool antiEntropy})? _takePending() {
    final trigger = _pendingTrigger;
    _pendingTrigger = null;
    final antiEntropy = _pendingAntiEntropy;
    _pendingAntiEntropy = false;
    if (trigger == null) return null;
    return (trigger: trigger, antiEntropy: antiEntropy);
  }

  /// 触发原因按「手动优先」合并：补跑轮不能被自动原因稀释掉用户动作。
  static SyncTrigger _mergeTrigger(
    SyncTrigger? existing,
    SyncTrigger incoming,
  ) {
    if (existing == null) return incoming;
    if (existing == SyncTrigger.manual || incoming == SyncTrigger.manual) {
      return SyncTrigger.manual;
    }
    return existing;
  }
}
