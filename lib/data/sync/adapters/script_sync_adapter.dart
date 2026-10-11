import '../../../domain/models/device_sync.dart';
import '../../../sources/lx/lx_script_info.dart';
import '../../../sources/lx/lx_script_repository.dart';
import '../sync_adapter.dart';
import '../sync_state_store.dart';

/// LX 音源脚本适配器（来源类别中除设置键以外的部分）。
///
/// - 脚本记录键 = 脚本 id，时间戳 = `importedAt`（更新脚本保留原导入时间，
///   因此重新导入后才产生新戳）；
/// - 脚本文件本身不记录来源设备，`updatedBy` 留空（同戳冲突时本地保留）；
/// - 删除（本机删除或应用远端墓碑）登记在同步状态里跨轮传播；
/// - 激活脚本作为单例记录（[SyncRecordKeys.activeScriptKey]），应用后经
///   [onScriptsChanged] 让 SourceManager 重新激活；
/// - 收到脚本不弹确认：同步组内设备完全互信（ADR-0003）。
class ScriptSyncAdapter implements SyncAdapter {
  ScriptSyncAdapter({
    required LxScriptRepository repository,
    required SyncStateStore state,
    required String Function() deviceId,
    required int Function() now,
    bool Function()? ready,
    Set<String> reservedKeys = const {},
    Future<void> Function()? onScriptsChanged,
  })  : _repository = repository,
        _state = state,
        _deviceId = deviceId,
        _now = now,
        _ready = ready ?? (() => true),
        _reservedKeys = reservedKeys,
        _onScriptsChanged = onScriptsChanged;

  final LxScriptRepository _repository;
  final SyncStateStore _state;
  final String Function() _deviceId;
  final int Function() _now;
  final bool Function() _ready;

  /// 来源类别中由 PrefsSyncAdapter 负责的键（脚本适配器跳过）。
  final Set<String> _reservedKeys;
  final Future<void> Function()? _onScriptsChanged;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.sources};

  @override
  bool get ready => _ready();

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    if (!ready) return const {};
    final scripts = _repository.scripts;
    final currentIds = [for (final script in scripts) script.id];
    final knownIds = _state.knownScriptIds;
    final now = _now();
    final deviceId = _deviceId();

    // 本机删除检测：上轮还在、本轮消失且尚无墓碑 → 记删除墓碑。
    for (final id in knownIds) {
      if (currentIds.contains(id)) continue;
      _state.scriptTombstones.putIfAbsent(
        id,
        () => SyncStamp(updatedAt: now, updatedBy: deviceId),
      );
    }
    _state.setKnownScriptIds(currentIds);

    final records = <SyncRecord>[
      for (final script in scripts)
        SyncRecord(
          key: script.id,
          updatedAt: script.importedAt,
          data: script.toJson(),
        ),
      for (final entry in _state.scriptTombstones.entries)
        SyncRecord.tombstone(
          key: entry.key,
          updatedAt: entry.value.updatedAt,
          updatedBy: entry.value.updatedBy,
        ),
    ];

    // 激活脚本：值变化（含为空）时打当前戳；首次非空值视为用户既有选择。
    final activeId = _repository.activeId ?? '';
    final stamp = _state.activeScriptStamp;
    SyncStamp effective;
    if (stamp == null || stamp.hash != activeId) {
      final seeded = stamp == null && activeId.isEmpty;
      effective = SyncStamp(
        hash: activeId,
        updatedAt: seeded ? 0 : now,
        updatedBy: seeded ? '' : deviceId,
      );
      _state.setActiveScriptStamp(effective);
    } else {
      effective = stamp;
    }
    records.add(SyncRecord(
      key: SyncRecordKeys.activeScriptKey,
      updatedAt: effective.updatedAt,
      updatedBy: effective.updatedBy,
      data: {'id': activeId.isEmpty ? null : activeId},
    ));
    return {SyncCategory.sources: records};
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    if (!ready) return SyncApplyOutcome.none;
    var applied = 0;
    var skipped = 0;
    var changed = false;
    for (final record in records[SyncCategory.sources] ?? const <SyncRecord>[]) {
      if (_reservedKeys.contains(record.key)) continue;

      if (record.key == SyncRecordKeys.activeScriptKey) {
        final stamp = _state.activeScriptStamp;
        if (stamp != null &&
            !record.isNewerThan(SyncRecord(
              key: record.key,
              updatedAt: stamp.updatedAt,
              updatedBy: stamp.updatedBy,
            ))) {
          skipped++;
          continue;
        }
        final rawId = record.data?['id'];
        final target = rawId is String && rawId.isNotEmpty ? rawId : null;
        if ((_repository.activeId ?? '') != (target ?? '')) {
          // 目标脚本可能在本轮稍后落地（同批记录顺序不保证）；
          // 全部应用完成后由 [onScriptsChanged] 按仓库现状统一刷新。
          await _repository.setActive(target);
          changed = true;
        }
        _state.setActiveScriptStamp(SyncStamp(
          hash: target ?? '',
          updatedAt: record.updatedAt,
          updatedBy: record.updatedBy,
        ));
        applied++;
        continue;
      }

      if (record.deleted) {
        final existing = _scriptOf(record.key);
        if (existing != null && record.updatedAt >= existing.importedAt) {
          await _repository.remove(record.key);
          changed = true;
          applied++;
        } else {
          skipped++;
        }
        _state.putScriptTombstone(
          record.key,
          SyncStamp(
            updatedAt: record.updatedAt,
            updatedBy: record.updatedBy,
          ),
        );
        continue;
      }

      final data = record.data;
      if (data == null) {
        skipped++;
        continue;
      }
      final LxScriptInfo info;
      try {
        info = LxScriptInfo.fromJson(data.cast<String, dynamic>());
      } catch (_) {
        skipped++;
        continue;
      }
      if (info.id.isEmpty) {
        skipped++;
        continue;
      }
      final existing = _scriptOf(info.id);
      if (existing != null && existing.importedAt >= record.updatedAt) {
        skipped++;
        continue;
      }
      await _repository.add(info);
      changed = true;
      applied++;
      final tombstone = _state.scriptTombstones[info.id];
      if (tombstone != null && record.updatedAt > tombstone.updatedAt) {
        _state.removeScriptTombstone(info.id);
      }
    }

    if (changed) {
      _state.setKnownScriptIds([for (final s in _repository.scripts) s.id]);
      final onChanged = _onScriptsChanged;
      if (onChanged != null) await onChanged();
    }
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  LxScriptInfo? _scriptOf(String id) {
    for (final script in _repository.scripts) {
      if (script.id == id) return script;
    }
    return null;
  }
}
