import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_adapter.dart';
import 'sync_book.dart';
import 'sync_codec_port.dart';
import 'sync_journal.dart';
import 'sync_known_store.dart';
import 'sync_round.dart';
import 'sync_scheduler.dart';
import 'sync_stamp.dart';
import 'sync_state_store.dart';
import 'sync_transport_runtime.dart';

/// 同步引擎：一轮 = 收集本地视图 → 拉取远端快照 → 逐键合并 → 写回本地 →
/// 推送合并后视图 → 记录可观察的一轮结果（[SyncRoundReport]）。
///
/// 引擎是公共门面：轮次执行在 [SyncRoundRunner]（只暴露整轮与服务端动作），UI 面的
/// 身份 / 开关 / 传输状态 / 口令在 `sync_control_plane.dart`，完整备份在
/// `sync_backup.dart`；三者共享同一个 `SyncStateStore` 与同一份适配器 /
/// 传输实例（组合根接线，见 `app/bootstrap/sync_stack.dart`）。
///
/// 成本模型：合并后只把**版本变化**的胜者交给适配器（[SyncKnownStore] 登记
/// 上一轮交付的版本），因此一轮的落地量、日志计数与适配器内部查询
/// ∝ 本轮变更量，不随库大小增长；空闲轮不拉取（传输门控）、不推送
/// （内容指纹未变）、不落地（登记未变）。
///
/// 可观察性契约：
/// - 报告区分五态：`noPeers`（一个对端都没发现）与 `noChanges`（对端可达但
///   没有变化）必须能分开，用户才能自查「同步到底做了什么」；
/// - 计数是**本轮变更量**（落地记录数 / 传输字节 / 失败个数），不是全库规模；
/// - 每传输与每对端都有独立结果，单点失败不会被吞掉；
/// - 失败原因是机器可读的 [SyncIssue]，UI 映射文案，原始细节只进日志与诊断；
/// - 入站快照在本轮失败时放回队列（对端花网络推来的数据不能丢）。
class SyncEngine extends ChangeNotifier implements SyncSchedulerHost {
  factory SyncEngine({
    required SyncStateStore state,
    required List<SyncAdapter> adapters,
    required Map<String, SyncTransport> transports,
    required SyncStampIssuer stamps,
    SyncKnownStore? known,
    SyncJournalStore? journal,
    SyncCodecPort? fingerprintPort,
    SyncTransportRuntime? runtime,
    DateTime Function()? clock,
    Duration inboundWindow = const Duration(milliseconds: 1500),
  }) {
    // 运行时只解析一次：引擎（轮次 ensure / 释放 stop）与控制面必须共享
    // 同一实例，否则「唯一运行时所有者」又会退化成两份启动循环。
    final resolvedClock = clock ?? DateTime.now;
    final resolvedRuntime =
        runtime ?? SyncTransportRuntime(state: state, transports: transports);
    final runner = SyncRoundRunner(
      state: state,
      adapters: adapters,
      transports: transports,
      stamps: stamps,
      known: known ?? InMemorySyncKnownStore(),
      journal: journal,
      fingerprintPort: fingerprintPort,
      runtime: resolvedRuntime,
      clock: resolvedClock,
    );
    return SyncEngine._(
      state: state,
      runner: runner,
      inboundWindow: inboundWindow,
      clock: resolvedClock,
    );
  }

  SyncEngine._({
    required SyncEngineState state,
    required SyncRoundRunner runner,
    required Duration inboundWindow,
    required DateTime Function() clock,
  })  : _state = state,
        _runner = runner,
        _inboundWindow = inboundWindow,
        _clock = clock {
    for (final entry in runner.transports.entries) {
      // 引擎只负责订阅入站流；发布台账等轮次状态由 runner 自己持有。
      _incomingSubscriptions.add(entry.value.incoming.listen(
        (envelope) => unawaited(onIncomingEnvelope(envelope)),
      ));
      // 发现事件是可选能力（WebDAV 没有）：只订阅实现了窄接口的传输。
      final transport = entry.value;
      if (transport is SyncSightingSource) {
        final source = transport as SyncSightingSource;
        _sightingSubscriptions.add(source.sightings.listen(
          _onPeerSighting,
          onError: (Object error) {
            _logger.fine(() => '对端公告流错误: $error');
          },
        ));
      }
    }
  }

  /// 推送时丢弃保留期外的墓碑（防止无限膨胀；保留期内复活风险可忽略）。
  static const int tombstoneRetentionMs = SyncRoundRunner.tombstoneRetentionMs;

