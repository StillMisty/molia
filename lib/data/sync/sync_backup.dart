import 'dart:convert';

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import 'sync_adapter.dart';
import 'sync_book.dart';
import 'sync_record_pipeline.dart';
import 'sync_stamp.dart';

/// 完整备份（导出 / 导入）：与同步共用 envelope、记录管道与版本戳，但不需要
/// 启用同步或轮次。
///
/// 为什么独立于引擎：备份是「本地文件 ↔ 本地数据」的转换，和「跑一轮、拉
/// 传输、写报告」没有共享的可变状态。拆开后导出 / 导入测试不必构造传输与
/// 轮次；引擎的 interface 也不再为备份留两个方法。记录层的收集 / 合并 /
/// 登记仍走 [SyncRecordPipeline]（与一轮同步同一实例），两条应用路径不会
/// 各自维护一套合并规则。
class SyncBackup {
  SyncBackup({
    required this._state,
    required this._pipeline,
    required this._stamps,
    this.onExported,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 备份文件外层格式标识（内层 envelope 是同步协议快照）。
  static const String backupKind = 'molia_backup';

  /// 备份文件外层格式版本（与同步协议版本相互独立）。
  static const int backupVersion = 1;

  final SyncBackupState _state;
  final SyncRecordPipeline _pipeline;
  final SyncStampIssuer _stamps;
  final DateTime Function() _clock;

  /// 导出完成后的释放钩子（组合根接统计导出缓存）。
  ///
  /// 完整备份会把整库记录读进内存；导出是低频动作，拿到 JSON 后缓存没有
  /// 继续常驻的理由，下一次同步按需重读即可。
  final void Function()? onExported;

  final Logger _logger = Logger('molia.sync');

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// 导出完整备份 JSON 文本（全部类别，含凭证）。
  ///
  /// 默认导出完整状态：歌单 / 历史 / 音源 / 设置 / 统计 / 会话 / 自定义封面 /
  /// 凭据（AI Key、any-listen token、B 站登录）。[includeCredentials] 只作为
  /// 显式排除凭证的逃生口；备份文件本身为明文 JSON，调用方负责保管。
  Future<String> exportBackupJson({bool includeCredentials = true}) async {
    final categories = _backupCategories(includeCredentials);
    // 备份是完整快照：必须绕过适配器的增量视图（会话的游标记录不含队列
    // tracks），否则导出文件无法在新设备上恢复完整会话。
    final records = await _pipeline.collect(categories, fresh: true);
    final envelope = _envelopeFrom(records);
    final json = const JsonEncoder.withIndent('  ').convert({
      'kind': backupKind,
      'v': backupVersion,
      'producedAt': _nowMs(),
      'envelope': envelope.toJson(),
    });
    // JSON 已经成形，缓存可以放掉；钩子失败不能把一次成功的导出变成失败。
    try {
      onExported?.call();
    } catch (e) {
      _logger.warning('备份导出后的缓存释放失败', e);
    }
    return json;
  }

  /// 导入完整备份：与本地数据逐键合并（LWW，不做整体覆盖）。
  ///
  /// 先收集本地现状更新登记，保证本地较新的改动不会被旧备份覆盖。
  /// 默认连同凭证一起恢复，保证换机后的状态与备份时一致。
  Future<SyncApplyOutcome> importBackupJson(
    String json, {
    bool includeCredentials = true,
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
    // 与一轮同步同一不变量：先收集本地现状播种登记，再合并应用；否则本地
    // 较新的改动会被旧备份按「先出现者胜」覆盖。
    await _pipeline.collect(categories);
    final filtered = _filterCategories(envelope, categories);
    // 备份不是「权威对端」：把载荷里的全部键作为强制交付，让合并跳过登记
    // 过滤、逐键交给适配器按 LWW 判定（与导入前的行为一致，陈旧记录由
    // 适配器 / 库内版本比较跳过）。
    final forcedKeys = <SyncKnownKey>{
      for (final entry in filtered.records.entries)
        for (final record in entry.value)
          (category: entry.key, key: record.key),
    };
    final result = await _pipeline.apply(filtered, forcedKeys: forcedKeys);
    await _state.commit();
    return SyncApplyOutcome(applied: result.applied, skipped: result.skipped);
  }

  /// 只保留本次备份允许的类别（凭证排除是备份层的策略，管道不认识）。
  static SyncEnvelope _filterCategories(
    SyncEnvelope envelope,
    Set<SyncCategory> categories,
  ) {
    final records = <SyncCategory, List<SyncRecord>>{
      for (final entry in envelope.records.entries)
        if (categories.contains(entry.key)) entry.key: entry.value,
    };
    return SyncEnvelope(
      deviceId: envelope.deviceId,
      deviceName: envelope.deviceName,
      producedAt: envelope.producedAt,
      snapshotId: envelope.snapshotId,
      version: envelope.version,
      records: records,
      journalHead: envelope.journalHead,
      baseSeq: envelope.baseSeq,
      windowStart: envelope.windowStart,
      windowEnd: envelope.windowEnd,
      journal: envelope.journal,
      acks: envelope.acks,
      categories: envelope.categories,
    );
  }

  Set<SyncCategory> _backupCategories(bool includeCredentials) => {
    for (final category in SyncCategory.values)
      if (includeCredentials || category != SyncCategory.credentials) category,
  };

  SyncEnvelope _envelopeFrom(Map<SyncCategory, List<SyncRecord>> records) =>
      SyncEnvelope(
        deviceId: _state.deviceId,
        deviceName: _state.deviceName,
        producedAt: _nowMs(),
        records: records,
      );
}
