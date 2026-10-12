import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../settings/settings_key.dart';
import '../../settings/settings_registry.dart';
import '../sync_adapter.dart';
import '../sync_state_store.dart';

/// 设置 / 音源配置 / 凭证适配器（键规格与读写都在 [SettingsRegistry]）。
///
/// 变化检测用「登记哈希」：每次 collect 对比当前值与上轮登记的哈希，不同则视为
/// 本地修改（打当前时间戳 + 本设备 id）；应用远端后同步更新登记，保证重复应用
/// 幂等。类别开关由引擎过滤，本适配器始终登记全部键（关闭期间也持续跟踪本地
/// 变化，重新开启后可直接参与合并）。
class PrefsSyncAdapter implements SyncAdapter {
  PrefsSyncAdapter({
    required SyncStateStore state,
    required SettingsRegistry settings,
    required String Function() deviceId,
    required int Function() now,
    this.onApplied,
  })  : _state = state,
        _settings = settings,
        _byName = {for (final key in settings.keys) key.name: key},
        _deviceId = deviceId,
        _now = now;

  final SyncStateStore _state;
  final SettingsRegistry _settings;
  final Map<String, SettingsKey<Object?>> _byName;
  final String Function() _deviceId;
  final int Function() _now;

  /// 应用远端设置后回调（组合根接线：注册表按键触发 reload 钩子）。
  final Future<void> Function(Set<String> keys)? onApplied;

  @override
  Set<SyncCategory> get categories => {
        for (final key in _settings.keys) key.category,
      };

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final records = <SyncCategory, List<SyncRecord>>{};
    final now = _now();
    final deviceId = _deviceId();
    for (final key in _settings.keys) {
      final value = await _settings.readRaw(key);
      final hash = _hash(value);
      final stamp = _state.settingStamps[key.name];
      final SyncRecord record;
      if (stamp == null || stamp.hash != hash) {
        final isDefault = _canonical(value) == _canonical(key.defaultValue);
        final first = stamp == null;
        final updatedAt = first && isDefault ? 0 : now;
        final updatedBy = first && isDefault ? '' : deviceId;
        _state.putSettingStamp(
          key.name,
          SyncStamp(hash: hash, updatedAt: updatedAt, updatedBy: updatedBy),
        );
        record = SyncRecord(
          key: key.name,
          updatedAt: updatedAt,
          updatedBy: updatedBy,
          data: {'v': value},
        );
      } else {
        record = SyncRecord(
          key: key.name,
          updatedAt: stamp.updatedAt,
          updatedBy: stamp.updatedBy,
          data: {'v': value},
        );
      }
      records.putIfAbsent(key.category, () => []).add(record);
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
        final stamp = _state.settingStamps[record.key];
        if (stamp != null &&
            !record.isNewerThan(SyncRecord(
              key: record.key,
              updatedAt: stamp.updatedAt,
              updatedBy: stamp.updatedBy,
            ))) {
          skipped++;
          continue;
        }
        final value = record.data?['v'];
        await _settings.writeRaw(key, value);
        _state.putSettingStamp(
          record.key,
          SyncStamp(
            hash: _hash(value),
            updatedAt: record.updatedAt,
            updatedBy: record.updatedBy,
          ),
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
