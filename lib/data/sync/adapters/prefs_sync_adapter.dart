import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../settings/settings_key.dart';
import '../../settings/settings_sync_surface.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// 设置 / 音源配置 / 凭证适配器（键规格与读写都在 [SettingsSyncSurface]）。
///
/// 变化检测用「登记哈希」：每次 collect 对比当前值与上轮登记的哈希，不同则视为
/// 本地修改（向唯一发号器取版本戳）；应用远端后同步更新登记，保证重复应用
/// 幂等。类别开关由引擎过滤，本适配器始终登记全部键（关闭期间也持续跟踪本地
/// 变化，重新开启后可直接参与合并）。
///
/// 只依赖同步窄接口：整张登记表、本地写入钩子与本地写方法都不下放，单测可用
/// fake surface 覆盖应用与重载时序。
class PrefsSyncAdapter implements SyncAdapter {
  PrefsSyncAdapter({
    required this._state,
    required SettingsSyncSurface settings,
    this._journal,
  }) : _settings = settings,
       _byName = {for (final key in settings.entries) key.name: key};

  final SyncStampLedger _state;
  final SettingsSyncSurface _settings;

  /// 增量日志（可选）：登记哈希发现本地修改时追加，对端按游标只拉变更。
  /// 首次登记（进程首次见到该键）不算变更——初始视图由全量快照覆盖。
  final SyncJournalAppender? _journal;
  final Map<String, SettingsKey<Object?>> _byName;

  @override
  Set<SyncCategory> get categories => {
    for (final key in _settings.entries) key.category,
  };

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({
    bool fresh = false,
  }) async {
    final records = <SyncCategory, List<SyncRecord>>{};
    final changes = <SyncJournalChange>[];
    // 登记先暂存：日志追加失败时不能留下「已同步」的哈希，否则这次变更
    // 下一轮会被当成未变化而永久跳过（轮末提交会把旧登记落盘）。
    final registrations = <String, SyncStamp>{};
    for (final key in _settings.entries) {
      final value = await _settings.readRaw(key);
      final resolved = _resolve(key, value);
      final stamp = resolved.stamp;
      if (stamp != null) registrations[key.name] = stamp;
      if (resolved.changed) {
        changes.add((category: key.category, record: resolved.record));
      }
      records.putIfAbsent(key.category, () => []).add(resolved.record);
    }
    final journal = _journal;
    if (journal != null && changes.isNotEmpty) {
      await journal.appendAll(changes);
    }
    for (final entry in registrations.entries) {
      _state.putSettingStamp(entry.key, entry.value);
    }
    return records;
  }

  /// 本机写入设置键（组合根在注册表的写入钩子上接线）：**立即**取版本 /
  /// 登记 / 追加日志，不依赖下一轮的登记哈希检测——写入后进程被杀也不会
  /// 丢掉这次变更。
  Future<void> noteKeyWritten(SettingsKey<Object?> key) async {
    final value = await _settings.readRaw(key);
    final resolved = _resolve(key, value);
    final stamp = resolved.stamp;
    if (stamp == null) return;
    final journal = _journal;
    // 首次登记没有历史记录需要外发：直接登记，不必追加。
    if (resolved.changed && journal != null) {
      await journal.appendAll([
        (category: key.category, record: resolved.record),
      ]);
    }
    _state.putSettingStamp(key.name, stamp);
  }

  /// 单个键的当前记录 + 是否发生了**本机修改**（登记哈希变化）。
  ///
  /// 首次登记（进程首次见到该键）不算变更：初始视图由全量快照覆盖；
  /// 首次登记且仍是默认值时用零值戳（输给任何真实写入，避免把「默认」
  /// 当成本机修改推向全组）。
  ///
  /// 只计算登记、不写状态：调用方在日志追加成功后统一写入（见 [collect]）。
  ({SyncRecord record, bool changed, SyncStamp? stamp}) _resolve(
    SettingsKey<Object?> key,
    Object? value,
  ) {
    final hash = _hash(value);
    final stamp = _state.settingStamps[key.name];
    if (stamp != null && stamp.hash == hash) {
      return (
        record: SyncRecord(
          key: key.name,
          version: stamp.version,
          data: {'v': value},
        ),
        changed: false,
        stamp: null,
      );
    }
    final isDefault = _canonical(value) == _canonical(key.defaultValue);
    final first = stamp == null;
    final version = first && isDefault
        ? SyncVersion.zero
        : _state.stampIssuer.next();
    return (
      record: SyncRecord(key: key.name, version: version, data: {'v': value}),
      changed: !first,
      stamp: SyncStamp(hash: hash, version: version),
    );
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    var applied = 0;
    var skipped = 0;
    final changed = <String>{};
    for (final list in records.values) {
      for (final record in list) {
        final key = _byName[record.key];
        if (key == null || record.deleted) {
          skipped++;
          continue;
        }
        final value = record.data?['v'];
        final stamp = _state.settingStamps[record.key];
        if (stamp != null) {
          if (stamp.version.isNewerThan(record.version)) {
            skipped++;
            continue;
          }
          // 同版本（只会来自全量快照的强制交付）：比较**当前值**与登记——
          // 一致则幂等跳过；不一致说明值被直接改写，用权威视图修回去。
          if (stamp.version == record.version) {
            final current = await _settings.readRaw(key);
            if (stamp.hash == _hash(current)) {
              skipped++;
              continue;
            }
          }
        }
        // 远端值：不触发本机写入钩子（不标记待发、不追加日志），由
        // [SettingsSyncSurface] 登记待重载键。
        await _settings.applyRemote(key, value);
        _state.putSettingStamp(
          record.key,
          SyncStamp(hash: _hash(value), version: record.version),
        );
        changed.add(record.key);
        applied++;
      }
    }
    if (changed.isNotEmpty) {
      await _settings.reloadApplied();
    }
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(_canonical(value))).toString();

  /// 仅用于相等比较的规范 JSON（键序固定由 [jsonEncode] 保证；登记键的值都是
  /// 标量或字符串列表，无 Map）。
  static String _canonical(Object? value) => jsonEncode(value);
}
