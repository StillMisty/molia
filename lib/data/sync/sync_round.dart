/// 一轮同步的阶段编排与轮次上下文。
///
/// 为什么拆出来：`SyncEngine._runRound` 曾在一个方法里做十二件事（口令、
/// 传输启动、收集、anti-entropy、拉取、游标消费、缺口兜底、合并、应用、
/// 裁日志、构建快照、推送、五态报告）。任何一步的局部变量都要在几百行里
/// 传递，阶段之间靠大段注释维持顺序，既难改也难单测。
///
/// 现在一轮只剩 [SyncRoundRunner.runRound] 的线性编排；每个阶段只读写
/// [SyncRoundContext]，可以在不跑整轮的情况下单独调用（注入假传输 / 假
/// 适配器）。同步语义（应用成功才推进游标、forced delivery、缺口二次拉取、
/// anti-entropy、入站轮、名册失败记账、报告五态）逐条保留。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import '../../domain/ports/sync_transport.dart';
import 'peer_journal_protocol.dart';
import 'publish_ledger.dart';
import 'sync_adapter.dart';
import 'sync_codec_port.dart';
import 'sync_fingerprint.dart';
import 'sync_journal.dart';
import 'sync_pull_plan.dart';
import 'sync_stamp.dart';
import 'sync_state_store.dart';
import 'sync_transport_runtime.dart';

/// 一轮同步的可变上下文：输入 + 各阶段产出。
class SyncRoundContext {
  SyncRoundContext({
    required this.trigger,
    required this.push,
    required this.antiEntropy,
    required this.onlyCategories,
    required this.startedAt,
    required this.window,
  });

  final SyncTrigger trigger;
  final bool push;
  final bool antiEntropy;
  final Set<SyncCategory>? onlyCategories;
  final int startedAt;

  /// pull 与 push 共享的显式窗口。
  final SyncRoundWindow window;

  // ---- collect ----
  String passphrase = '';
  int journalHead = 0;
  Set<SyncCategory> categories = const {};
  Map<SyncCategory, List<SyncRecord>> local = const {};
  bool localChanged = false;
  Map<String, SyncTransportAccumulator> accumulators = const {};
  Set<String> fullFor = const {};
  bool inboundOnly = false;

  // ---- pull / consume ----
  final List<(String, SyncEnvelope)> pulledEntries = [];
  final Map<SyncCategory, List<SyncRecord>> remoteRecords = {};
  final Set<SyncKnownKey> forcedDelivery = {};
  final Map<String, int> pendingCursors = {};
  List<SyncEnvelope> inboundSnapshot = const [];
  bool pullContact = false;

  // ---- apply ----
  int applied = 0;
  int applyFailures = 0;
  bool inboundRestored = false;

  // ---- publish ----
  int journalBase = 0;
  int? snapshotSeq;
  Map<SyncCategory, List<SyncRecord>> refreshed = const {};
  SyncEnvelope? outgoing;
  int succeededPushes = 0;

  // ---- report ----
  SyncRoundReport? report;
}

/// 一轮的编排器：拥有名册观测、收集缓存、发布台账与 inbound 队列。
///
/// 引擎（[SyncEngine]）只保留公共门面（调度器宿主 / 服务端语义 / 入站合流 /
/// 公告过滤）；轮次内的状态全部在这里，阶段方法可单独测试。
class SyncRoundRunner {
  SyncRoundRunner({
    required SyncStateStore state,
    required List<SyncAdapter> adapters,
    required Map<String, SyncTransport> transports,
    required SyncStampIssuer stamps,
    required SyncKnownStore known,
    SyncJournalStore? journal,
    SyncCodecPort? fingerprintPort,
    required SyncTransportRuntime runtime,
    required DateTime Function() clock,
    Logger? logger,
  })  : _state = state,
        _adapters = adapters,
        _transports = transports,
        _stamps = stamps,
        _known = known,
        _journal = journal,
        _fingerprintPort = fingerprintPort,
        _runtime = runtime,
        _clock = clock,
        _logger = logger ?? Logger('molia.sync') {
    // 发布台账由运行时自己建立：阶段测试直接构造 runner 也不会漏门控。
    for (final entry in transports.entries) {
      _publishLedgers[entry.key] = PublishLedger(
        kind: entry.key,
        state: state,
        servesLiveSnapshot: () => entry.value.servesLiveSnapshot,
      );
    }
  }

  /// 推送时丢弃保留期外的墓碑（防止无限膨胀；保留期内复活风险可忽略）。
  static const int tombstoneRetentionMs = 90 * 24 * 60 * 60 * 1000;

  /// anti-entropy 全量兜底的节流间隔（同一对端不频繁重拉；分歧仍会被修复）。
  static const int antiEntropyIntervalMs = 10 * 60 * 1000;

  final SyncStateStore _state;
  final List<SyncAdapter> _adapters;
  final Map<String, SyncTransport> _transports;
  final SyncStampIssuer _stamps;
  final SyncKnownStore _known;
  final SyncJournalStore? _journal;
  final SyncCodecPort? _fingerprintPort;
  final SyncTransportRuntime _runtime;
  final DateTime Function() _clock;
  final Logger _logger;

  /// 登记的内存视图（首次使用时加载一次，之后只写变化项）。
  Map<SyncKnownKey, SyncVersion>? _knownVersions;

  /// 上轮本地视图指纹（未注入日志时用于区分「本机没有变化」）。
  String? _localFingerprint;

  /// 上一轮快照指纹与它覆盖的日志头部（空闲轮复用）。
  String? _snapshotFingerprintId;
  int? _snapshotFingerprintHead;

  /// 上一轮开始时的日志头部：与本轮头部比较即「本机有没有变化」。
  int? _localJournalHead;

  /// 上一轮各适配器的收集结果（身份）与聚合视图。
  final Map<SyncAdapter, Map<SyncCategory, List<SyncRecord>>>
      _lastAdapterCollect = {};
  Map<SyncCategory, List<SyncRecord>>? _lastAggregate;
  Set<SyncCategory>? _lastAggregateCategories;

  /// 每传输的发布台账。
  final Map<String, PublishLedger> _publishLedgers = {};

  /// 入站快照队列（引擎的合流计时器把载荷放进来，轮次消费）。
  final List<SyncEnvelope> _inbound = [];

  /// 本轮推送失败过的对端：名册重建时据此保留失败状态。
  final Set<String> _peersFailedThisRound = {};