  final SyncEngineState _state;
  final SyncRoundRunner _runner;

  /// 入站合流窗口：窗口内到达的多个对端推送合并成一轮。
  final Duration _inboundWindow;

  final DateTime Function() _clock;
  final List<StreamSubscription<SyncEnvelope>> _incomingSubscriptions = [];
  final List<StreamSubscription<LanPeerSighting>> _sightingSubscriptions = [];
  final Logger _logger = Logger('molia.sync');

  /// 对端公告过滤状态（不写进名册：公告观测不该刷新 `lastSeenAt`）。
  final Map<String, _PeerSightingState> _sightingState = {};

  /// 过滤后的「值得跑一轮」事件流（调度器订阅后去抖 + 冷却）。
  final StreamController<void> _peerSightings =
      StreamController<void>.broadcast();

  Timer? _inboundTimer;

  bool _syncing = false;
  bool _initialized = false;

  /// 同步进行中收到的同步请求（手动点击 / 入站推送）：合并成一次排队，
  /// 当前轮结束后立刻补跑，请求不会被丢弃。
  ///
  /// 排队合并语义（与拆出轮次编排器之前一致）：触发原因按「手动优先」合并、
  /// anti-entropy 取或；`push` 与 `onlyCategories` 沿用发起这段轮次链的请求。
  SyncTrigger? _pendingTrigger;
  bool _pendingAntiEntropy = false;

  /// 排队请求的等待者：每个请求都在**补跑轮**跑完后拿到该轮报告。
  ///
  /// 与 [_pendingTrigger] 同生命周期：加入等待者前一定先合并触发原因，
  /// 因此补跑链不会出现「有等待者却没有待跑轮次」的状态。
  final List<Completer<SyncRoundReport?>> _queuedRequests = [];

  SyncRoundReport? _lastReport;

  /// 「首次连通」通知流：每台设备只在第一次真正交换数据后发一次。
  final StreamController<SyncPeerState> _peerConnected =
      StreamController<SyncPeerState>.broadcast();

  bool get syncing => _syncing;
  bool get initialized => _initialized;

  /// 最近一轮的完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _lastReport;

  /// 最近一轮推送/构建的快照（局域网端点直接返回给对端 GET）。
  SyncEnvelope? get lastEnvelope => _runner.lastEnvelope;

  /// 增量模式是否启用（注入 journal 的前提）。
  ///
  /// 组合根接线契约：`buildSyncStack` 必须传 `library.syncJournal`。
  /// 未注入时引擎仍正确，但整体退化为「每轮全量」——全库指纹、整库加密
  /// 推送、日志只写不裁；这条只读位供组合根冒烟测试守住接线。
  bool get incrementalEnabled => _runner.incrementalEnabled;

  /// 服务端语义（局域网增量端点 / WebDAV 日志文件）：按请求方游标返回
  /// 增量窗口；游标落后于窗口起点（条目已被裁剪）时返回全量快照（bootstrap）。
  Future<SyncEnvelope> serveJournal({required int since}) =>
      _runner.serveJournal(since: since);

  /// 全量快照（局域网 `GET /snapshot` 与 bootstrap 兜底）。
  Future<SyncEnvelope> serveSnapshot() => _runner.serveSnapshot();

  int _nowMs() => _clock().millisecondsSinceEpoch;

  Future<void> init() async {
    if (_initialized) return;
    await _state.init();
    if (_state.freshInstall) {
      // 首次使用新命名空间 = 全新安装：日志与已知版本登记都是可再生的派生
      // 状态，旧命名空间留下的行无法解释（seq / 版本语义已断代），必须清空。
      // 用户数据表与墓碑不在此列；标记在两者都成功后落盘，失败下次启动重试。
      await _runner.resetDerivedState();
      await _state.markFreshHandled();
    }
    _initialized = true;
    notifyListeners();
  }

  /// 从内存名册移除一台设备（用户「从本机移除」）。
  ///
  /// 只清观测，不撤销授权：设备下一轮被探测 / 推送时会重新进入名册。落库侧
  /// 的删除由控制面同步完成；这里先摘掉内存项，避免在途轮次继续引用。
  void forgetPeer(String deviceId) {
    if (deviceId.isEmpty) return;
    _runner.forgetPeer(deviceId);
    _sightingState.remove(deviceId);
  }

