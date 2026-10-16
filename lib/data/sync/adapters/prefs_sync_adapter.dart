import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../settings/settings_key.dart';
import '../../settings/settings_registry.dart';
import '../sync_adapter.dart';
import '../sync_journal.dart';
import '../sync_state_store.dart';

/// 设置 / 音源配置 / 凭证适配器（键规格与读写都在 [SettingsRegistry]）。
///
/// 变化检测用「登记哈希」：每次 collect 对比当前值与上轮登记的哈希，不同则视为
/// 本地修改（向唯一发号器取版本戳）；应用远端后同步更新登记，保证重复应用
/// 幂等。类别开关由引擎过滤，本适配器始终登记全部键（关闭期间也持续跟踪本地
/// 变化，重新开启后可直接参与合并）。
class PrefsSyncAdapter implements SyncAdapter {
  PrefsSyncAdapter({
    required SyncStateStore state,
    required SettingsRegistry settings,
    SyncJournalRepository? journal,
    this.onApplied,
  })  : _state = state,
        _settings = settings,
        _journal = journal,
        _byName = {for (final key in settings.keys) key.name: key};

  final SyncStateStore _state;
  final SettingsRegistry _settings;

  /// 增量日志（可选）：登记哈希发现本地修改时追加，对端按游标只拉变更。
  /// 首次登记（进程首次见到该键）不算变更——初始视图由全量快照覆盖。
  final SyncJournalRepository? _journal;
  final Map<String, SettingsKey<Object?>> _byName;

  /// 应用远端设置后回调（组合根接线：注册表按键触发 reload 钩子）。
  final Future<void> Function(Set<String> keys)? onApplied;

  @override
  Set<SyncCategory> get categories => {
        for (final key in _settings.keys) key.category,
      };

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false}) async {
    final records = <SyncCategory, List<SyncRecord>>{};
    final changes = <SyncJournalChange>[];
    for (final key in _settings.keys) {
      final value = await _settings.readRaw(key);
      final hash = _hash(value);
      final stamp = _state.settingStamps[key.name];
      final SyncRecord record;
      if (stamp == null || stamp.hash != hash) {
        final isDefault = _canonical(value) == _canonical(key.defaultValue);
        final first = stamp == null;
        // 首次登记且仍是默认值：零值戳（输给任何真实写入，避免把「默认」
        // 当成本机修改推向全组）。
        final version = first && isDefault
            ? SyncVersion.zero
            : _state.stampIssuer.next();
        record = SyncRecord(
          key: key.name,
          version: version,
          data: {'v': value},
        );
        // 首次登记不是变更（初始视图由全量快照覆盖）；其余登记哈希变化
        // 就是一次本地修改，与登记更新同点追加日志。
        if (!first) {
          changes.add((category: key.category, record: record));
        }
        _state.putSettingStamp(
          key.name,
          SyncStamp(hash: hash, version: version),
        );
      } else {
        record = SyncRecord(
          key: key.name,
          version: stamp.version,
          data: {'v': value},
        );
      }
      records.putIfAbsent(key.category, () => []).add(record);
    }
    final journal = _journal;
    if (journal != null && changes.isNotEmpty) {
      await journal.appendAll(changes);
    }
    return records;
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
        await _settings.writeRaw(key, value);
        _state.putSettingStamp(
          record.key,
          SyncStamp(hash: _hash(value), version: record.version),
        );
        changed.add(record.key);
        applied++;
      }
    }
    if (changed.isNotEmpty && onApplied != null) {
      await onApplied!(changed);
    }
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(_canonical(value))).toString();

  /// 仅用于相等比较的规范 JSON（键序固定由 [jsonEncode] 保证；登记键的值都是
  /// 标量或字符串列表，无 Map）。
  static String _canonical(Object? value) => jsonEncode(value);
}