  /// 本轮拉取失败过的对端：同一轮即使收到只带回执的载荷，也不能把失败
  /// 伪装成成功接触（成功时间不前进、上次失败原因保留）。
  final Set<String> _peersPullFailedThisRound = {};

  /// 内存名册（本轮观测优先；落库状态在 [allPeers] 里合并进来）。
  final Map<String, SyncPeerState> _peersById = {};

  SyncEnvelope? _lastEnvelope;

  bool get incrementalEnabled => _journal != null;

  SyncEnvelope? get lastEnvelope => _lastEnvelope;

  Map<String, SyncTransport> get transports => _transports;

  int _nowMs() => _clock().millisecondsSinceEpoch;

  Future<String> _fingerprintOf(Map<SyncCategory, List<SyncRecord>> records) =>
      _fingerprintPort?.fingerprint(records) ??
      Future.value(syncFingerprint(records));

  // ---- 入站队列（引擎的合流计时器与轮次共享） ----

  List<SyncEnvelope> get inbound => _inbound;

  void enqueueInbound(SyncEnvelope envelope) => _inbound.add(envelope);

  List<SyncEnvelope> takeInbound() {
    final snapshot = List<SyncEnvelope>.of(_inbound);
    _inbound.clear();
    return snapshot;
  }

  void restoreInbound(List<SyncEnvelope> envelopes) {
    _inbound.insertAll(0, envelopes);
  }

  // ---- 服务端语义（局域网端点 / WebDAV 日志文件） ----

  Future<SyncEnvelope> serveJournal({required int since}) async {
    final journal = _journal;
    if (journal == null) return serveSnapshot();
    final baseSeq = await journal.baseSeq();
    if (chooseJournalServeMode(
          since: since,
          baseSeq: baseSeq,
          headSeq: await journal.headSeq(),
        ) ==
        JournalServeMode.fullSnapshot) {
      return serveSnapshot();
    }
    final snapshot = _lastEnvelope ??
        await _buildLiveSnapshot(categories: _state.enabledCategories);
    final entries = await journal.window(since: since);
    final bounds = journalWindowBounds(entries);
    return SyncEnvelope(
      deviceId: _state.deviceId,
      deviceName: _state.deviceName,
      producedAt: _nowMs(),
      snapshotId: snapshot.snapshotId,
      journalHead: await journal.headSeq(),
      baseSeq: baseSeq,
      windowStart: bounds.windowStart,
      windowEnd: bounds.windowEnd,
      journal: entries,
      acks: snapshot.acks,
      categories: snapshot.categories,
    );
  }

  Future<SyncEnvelope> serveSnapshot() async =>
      _lastEnvelope ??
      await _buildLiveSnapshot(categories: _state.enabledCategories);

  Future<SyncEnvelope> _buildLiveSnapshot({
    required Set<SyncCategory> categories,
  }) async {
    final journal = _journal;
    final head = journal == null ? 0 : await journal.headSeq();
    final base = journal == null ? 0 : await journal.baseSeq();
    final records = await collect(categories);
    final pruned = _envelopeFrom(records).pruneTombstones(
      now: _nowMs(),
      tombstoneRetentionMs: tombstoneRetentionMs,
    );
    final snapshotId = await _fingerprintOf(pruned.records);
    return SyncEnvelope(
      deviceId: pruned.deviceId,
      deviceName: pruned.deviceName,
      producedAt: pruned.producedAt,
      records: pruned.records,
      journalHead: head,
      baseSeq: base,
      acks: _acks(),
      categories: [for (final category in categories) category.name],
    ).withSnapshotId(snapshotId);
  }

  /// 派生状态（日志 / 已知版本登记）随新命名空间重建。
  Future<void> resetDerivedState() async {
    await _journal?.reset();
    await _known.reset();
    _knownVersions = null;
  }

  void dispose() {
    unawaited(_runtime.stopAll());
  }

  // ---- 名册 ----

  void forgetPeer(String deviceId) {
    if (deviceId.isEmpty) return;
    _peersById.remove(deviceId);
    _peersFailedThisRound.remove(deviceId);
    _peersPullFailedThisRound.remove(deviceId);
  }

  SyncPeerState peerOf(String deviceId) {
    final existing = _peersById[deviceId];
    if (existing != null) return existing;
    for (final peer in _state.peers) {
      if (peer.deviceId == deviceId) return peer;
    }
    return SyncPeerState(deviceId: deviceId);
  }

  Iterable<SyncPeerState> allPeers() {
    for (final peer in _state.peers) {
      _peersById.putIfAbsent(peer.deviceId, () => peer);
    }
    return _peersById.values;
  }

  Future<List<SyncPeerState>> roster() async {
    final journal = _journal;
    final head = journal == null ? 0 : await journal.headSeq();
    final merged = <SyncPeerState>[];
    for (final peer in allPeers()) {
      if (peer.ackedSeq < 0 || head <= peer.ackedSeq) {
        merged.add(peer.copyWith(clearBehind: true));
        continue;
      }
      final behind = head - peer.ackedSeq;
      var behindBytes = peer.behindBytes;
      if (journal != null) {
        behindBytes = await journal.windowBytes(since: peer.ackedSeq);
      }
      merged.add(peer.copyWith(behindBy: behind, behindBytes: behindBytes));
    }
    final recent = trimPeers(merged, SyncStateStore.peerLimit);
    _peersById
      ..clear()
      ..addEntries(recent.map((peer) => MapEntry(peer.deviceId, peer)));
    return recent;
  }

  // ---- 轮次编排 ----

  Future<SyncRoundReport> runRound({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  }) async {
    final startedAt = _nowMs();
    final context = SyncRoundContext(
      trigger: trigger,
      push: push,
      antiEntropy: antiEntropy,
      onlyCategories: onlyCategories,
      startedAt: startedAt,
      window: SyncRoundWindow(startedAt: startedAt),
    );
    try {
      await collectStage(context);
      await pullStage(context);
      await consumeStage(context);
      await applyStage(context);
      await publishStage(context);
      context.report = await reportStage(context);
      _logger.fine(() => '同步一轮完成：${context.report}');
    } on _RoundAbort catch (abort) {
      // 用户可行动的明确状态（未设置口令）：不按内部异常处理。
      _logger.warning('同步一轮未完成：${abort.issue}');
      context.report = SyncRoundReport(
        trigger: trigger,
        startedAt: context.startedAt,
        finishedAt: _nowMs(),
        outcome: SyncOutcome.failed,
        error: abort.issue,
      );
    } catch (e, stackTrace) {
      _logger.warning('同步一轮失败', e, stackTrace);
      context.report = SyncRoundReport(
        trigger: trigger,
        startedAt: context.startedAt,
        finishedAt: _nowMs(),
        outcome: SyncOutcome.failed,
        error: SyncIssue(code: SyncIssueCode.internal, detail: '$e'),
      );
    }
    return context.report!;
  }