  /// 公告「无变化」的去重窗口：同一设备 2 分钟内重复公告不触发轮次。
  static const int peerSightingWindowMs = 2 * 60 * 1000;

  /// 公告过滤状态上限（公共网络里 deviceId 可以无限多，状态必须有界）。
  static const int maxSightingPeers = 64;

  /// 当前公告过滤状态条数（测试 / 诊断用；上限 [maxSightingPeers]）。
  int get sightingStateCount => _sightingState.length;

  /// 过滤认证通过的对端公告：只有真的值得跑一轮时才通知调度器。
  ///
  /// 触发条件：新设备 / bootId 变化（对端重启）/ snapshotId 与本机名册不同 /
  /// head 前进且仍高于本机游标。同一设备 2 分钟内没有变化（且未落后）不触发。
  /// 观测状态独立保存，**不写名册的 lastSeenAt**：公告只说明对端在线，
  /// 真正接触成功由一轮的结果更新名册。
  void _onPeerSighting(LanPeerSighting sighting) {
    final id = sighting.deviceId;
    if (id.isEmpty || id == _state.deviceId) return;
    final now = _nowMs();
    final prev = _sightingState[id];
    final roster = _runner.peerOf(id);
    final head = sighting.journalHead;
    final bootChanged = prev != null &&
        sighting.bootId.isNotEmpty &&
        sighting.bootId != prev.bootId;
    final previousSnapshot = prev?.snapshotId ?? roster.snapshotId;
    final snapshotChanged = sighting.snapshotId.isNotEmpty &&
        sighting.snapshotId != previousSnapshot;
    final headAdvanced =
        head != null && (prev?.head == null || head > prev!.head!);
    final behind = head != null && head > roster.cursorSeq;
    var notify = prev == null ||
        bootChanged ||
        snapshotChanged ||
        (behind && headAdvanced);
    if (!notify &&
        behind &&
        now - prev.lastTriggeredAt >= peerSightingWindowMs) {
      // 仍落后且 2 分钟没有变化：允许再唤醒一次（上一轮失败 / 对端还在
      // 推进时不必等到空闲退避）。
      notify = true;
    }
    _sightingState[id] = _PeerSightingState(
      lastSightingAt: now,
      lastTriggeredAt: notify ? now : (prev?.lastTriggeredAt ?? 0),
      bootId: sighting.bootId,
      head: head,
      snapshotId: sighting.snapshotId.isNotEmpty
          ? sighting.snapshotId
          : (prev?.snapshotId ?? ''),
    );
    _trimSightingState();
    if (notify && !_peerSightings.isClosed) _peerSightings.add(null);
  }

