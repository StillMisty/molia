import 'dart:convert';

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import 'sync_adapter.dart';
import 'sync_book.dart';
import 'sync_stamp.dart';

/// 收集函数：按类别返回适配器聚合后的本地视图。
///
/// 由引擎注入（`SyncEngine.collectRecords`）：备份必须与一轮同步使用**同一**
/// 类别过滤与适配器缓存语义，否则「导出 / 导入」和线上同步对同一份数据给出
/// 不同视图。只暴露这一个读动作，备份不接触引擎的轮次状态。
typedef SyncRecordCollector = Future<Map<SyncCategory, List<SyncRecord>>>
    Function(Set<SyncCategory> categories);

/// 完整备份（导出 / 导入）：与同步共用 envelope、适配器与版本戳，但不需要
/// 启用同步或轮次。
///
/// 为什么独立于引擎：备份是「本地文件 ↔ 本地数据」的转换，和「跑一轮、拉
/// 传输、写报告」没有共享的可变状态。拆开后导出 / 导入测试不必构造传输与
/// 轮次；引擎的 interface 也不再为备份留两个方法。
class SyncBackup {
  SyncBackup({
    required SyncBackupState state,
    required List<SyncAdapter> adapters,
    required SyncStampIssuer stamps,
    required SyncRecordCollector collect,
    DateTime Function()? clock,
  })  : _state = state,
        _adapters = adapters,
        _stamps = stamps,
        _collect = collect,
        _clock = clock ?? DateTime.now;

  /// 备份文件外层格式标识（内层 envelope 是同步协议快照）。
  static const String backupKind = 'molia_backup';

  /// 备份文件外层格式版本（与同步协议版本相互独立）。
  static const int backupVersion = 1;

  final SyncBackupState _state;
  final List<SyncAdapter> _adapters;
  final SyncStampIssuer _stamps;
  final SyncRecordCollector _collect;
  final DateTime Function() _clock;
  final Logger _logger = Logger('molia.sync');

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// 导出完整备份 JSON 文本（歌单 / 历史 / 音源 / 设置 / 统计 / 会话 / 自定义封面）。
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
        // 单个适配器失败不阻断其余类别（与一轮同步的边界一致）；结果计数
        // 只反映真正落地的项。
        _logger.warning('导入 ${adapter.runtimeType} 失败', e);
      }
    }
    await _state.commit();
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  Set<SyncCategory> _backupCategories(bool includeCredentials) => {
        for (final category in SyncCategory.values)
          if (includeCredentials || category != SyncCategory.credentials)
            category,
      };

  SyncEnvelope _envelopeFrom(Map<SyncCategory, List<SyncRecord>> records) =>
      SyncEnvelope(
        deviceId: _state.deviceId,
        deviceName: _state.deviceName,
        producedAt: _nowMs(),
        records: records,
      );
}