  /// 阶段 1：口令、传输、本地视图、变更判定、名册登记基线。
  Future<void> collectStage(SyncRoundContext context) async {
    final passphrase = await _state.readPassphrase();
    if (passphrase == null || passphrase.trim().isEmpty) {
      throw const _RoundAbort(SyncIssue(code: SyncIssueCode.noPassphrase));
    }
    context.passphrase = passphrase;
    await _runtime.ensureRunning();
    _peersFailedThisRound.clear();
    _peersPullFailedThisRound.clear();

    final journal = _journal;
    // 日志头部在收集本地视图**之前**读取：本轮快照覆盖到的位置不会漏掉
    // 随后发生的写入（写入的 seq 必然大于它，走下一份增量）。
    context.journalHead = journal == null ? 0 : await journal.headSeq();
    context.categories = context.onlyCategories ?? _state.enabledCategories;
    context.local = await collect(
      context.categories,
      fresh: context.antiEntropy,
    );
    context.localChanged = journal == null
        ? (_localFingerprint == null ||
            await _fingerprintOf(context.local) != _localFingerprint)
        : context.journalHead != _localJournalHead;

    // 本地视图就是适配器当前状态：以本地版本播种登记（内存内，不落库），
    // 空闲轮不向适配器交付任何记录；远端胜者版本更高时仍会交付。
    final known = await _ensureKnown();
    for (final entry in context.local.entries) {
      for (final record in entry.value) {
        known.putIfAbsent(
          (category: entry.key, key: record.key),
          () => record.version,
        );
      }
    }

    // 传输运行状态先落进报告：入站轮不拉取，但「开关开着但没在工作」同样
    // 要可见，且「本轮有没有可用传输」的判定不依赖拉取动作。
    context.accumulators = {
      for (final kind in _transports.keys)
        kind: SyncTransportAccumulator(
          kind,
          enabled: _state.enabledTransports.contains(kind),
        ),
    };
    for (final entry in _transports.entries) {
      final accumulator = context.accumulators[entry.key]!;
      if (!accumulator.enabled) continue;
      accumulator
        ..running = entry.value.isRunning
        ..unavailableReason = entry.value.unavailableReason;
      if (!entry.value.isRunning) {
        accumulator.error = SyncIssue(
          code: entry.value.unavailableReason ?? SyncIssueCode.startFailed,
          detail: entry.value.unavailableDetail,
        );
      }
    }
  }

  /// 阶段 2：anti-entropy 名单 + 一次拉取（入站轮不主动拉）。
  Future<void> pullStage(SyncRoundContext context) async {
    // 入站轮只消费收到的快照：不主动拉取任何对端。
    context.inboundOnly = context.trigger == SyncTrigger.incoming;
    // 强制发现：启动 / 回前台 / 换网 / 手动轮要广播 + 组播 + 单播；
    // 其余轮次只对已有候选单播（空闲轮 0 广播）。
    final forceDiscovery = context.trigger == SyncTrigger.manual ||
        context.trigger == SyncTrigger.startup ||
        context.trigger == SyncTrigger.resume ||
        context.trigger == SyncTrigger.network;

    // anti-entropy：对端内容指纹与本机不一致、且本机没有它的新条目时，
    // 主动取一次全量快照修复静默分歧（LWW 只保证「有新数据时收敛」）。
    context.fullFor = context.antiEntropy
        ? await _antiEntropyPeers(context.local, context.categories)
        : const <String>{};
    if (!context.inboundOnly) {
      context.pullContact = await _pullInto(
        context.accumulators,
        SyncPullRequest(
          plan: _pullPlan(
            fullPeers: context.fullFor,
            forceDiscovery: forceDiscovery,
          ),
          window: context.window,
        ),
        context.pulledEntries,
      );
    }

    // 入站轮同样消费收到的快照；窗口缺口只对被推来「不完整窗口」的对端
    // 做定向 bootstrap，不是全量广播。
    context.inboundSnapshot = takeInbound();
    for (final envelope in context.inboundSnapshot) {
      context.pulledEntries.add(('', envelope));
    }
  }

  /// 阶段 3：消费载荷（游标 / ack / 缺口）+ 缺口二次拉取。
  Future<void> consumeStage(SyncRoundContext context) async {
    // 待提交的游标（应用成功后才落进名册 / ack）：apply 失败时不推进，
    // 下轮按原游标重取，避免「未落地的变更被永久跳过」。
    var fullPeers = await _consumePayloads(
      context.pulledEntries,
      context.remoteRecords,
      context.forcedDelivery,
      context.pendingCursors,
      requestedFull: context.fullFor,
      antiEntropy: context.antiEntropy,
      local: context.local,
      categories: context.categories,
    );
    if (fullPeers.isEmpty) return;
    // 窗口缺口（条目已被对端裁剪 / 载荷不完整）或指纹不一致：同一轮内
    // 立刻改取全量快照（幂等；最多两遍，避免无限往返）。
    final secondEntries = <(String, SyncEnvelope)>[];
    final contacted = await _pullInto(
      context.accumulators,
      SyncPullRequest(
        plan: _pullPlan(fullPeers: fullPeers),
        window: context.window,
      ),
      secondEntries,
    );
    context.pullContact = context.pullContact || contacted;
    context.pulledEntries.addAll(secondEntries);
    fullPeers = await _consumePayloads(
      secondEntries,
      context.remoteRecords,
      context.forcedDelivery,
      context.pendingCursors,
      requestedFull: fullPeers,
      antiEntropy: false,
      local: context.local,
      categories: context.categories,
    );
  }