  /// 超过 [maxSightingPeers] 时淘汰最久没再公告的设备。
  void _trimSightingState() {
    while (_sightingState.length > maxSightingPeers) {
      String? oldestId;
      var oldestAt = 1 << 62;
      for (final entry in _sightingState.entries) {
        if (entry.value.lastSightingAt < oldestAt) {
          oldestAt = entry.value.lastSightingAt;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) return;
      _sightingState.remove(oldestId);
    }
  }

  /// 过滤后的对端公告事件（调度器订阅后去抖 + 冷却）。
  Stream<void> get peerSightings => _peerSightings.stream;

  /// 对端主动推送的快照：在合流窗口内合并成一轮。
  ///
  /// 入站轮只消费收到的快照：不拉取全部对端（避免 N 台平方级放大）、不推送
  /// （防止 A 推 B → B 推 A 的乒乓）；需要外发的本地变更由常规触发承担。
  /// 窗口内的多次推送（含多个对端）只触发一轮。
  Future<void> onIncomingEnvelope(SyncEnvelope envelope) async {
    if (!_state.enabled) return;
    _runner.enqueueInbound(envelope);
    if (_syncing) {
      _pendingTrigger = _mergeTrigger(_pendingTrigger, SyncTrigger.incoming);
      return;
    }
    _inboundTimer ??= Timer(_inboundWindow, () {
      _inboundTimer = null;
      if (_runner.inbound.isEmpty) return;
      unawaited(syncNow(trigger: SyncTrigger.incoming, push: false));
    });
  }

  /// 跑一轮同步，返回**这次请求所加入的那一轮**的报告。
  ///
  /// - 没有轮次在跑：自己跑一整段（期间排队的请求会连续补跑），返回最后
  ///   一轮的报告；
  /// - 已有轮次在跑：请求并入下一次补跑，返回**补跑轮**的报告（不是上一轮）；
  ///   同一个在途轮内到达的多个请求仍只补跑一轮，全部等待者收到同一份报告；
  /// - 同步关闭（未启用任何传输）：返回 null（本轮没有真正跑）。
  ///
  /// 排队合并语义沿用既有行为：触发原因按「手动优先」合并、[antiEntropy]
  /// 取或；[push] 与 [onlyCategories] 属于整段轮次链的外发范围，由发起
  /// 请求决定（补跑轮不会因为排队请求而改变外发 / 类别范围）。
  ///
  /// [onlyCategories] 非空时只处理这些类别（蜂窝小类别策略；适配器的本地
  /// 变化登记照常进行，不受影响）。[antiEntropy] 允许全量兜底（周期性比对
  /// `snapshotId` 修复静默分歧；充电 / Wi-Fi / 前台的唤醒才置位）。
  Future<SyncRoundReport?> syncNow({
    SyncTrigger trigger = SyncTrigger.timer,
    bool push = true,
    bool antiEntropy = false,
    Set<SyncCategory>? onlyCategories,
  }) async {
    if (_syncing) return _queueRequest(trigger, antiEntropy);
    if (!_initialized) await init();
    // 初始化等待期间另一条请求可能已经起跑：重新入队，保证同一时刻只有
    // 一条轮次链，且本次请求仍能拿到补跑轮报告。
    if (_syncing) return _queueRequest(trigger, antiEntropy);
    if (!_state.enabled) return null;

    // 同步进行中到达的请求会被排队：整段（含补跑）持有 `_syncing`，保证同一时刻
    // 只有一条轮次在跑；点一次必有一次，多个入站推送也只合并成额外一轮。
    _syncing = true;
    notifyListeners();
    var nextTrigger = trigger;
    var nextAntiEntropy = antiEntropy;
    SyncRoundReport? report;
    try {
      while (true) {
        // 本轮开始前已排队的请求都归这一轮：轮次结束后用本轮报告完成它们。
        // 本轮执行期间到达的请求进入下一轮（循环继续由 `_pendingTrigger` 保证）。
        final waiters = List<Completer<SyncRoundReport?>>.of(_queuedRequests);
        _queuedRequests.clear();
        report = await _runRound(
          nextTrigger,
          push: push,
          antiEntropy: nextAntiEntropy,
          onlyCategories: onlyCategories,
        );
        for (final waiter in waiters) {
          if (!waiter.isCompleted) waiter.complete(report);
        }
        final pending = _pendingTrigger;
        _pendingTrigger = null;
        final pendingAntiEntropy = _pendingAntiEntropy;
        _pendingAntiEntropy = false;
        if (pending == null) break;
        nextTrigger = pending;
        nextAntiEntropy = pendingAntiEntropy;
        // 补跑轮沿用排队时的类别范围（同一策略下不应切换范围）。
      }
    } catch (error, stackTrace) {
      // 轮次链异常：排队请求不能永远挂着，按同一异常结束（发起请求本身也
      // 会抛出，保持既有的失败行为）。
      _pendingTrigger = null;
      _pendingAntiEntropy = false;
      final waiters = List<Completer<SyncRoundReport?>>.of(_queuedRequests);
      _queuedRequests.clear();
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return report;
  }

  /// 把请求并入下一次补跑：合并触发原因与 anti-entropy，登记一个等待者。
  ///
  /// 等待者在补跑轮结束后收到该轮报告；多个请求只补跑一轮（[syncNow]）。
  Future<SyncRoundReport?> _queueRequest(
    SyncTrigger trigger,
    bool antiEntropy,
  ) {
    _pendingTrigger = _mergeTrigger(_pendingTrigger, trigger);
    _pendingAntiEntropy = _pendingAntiEntropy || antiEntropy;
    final waiter = Completer<SyncRoundReport?>();
    _queuedRequests.add(waiter);
    return waiter.future;
  }

  /// 调度器宿主接口：跑一轮并回传**外发结果**（[SyncScheduler] 据此只清
  /// 已外发类别的待发标记）。
  @override
  bool get syncEnabled => _state.enabled;

  @override
  Future<SyncRunOutcome> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  }) async {
    final report = await syncNow(
      trigger: trigger,
      push: push,
      antiEntropy: antiEntropy,
      onlyCategories: onlyCategories,
    );
    // 未初始化 / 同步关闭：本轮没有真正跑，按「不接触」之外的默认处理
    // （不触发重连阶梯——没有口令 / 传输关闭不是网络问题）。
    if (report == null) return SyncRunOutcome.none;
    // 「零对端」用探测计数判定（noPeers 与「接触过但没变化」必须分开）。
    final contacted = report.peersSeen > 0;
    final contactedLan = report.transports.any(
      (item) => item.kind == SyncTransportKind.lan && item.peersSeen > 0,
    );
    // 入站轮 / 只拉不推的轮次同样要回传接触信息：resume 轮没有本地变更时
    // 不推送，但仍决定是否 arm 重连阶梯。
    if (!push) {
      return SyncRunOutcome(
        categories: const {},
        delivered: false,
        contacted: contacted,
        contactedLan: contactedLan,
        report: report,
      );
    }
    final enabled = _state.enabledCategories;
    final categories =
        onlyCategories == null ? enabled : onlyCategories.intersection(enabled);
    return SyncRunOutcome(
      categories: categories,
      delivered:
          report.outcome != SyncOutcome.failed && report.failedCount == 0,
      contacted: contacted,
      contactedLan: contactedLan,
      report: report,
    );
  }

