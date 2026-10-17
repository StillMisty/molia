import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import '../../domain/ports/sync_transport.dart';
import 'publish_ledger.dart';
import 'sync_adapter.dart';
import 'sync_journal.dart';
import 'sync_known_store.dart';
import 'sync_passphrase.dart';
import 'sync_scheduler.dart';
import 'sync_stamp.dart';
import 'sync_state_store.dart';

/// 同步引擎：一轮 = 收集本地视图 → 拉取远端快照 → 逐键合并 → 写回本地 →
/// 推送合并后视图 → 记录可观察的一轮结果（[SyncRoundReport]）。
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
  SyncEngine({
    required SyncStateStore state,
    required List<SyncAdapter> adapters,
    required Map<String, SyncTransport> transports,
    required SyncStampIssuer stamps,
    SyncKnownStore? known,
    SyncJournalStore? journal,
    DateTime Function()? clock,
    Duration inboundWindow = const Duration(milliseconds: 1500),
  })  : _state = state,
        _adapters = adapters,
        _transports = transports,
        _stamps = stamps,
        _known = known ?? InMemorySyncKnownStore(),
        _journal = journal,
        _inboundWindow = inboundWindow,
        _clock = clock ?? DateTime.now {
    for (final entry in transports.entries) {
      // 每传输一份发布台账：门控判据（跳过加密 / 上传、日志可裁范围）只有
      // 台账回答，引擎只提供「哪些传输存在 / 启用」这一编排事实。
      _publishLedgers[entry.key] = PublishLedger(
        kind: entry.key,
        state: state,
        servesLiveSnapshot: () => entry.value.servesLiveSnapshot,
      );
      _incomingSubscriptions.add(entry.value.incoming.listen(
        (envelope) => unawaited(onIncomingEnvelope(envelope)),
      ));
    }
  }

  /// 推送时丢弃保留期外的墓碑（防止无限膨胀；保留期内复活风险可忽略）。
  static const int tombstoneRetentionMs = 90 * 24 * 60 * 60 * 1000;

  final SyncStateStore _state;
  final List<SyncAdapter> _adapters;
  final Map<String, SyncTransport> _transports;

  /// 版本戳发号器（必填：唯一实例由组合根注入，避免各自建号发出重复版本）。
  final SyncStampIssuer _stamps;

  /// 已知版本登记（变更集判定）；未注入时退化为进程内登记。
  final SyncKnownStore _known;

  /// 增量日志（可选）：注入后日常轮次只外发**变更**（增量窗口），对端按游标
  /// 拉取；未注入时始终外发全量快照（仍正确，只是不增量）。
  final SyncJournalStore? _journal;

  /// 入站合流窗口：窗口内到达的多个对端推送合并成一轮。
  final Duration _inboundWindow;

  final DateTime Function() _clock;
  final List<SyncEnvelope> _inbound = [];
  final List<StreamSubscription<SyncEnvelope>> _incomingSubscriptions = [];
  final Logger _logger = Logger('molia.sync');

  /// 登记的内存视图（首次使用时加载一次，之后只写变化项）。
  Map<SyncKnownKey, SyncVersion>? _knownVersions;
  Timer? _inboundTimer;

  bool _syncing = false;
  bool _initialized = false;

  /// 同步进行中收到的同步请求（手动点击 / 入站推送）：合并成一次排队，
  /// 当前轮结束后立刻补跑，请求不会被丢弃。
  SyncTrigger? _pendingTrigger;
  bool _pendingAntiEntropy = false;

  SyncRoundReport? _lastReport;
  SyncEnvelope? _lastEnvelope;

  /// 上轮本地视图指纹（用于区分「本机没有变化」与「有变更需要外发」）。
  String? _localFingerprint;

  /// 上一轮快照指纹与它覆盖的日志头部（空闲轮复用，见 `_runRound`）。
  String? _snapshotFingerprintId;
  int? _snapshotFingerprintHead;

  /// 上一轮开始时的日志头部：与本轮头部比较即「本机有没有变化」。
  int? _localJournalHead;

  /// 上一轮各适配器的收集结果（身份）与聚合视图：见 [_collect] 的复用守卫。
  final Map<SyncAdapter, Map<SyncCategory, List<SyncRecord>>> _lastAdapterCollect =
      {};
  Map<SyncCategory, List<SyncRecord>>? _lastAggregate;
  Set<SyncCategory>? _lastAggregateCategories;

  /// 每传输的发布台账（键 = 传输标识）：跳过加密 / 上传与日志可裁范围的
  /// 唯一判据处（见 [PublishLedger]）。
  final Map<String, PublishLedger> _publishLedgers = {};

  SyncStateStore get state => _state;
  bool get syncing => _syncing;
  bool get initialized => _initialized;

  /// 最近一轮的完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _lastReport;

  /// 最近一轮推送/构建的快照（局域网端点直接返回给对端 GET）。
  SyncEnvelope? get lastEnvelope => _lastEnvelope;

  /// 服务端语义（局域网增量端点 / WebDAV 日志文件）：按请求方游标返回
  /// 增量窗口；游标落后于窗口起点（条目已被裁剪）时返回全量快照（bootstrap）。
  Future<SyncEnvelope> serveJournal({required int since}) async {
    final journal = _journal;
    if (journal == null) return serveSnapshot();
    final baseSeq = await journal.baseSeq();
    if (since < baseSeq) return serveSnapshot();
    final snapshot = _lastEnvelope ??
        await _buildLiveSnapshot(categories: _state.enabledCategories);
    final entries = await journal.window(since: since);
    return SyncEnvelope(
      deviceId: _state.deviceId,
      deviceName: _state.deviceName,
      producedAt: _nowMs(),
      snapshotId: snapshot.snapshotId,
      journalHead: await journal.headSeq(),
      baseSeq: baseSeq,
      windowStart: entries.isEmpty ? 0 : entries.first.seq,
      windowEnd: entries.isEmpty ? 0 : entries.last.seq,
      journal: entries,
      acks: snapshot.acks,
      categories: snapshot.categories,
    );
  }

  /// 全量快照（局域网 `GET /snapshot` 与 bootstrap 兜底）。
  ///
  /// 最近一轮的快照；本轮还没跑过（进程刚起 / 尚未启用）时就地收集一份——
  /// 否则对端会拿到空快照并把游标推进到 0，之后只能靠 anti-entropy 修复。
  Future<SyncEnvelope> serveSnapshot() async =>
      _lastEnvelope ??
      await _buildLiveSnapshot(categories: _state.enabledCategories);

  /// 就地构建一份全量快照（先读日志头部再收集：快照覆盖位置不会漏掉随后
  /// 发生的写入）。
  Future<SyncEnvelope> _buildLiveSnapshot({
    required Set<SyncCategory> categories,
  }) async {
    final journal = _journal;
    final head = journal == null ? 0 : await journal.headSeq();
    final base = journal == null ? 0 : await journal.baseSeq();
    final records = await _collect(categories);
    final pruned = _envelopeFrom(records).pruneTombstones(
      now: _nowMs(),
      tombstoneRetentionMs: tombstoneRetentionMs,
    );
    return SyncEnvelope(
      deviceId: pruned.deviceId,
      deviceName: pruned.deviceName,
      producedAt: pruned.producedAt,
      records: pruned.records,
      journalHead: head,
      baseSeq: base,
      acks: _acks(),
      categories: [for (final category in categories) category.name],
    ).withSnapshotId(_fingerprint(pruned.records));
  }

  /// 传输当前状态（UI 呈现「开关开着但没在工作」）；未知 kind 返回 null。
  /// 与一轮报告同一类型：计数为零、`error` 为启动类失败原因（含诊断细节），
  /// 避免「状态视图」与「报告」两套字段各自漂移。
  SyncTransportReport? transportStatus(String kind) {
    final transport = _transports[kind];
    if (transport == null) return null;
    final running = transport.isRunning;
    final reason = transport.unavailableReason;
    return SyncTransportReport(
      kind: kind,
      enabled: _state.enabledTransports.contains(kind),
      running: running,
      unavailableReason: reason,
      error: running || reason == null
          ? null
          : SyncIssue(code: reason, detail: transport.unavailableDetail),
    );
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// 登记的内存视图：首次使用时一次加载（之后由引擎维护）。
  Future<Map<SyncKnownKey, SyncVersion>> _ensureKnown() async =>
      _knownVersions ??= await _known.knownVersions();

  Future<void> init() async {
    if (_initialized) return;
    await _state.init();
    if (_state.enabled) await _ensureTransportsRunning();
    _initialized = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await _state.setEnabled(value);
    if (value) {
      await _ensureTransportsRunning();
    } else {
      await _stopTransports();
    }
    notifyListeners();
  }

  Future<void> setCategory(SyncCategory category, bool value) async {
    await _state.setCategory(category, value);
    notifyListeners();
  }

  Future<void> setTransportEnabled(String kind, bool value) async {
    await _state.setTransportEnabled(kind, value);
    final transport = _transports[kind];
    if (transport != null) {
      if (value) {
        await _ensureTransportsRunning();
      } else if (transport.isRunning) {
        await transport.stop();
      }
    }
    notifyListeners();
  }

  Future<void> setDeviceName(String value) async {
    await _state.setDeviceName(value);
    notifyListeners();
  }

  Future<void> setWebdavConfig(WebDavConfig config) async {
    await _state.setWebdavConfig(config);
    notifyListeners();
  }

  // 手动对端地址簿（局域网发现失败时的兜底：AP 隔离 / 多网段 / 防火墙）。
  // 权限被拒时它同样无效——那是网关级阻断，只能授权或转 WebDAV。

  /// 添加手动对端（地址 + 可选名称）；重复地址按地址合并。
  ///
  /// 返回 false 表示该地址已存在（UI 据此提示「已更新」而不是「已添加」）。
  Future<bool> addManualPeer(ManualPeer peer) async {
    final added = await _state.addManualPeer(peer);
    notifyListeners();
    return added;
  }

  /// 移除手动对端（只删地址簿条目，已发现的名册不受影响）。
  Future<void> removeManualPeer(String host) async {
    await _state.removeManualPeer(host);
    notifyListeners();
  }

  /// 本地忽略某台设备：不再拉取 / 合并它的载荷（幽灵 / 已失联设备的处置）。
  ///
  /// 只影响本机（对端不知道、其它设备不受影响）；远端文件不自动删除
  /// （需要时用 [cleanupRemote] 显式清理）。
  Future<void> setPeerIgnored(String deviceId, bool ignored) async {
    if (deviceId.isEmpty) return;
    await _state.setPeerIgnored(deviceId, ignored);
    if (ignored) _peersById.remove(deviceId);
    notifyListeners();
  }

  /// 显式清理某台设备的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 返回每个传输的结果；没有可清理内容的传输返回 false（局域网直连无远端
  /// 存储）。失败原因进日志与返回值，UI 据此提示。
  Future<({bool removed, SyncIssue? error})> cleanupRemote(
    String deviceId,
  ) async {
    if (deviceId.isEmpty) return (removed: false, error: null);
    var removed = false;
    SyncIssue? firstError;
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      try {
        if (await entry.value.deleteRemote(deviceId)) removed = true;
      } catch (e) {
        firstError ??= SyncIssue(
          code: SyncIssueCode.deleteRemoteFailed,
          args: {'peer': deviceId},
          detail: '$e',
        );
        _logger.warning('清理远端文件失败（${entry.key}/$deviceId）', e);
      }
    }
    return (removed: removed, error: firstError);
  }

  Future<String?> readPassphrase() => _state.readPassphrase();

  /// 读取现有口令；不存在时生成并持久化（开启同步的入口）。
  Future<String> ensurePassphrase() async {
    final existing = await _state.readPassphrase();
    if (existing != null && existing.trim().isNotEmpty) return existing;
    final generated = SyncPassphrase.generate();
    await _state.writePassphrase(generated);
    notifyListeners();
    return generated;
  }

  Future<void> setPassphrase(String passphrase) async {
    await _state.writePassphrase(passphrase);
    notifyListeners();
  }

  /// 重置口令：全部设备需重新输入（口令即信任根）。
  Future<String> resetPassphrase() async {
    final generated = SyncPassphrase.generate();
    await _state.writePassphrase(generated);
    notifyListeners();
    return generated;
  }

  /// 对端主动推送的快照：在合流窗口内合并成一轮。
  ///
  /// 入站轮只消费收到的快照：不拉取全部对端（避免 N 台平方级放大）、不推送
  /// （防止 A 推 B → B 推 A 的乒乓）；需要外发的本地变更由常规触发承担。
  /// 窗口内的多次推送（含多个对端）只触发一轮。
  Future<void> onIncomingEnvelope(SyncEnvelope envelope) async {
    if (!_state.enabled) return;
    _inbound.add(envelope);
    if (_syncing) {
      _pendingTrigger = _mergeTrigger(_pendingTrigger, SyncTrigger.incoming);
      return;
    }
    _inboundTimer ??= Timer(_inboundWindow, () {
      _inboundTimer = null;
      if (_inbound.isEmpty) return;
      unawaited(syncNow(trigger: SyncTrigger.incoming, push: false));
    });
  }

  /// 跑一轮同步。返回**最终**一轮的报告（若期间收到排队请求，会连续跑完）。
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
    if (_syncing) {
      // 排队一次：手动点击与入站推送都不该被静默丢弃。
      _pendingTrigger = _mergeTrigger(_pendingTrigger, trigger);
      _pendingAntiEntropy = _pendingAntiEntropy || antiEntropy;
      return _lastReport;
    }
    if (!_initialized) await init();
    if (!_state.enabled) return _lastReport;

    // 同步进行中到达的请求会被排队：整段（含补跑）持有 `_syncing`，保证同一时刻
    // 只有一条轮次在跑；点一次必有一次，多个入站推送也只合并成额外一轮。
    _syncing = true;
    notifyListeners();
    var nextTrigger = trigger;
    var nextAntiEntropy = antiEntropy;
    var nextCategories = onlyCategories;
    SyncRoundReport? report;
    try {
      while (true) {
        report = await _runRound(
          nextTrigger,
          push: push,
          antiEntropy: nextAntiEntropy,
          onlyCategories: nextCategories,
        );
        final pending = _pendingTrigger;
        _pendingTrigger = null;
        final pendingAntiEntropy = _pendingAntiEntropy;
        _pendingAntiEntropy = false;
        if (pending == null) break;
        nextTrigger = pending;
        nextAntiEntropy = pendingAntiEntropy;
        // 补跑轮沿用排队时的类别范围（同一策略下不应切换范围）。
        nextCategories = onlyCategories;
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return report;
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
    // 入站轮 / 未设置口令等中止轮不外发：待发标记保留给下一轮。
    if (report == null || !push) return SyncRunOutcome.none;
    final enabled = _state.enabledCategories;
    final categories = onlyCategories == null
        ? enabled
        : onlyCategories.intersection(enabled);
    return SyncRunOutcome(
      categories: categories,
      delivered: report.outcome != SyncOutcome.failed &&
          report.failedCount == 0,
    );
  }

  Future<SyncRoundReport> _runRound(
    SyncTrigger trigger, {
    required bool push,
    Set<SyncCategory>? onlyCategories,
    bool antiEntropy = false,
  }) async {
    final startedAt = _nowMs();
    var report = SyncRoundReport(
      trigger: trigger,
      startedAt: startedAt,
      finishedAt: startedAt,
      outcome: SyncOutcome.failed,
    );
    try {
      final passphrase = await _state.readPassphrase();
      if (passphrase == null || passphrase.trim().isEmpty) {
        throw const _RoundAbort(SyncIssue(code: SyncIssueCode.noPassphrase));
      }
      await _ensureTransportsRunning();
      // 本轮推送失败的对端（名册重建时据此保留失败状态）。
      _peersFailedThisRound.clear();

      // 日志头部在收集本地视图**之前**读取：本轮快照覆盖到的位置不会漏掉
      // 随后发生的写入（写入的 seq 必然大于它，走下一份增量）。
      final journal = _journal;
      final journalHead = journal == null ? 0 : await journal.headSeq();

      final categories = onlyCategories ?? _state.enabledCategories;
      // anti-entropy 轮重新读行（廉价指纹看不到「行被直接改写」）。
      final local = await _collect(categories, fresh: antiEntropy);
      // 「本机有没有变化」的判定：注入日志时看日志头部（所有类别的本机写入
      // 都在同一事务里追加，O(1)），否则退回整视图指纹（逐条 jsonEncode）。
      final localChanged = journal == null
          ? (_localFingerprint == null ||
              _fingerprint(local) != _localFingerprint)
          : journalHead != _localJournalHead;

      // 本地视图就是适配器当前状态：以本地版本播种登记（内存内，不落库），
      // 空闲轮不向适配器交付任何记录；远端胜者版本更高时仍会交付。
      final known = await _ensureKnown();
      for (final entry in local.entries) {
        for (final record in entry.value) {
          known.putIfAbsent(
            (category: entry.key, key: record.key),
            () => record.version,
          );
        }
      }

      // 拉取：逐传输计时 + 逐对端计数。
      final accumulators = <String, _TransportAccumulator>{
        for (final kind in _transports.keys)
          kind: _TransportAccumulator(
            kind,
            enabled: _state.enabledTransports.contains(kind),
          ),
      };
      // 传输运行状态先落进报告：入站轮不拉取，但「开关开着但没在工作」同样
      // 要可见，且「本轮有没有可用传输」的判定不依赖拉取动作。
      for (final entry in _transports.entries) {
        final accumulator = accumulators[entry.key]!;
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
      final pulledEntries = <(String, SyncEnvelope)>[];
      // 远端记录（已按本机游标过滤）：合并与报告都用它。
      final remoteRecords = <SyncCategory, List<SyncRecord>>{};
      // 主动请求的全量快照（anti-entropy / 窗口缺口兜底）带来的记录绕过
      // 「登记未变不交付」的变更集优化：快照是权威全量视图，本机可能有登记
      // 看不到的静默分歧（被篡改 / 直接改库），必须交给适配器按自身状态判定
      // （适配器幂等；这类全量拉取本身有节流，不会每轮发生）。
      final forcedDelivery = <SyncKnownKey>{};
      // 入站轮只消费收到的快照：不主动拉取任何对端。
      final inboundOnly = trigger == SyncTrigger.incoming;
      var pullContact = false;

      // anti-entropy：对端内容指纹与本机不一致、且本机没有它的新条目时，
      // 主动取一次全量快照修复静默分歧（LWW 只保证「有新数据时收敛」）。
      final fullFor = antiEntropy
          ? _antiEntropyPeers(local, categories)
          : const <String>{};
      if (!inboundOnly) {
        pullContact = await _pullInto(
          accumulators,
          SyncPullRequest(cursors: _cursors(), fullPeers: fullFor),
          pulledEntries,
        );
      }

      final inboundSnapshot = List<SyncEnvelope>.of(_inbound);
      _inbound.clear();
      for (final envelope in inboundSnapshot) {
        pulledEntries.add(('', envelope));
      }

      // 处理载荷：推进游标 / 学习对端 ack / 收集远端记录 / 识别窗口缺口。
      // 待提交的游标（应用成功后才落进名册 / ack）：apply 失败时不推进，
      // 下轮按原游标重取，避免「未落地的变更被永久跳过」。
      final pendingCursors = <String, int>{};
      var fullPeers = _consumePayloads(
        pulledEntries,
        remoteRecords,
        forcedDelivery,
        pendingCursors,
        requestedFull: fullFor,
        antiEntropy: antiEntropy,
        local: local,
        categories: categories,
      );
      if (fullPeers.isNotEmpty) {
        // 窗口缺口（条目已被对端裁剪 / 载荷不完整）或指纹不一致：同一轮内
        // 立刻改取全量快照（幂等；最多两遍，避免无限往返）。入站轮同样补：
        // 只对被推来「不完整窗口」的对端做定向 bootstrap，不是全量广播。
        final secondEntries = <(String, SyncEnvelope)>[];
        final contacted = await _pullInto(
          accumulators,
          SyncPullRequest(cursors: _cursors(), fullPeers: fullPeers),
          secondEntries,
        );
        pullContact = pullContact || contacted;
        pulledEntries.addAll(secondEntries);
        fullPeers = _consumePayloads(
          secondEntries,
          remoteRecords,
          forcedDelivery,
          pendingCursors,
          requestedFull: fullPeers,
          antiEntropy: false,
          local: local,
          categories: categories,
        );
      }

      var applied = 0;
      var applyFailures = 0;
      var inboundRestored = false;

      try {
        // 强制交付的键：合并时剔除本地同版本记录，让权威视图胜出
        // （同版本但内容不一致 = 本地被直接改写，不能按「先出现者胜」保留）。
        final localForMerge = <SyncCategory, List<SyncRecord>>{};
        for (final entry in local.entries) {
          final kept = [
            for (final record in entry.value)
              if (!forcedDelivery
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
              producedAt: startedAt,
              records: remoteRecords,
            ),
          ],
          categories: categories,
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
              if (!forcedDelivery.contains(key) &&
                  known[key] == record.version) {
                continue;
              }
              subset.putIfAbsent(category, () => []).add(record);
            }
          }
          if (subset.isEmpty) continue;
          try {
            final outcome = await adapter.apply(subset);
            applied += outcome.applied;
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
            applyFailures++;
            _logger.warning('应用 ${adapter.runtimeType} 失败', e);
          }
        }
      } catch (e) {
        // 入站快照是对端花网络推过来的：本轮失败不能丢，放回队列下轮消费。
        _inbound.insertAll(0, inboundSnapshot);
        inboundRestored = true;
        rethrow;
      }

      if (applyFailures > 0 && !inboundRestored) {
        _inbound.insertAll(0, inboundSnapshot);
        inboundRestored = true;
      }

      // 游标只在**全部落地成功**后提交：失败轮不推进也不 ack（对端据此不会
      // 裁掉未落地的条目），下一轮按原游标重取（幂等）。
      if (applyFailures == 0) {
        for (final entry in pendingCursors.entries) {
          final peer = _peersById[entry.key];
          if (peer == null) continue;
          _peersById[entry.key] = peer.copyWith(cursorSeq: entry.value);
        }
      }

      await _state.save();

      // compact：按对端 ack 与已发布快照覆盖裁剪日志窗口（注入日志时）。
      // 覆盖下限由发布台账推导：需要发布快照文件的传输（WebDAV）必须覆盖到
      // 窗口起点，按需给出实时快照的传输（局域网）没有发布延迟、不参与。
      var journalBase = 0;
      // 本轮全量快照的覆盖位置（null = 未注入增量日志：没有覆盖可依，
      // 每轮都外发全量快照）。
      int? snapshotSeq;
      if (journal != null) {
        final now = _nowMs();
        await journal.compact(
          minAck: _minPeerAck(now) ?? 0,
          coverage: journalCoverage(
            ledgers: _publishLedgers.values,
            enabledKinds: _state.enabledTransports,
            journalHead: journalHead,
          ),
          nowMs: now,
        );
        snapshotSeq = await journal.snapshotSeq();
        journalBase = await journal.baseSeq();
        if (snapshotSeq < 0) {
          // 首次构建全量快照：内容覆盖到本轮头部（引擎随后按需发布）。
          await journal.markSnapshotBuilt(journalHead);
          snapshotSeq = journalHead;
        }
      }

      // 推送合并后的本地视图（重新收集，包含刚应用的远端记录）。
      final refreshed = await _collect(categories);
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
          journalHead == _snapshotFingerprintHead &&
          applied == 0 &&
          prunedCount == refreshedCount;
      final snapshotId = fingerprintReusable
          ? _snapshotFingerprintId!
          : _fingerprint(pruned.records);
      _snapshotFingerprintId = snapshotId;
      _snapshotFingerprintHead = journalHead;
      _localJournalHead = journalHead;
      // 未注入日志时保留整视图指纹：下一轮的变更判定用它。
      if (journal == null) {
        _localFingerprint = _fingerprint(refreshed);
      }
      final outgoing = SyncEnvelope(
        deviceId: pruned.deviceId,
        deviceName: pruned.deviceName,
        producedAt: pruned.producedAt,
        records: pruned.records,
        journalHead: journalHead,
        baseSeq: journalBase,
        acks: _acks(),
        // 本载荷覆盖的类别（蜂窝小类别轮只含小类别）：anti-entropy 按它
        // 只在双方共享的类别上比对指纹。
        categories: [for (final category in categories) category.name],
      ).withSnapshotId(snapshotId);
      _lastEnvelope = outgoing;

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

      var succeededPushes = 0;
      if (push) {
        for (final entry in _transports.entries) {
          final accumulator = accumulators[entry.key]!;
          final transport = entry.value;
          if (!transport.isRunning ||
              !_state.enabledTransports.contains(entry.key)) {
            continue;
          }
          final ledger = _publishLedgers[entry.key]!;
          // 1) 全量快照：首次引导 / 日志超硬上限重写时发布；未注入日志时
          //    始终外发全量。内容未变 / 已发布覆盖够到时跳过加密 + 上传。
          if (ledger.plan(outgoing, snapshotSeq: snapshotSeq)) {
            final result =
                await _pushEnvelope(transport, outgoing, accumulator);
            succeededPushes += result.succeededPeers;
            await ledger.mark(result);
            _recordPushPeers(result, entry.key);
          }
          // 2) 增量窗口：内容或 ack 有变化才推（对端未变不传、不解密）。
          final deltaEnvelope = await buildDelta();
          if (deltaEnvelope != null && ledger.plan(deltaEnvelope)) {
            final result =
                await _pushEnvelope(transport, deltaEnvelope, accumulator);
            succeededPushes += result.succeededPeers;
            await ledger.mark(result);
            _recordPushPeers(result, entry.key);
          }
        }
      }

      final finishedAt = _nowMs();
      final transportReports = [
        for (final accumulator in accumulators.values) accumulator.build(),
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
      final remoteCount = remoteRecords.values
          .fold<int>(0, (sum, list) => sum + list.length);
      final contact = peersSeen > 0 ||
          applied > 0 ||
          remoteCount > 0 ||
          failedCount + applyFailures > 0;
      final outcome = _resolveOutcome(
        anyTransport: anyTransport,
        contact: contact,
        pullContact: pullContact,
        failed: failedCount + applyFailures,
        succeededPulls: succeededPulls,
        succeededPushes: succeededPushes,
        applied: applied,
        localChanged: localChanged,
      );
      final transportError = transportReports
          .map((item) => item.error)
          .firstWhere((value) => value != null, orElse: () => null);
      final applyError = applyFailures > 0
          ? SyncIssue(
              code: SyncIssueCode.applyFailed,
              args: {'count': applyFailures},
            )
          : null;
      final error = switch (outcome) {
        SyncOutcome.failed => transportError ??
            applyError ??
            _allPeersUnreachable(transportReports),
        SyncOutcome.partial => transportError ?? applyError,
        // noPeers 不吞传输级错误：广播失败 / 零应答 / 目录准备失败要能看见。
        SyncOutcome.noPeers => transportError,
        _ => null,
      };

      report = SyncRoundReport(
        trigger: trigger,
        startedAt: startedAt,
        finishedAt: finishedAt,
        outcome: outcome,
        applied: applied,
        applyFailures: applyFailures,
        transports: transportReports,
        peers: await _roster(),
        remoteRecords: remoteCount,
        error: error,
      );
      _logger.fine(() => '同步一轮完成：$report');
    } on _RoundAbort catch (abort) {
      // 用户可行动的明确状态（未设置口令）：不按内部异常处理。
      _logger.warning('同步一轮未完成：${abort.issue}');
      report = SyncRoundReport(
        trigger: trigger,
        startedAt: startedAt,
        finishedAt: _nowMs(),
        outcome: SyncOutcome.failed,
        error: abort.issue,
      );
    } catch (e, stackTrace) {
      _logger.warning('同步一轮失败', e, stackTrace);
      report = SyncRoundReport(
        trigger: trigger,
        startedAt: startedAt,
        finishedAt: _nowMs(),
        outcome: SyncOutcome.failed,
        error: SyncIssue(code: SyncIssueCode.internal, detail: '$e'),
      );
    } finally {
      _lastReport = report;
      _state.recordRound(report);
      await _state.save();
      notifyListeners();
    }
    return report;
  }

  /// 逐传输拉取一次并把载荷追加到 [out]；返回是否接触到了远端。
  Future<bool> _pullInto(
    Map<String, _TransportAccumulator> accumulators,
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
      // 任何接触（含未变跳过 / 探测应答）都更新「最近接触」：在线但长期
      // 没有内容变化的对端不该被误标失联。
      for (final id in result.seenIds) {
        _touchPeer(id, entry.key, seen: true);
      }
      for (final envelope in result.envelopes) {
        out.add((entry.key, envelope));
      }
    }
    return contact;
  }

  /// 通过传输外发一份载荷，并把耗时与计数记进本轮累计器。
  ///
  /// 传输异常在边界吸收成失败结果（单点崩溃不该打断本轮其余外发）。
  Future<SyncPushResult> _pushEnvelope(
    SyncTransport transport,
    SyncEnvelope envelope,
    _TransportAccumulator accumulator,
  ) async {
    final watch = Stopwatch()..start();
    SyncPushResult result;
    try {
      result = await transport.push(envelope);
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

  /// 外发结果里的对端归属进名册（局域网能归属到具体对端；WebDAV 只有计数）。
  void _recordPushPeers(SyncPushResult result, String kind) {
    for (final id in result.succeededIds) {
      _touchPeer(id, kind, pushOk: true);
    }
    for (final id in result.failedIds) {
      _touchPeer(id, kind, pushOk: false);
    }
  }

  /// 处理收到的载荷：推进本机游标 / 学习对端 ack / 收集远端记录 / 识别缺口。
  ///
  /// 返回需要**全量兜底**的对端 id（窗口缺口，或 anti-entropy 发现指纹不一致
  /// 且本机没有它的新条目）；调用方在同一轮内再取一次它们的全量快照。
  Set<String> _consumePayloads(
    List<(String, SyncEnvelope)> payloads,
    Map<SyncCategory, List<SyncRecord>> remoteRecords,
    Set<SyncKnownKey> forcedDelivery,
    Map<String, int> pendingCursors, {
    required Set<String> requestedFull,
    required bool antiEntropy,
    required Map<SyncCategory, List<SyncRecord>> local,
    required Set<SyncCategory> categories,
  }) {
    final fullPeers = <String>{};
    final now = _nowMs();
    for (final (kind, envelope) in payloads) {
      final peerId = envelope.deviceId;
      if (peerId.isEmpty) continue;
      final existing = _peerOf(peerId);
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
        if (cursor < envelope.baseSeq) {
          // 窗口缺口：本机游标之前的条目已被对端裁剪，窗口不完整。
          gap = true;
          fullPeers.add(peerId);
        } else {
          // 只接受**连续**覆盖本机游标之后的条目：解析层丢掉的坏条目 / 未知
          // 类别会造成空洞，此时不能把游标推到 windowEnd（会永久跳过它们）。
          final entries = [...(envelope.journal ?? const <SyncJournalEntry>[])]
            ..sort((a, b) => a.seq.compareTo(b.seq));
          var expected = cursor + 1;
          var hole = false;
          for (final entry in entries) {
            if (entry.seq <= cursor) continue;
            if (entry.seq != expected) {
              hole = true;
              break;
            }
            expected = entry.seq + 1;
            remoteRecords.putIfAbsent(entry.category, () => []).add(entry.record);
          }
          if (hole || (envelope.windowEnd > cursor && expected - 1 < envelope.windowEnd)) {
            // 窗口内不连续：标缺口改走 bootstrap（已接受的条目照常应用，
            // 游标只推进到已接受的最大 seq）。
            gap = true;
            fullPeers.add(peerId);
          }
          if (expected - 1 > nextCursor) nextCursor = expected - 1;
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
        if (envelope.journalHead > nextCursor) nextCursor = envelope.journalHead;
        fullPulledAt = now;
      }
      if (nextCursor > cursor) {
        final previous = pendingCursors[peerId];
        pendingCursors[peerId] = previous == null || nextCursor > previous
            ? nextCursor
            : previous;
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
            cursor >= envelope.journalHead &&
            now - fullPulledAt >= antiEntropyIntervalMs &&
            _fingerprintDiffers(
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
        lastPullAt: now,
        // 成功拉取 = 接触成功：清掉上一次的失败；本轮推送失败的对端保留状态。
        lastError: _peersFailedThisRound.contains(peerId)
            ? existing.lastError
            : null,
        clearLastError: !_peersFailedThisRound.contains(peerId),
        ackedSeq: ackedSeq,
        snapshotId:
            envelope.snapshotId.isNotEmpty ? envelope.snapshotId : null,
        categories: envelope.categories.isNotEmpty ? envelope.categories : null,
        fullPulledAt: fullPulledAt > 0 ? fullPulledAt : null,
        clockSkewMs: envelope.producedAt > 0 ? envelope.producedAt - now : null,
      );
    }
    return fullPeers;
  }

  /// 本机游标（对端 id → 已消费位置）；拉取请求按它只取变更。
  Map<String, int> _cursors() => {
        for (final peer in _allPeers()) peer.deviceId: peer.cursorSeq,
      };

  /// 本机已消费各对端 journal 的位置（随载荷外发，对端据此 compact）。
  Map<String, int> _acks() {
    final acks = <String, int>{};
    for (final peer in _allPeers()) {
      if (peer.cursorSeq >= 0) acks[peer.deviceId] = peer.cursorSeq;
    }
    return acks;
  }

  /// anti-entropy 全量兜底的节流间隔（同一对端不频繁重拉；分歧仍会被修复）。
  static const int antiEntropyIntervalMs = 10 * 60 * 1000;

  /// 对端指纹与本机视图是否真的不一致（类别感知）。
  ///
  /// [peerCategories] 是对端本轮覆盖的类别：本机按**同一类别集合**、同一
  /// 裁剪口径（墓碑保留期）计算指纹——类别开关不同的设备不会被误判为分歧；
  /// 对端覆盖了本机没有的类别时无法比较（返回 false，不做兜底）。
  bool _fingerprintDiffers({
    required String peerSnapshotId,
    required List<String> peerCategories,
    required Map<SyncCategory, List<SyncRecord>> local,
    required Set<SyncCategory> categories,
  }) {
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
    return _fingerprint(subset) != peerSnapshotId;
  }

  /// anti-entropy 的全量兜底名单：指纹不一致、且距上次兜底超过节流间隔。
  Set<String> _antiEntropyPeers(
    Map<SyncCategory, List<SyncRecord>> local,
    Set<SyncCategory> categories,
  ) {
    final now = _nowMs();
    return {
      for (final peer in _allPeers())
        if (peer.snapshotId.isNotEmpty &&
            now - peer.fullPulledAt >= antiEntropyIntervalMs &&
            _fingerprintDiffers(
              peerSnapshotId: peer.snapshotId,
              peerCategories: peer.categories,
              local: local,
              categories: categories,
            ))
          peer.deviceId,
    };
  }

  /// 各对端 ack 的最小值（compact 的裁剪边界）；null = 没有对端 ack 过。
  ///
  /// 失联设备（超过 [SyncPeerState.lostThresholdMs] 无接触）与**已本地忽略**
  /// 的设备不参与：它们的位置由硬上限与 bootstrap 兜底，不该让日志无界增长
  /// （也不该钉住窗口）。
  int? _minPeerAck(int nowMs) {
    int? minAck;
    for (final peer in _allPeers()) {
      if (peer.ackedSeq < 0) continue;
      if (peer.isLostAt(nowMs)) continue;
      if (_state.isPeerIgnored(peer.deviceId)) continue;
      if (minAck == null || peer.ackedSeq < minAck) minAck = peer.ackedSeq;
    }
    return minAck;
  }

  /// 构建增量窗口载荷（当前保留的窗口条目；空窗口但 ack 有推进时也返回）。
  Future<SyncEnvelope?> _buildDelta(
    SyncJournalStore journal,
    SyncEnvelope outgoing,
  ) async {
    final entries = await journal.window(since: outgoing.baseSeq);
    return SyncEnvelope(
      deviceId: outgoing.deviceId,
      deviceName: outgoing.deviceName,
      producedAt: outgoing.producedAt,
      snapshotId: outgoing.snapshotId,
      journalHead: outgoing.journalHead,
      baseSeq: outgoing.baseSeq,
      windowStart: entries.isEmpty ? 0 : entries.first.seq,
      windowEnd: entries.isEmpty ? 0 : entries.last.seq,
      journal: entries,
      acks: outgoing.acks,
      categories: outgoing.categories,
    );
  }

  /// 从名册取对端（内存视图优先，其次落库状态）。
  SyncPeerState _peerOf(String deviceId) {
    final existing = _peersById[deviceId];
    if (existing != null) return existing;
    for (final peer in _state.peers) {
      if (peer.deviceId == deviceId) return peer;
    }
    return SyncPeerState(deviceId: deviceId);
  }

  /// 名册合并视图（内存观测优先；含落库状态里的对端）。
  Iterable<SyncPeerState> _allPeers() {
    for (final peer in _state.peers) {
      _peersById.putIfAbsent(peer.deviceId, () => peer);
    }
    return _peersById.values;
  }

  /// 全失败兜底原因：带上全不可达的传输（UI 据此给对应出路——手动地址是
  /// 局域网概念，WebDAV 全失败只给配置与重试）。
  static SyncIssue _allPeersUnreachable(List<SyncTransportReport> reports) {
    final failedKinds = {
      for (final item in reports)
        if (item.failedPulls + item.failedPushes > 0) item.kind,
    };
    return SyncIssue(
      code: SyncIssueCode.allPeersUnreachable,
      args: failedKinds.length == 1
          ? {'transport': failedKinds.single}
          : const {},
    );
  }

  /// 五态判定（优先级：没有可用传输 / 没联系上任何对端 → 全失败 →
  /// 部分失败 → 无变化 → 完成）。
  static SyncOutcome _resolveOutcome({
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

  static SyncTrigger _mergeTrigger(SyncTrigger? existing, SyncTrigger incoming) {
    if (existing == null) return incoming;
    if (existing == SyncTrigger.manual || incoming == SyncTrigger.manual) {
      return SyncTrigger.manual;
    }
    return existing;
  }

  /// 本轮推送失败过的对端：名册重建时据此保留失败状态（成功接触显式清除）。
  final Set<String> _peersFailedThisRound = {};

  /// 内存名册（本轮观测优先；落库状态在 [_allPeers] 里合并进来）。
  final Map<String, SyncPeerState> _peersById = {};

  /// 记录/更新名册项（引擎只在这里写名册，落库由 [SyncStateStore.recordRound]）。
  ///
  /// [seen] = 只接触过（探测应答 / 未变跳过）：更新最近接触时间并清除失败，
  /// 但不改「最后拉取」时间（没有数据流转）。
  void _touchPeer(
    String deviceId,
    String kind, {
    bool pushOk = false,
    bool seen = false,
  }) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    final now = _nowMs();
    if (seen) {
      _peersFailedThisRound.remove(deviceId);
      _peersById[deviceId] = existing.copyWith(
        transport: kind,
        lastSeenAt: now,
        clearLastError: true,
      );
      return;
    }
    if (pushOk) {
      _peersFailedThisRound.remove(deviceId);
      _peersById[deviceId] = existing.copyWith(
        transport: kind,
        lastSeenAt: now,
        lastPushAt: now,
        clearLastError: true,
      );
      return;
    }
    _peersFailedThisRound.add(deviceId);
    _peersById[deviceId] = existing.copyWith(
      transport: kind,
      lastSeenAt: now,
      lastError: const SyncIssue(code: SyncIssueCode.pushFailed),
    );
  }

  /// 本轮名册快照：内存观测 + 落库状态，并计算每对端的落后条数 / 字节。
  ///
  /// 落后 = 本机 journal 头部 − 对端已 ack 的位置（对端没跟上的变更量）；
  /// 未 ack 过 / 已失联的对端没有可靠观测，不计算（名册按失联阈值另行标记）。
  Future<List<SyncPeerState>> _roster() async {
    final journal = _journal;
    final head = journal == null ? 0 : await journal.headSeq();
    final merged = <SyncPeerState>[];
    for (final peer in _allPeers()) {
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
    // 内存名册与落库侧共用同一套排序 / 淘汰（落库侧还会再裁一次）。
    final recent = trimPeers(merged, SyncStateStore.peerLimit);
    _peersById
      ..clear()
      ..addEntries(recent.map((peer) => MapEntry(peer.deviceId, peer)));
    return recent;
  }

  // 完整快照备份（导出/导入）：与同步共用 envelope 与适配器，
  // 但不需要启用同步或口令；凭证类默认排除（密钥不落明文备份文件）。

  static const String backupKind = 'molia_backup';
  static const int backupVersion = 1;

  /// 导出完整备份 JSON 文本（歌单 / 历史 / 音源 / 设置 / 统计 / 会话）。
  Future<String> exportBackupJson({bool includeCredentials = false}) async {
    final categories = _backupCategories(includeCredentials);
    final records = await _collect(categories);
    final envelope = _envelopeFrom(records);
    return const JsonEncoder.withIndent('  ').convert({
      'kind': backupKind,
      'v': backupVersion,
      'producedAt': _nowMs(),
      'envelope': envelope.toJson(),
    });
  }

  /// 导入完整备份：与本地数据逐键合并（LWW，不做整体覆盖）。
  ///
  /// 先收集本地现状更新登记，保证本地较新的改动不会被旧备份覆盖。
  Future<SyncApplyOutcome> importBackupJson(
    String json, {
    bool includeCredentials = false,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw const FormatException('备份文件不是有效 JSON');
    }
    if (decoded is! Map || decoded['kind'] != backupKind) {
      throw const FormatException('不是 Molia 备份文件');
    }
    final envelope = SyncEnvelope.fromJson(decoded['envelope']);
    if (envelope == null) throw const FormatException('备份内容无效');
    // 导入备份的戳同样要吸收：否则恢复的旧备份会与库内新数据打架。
    for (final list in envelope.records.values) {
      for (final record in list) {
        _stamps.observe(record.version);
      }
    }

    final categories = _backupCategories(includeCredentials);
    await _collect(categories);

    var applied = 0;
    var skipped = 0;
    for (final adapter in _adapters) {
      if (!adapter.ready) continue;
      final subset = <SyncCategory, List<SyncRecord>>{};
      for (final category in adapter.categories) {
        if (!categories.contains(category)) continue;
        final list = envelope.records[category];
        if (list == null || list.isEmpty) continue;
        subset[category] = list;
      }
      if (subset.isEmpty) continue;
      try {
        final outcome = await adapter.apply(subset);
        applied += outcome.applied;
        skipped += outcome.skipped;
      } catch (e) {
        _logger.warning('导入 ${adapter.runtimeType} 失败', e);
      }
    }
    await _state.save();
    notifyListeners();
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  Set<SyncCategory> _backupCategories(bool includeCredentials) => {
        for (final category in SyncCategory.values)
          if (includeCredentials || category != SyncCategory.credentials)
            category,
      };

  Future<void> _ensureTransportsRunning() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      if (entry.value.isRunning) continue;
      // 启动失败由传输自己记录（`unavailableReason`）并进入本轮报告：
      // 「开关打开但没在工作」必须能被用户看到，不能只留在日志里。
      await entry.value.start();
    }
  }

  Future<void> _stopTransports() async {
    for (final transport in _transports.values) {
      if (!transport.isRunning) continue;
      try {
        await transport.stop();
      } catch (_) {
        // 停止失败不影响后续轮次（start 幂等）。
      }
    }
  }

  Future<Map<SyncCategory, List<SyncRecord>>> _collect(
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

  /// 就绪适配器数（`_collect` 的身份复用守卫：就绪集合变化即不能复用）。
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

  /// 本地视图指纹：用于区分「本机没有变化」与「有变更需要外发」。
  ///
  /// 逐类别按键排序后哈希，与集合顺序无关；只在同一进程内比较（跨重启由
  /// 后续的增量协议以游标替代）。
  static String _fingerprint(Map<SyncCategory, List<SyncRecord>> records) {    final buffer = StringBuffer();
    for (final category in SyncCategory.values) {
      final list = records[category];
      if (list == null || list.isEmpty) continue;
      final sorted = [...list]..sort((a, b) => a.key.compareTo(b.key));
      for (final record in sorted) {
        buffer
          ..write(category.name)
          ..write('\u0001')
          ..write(record.key)
          ..write('\u0001')
          ..write(record.version.physical)
          ..write('\u0001')
          ..write(record.version.counter)
          ..write('\u0001')
          ..write(record.version.deviceId)
          ..write('\u0001')
          ..write(record.deleted ? '1' : '0')
          ..write('\u0001')
          ..write(record.data == null ? '' : jsonEncode(record.data))
          ..write('\n');
      }
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }

  SyncEnvelope _envelopeFrom(Map<SyncCategory, List<SyncRecord>> records) =>
      SyncEnvelope(
        deviceId: _state.deviceId,
        deviceName: _state.deviceName,
        producedAt: _nowMs(),
        records: records,
      );

  @override
  void dispose() {
    _inboundTimer?.cancel();
    _inboundTimer = null;
    for (final subscription in _incomingSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_stopTransports());
    super.dispose();
  }
}

/// 一轮内可变的传输累计器（构造报告时转成不可变的 [SyncTransportReport]）。
class _TransportAccumulator {
  _TransportAccumulator(this.kind, {required this.enabled});

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

/// 一轮中止（用户可行动的明确状态，如未设置口令）：携带类型化原因。
class _RoundAbort implements Exception {
  const _RoundAbort(this.issue);

  final SyncIssue issue;

  @override
  String toString() => 'SyncRoundAbort(${issue.code})';
}
