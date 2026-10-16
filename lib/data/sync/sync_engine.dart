import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_adapter.dart';
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
    DateTime Function()? clock,
    Duration inboundWindow = const Duration(milliseconds: 1500),
  })  : _state = state,
        _adapters = adapters,
        _transports = transports,
        _stamps = stamps,
        _known = known ?? InMemorySyncKnownStore(),
        _inboundWindow = inboundWindow,
        _clock = clock ?? DateTime.now {
    for (final transport in transports.values) {
      _incomingSubscriptions.add(transport.incoming.listen(
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

  SyncRoundReport? _lastReport;
  SyncEnvelope? _lastEnvelope;

  /// 上轮本地视图指纹（用于区分「本机没有变化」与「有变更需要外发」）。
  String? _localFingerprint;

  /// 每传输最近一次成功推送的快照内容指纹：与待推送内容一致时跳过
  /// 加密 + 上传（本机未变不推）。
  final Map<String, String> _lastPushedSnapshotId = {};

  SyncStateStore get state => _state;
  bool get syncing => _syncing;
  bool get initialized => _initialized;

  /// 最近一轮的完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _lastReport;

  /// 最近一轮推送/构建的快照（局域网端点直接返回给对端 GET）。
  SyncEnvelope? get lastEnvelope => _lastEnvelope;

  /// 传输当前状态（UI 呈现「开关开着但没在工作」）；未知 kind 返回 null。
  ///
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
  /// 变化登记照常进行，不受影响）。
  Future<SyncRoundReport?> syncNow({
    SyncTrigger trigger = SyncTrigger.timer,
    bool push = true,
    Set<SyncCategory>? onlyCategories,
  }) async {
    if (_syncing) {
      // 排队一次：手动点击与入站推送都不该被静默丢弃。
      _pendingTrigger = _mergeTrigger(_pendingTrigger, trigger);
      return _lastReport;
    }
    if (!_initialized) await init();
    if (!_state.enabled) return _lastReport;

    // 同步进行中到达的请求会被排队：整段（含补跑）持有 `_syncing`，保证同一时刻
    // 只有一条轮次在跑；点一次必有一次，多个入站推送也只合并成额外一轮。
    _syncing = true;
    notifyListeners();
    var nextTrigger = trigger;
    var nextCategories = onlyCategories;
    SyncRoundReport? report;
    try {
      while (true) {
        report = await _runRound(
          nextTrigger,
          push: push,
          onlyCategories: nextCategories,
        );
        final pending = _pendingTrigger;
        _pendingTrigger = null;
        if (pending == null) break;
        nextTrigger = pending;
        // 补跑轮沿用排队时的类别范围（同一策略下不应切换范围）。
        nextCategories = onlyCategories;
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return report;
  }

  /// 调度器宿主接口：跑一轮（[SyncScheduler] 注入的驱动面）。
  @override
  bool get syncEnabled => _state.enabled;

  @override
  Future<void> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    Set<SyncCategory>? onlyCategories,
  }) async {
    await syncNow(trigger: trigger, push: push, onlyCategories: onlyCategories);
  }

  Future<SyncRoundReport> _runRound(
    SyncTrigger trigger, {
    required bool push,
    Set<SyncCategory>? onlyCategories,
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

      final categories = onlyCategories ?? _state.enabledCategories;
      final local = await _collect(categories);
      final fingerprint = _fingerprint(local);
      final localChanged = _localFingerprint == null || fingerprint != _localFingerprint;

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
      final pulledEntries = <(String, SyncEnvelope)>[];
      // 入站轮只消费收到的快照：不主动拉取任何对端。
      final inboundOnly = trigger == SyncTrigger.incoming;
      for (final entry in _transports.entries) {
        final accumulator = accumulators[entry.key]!;
        final transport = entry.value;
        if (!_state.enabledTransports.contains(entry.key)) {
          continue;
        }
        accumulator
          ..running = transport.isRunning
          ..unavailableReason = transport.unavailableReason;
        if (!transport.isRunning) {
          // 启动类失败（端口占用 / 权限 / 未配置）进入本轮错误面：
          // 「开关开着但没在工作」必须在状态与日志里看得见。
          accumulator.error = SyncIssue(
            code: transport.unavailableReason ?? SyncIssueCode.startFailed,
            detail: transport.unavailableDetail,
          );
          continue;
        }
        if (inboundOnly) continue;

        final watch = Stopwatch()..start();
        SyncPullResult result;
        try {
          result = await transport.pull();
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
        for (final envelope in result.envelopes) {
          pulledEntries.add((entry.key, envelope));
        }
      }

      var applied = 0;
      var applyFailures = 0;
      var inboundRestored = false;
      final inboundSnapshot = List<SyncEnvelope>.of(_inbound);
      _inbound.clear();
      for (final envelope in inboundSnapshot) {
        pulledEntries.add(('', envelope));
      }

      // 吸收远端版本（含未获胜者）：超前戳让本机下一次写入必胜，因此必须在
      // 合并之外对收到的全部记录生效。
      for (final entry in pulledEntries) {
        for (final list in entry.$2.records.values) {
          for (final record in list) {
            _stamps.observe(record.version);
          }
        }
      }

      try {
        final merged = mergeEnvelopesByCategory(
          [_envelopeFrom(local), ...pulledEntries.map((entry) => entry.$2)],
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
              if (known[(category: category, key: record.key)] ==
                  record.version) {
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

      await _state.save();

      // 推送合并后的本地视图（重新收集，包含刚应用的远端记录）。
      final refreshed = await _collect(categories);
      // 指纹以「本轮最终视图」为准：应用远端记录带来的变化不算本机变更，
      // 否则下一轮永远判成「有变化」（结论就永远不是「无变化」）。
      _localFingerprint = _fingerprint(refreshed);
      final pruned = _envelopeFrom(refreshed).pruneTombstones(
        now: _nowMs(),
        tombstoneRetentionMs: tombstoneRetentionMs,
      );
      // 内容指纹按实际外发的记录集（裁剪墓碑后）计算：对端探测应答 / 本机
      // 「未变不推」都拿它与自己缓存的值比较。
      final outgoing = pruned.withSnapshotId(_fingerprint(pruned.records));
      _lastEnvelope = outgoing;

      var succeededPushes = 0;
      if (push) {
        for (final entry in _transports.entries) {
          final accumulator = accumulators[entry.key]!;
          final transport = entry.value;
          if (!transport.isRunning ||
              !_state.enabledTransports.contains(entry.key)) {
            continue;
          }
          // 本机内容与上次成功推送一致：跳过加密 + 上传（对端仍可主动拉取）。
          if (outgoing.snapshotId.isNotEmpty &&
              _lastPushedSnapshotId[entry.key] == outgoing.snapshotId) {
            continue;
          }
          final watch = Stopwatch()..start();
          SyncPushResult result;
          try {
            result = await transport.push(outgoing);
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
          succeededPushes += result.succeededPeers;
          // 只在「确实有对端收下且没有失败」时记住指纹：零对端（局域网无人
          // 在线）不算推送成功，否则对端上线后会被误判为「已推过」。
          if (result.failedPeers == 0 && result.succeededPeers > 0) {
            _lastPushedSnapshotId[entry.key] = outgoing.snapshotId;
          } else {
            _lastPushedSnapshotId.remove(entry.key);
          }
          for (final id in result.succeededIds) {
            _touchPeer(id, entry.key, pushOk: true);
          }
          for (final id in result.failedIds) {
            _touchPeer(id, entry.key, pushOk: false);
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
      final remoteRecords = pulledEntries.fold<int>(
        0,
        (sum, entry) => sum + entry.$2.recordCount,
      );
      final contact = peersSeen > 0 ||
          applied > 0 ||
          remoteRecords > 0 ||
          failedCount + applyFailures > 0;
      final outcome = _resolveOutcome(
        anyTransport: anyTransport,
        contact: contact,
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
            const SyncIssue(code: SyncIssueCode.allPeersUnreachable),
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
        peers: _roster(pulledEntries),
        remoteRecords: remoteRecords,
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

  /// 五态判定（优先级：没有可用传输 / 没联系上任何对端 → 全失败 →
  /// 部分失败 → 无变化 → 完成）。
  static SyncOutcome _resolveOutcome({
    required bool anyTransport,
    required bool contact,
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
    // 有失败：拉取 / 推送 / 落地任一面成功过就是部分失败；全都没有才是整轮
    // 失败（拉取成功但推送全败仍有成功面，不是「所有对端都联系不上」）。
    if (succeededPulls == 0 && succeededPushes == 0 && applied == 0) {
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

  /// 记录/更新名册项（引擎只在这里写名册，落库由 [SyncStateStore.recordRound]）。
  void _touchPeer(
    String deviceId,
    String kind, {
    bool pushOk = false,
  }) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    final now = _nowMs();
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

  /// 本轮名册快照（拉取得到的对端 + 推送接触过的对端）。
  final Map<String, SyncPeerState> _peersById = {};

  List<SyncPeerState> _roster(List<(String, SyncEnvelope)> pulledEntries) {
    // 先吸收既有名册，再用本轮观测覆盖。
    for (final peer in _state.peers) {
      _peersById.putIfAbsent(peer.deviceId, () => peer);
    }
    final now = _nowMs();
    for (final (kind, envelope) in pulledEntries) {
      if (envelope.deviceId.isEmpty) continue;
      final existing = _peersById[envelope.deviceId] ??
          SyncPeerState(deviceId: envelope.deviceId);
      _peersById[envelope.deviceId] = SyncPeerState(
        deviceId: envelope.deviceId,
        name: envelope.deviceName.isNotEmpty ? envelope.deviceName : existing.name,
        transport: kind.isNotEmpty ? kind : existing.transport,
        lastSeenAt: now,
        lastPullAt: now,
        lastPushAt: existing.lastPushAt,
        // 成功拉取 = 接触成功：清掉上一次的失败；本轮推送失败的对端保留状态。
        lastError: _peersFailedThisRound.contains(envelope.deviceId)
            ? existing.lastError
            : null,
        clockSkewMs: envelope.producedAt > 0
            ? envelope.producedAt - now
            : existing.clockSkewMs,
      );
    }
    // 内存名册与落库侧共用同一套排序 / 淘汰（落库侧还会再裁一次）。
    final recent = trimPeers(_peersById.values, SyncStateStore.peerLimit);
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
    Set<SyncCategory> categories,
  ) async {
    final result = <SyncCategory, List<SyncRecord>>{};
    for (final adapter in _adapters) {
      if (!adapter.ready) continue;
      final collected = await adapter.collect();
      for (final entry in collected.entries) {
        if (!categories.contains(entry.key)) continue;
        if (entry.value.isEmpty) continue;
        result.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
    }
    return result;
  }

  /// 本地视图指纹：用于区分「本机没有变化」与「有变更需要外发」。
  ///
  /// 逐类别按键排序后哈希，与集合顺序无关；只在同一进程内比较（跨重启由
  /// 后续的增量协议以游标替代）。
  static String _fingerprint(Map<SyncCategory, List<SyncRecord>> records) {
    final buffer = StringBuffer();
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