  /// 跑一轮并落日志 / 通知（阶段编排在 [SyncRoundRunner.runRound]）。
  Future<SyncRoundReport> _runRound(
    SyncTrigger trigger, {
    required bool push,
    Set<SyncCategory>? onlyCategories,
    bool antiEntropy = false,
  }) async {
    final report = await _runner.runRound(
      trigger: trigger,
      push: push,
      antiEntropy: antiEntropy,
      onlyCategories: onlyCategories,
    );
    _lastReport = report;
    _state.recordRound(report);
    // 首次连通提示与轮次结果共用同一次提交：一轮只写一份状态 JSON。
    _announceConnectedPeers();
    await _state.commit();
    notifyListeners();
    return report;
  }

  /// 首次连通：名册里「真正交换过数据」的对端，未提示过的各补发一次。
  ///
  /// 判据用 `lastPullAt` / `lastPushAt` 而不是 `lastSeenAt`：探测应答只说明
  /// 「在线」，真正交换过（含入站推送，它按拉取计）才代表口令对得上、数据通了。
  /// 一次性由 [SyncStateStore.markPeerConnectNotified] 的登记保证，随本次轮末
  /// 提交落盘，重启不重发。
  void _announceConnectedPeers() {
    if (_peerConnected.isClosed) return;
    for (final peer in _state.peers) {
      if (peer.deviceId.isEmpty) continue;
      if (peer.lastPullAt <= 0 && peer.lastPushAt <= 0) continue;
      if (_state.isPeerConnectNotified(peer.deviceId)) continue;
      _state.markPeerConnectNotified(peer.deviceId);
      _peerConnected.add(peer);
    }
  }

  static SyncTrigger _mergeTrigger(
      SyncTrigger? existing, SyncTrigger incoming) {
    if (existing == null) return incoming;
    if (existing == SyncTrigger.manual || incoming == SyncTrigger.manual) {
      return SyncTrigger.manual;
    }
    return existing;
  }

  /// 完整备份模块的收集入口：按类别返回适配器聚合视图（与一轮同步同一份
  /// 类别过滤与缓存语义）。备份不接触轮次状态，只需要这一个读动作。
  Future<Map<SyncCategory, List<SyncRecord>>> collectRecords(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) =>
      _runner.collectRecords(categories, fresh: fresh);

  /// 首次连通通知流（UI 消费：应用壳弹一次底栏提示）。
  Stream<SyncPeerState> get peerConnectedNotices => _peerConnected.stream;

  @override
  void dispose() {
    _inboundTimer?.cancel();
    _inboundTimer = null;
    for (final subscription in _incomingSubscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _sightingSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_peerSightings.close());
    unawaited(_peerConnected.close());
    _runner.dispose();
    super.dispose();
  }
}

/// 每台对端的公告观测（独立于名册：公告不刷新 `lastSeenAt`）。
class _PeerSightingState {
  const _PeerSightingState({
    required this.lastSightingAt,
    required this.lastTriggeredAt,
    required this.bootId,
    required this.head,
    required this.snapshotId,
  });

  /// 最近一次收到公告的时间（只用于有界淘汰；触发判据见 `_onPeerSighting`）。
  final int lastSightingAt;
  final int lastTriggeredAt;
  final String bootId;
  final int? head;
  final String snapshotId;
}
