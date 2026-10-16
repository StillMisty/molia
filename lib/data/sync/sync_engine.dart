import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_adapter.dart';
import 'sync_passphrase.dart';
import 'sync_state_store.dart';

/// 同步引擎：一轮 = 收集本地视图 → 拉取远端快照 → 逐键合并 → 写回本地 →
/// 推送合并后视图 → 记录可观察的一轮结果（[SyncRoundReport]）。
///
/// 可观察性契约（与旧实现的关键差别）：
/// - 报告区分五态：`noPeers`（一个对端都没发现）与 `noChanges`（对端可达但
///   没有变化）必须能分开——旧实现里两者都显示「同步成功」；
/// - 计数是**本轮变更量**（落地记录数 / 传输字节 / 失败个数），不是全库规模；
/// - 每传输与每对端都有独立结果，单点失败不再被吞掉；
/// - 入站快照在本轮失败时放回队列（对端花网络推来的数据不能丢）。
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required SyncStateStore state,
    required List<SyncAdapter> adapters,
    required Map<String, SyncTransport> transports,
    DateTime Function()? clock,
  })  : _state = state,
        _adapters = adapters,
        _transports = transports,
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
  final DateTime Function() _clock;
  final List<SyncEnvelope> _inbound = [];
  final List<StreamSubscription<SyncEnvelope>> _incomingSubscriptions = [];
  final Logger _logger = Logger('molia.sync');

  bool _syncing = false;
  bool _initialized = false;

  /// 同步进行中收到的同步请求（手动点击 / 入站推送）：合并成一次排队，
  /// 当前轮结束后立刻补跑，不再静默丢弃。
  SyncTrigger? _pendingTrigger;

  SyncRoundReport? _lastReport;
  SyncEnvelope? _lastEnvelope;

  /// 上轮本地视图指纹（用于区分「本机没有变化」与「有变更需要外发」）。
  String? _localFingerprint;

  SyncStateStore get state => _state;
  bool get syncing => _syncing;
  bool get initialized => _initialized;

  /// 最近一轮的完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _lastReport;

  /// 最近一轮推送/构建的快照（局域网端点直接返回给对端 GET）。
  SyncEnvelope? get lastEnvelope => _lastEnvelope;

  /// 传输当前状态（UI 呈现「开关开着但没在工作」）。
  SyncTransportStatus transportStatus(String kind) {
    final transport = _transports[kind];
    if (transport == null) {
      return const SyncTransportStatus(kind: '', running: false);
    }
    return SyncTransportStatus(
      kind: kind,
      running: transport.isRunning,
      unavailableReason: transport.unavailableReason,
    );
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;

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
  Future<void> addManualPeer(ManualPeer peer) async {
    await _state.addManualPeer(peer);
    notifyListeners();
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

  /// 对端主动推送的快照：并入下一轮（未在同步中则立即触发一轮）。
  ///
  /// 本轮不推送：推送方在自己的轮次里已拉取过本机视图，入站触发的轮次再推送
  /// 会形成「A 推 B → B 推 A」的无限乒乓；需要外发的本地变更由常规触发
  /// （启动 / 去抖 / 定时）承担。
  Future<void> onIncomingEnvelope(SyncEnvelope envelope) async {
    if (!_state.enabled) return;
    _inbound.add(envelope);
    if (!_syncing) {
      await syncNow(trigger: SyncTrigger.incoming, push: false);
    } else {
      _pendingTrigger = _mergeTrigger(_pendingTrigger, SyncTrigger.incoming);
    }
  }

  /// 跑一轮同步。返回**最终**一轮的报告（若期间收到排队请求，会连续跑完）。
  Future<SyncRoundReport?> syncNow({
    SyncTrigger trigger = SyncTrigger.timer,
    bool push = true,
  }) async {
    if (_syncing) {
      // 排队一次：手动点击与入站推送都不该被静默丢弃（旧实现直接返回旧报告）。
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
    SyncRoundReport? report;
    try {
      while (true) {
        report = await _runRound(nextTrigger, push: push);
        final pending = _pendingTrigger;
        _pendingTrigger = null;
        if (pending == null) break;
        nextTrigger = pending;
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return report;
  }

  Future<SyncRoundReport> _runRound(SyncTrigger trigger, {required bool push}) async {
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
        throw StateError('未设置同步口令');
      }
      await _ensureTransportsRunning();

      final categories = _state.enabledCategories;
      final local = await _collect(categories);
      final fingerprint = _fingerprint(local);
      final localChanged = _localFingerprint == null || fingerprint != _localFingerprint;

      // 拉取：逐传输计时 + 逐对端计数。
      final accumulators = <String, _TransportAccumulator>{
        for (final kind in _transports.keys) kind: _TransportAccumulator(kind),
      };
      final pulledEntries = <(String, SyncEnvelope)>[];
      for (final entry in _transports.entries) {
        final accumulator = accumulators[entry.key]!;
        final transport = entry.value;
        if (!_state.enabledTransports.contains(entry.key)) {
          continue;
        }
        accumulator
          ..running = transport.isRunning
          ..unavailableReason = transport.unavailableReason;
        if (!transport.isRunning) continue;

        final watch = Stopwatch()..start();
        SyncPullResult result;
        try {
          result = await transport.pull();
        } catch (e) {
          result = SyncPullResult(failedPeers: 1, error: '$e');
        }
        watch.stop();
        accumulator
          ..pulled += result.envelopes.length
          ..peersSeen += result.peersSeen
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

      try {
        final merged = mergeEnvelopesByCategory(
          [_envelopeFrom(local), ...pulledEntries.map((entry) => entry.$2)],
          categories: categories,
        );

        for (final adapter in _adapters) {
          if (!adapter.ready) continue;
          final subset = <SyncCategory, List<SyncRecord>>{};
          for (final category in adapter.categories) {
            final winners = merged[category];
            if (winners == null || winners.isEmpty) continue;
            subset[category] = winners.values.toList();
          }
          if (subset.isEmpty) continue;
          try {
            final outcome = await adapter.apply(subset);
            applied += outcome.applied;
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
      final outgoing = _envelopeFrom(refreshed).pruneTombstones(
        now: _nowMs(),
        tombstoneRetentionMs: tombstoneRetentionMs,
      );
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
          final watch = Stopwatch()..start();
          SyncPushResult result;
          try {
            result = await transport.push(outgoing);
          } catch (e) {
            result = SyncPushResult(failedPeers: 1, error: '$e');
          }
          watch.stop();
          accumulator
            ..pushed += result.succeededPeers
            ..failedPushes += result.failedPeers
            ..bytesOut += result.bytesOut
            ..durationMs += watch.elapsedMilliseconds
            ..error ??= result.error;
          succeededPushes += result.succeededPeers;
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
      final anyTransport = transportReports.any((item) => item.running);
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
        succeededPushes: succeededPushes,
        applied: applied,
        localChanged: localChanged,
      );
      final transportError = transportReports
          .map((item) => item.error)
          .firstWhere((value) => value != null && value.isNotEmpty,
              orElse: () => null);
      final applyError = applyFailures > 0 ? '应用失败 $applyFailures 次' : null;
      final error = switch (outcome) {
        SyncOutcome.failed =>
          transportError ?? applyError ?? '所有对端均不可达',
        SyncOutcome.partial => _joinErrors(transportError, applyError),
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
    } catch (e, stackTrace) {
      _logger.warning('同步一轮失败', e, stackTrace);
      report = SyncRoundReport(
        trigger: trigger,
        startedAt: startedAt,
        finishedAt: _nowMs(),
        outcome: SyncOutcome.failed,
        error: '$e',
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
    required int succeededPushes,
    required int applied,
    required bool localChanged,
  }) {
    if (!anyTransport || !contact) return SyncOutcome.noPeers;
    if (failed == 0) {
      if (!localChanged && applied == 0) return SyncOutcome.noChanges;
      return SyncOutcome.ok;
    }
    if (succeededPushes == 0 && applied == 0) return SyncOutcome.failed;
    return SyncOutcome.partial;
  }

  static String? _joinErrors(String? first, String? second) {
    final parts = [
      if (first != null && first.isNotEmpty) first,
      if (second != null && second.isNotEmpty) second,
    ];
    return parts.isEmpty ? null : parts.join('；');
  }

  static SyncTrigger _mergeTrigger(SyncTrigger? existing, SyncTrigger incoming) {
    if (existing == null) return incoming;
    if (existing == SyncTrigger.manual || incoming == SyncTrigger.manual) {
      return SyncTrigger.manual;
    }
    return existing;
  }

  /// 记录/更新名册项（引擎只在这里写名册，落库由 [SyncStateStore.recordRound]）。
  void _touchPeer(String deviceId, String kind, {required bool pushOk}) {
    if (deviceId.isEmpty) return;
    final existing = _peersById[deviceId] ?? SyncPeerState(deviceId: deviceId);
    final now = _nowMs();
    _peersById[deviceId] = pushOk
        ? existing.copyWith(
            transport: kind,
            lastSeenAt: now,
            lastPushAt: now,
            clearLastError: true,
          )
        : existing.copyWith(
            transport: kind,
            lastSeenAt: now,
            lastError: '推送失败',
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
        clockSkewMs: envelope.producedAt > 0
            ? envelope.producedAt - now
            : existing.clockSkewMs,
      );
    }
    // 内存名册同样按最近接触时间有界（落库侧也会裁剪）。
    if (_peersById.length > SyncStateStore.peerLimit) {
      final recent = _peersById.values.toList()
        ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
      _peersById
        ..clear()
        ..addEntries(
          recent
              .take(SyncStateStore.peerLimit)
              .map((peer) => MapEntry(peer.deviceId, peer)),
        );
    }
    return List.unmodifiable(_peersById.values);
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
          ..write(record.updatedAt)
          ..write('\u0001')
          ..write(record.updatedBy)
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
    for (final subscription in _incomingSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_stopTransports());
    super.dispose();
  }
}

/// 传输状态快照（UI 呈现用：开关开着但不可用时要有明确原因）。
class SyncTransportStatus {
  const SyncTransportStatus({
    required this.kind,
    required this.running,
    this.unavailableReason,
  });

  final String kind;
  final bool running;
  final String? unavailableReason;
}

/// 一轮内可变的传输累计器（构造报告时转成不可变的 [SyncTransportReport]）。
class _TransportAccumulator {
  _TransportAccumulator(this.kind);

  final String kind;
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
  String? error;

  SyncTransportReport build() => SyncTransportReport(
        kind: kind,
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
