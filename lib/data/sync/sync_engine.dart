import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_adapter.dart';
import 'sync_passphrase.dart';
import 'sync_state_store.dart';

/// 同步引擎：一轮 = 收集本地视图 → 拉取远端快照 → 逐键合并 → 写回本地 →
/// 推送合并后视图 → 记日志。
///
/// 单点失败（某传输不可用、某快照解密失败）不影响其他对端；
/// 快照格式与合并规则见 [SyncEnvelope] 与 [mergeEnvelopesByCategory]。
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

  bool _syncing = false;
  bool _initialized = false;
  SyncReport _lastReport = SyncReport.idle;
  SyncEnvelope? _lastEnvelope;

  SyncStateStore get state => _state;
  bool get syncing => _syncing;
  bool get initialized => _initialized;
  SyncReport get lastReport => _lastReport;

  /// 最近一轮推送/构建的快照（局域网端点直接返回给对端 GET）。
  SyncEnvelope? get lastEnvelope => _lastEnvelope;

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
    if (!_syncing) await syncNow(push: false);
  }

  Future<SyncReport> syncNow({bool manual = false, bool push = true}) async {
    if (_syncing) return _lastReport;
    if (!_initialized) await init();
    if (!_state.enabled) return _lastReport;

    _syncing = true;
    notifyListeners();
    var report = SyncReport(ok: false);
    try {
      final passphrase = await _state.readPassphrase();
      if (passphrase == null || passphrase.trim().isEmpty) {
        throw StateError('未设置同步口令');
      }
      await _ensureTransportsRunning();

      final categories = _state.enabledCategories;
      final local = await _collect(categories);

      var failedPulls = 0;
      final pulled = <SyncEnvelope>[];
      for (final transport in _activeTransports) {
        try {
          pulled.addAll(await transport.pull());
        } catch (_) {
          failedPulls++;
        }
      }
      pulled.addAll(_inbound);
      _inbound.clear();

      final merged = mergeEnvelopesByCategory(
        [_envelopeFrom(local), ...pulled],
        categories: categories,
      );

      var applied = 0;
      var skipped = 0;
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
          skipped += outcome.skipped;
        } catch (e) {
          debugPrint('[SyncEngine] 应用 ${adapter.runtimeType} 失败: $e');
        }
      }

      await _state.save();

      // 推送合并后的本地视图（重新收集，包含刚应用的远端记录）。
      final refreshed = await _collect(categories);
      final outgoing = _envelopeFrom(refreshed).pruneTombstones(
        now: _nowMs(),
        tombstoneRetentionMs: tombstoneRetentionMs,
      );
      _lastEnvelope = outgoing;
      if (push) {
        for (final transport in _activeTransports) {
          try {
            await transport.push(outgoing);
          } catch (_) {
            // 推送失败留给对端的下一轮拉取兜底。
          }
        }
      }

      report = SyncReport(
        ok: true,
        pulled: pulled.length,
        failedPulls: failedPulls,
        applied: applied,
        skipped: skipped,
      );
    } catch (e) {
      report = SyncReport(ok: false, error: '$e');
    } finally {
      _syncing = false;
      _lastReport = report;
      _state.recordSyncResult(
        ok: report.ok,
        manual: manual,
        pulled: report.pulled,
        applied: report.applied,
        skipped: report.skipped,
        error: report.error,
      );
      await _state.save();
      notifyListeners();
    }
    return report;
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
        debugPrint('[SyncEngine] 导入 ${adapter.runtimeType} 失败: $e');
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

  Iterable<SyncTransport> get _activeTransports => [        for (final entry in _transports.entries)
          if (_state.enabledTransports.contains(entry.key) && entry.value.isRunning)
            entry.value,
      ];

  Future<void> _ensureTransportsRunning() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      if (entry.value.isRunning) continue;
      try {
        await entry.value.start();
      } catch (e) {
        debugPrint('[SyncEngine] 启动传输 ${entry.key} 失败: $e');
      }
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
