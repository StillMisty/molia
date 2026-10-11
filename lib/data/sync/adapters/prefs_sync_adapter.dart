import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/models/device_sync.dart';
import '../sync_adapter.dart';
import '../sync_state_store.dart';

/// 值的存放位置。
enum SyncValueStore { preferences, secure }

/// 值的类型（决定从 SharedPreferences 以哪种 getter 读取与写回）。
enum SyncValueKind { string, bool, int, stringList }

/// 一个可同步设置键的规格：类别 / 存储 / 类型 / 默认值。
///
/// 默认值参与两条规则：① 首次开启同步时，等于默认值的键以时间戳 0 登记
/// （新设备接入时让已有配置胜出）；② 缺键按默认值读取（缺省与默认等价）。
class SyncSettingSpec {
  final String key;
  final SyncCategory category;
  final SyncValueStore store;
  final SyncValueKind kind;
  final Object? defaultValue;

  const SyncSettingSpec({
    required this.key,
    required this.category,
    this.store = SyncValueStore.preferences,
    this.kind = SyncValueKind.string,
    this.defaultValue,
  });
}

/// 设置 / 音源配置 / 凭证适配器。
///
/// 变化检测用「登记哈希」而不是改造全部写入方：每次 collect 对比当前值与
/// 上轮登记的哈希，不同则视为本地修改（打当前时间戳 + 本设备 id）；应用远端
/// 后同步更新登记，保证重复应用幂等。类别开关由引擎过滤，本适配器始终登记
/// 全部键（关闭期间也持续跟踪本地变化，重新开启后可直接参与合并）。
class PrefsSyncAdapter implements SyncAdapter {
  PrefsSyncAdapter({
    required SyncStateStore state,
    required List<SyncSettingSpec> specs,
    required String Function() deviceId,
    required int Function() now,
    SharedPreferences? preferences,
    this.onApplied,
  })  : _state = state,
        _specs = specs,
        _specsByKey = {for (final spec in specs) spec.key: spec},
        _deviceId = deviceId,
        _now = now,
        _preferences = preferences;

  final SyncStateStore _state;
  final List<SyncSettingSpec> _specs;
  final Map<String, SyncSettingSpec> _specsByKey;
  final String Function() _deviceId;
  final int Function() _now;
  SharedPreferences? _preferences;

  /// 应用远端设置后回调（组合根接线：按类别重载主题 / 导航 / 音源等）。
  final Future<void> Function(Set<String> keys)? onApplied;

  @override
  Set<SyncCategory> get categories => {
        for (final spec in _specs) spec.category,
      };

  @override
  bool get ready => true;

  Future<SharedPreferences> _prefs() async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final records = <SyncCategory, List<SyncRecord>>{};
    final now = _now();
    final deviceId = _deviceId();
    for (final spec in _specs) {
      final value = await _readValue(spec);
      final hash = _hash(value);
      final stamp = _state.settingsRegistry[spec.key];
      final SyncRecord record;
      if (stamp == null || stamp.hash != hash) {
        final isDefault = _canonical(value) == _canonical(spec.defaultValue);
        final first = stamp == null;
        final updatedAt = first && isDefault ? 0 : now;
        final updatedBy = first && isDefault ? '' : deviceId;
        _state.putSettingStamp(
          spec.key,
          SyncStamp(hash: hash, updatedAt: updatedAt, updatedBy: updatedBy),
        );
        record = SyncRecord(
          key: spec.key,
          updatedAt: updatedAt,
          updatedBy: updatedBy,
          data: {'v': value},
        );
      } else {
        record = SyncRecord(
          key: spec.key,
          updatedAt: stamp.updatedAt,
          updatedBy: stamp.updatedBy,
          data: {'v': value},
        );
      }
      records.putIfAbsent(spec.category, () => []).add(record);
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
        final spec = _specsByKey[record.key];
        if (spec == null || record.deleted) {
          skipped++;
          continue;
        }
        final stamp = _state.settingsRegistry[record.key];
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
        await _writeValue(spec, value);
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

  Future<Object?> _readValue(SyncSettingSpec spec) async {
    if (spec.store == SyncValueStore.secure) {
      final raw = await _state.readSecretValue(spec.key);
      if (raw == null) return spec.defaultValue;
      return raw;
    }
    final prefs = await _prefs();
    return switch (spec.kind) {
      SyncValueKind.string => prefs.getString(spec.key) ?? spec.defaultValue,
      SyncValueKind.bool => prefs.getBool(spec.key) ?? spec.defaultValue,
      SyncValueKind.int => prefs.getInt(spec.key) ?? spec.defaultValue,
      SyncValueKind.stringList =>
        prefs.getStringList(spec.key) ?? spec.defaultValue,
    };
  }

  Future<void> _writeValue(SyncSettingSpec spec, Object? value) async {
    if (spec.store == SyncValueStore.secure) {
      if (value == null || (value is String && value.isEmpty)) {
        await _state.deleteSecretValue(spec.key);
      } else if (value is String) {
        await _state.writeSecretValue(spec.key, value);
      }
      return;
    }
    final prefs = await _prefs();
    if (value == null) {
      await prefs.remove(spec.key);
      return;
    }
    switch (spec.kind) {
      case SyncValueKind.string:
        if (value is String) {
          await prefs.setString(spec.key, value);
        } else {
          await prefs.setString(spec.key, value.toString());
        }
      case SyncValueKind.bool:
        final boolValue = value is bool
            ? value
            : (value is String ? value.toLowerCase() == 'true' : null);
        if (boolValue == null) {
          await prefs.remove(spec.key);
        } else {
          await prefs.setBool(spec.key, boolValue);
        }
      case SyncValueKind.int:
        final intValue = value is num
            ? value.toInt()
            : (value is String ? int.tryParse(value) : null);
        if (intValue == null) {
          await prefs.remove(spec.key);
        } else {
          await prefs.setInt(spec.key, intValue);
        }
      case SyncValueKind.stringList:
        if (value is List) {
          await prefs.setStringList(spec.key, value.whereType<String>().toList());
        } else {
          await prefs.remove(spec.key);
        }
    }
  }

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(_canonical(value))).toString();

  /// 仅用于相等比较的规范 JSON（键序固定由 [jsonEncode] 保证；本适配器
  /// 的值都是标量或字符串列表，无 Map）。
  static String _canonical(Object? value) => jsonEncode(value);
}