  /// 阶段 4：合并 + 只交付版本变化的胜者 + 应用成功才提交游标。
  Future<void> applyStage(SyncRoundContext context) async {
    final known = await _ensureKnown();
    try {
      // 强制交付的键：合并时剔除本地同版本记录，让权威视图胜出
      // （同版本但内容不一致 = 本地被直接改写，不能按「先出现者胜」保留）。
      final localForMerge = <SyncCategory, List<SyncRecord>>{};
      for (final entry in context.local.entries) {
        final kept = [
          for (final record in entry.value)
            if (!context.forcedDelivery
                .contains((category: entry.key, key: record.key)))
              record,
        ];
        if (kept.isNotEmpty) localForMerge[entry.key] = kept;
      }
      final merged = mergeEnvelopesByCategory(
        [
          _envelopeFrom(localForMerge),
          SyncEnvelope(
            deviceId: _state.deviceId,
            producedAt: context.startedAt,
            records: context.remoteRecords,
          ),
        ],
        categories: context.categories,
      );

      for (final adapter in _adapters) {
        if (!adapter.ready) continue;
        // 只交付版本变化的胜者：登记一致的键不进入适配器（变更集应用）。
        final subset = <SyncCategory, List<SyncRecord>>{};
        for (final category in adapter.categories) {
          final winners = merged[category];
          if (winners == null || winners.isEmpty) continue;
          for (final record in winners.values) {
            final key = (category: category, key: record.key);
            if (!context.forcedDelivery.contains(key) &&
                known[key] == record.version) {
              continue;
            }
            subset.putIfAbsent(category, () => []).add(record);
          }
        }
        if (subset.isEmpty) continue;
        try {
          final outcome = await adapter.apply(subset);
          context.applied += outcome.applied;
          // 交付成功才登记（含适配器跳过的项）：适配器对同一状态的判定
          // 是确定的，重复交付只会重复消耗；登记落库后跨重启不再重放。
          final delivered = <SyncKnownKey, SyncVersion>{};
          for (final entry in subset.entries) {
            for (final record in entry.value) {
              final key = (category: entry.key, key: record.key);
              if (known[key] == record.version) continue;
              delivered[key] = record.version;
            }
          }
          if (delivered.isNotEmpty) {
            known.addAll(delivered);
            await _known.putKnownVersions(delivered);
          }
        } catch (e) {
          // 应用失败 = 对端推来的记录没有落地：计入本轮失败并把入站快照放回
          // 队列（下轮重试），不静默丢数据。
          context.applyFailures++;
          _logger.warning('应用 ${adapter.runtimeType} 失败', e);
        }
      }
    } catch (e) {
      // 入站快照是对端花网络推过来的：本轮失败不能丢，放回队列下轮消费。
      restoreInbound(context.inboundSnapshot);
      context.inboundRestored = true;
      rethrow;
    }

    if (context.applyFailures > 0 && !context.inboundRestored) {
      restoreInbound(context.inboundSnapshot);
      context.inboundRestored = true;
    }

    // 游标只在**全部落地成功**后提交：失败轮不推进也不 ack（对端据此不会
    // 裁掉未落地的条目），下一轮按原游标重取（幂等）。
    //
    // 这里只改内存名册：落盘统一由引擎在 `runRound` 返回后做一次。旧实现
    // 每轮在 apply 后与 finally 各保存一次，活跃期 4s 去抖轮会把整份
    // sync_state_v2 写两遍，属于写放大回归。
    if (context.applyFailures == 0) {
      for (final entry in context.pendingCursors.entries) {
        final peer = _peersById[entry.key];
        if (peer == null) continue;
        _peersById[entry.key] = peer.copyWith(cursorSeq: entry.value);
      }
    }
  }

  /// 阶段 5：裁日志 + 构建本轮外发视图 + 推送。
  Future<void> publishStage(SyncRoundContext context) async {
    final journal = _journal;
    var journalBase = 0;
    int? snapshotSeq;
    if (journal != null) {
      final now = _nowMs();
      await journal.compact(
        minAck: _minPeerAck(now) ?? 0,
        coverage: journalCoverage(
          ledgers: _publishLedgers.values,
          enabledKinds: _state.enabledTransports,
          journalHead: context.journalHead,
        ),
        nowMs: now,
      );
      snapshotSeq = await journal.snapshotSeq();
      journalBase = await journal.baseSeq();
      if (snapshotSeq < 0) {
        // 首次构建全量快照：内容覆盖到本轮头部（引擎随后按需发布）。
        await journal.markSnapshotBuilt(context.journalHead);
        snapshotSeq = context.journalHead;
      }
    }
    context.journalBase = journalBase;
    context.snapshotSeq = snapshotSeq;

    // 推送合并后的本地视图（重新收集，包含刚应用的远端记录）。
    final refreshed = await collect(context.categories);
    final pruned = _envelopeFrom(refreshed).pruneTombstones(
      now: _nowMs(),
      tombstoneRetentionMs: tombstoneRetentionMs,
    );
    // 内容指纹按实际外发的记录集（裁剪墓碑后）计算：对端探测应答与发布
    // 台账的快照门控都拿它与自己已记下的值比较。
    //
    // 复用：日志头部未推进（没有任何本机写入）、本轮没有落地远端记录、
    // 墓碑也没被裁掉时，记录集与上一轮完全相同——`_fingerprint` 是逐条
    // jsonEncode 的 O(全库) 工作，空闲轮不必付。
    final refreshedCount = _recordCount(refreshed);
    final prunedCount = _recordCount(pruned.records);
    final fingerprintReusable = journal != null &&
        _snapshotFingerprintId != null &&
        context.journalHead == _snapshotFingerprintHead &&
        context.applied == 0 &&
        prunedCount == refreshedCount;
    final snapshotId = fingerprintReusable
        ? _snapshotFingerprintId!
        : await _fingerprintOf(pruned.records);
    _snapshotFingerprintId = snapshotId;
    _snapshotFingerprintHead = context.journalHead;
    _localJournalHead = context.journalHead;
    // 未注入日志时保留整视图指纹：下一轮的变更判定用它。
    if (journal == null) {
      _localFingerprint = await _fingerprintOf(refreshed);
    }
    final outgoing = SyncEnvelope(
      deviceId: pruned.deviceId,
      deviceName: pruned.deviceName,
      producedAt: pruned.producedAt,
      records: pruned.records,
      journalHead: context.journalHead,
      baseSeq: journalBase,
      acks: _acks(),
      // 本载荷覆盖的类别（蜂窝小类别轮只含小类别）：anti-entropy 按它
      // 只在双方共享的类别上比对指纹。
      categories: [for (final category in context.categories) category.name],
    ).withSnapshotId(snapshotId);
    _lastEnvelope = outgoing;
    context.refreshed = refreshed;
    context.outgoing = outgoing;

    // 增量窗口：只带变更（对端按自己的游标过滤应用）。窗口为空但 ack
    // 有推进时也要外发：对端据此 compact 自己的日志。
    //
    // 惰性构建：窗口读取 + 逐条 jsonDecode 是 O(窗口条目) 的开销，
    // 入站轮 / 没有可用传输的轮次根本用不到，不预先构建。
    SyncEnvelope? delta;
    var deltaBuilt = false;
    Future<SyncEnvelope?> buildDelta() async {
      if (!deltaBuilt) {
        deltaBuilt = true;
        delta = journal == null ? null : await _buildDelta(journal, outgoing);
      }
      return delta;
    }

    if (!context.push) return;
    for (final entry in _transports.entries) {
      final accumulator = context.accumulators[entry.key]!;
      final transport = entry.value;
      if (!transport.isRunning ||
          !_state.enabledTransports.contains(entry.key)) {
        continue;
      }
      final ledger = _publishLedgers[entry.key]!;
      // 1) 全量快照：首次引导 / 日志超硬上限重写时发布；未注入日志时
      //    始终外发全量。内容未变 / 已发布覆盖够到时跳过加密 + 上传。
      if (ledger.plan(outgoing, snapshotSeq: snapshotSeq)) {
        final result = await _pushEnvelope(
          transport,
          outgoing,
          accumulator,
          context.window,
        );
        context.succeededPushes += result.succeededPeers;
        await ledger.mark(result);
        _recordPushPeers(result, entry.key);
      }
      // 2) 增量窗口：内容或 ack 有变化才推（对端未变不传、不解密）。
      final deltaEnvelope = await buildDelta();
      if (deltaEnvelope != null && ledger.plan(deltaEnvelope)) {
        final result = await _pushEnvelope(
          transport,
          deltaEnvelope,
          accumulator,
          context.window,
        );
        context.succeededPushes += result.succeededPeers;
        await ledger.mark(result);
        _recordPushPeers(result, entry.key);
      }
    }

    // 本地变更但本轮 LAN 推送零对端：单次定向公告，唤醒对端来拉（只单播，
    // 不广播）。失败只记日志：公告是「加速」而不是正确性前提。
    if (context.localChanged &&
        _state.enabledTransports.contains(SyncTransportKind.lan) &&
        (context.accumulators[SyncTransportKind.lan]?.pushed ?? 0) == 0) {
      unawaited(_runtime.announceLocalChange(SyncTransportKind.lan));
    }
  }

  /// 阶段 6：五态判定与报告（不写状态；引擎在 `runRound` 返回后落报告 / 通知）。
  Future<SyncRoundReport> reportStage(SyncRoundContext context) async {
    final transportReports = [
      for (final accumulator in context.accumulators.values)
        accumulator.build(),
    ];
    final failedCount = transportReports.fold<int>(
      0,
      (sum, item) => sum + item.failedPulls + item.failedPushes,
    );
    final peersSeen = transportReports.fold<int>(
      0,
      (sum, item) => sum + item.peersSeen,
    );
    final succeededPulls = transportReports.fold<int>(
      0,
      (sum, item) => sum + item.pulled,
    );
    final anyTransport =
        transportReports.any((item) => item.enabled && item.running);
    final remoteCount = context.remoteRecords.values
        .fold<int>(0, (sum, list) => sum + list.length);
    final contact = peersSeen > 0 ||
        context.applied > 0 ||
        remoteCount > 0 ||
        failedCount + context.applyFailures > 0;
    final outcome = _resolveOutcome(
      anyTransport: anyTransport,
      contact: contact,
      pullContact: context.pullContact,
      failed: failedCount + context.applyFailures,
      succeededPulls: succeededPulls,
      succeededPushes: context.succeededPushes,
      applied: context.applied,
      localChanged: context.localChanged,
    );
    final transportError = transportReports
        .map((item) => item.error)
        .firstWhere((value) => value != null, orElse: () => null);
    final applyError = context.applyFailures > 0
        ? SyncIssue(
            code: SyncIssueCode.applyFailed,
            args: {'count': context.applyFailures},
          )
        : null;
    final error = switch (outcome) {
      SyncOutcome.failed =>
        transportError ?? applyError ?? _allPeersUnreachable(transportReports),
      SyncOutcome.partial => transportError ?? applyError,
      // noPeers 不吞传输级错误：广播失败 / 零应答 / 目录准备失败要能看见。
      SyncOutcome.noPeers => transportError,
      _ => null,
    };
    return SyncRoundReport(
      trigger: context.trigger,
      startedAt: context.startedAt,
      finishedAt: _nowMs(),
      outcome: outcome,
      applied: context.applied,
      applyFailures: context.applyFailures,
      transports: transportReports,
      peers: await roster(),
      remoteRecords: remoteCount,
      error: error,
    );
  }

  // ---- 拉取实现 ----

  Future<bool> _pullInto(
    Map<String, SyncTransportAccumulator> accumulators,
    SyncPullRequest request,
    List<(String, SyncEnvelope)> out,
  ) async {
    var contact = false;
    for (final entry in _transports.entries) {
      final accumulator = accumulators[entry.key]!;
      final transport = entry.value;
      if (!_state.enabledTransports.contains(entry.key)) continue;
      accumulator
        ..running = transport.isRunning
        ..unavailableReason = transport.unavailableReason;
      if (!transport.isRunning) {
        // 启动类失败（端口占用 / 权限 / 未配置）进入本轮错误面：
        // 「开关开着但没在工作」必须在状态与日志里看得见。
        accumulator.error ??= SyncIssue(
          code: transport.unavailableReason ?? SyncIssueCode.startFailed,
          detail: transport.unavailableDetail,
        );
        continue;
      }
      final watch = Stopwatch()..start();
      SyncPullResult result;
      try {
        result = await transport.pull(request);
      } catch (e) {
        result = SyncPullResult(
          failedPeers: 1,
          error: SyncIssue(code: SyncIssueCode.pullFailed, detail: '$e'),
        );
      }
      watch.stop();
      accumulator
        ..pulled += result.envelopes.length
        ..peersSeen += result.peersSeen
        ..skippedUnchanged += result.skippedUnchanged
        ..failedPulls += result.failedPeers
        ..bytesIn += result.bytesIn
        ..durationMs += watch.elapsedMilliseconds
        ..error ??= result.error;
      contact = contact || result.contacted;
      // 失败优先于同名成功：传输明确报告某台设备读取失败时，即使它同时
      // 出现在 seenIds（旧实现 / 回执文件成功），也不能算成功接触。
      final failedIds = result.failedIds.toSet();
      // 任何成功接触（含未变跳过 / 探测应答）都更新「最近接触」与
      // lastSuccessAt：在线但长期没有内容变化的对端不该被误标失联。
      for (final id in result.seenIds) {
        if (failedIds.contains(id)) continue;
        _touchPeerSeen(id, entry.key);
      }
      // 失败只刷新「最近尝试」与 lastError，不动 lastSuccessAt。
      for (final id in result.failedIds) {
        _touchPeerPullFailed(
          id,
          entry.key,
          _pullFailureIssue(result, id),
        );
      }
      for (final envelope in result.envelopes) {
        out.add((entry.key, envelope));
      }
    }
    return contact;
  }

  Future<SyncPushResult> _pushEnvelope(
    SyncTransport transport,
    SyncEnvelope envelope,
    SyncTransportAccumulator accumulator,
    SyncRoundWindow window,
  ) async {
    final watch = Stopwatch()..start();
    SyncPushResult result;
    try {
      result = await transport.push(envelope, window: window);
    } catch (e) {
      result = SyncPushResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.pushFailed, detail: '$e'),
      );
    }
    watch.stop();
    accumulator
      ..pushed += result.succeededPeers
      ..failedPushes += result.failedPeers
      ..bytesOut += result.bytesOut
      ..durationMs += watch.elapsedMilliseconds
      ..error ??= result.error;
    return result;
  }

  void _recordPushPeers(SyncPushResult result, String kind) {
    for (final id in result.succeededIds) {
      _touchPeerPushOk(id, kind);
    }
    for (final id in result.failedIds) {
      _touchPeerPushFailed(id, kind);
    }
  }

  /// 拉取失败的逐设备原因：能识别为解密失败时保留更具体的原因，否则按
  /// 读取失败处理；`peer` 参数换成设备 id，详情弹层才能说清是哪台。
  SyncIssue _pullFailureIssue(SyncPullResult result, String deviceId) {
    final error = result.error;
    final code = switch (error?.code) {
      SyncIssueCode.peerDecryptFailed ||
      SyncIssueCode.webdavDecryptFailed =>
        error!.code,
      _ => SyncIssueCode.peerReadFailed,
    };
    return SyncIssue(code: code, args: {'peer': deviceId});
  }

  Future<Set<String>> _consumePayloads(
    List<(String, SyncEnvelope)> payloads,
    Map<SyncCategory, List<SyncRecord>> remoteRecords,
    Set<SyncKnownKey> forcedDelivery,
    Map<String, int> pendingCursors, {
    required Set<String> requestedFull,
    required bool antiEntropy,
    required Map<SyncCategory, List<SyncRecord>> local,
    required Set<SyncCategory> categories,
  }) async {
    final fullPeers = <String>{};
    final now = _nowMs();
    for (final (kind, envelope) in payloads) {
      final peerId = envelope.deviceId;
      if (peerId.isEmpty) continue;
      final existing = peerOf(peerId);
      // 吸收远端版本（含未获胜者与被跳过的载荷）：超前戳让本机下一次写入必胜。
      for (final list in envelope.payloadRecords.values) {
        for (final record in list) {
          _stamps.observe(record.version);
        }
      }

      // 本轮已从同一对端接受过载荷时用待提交游标：同一轮里「拉取 + 入站推送」
      // 两份载荷不能各自从旧游标重新判缺口（会误判成缺口而重复全量拉取）。
      final pending = pendingCursors[peerId];
      final cursor = pending != null && pending > existing.cursorSeq
          ? pending
          : existing.cursorSeq;
      var ackedSeq = existing.ackedSeq;
      var fullPulledAt = existing.fullPulledAt;
      var nextCursor = cursor;
      var gap = false;
      if (envelope.isDelta) {
        // 游标语义（-1 夹到 0、连续条目、空窗口不算截断、缺口只推进到已接受
        // 位置）集中在协议模块：这里只把结果落到远端记录与待提交游标。
        final consumed = consumeJournalDelta(
          cursor: cursor,
          baseSeq: envelope.baseSeq,
          windowEnd: envelope.windowEnd,
          entries: envelope.journal ?? const <SyncJournalEntry>[],
        );
        for (final entry in consumed.accepted) {
          remoteRecords.putIfAbsent(entry.category, () => []).add(entry.record);
        }
        nextCursor = consumed.nextCursor;
        if (consumed.gap) {
          gap = true;
          fullPeers.add(peerId);
        }
      } else {
        // 全量快照：记录集整体应用，游标推进到快照覆盖的位置。
        final force = requestedFull.contains(peerId);
        for (final entry in envelope.records.entries) {
          if (entry.value.isEmpty) continue;
          remoteRecords.putIfAbsent(entry.key, () => []).addAll(entry.value);
          if (force) {
            for (final record in entry.value) {
              forcedDelivery.add((category: entry.key, key: record.key));
            }
          }
        }
        // 全量快照 = 权威全量视图：游标落在快照覆盖位置（**不取最大**）。
        // 对端日志重置时它的头部会变小，取最大会让游标悬空——之后 seq 更小
        // 的变更被永久跳过（静默分歧）。回退导致的重取是幂等的。
        nextCursor = envelope.journalHead;
        fullPulledAt = now;
      }
      if (nextCursor != cursor) {
        // 同一轮同一对端可能有多份载荷（拉取 + 入站推送）：以**后处理**的
        // 那份判定为准（全量快照的权威位置覆盖此前的增量推进），因此这里不做
        // 「取最大」——那会让重置后的回退永远提交不出去。
        pendingCursors[peerId] = nextCursor;
      }
      if (!gap) {
        // 对端载荷里的 ack 回执：它已消费本机 journal 到该位置（用于 compact）。
        final ack = envelope.acks[_state.deviceId];
        if (ack != null && ack > ackedSeq) ackedSeq = ack;
        // anti-entropy：对端内容指纹与本机不一致，而它的日志又没有本机缺的
        // 条目（游标已到头部）——静默分歧，取一次全量快照兜底；同一对端按
        // 节流间隔不频繁重拉（分歧仍会被修复）。
        if (antiEntropy &&
            envelope.snapshotId.isNotEmpty &&
            isPeerUpToDate(cursor: cursor, headSeq: envelope.journalHead) &&
            now - fullPulledAt >= antiEntropyIntervalMs &&
            await _fingerprintDiffers(
              peerSnapshotId: envelope.snapshotId,
              peerCategories: envelope.categories,
              local: local,
              categories: categories,
            )) {
          fullPeers.add(peerId);
        }
      }

      _peersById[peerId] = existing.copyWith(
        name: envelope.deviceName.isNotEmpty ? envelope.deviceName : null,
        transport: kind.isNotEmpty ? kind : null,
        lastSeenAt: now,
        // 本轮拉取失败过的设备：即使随后收到只带回执的载荷，也不刷新成功
        // 时间（失败不能伪装成成功接触）；游标 / ack 照常推进。
        lastPullAt: _peersPullFailedThisRound.contains(peerId) ? null : now,
        lastSuccessAt:
            _peersPullFailedThisRound.contains(peerId) ? null : now,
        // 成功拉取 = 接触成功：清掉上一次的失败；本轮推送失败 / 拉取失败的
        // 对端保留状态。
        lastError: _peersFailedThisRound.contains(peerId) ||
                _peersPullFailedThisRound.contains(peerId)
            ? existing.lastError
            : null,
        clearLastError: !_peersFailedThisRound.contains(peerId) &&
            !_peersPullFailedThisRound.contains(peerId),
        ackedSeq: ackedSeq,
        snapshotId: envelope.snapshotId.isNotEmpty ? envelope.snapshotId : null,
        categories: envelope.categories.isNotEmpty ? envelope.categories : null,
        fullPulledAt: fullPulledAt > 0 ? fullPulledAt : null,
        clockSkewMs: envelope.producedAt > 0 ? envelope.producedAt - now : null,
      );
    }
    return fullPeers;
  }

  SyncPullPlan _pullPlan({
    Set<String> fullPeers = const {},
    bool forceDiscovery = false,
  }) {
    final peers = <String, SyncPeerPullIntent>{};
    for (final peer in allPeers()) {
      if (peer.deviceId.isEmpty) continue;
      peers[peer.deviceId] = SyncPeerPullIntent(
        deviceId: peer.deviceId,
        cursor: peer.cursorSeq,
        forceFull: fullPeers.contains(peer.deviceId),
      );
    }
    for (final id in fullPeers) {
      peers.putIfAbsent(
        id,
        () => SyncPeerPullIntent(
          deviceId: id,
          cursor: SyncPullRequest.noCursor,
          forceFull: true,
        ),
      );
    }
    return SyncPullPlan(
      discovery:
          forceDiscovery ? SyncPullDiscovery.full : SyncPullDiscovery.knownOnly,
      peers: peers,
    );
  }

  Map<String, int> _acks() {
    final acks = <String, int>{};
    for (final peer in allPeers()) {
      if (peer.cursorSeq >= 0) acks[peer.deviceId] = peer.cursorSeq;
    }
    return acks;
  }

  Future<bool> _fingerprintDiffers({
    required String peerSnapshotId,
    required List<String> peerCategories,
    required Map<SyncCategory, List<SyncRecord>> local,
    required Set<SyncCategory> categories,
  }) async {
    final peerSet = <SyncCategory>{
      for (final name in peerCategories)
        if (SyncCategory.tryParse(name) case final category?) category,
    };
    if (peerSet.isEmpty) {
      // 对端未声明类别（测试注入的载荷）：按本机类别集合比较。
      peerSet.addAll(categories);
    }
    if (!categories.containsAll(peerSet)) return false;
    final pruned = _envelopeFrom(local).pruneTombstones(
      now: _nowMs(),
      tombstoneRetentionMs: tombstoneRetentionMs,
    );
    final subset = <SyncCategory, List<SyncRecord>>{
      for (final entry in pruned.records.entries)
        if (peerSet.contains(entry.key)) entry.key: entry.value,
    };
    final localFingerprint = await _fingerprintOf(subset);
    return localFingerprint != peerSnapshotId;
  }

  Future<Set<String>> _antiEntropyPeers(
    Map<SyncCategory, List<SyncRecord>> local,
    Set<SyncCategory> categories,
  ) async {
    final now = _nowMs();
    final peers = <String>[];
    for (final peer in allPeers()) {
      if (peer.snapshotId.isEmpty) continue;
      if (now - peer.fullPulledAt < antiEntropyIntervalMs) continue;
      if (await _fingerprintDiffers(
        peerSnapshotId: peer.snapshotId,
        peerCategories: peer.categories,
        local: local,
        categories: categories,
      )) {
        peers.add(peer.deviceId);
      }
    }
    return peers.toSet();
  }

  int? _minPeerAck(int nowMs) {
    int? minAck;
    for (final peer in allPeers()) {
      if (peer.ackedSeq < 0) continue;
      if (peer.isLostAt(nowMs)) continue;
      if (minAck == null || peer.ackedSeq < minAck) minAck = peer.ackedSeq;
    }
    return minAck;
  }

  Future<SyncEnvelope?> _buildDelta(
    SyncJournalStore journal,
    SyncEnvelope outgoing,
  ) async {
    final entries = await journal.window(since: outgoing.baseSeq);
    final bounds = journalWindowBounds(entries);
    return SyncEnvelope(
      deviceId: outgoing.deviceId,
      deviceName: outgoing.deviceName,
      producedAt: outgoing.producedAt,
      snapshotId: outgoing.snapshotId,
      journalHead: outgoing.journalHead,
      baseSeq: outgoing.baseSeq,
      windowStart: bounds.windowStart,
      windowEnd: bounds.windowEnd,
      journal: entries,
      acks: outgoing.acks,
      categories: outgoing.categories,
    );
  }

  /// 成功接触（探测应答 / 未变跳过）：刷新最近尝试与成功时间，清除失败。
  void _touchPeerSeen(String deviceId, String kind) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    final now = _nowMs();
    _peersFailedThisRound.remove(deviceId);
    _peersPullFailedThisRound.remove(deviceId);
    _peersById[deviceId] = existing.copyWith(
      transport: kind,
      lastSeenAt: now,
      lastSuccessAt: now,
      clearLastError: true,
    );
  }

  /// 推送成功：一次真正交换数据，同时刷新最近尝试与成功时间。
  void _touchPeerPushOk(String deviceId, String kind) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    final now = _nowMs();
    _peersFailedThisRound.remove(deviceId);
    _peersById[deviceId] = existing.copyWith(
      transport: kind,
      lastSeenAt: now,
      lastSuccessAt: now,
      lastPushAt: now,
      clearLastError: true,
    );
  }

  /// 拉取失败：只刷新最近尝试与失败原因，lastSuccessAt 保持不变。
  void _touchPeerPullFailed(String deviceId, String kind, SyncIssue issue) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    _peersPullFailedThisRound.add(deviceId);
    _peersById[deviceId] = existing.copyWith(
      transport: kind,
      lastSeenAt: _nowMs(),
      lastError: issue,
    );
  }

  /// 推送失败：只刷新最近尝试与失败原因，lastSuccessAt 保持不变。
  void _touchPeerPushFailed(String deviceId, String kind) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    _peersFailedThisRound.add(deviceId);
    _peersById[deviceId] = existing.copyWith(
      transport: kind,
      lastSeenAt: _nowMs(),
      lastError: const SyncIssue(code: SyncIssueCode.pushFailed),
    );
  }

  // ---- 收集 ----

  /// 完整备份模块的收集入口（与一轮同步同一份类别过滤与缓存语义）。
  Future<Map<SyncCategory, List<SyncRecord>>> collectRecords(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) =>
      collect(categories, fresh: fresh);

  Future<Map<SyncCategory, List<SyncRecord>>> collect(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) async {
    // 适配器在指纹未变时返回同一份缓存对象（身份复用）；只要每个适配器的
    // 返回值身份都没变、类别集合也没变，聚合结果与上一轮完全相同——直接
    // 复用，省掉每轮 O(全库) 的按类别 addAll 拷贝（列表被当作不可变使用，
    // 与适配器缓存同一约定）。
    final results = <SyncAdapter, Map<SyncCategory, List<SyncRecord>>>{};
    var identicalToLastRound = !fresh &&
        _lastAggregate != null &&
        _lastAdapterCollect.length == _readyAdapterCount;
    for (final adapter in _adapters) {
      if (!adapter.ready) continue;
      final collected = await adapter.collect(fresh: fresh);
      results[adapter] = collected;
      if (identicalToLastRound &&
          !identical(_lastAdapterCollect[adapter], collected)) {
        identicalToLastRound = false;
      }
    }
    if (identicalToLastRound &&
        _sameCategorySet(_lastAggregateCategories, categories)) {
      return _lastAggregate!;
    }
    final result = <SyncCategory, List<SyncRecord>>{};
    for (final collected in results.values) {
      for (final entry in collected.entries) {
        if (!categories.contains(entry.key)) continue;
        if (entry.value.isEmpty) continue;
        result.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
    }
    _lastAdapterCollect
      ..clear()
      ..addAll(results);
    _lastAggregate = result;
    _lastAggregateCategories = {...categories};
    return result;
  }

  int get _readyAdapterCount {
    var count = 0;
    for (final adapter in _adapters) {
      if (adapter.ready) count++;
    }
    return count;
  }

  static bool _sameCategorySet(Set<SyncCategory>? a, Set<SyncCategory> b) {
    if (a == null || a.length != b.length) return false;
    for (final category in b) {
      if (!a.contains(category)) return false;
    }
    return true;
  }

  static int _recordCount(Map<SyncCategory, List<SyncRecord>> records) {
    var total = 0;
    for (final list in records.values) {
      total += list.length;
    }
    return total;
  }

  SyncEnvelope _envelopeFrom(Map<SyncCategory, List<SyncRecord>> records) =>
      SyncEnvelope(
        deviceId: _state.deviceId,
        deviceName: _state.deviceName,
        producedAt: _nowMs(),
        records: records,
      );

  Future<Map<SyncKnownKey, SyncVersion>> _ensureKnown() async =>
      _knownVersions ??= await _known.knownVersions();
}

/// 一轮内可变的传输累计器（构造报告时转成不可变的 [SyncTransportReport]）。
class SyncTransportAccumulator {
  SyncTransportAccumulator(this.kind, {required this.enabled});

  final String kind;
  final bool enabled;
  bool running = false;
  String? unavailableReason;
  int pulled = 0;
  int pushed = 0;
  int skippedUnchanged = 0;
  int peersSeen = 0;
  int failedPulls = 0;
  int failedPushes = 0;
  int bytesIn = 0;
  int bytesOut = 0;
  int durationMs = 0;
  SyncIssue? error;

  SyncTransportReport build() => SyncTransportReport(
        kind: kind,
        enabled: enabled,
        running: running,
        unavailableReason: unavailableReason,
        pulled: pulled,
        pushed: pushed,
        skippedUnchanged: skippedUnchanged,
        peersSeen: peersSeen,
        failedPulls: failedPulls,
        failedPushes: failedPushes,
        bytesIn: bytesIn,
        bytesOut: bytesOut,
        durationMs: durationMs,
        error: error,
      );
}

class _RoundAbort implements Exception {
  const _RoundAbort(this.issue);

  final SyncIssue issue;

  @override
  String toString() => 'SyncRoundAbort(${issue.code})';
}

/// 五态判定（优先级：没有可用传输 / 没联系上任何对端 → 全失败 →
/// 部分失败 → 无变化 → 完成）。
SyncOutcome _resolveOutcome({
  required bool anyTransport,
  required bool contact,
  required bool pullContact,
  required int failed,
  required int succeededPulls,
  required int succeededPushes,
  required int applied,
  required bool localChanged,
}) {
  if (!anyTransport || !contact) return SyncOutcome.noPeers;
  if (failed == 0) {
    if (!localChanged && applied == 0) return SyncOutcome.noChanges;
    return SyncOutcome.ok;
  }
  // 有失败：拉取动作成功（远端可达，零快照也算）/ 推送成功 / 有落地任一面
  // 成功过就是部分失败；全都没有才是整轮失败（有已知对端但全不可达）。
  if (succeededPulls == 0 &&
      succeededPushes == 0 &&
      applied == 0 &&
      !pullContact) {
    return SyncOutcome.failed;
  }
  return SyncOutcome.partial;
}

/// 全失败兜底原因：带上全不可达的传输（UI 据此给对应出路——手动地址是
/// 局域网概念，WebDAV 全失败只给配置与重试）。
SyncIssue _allPeersUnreachable(List<SyncTransportReport> reports) {
  final failedKinds = {
    for (final item in reports)
      if (item.failedPulls + item.failedPushes > 0) item.kind,
  };
  return SyncIssue(
    code: SyncIssueCode.allPeersUnreachable,
    args:
        failedKinds.length == 1 ? {'transport': failedKinds.single} : const {},
  );
}
