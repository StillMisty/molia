import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../../sources/lx/lx_script_info.dart';
import '../../../sources/lx/lx_script_repository.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// LX 音源脚本适配器（来源类别中除设置键以外的部分）。
///
/// - 脚本记录键 = 脚本 id；`importedAt` 是内容时间（何时导入）**不参与**
///   胜负判定，版本 = 内容哈希变化时向发号器现取的版本戳（脚本文件本身
///   不带版本，登记在同步状态里跨轮稳定）；
/// - 删除（本机删除或应用远端墓碑）登记在同步状态里跨轮传播；
/// - 激活脚本作为单例记录（[SyncRecordKeys.activeScriptKey]），应用后经
///   [onScriptsChanged] 让 SourceManager 重新激活；
/// - 收到脚本不弹确认：同步组内设备完全互信（ADR-0003）。
class ScriptSyncAdapter implements SyncAdapter {
  ScriptSyncAdapter({
    required this._repository,
    required this._state,
    this._journal,
    bool Function()? ready,
    this._reservedKeys = const {},
    this._onScriptsChanged,
  })  : _ready = ready ?? (() => true);

  final LxScriptRepository _repository;
  final SyncStampLedger _state;

  /// 增量日志（可选）：内容哈希发现脚本变化、本机删除、激活脚本切换时
  /// 追加；首次登记不算变更（初始视图由全量快照覆盖）。
  final SyncJournalAppender? _journal;
  final bool Function() _ready;

  /// 来源类别中由 PrefsSyncAdapter 负责的键（脚本适配器跳过）。
  final Set<String> _reservedKeys;
  final Future<void> Function()? _onScriptsChanged;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.sources};

  @override
  bool get ready => _ready();

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
      {bool fresh = false}) async {
    if (!ready) return const {};
    final scripts = _repository.scripts;
    final currentIds = [for (final script in scripts) script.id];
    final knownIds = _state.knownScriptIds;
    final changes = <SyncJournalChange>[];
    // 登记先暂存，日志追加成功后才写：追加失败时保留旧登记，下一轮仍能
    // 检测到删除 / 替换（否则轮末提交会把「已同步」的登记落盘，变更永失）。
    final registrations = <String, SyncStamp>{};
    final removedStamps = <String>{};
    final tombstones = <String, SyncStamp>{};

    // 本机删除检测：上轮还在、本轮消失 → **一律取新戳**。复用旧墓碑会让这次
    // 本地删除输给陈旧的远端墓碑（发号器已吸收观测值，新戳必然更大）。
    for (final id in knownIds) {
      if (currentIds.contains(id)) continue;
      final version = _state.stampIssuer.next();
      tombstones[id] = SyncStamp(version: version);
      removedStamps.add(id);
      changes.add((
        category: SyncCategory.sources,
        record: SyncRecord.tombstone(key: id, version: version),
      ));
    }

    final records = <SyncRecord>[
      for (final script in scripts)
        _scriptRecord(script, changes, registrations),
      // 本轮新删除的墓碑覆盖旧登记；其它墓碑沿用持久化值。
      for (final entry in {..._state.scriptTombstones, ...tombstones}.entries)
        SyncRecord.tombstone(
          key: entry.key,
          version: entry.value.version,
          deletedAt: entry.value.version.physical,
        ),
    ];

    // 激活脚本：值变化（含为空）时取新戳；首次非空值视为用户既有选择。
    final activeId = _repository.activeId ?? '';
    final stamp = _state.activeScriptStamp;
    SyncStamp effective;
    SyncStamp? activeRegistration;
    if (stamp == null || stamp.hash != activeId) {
      final seeded = stamp == null && activeId.isEmpty;
      effective = SyncStamp(
        hash: activeId,
        version: seeded ? SyncVersion.zero : _state.stampIssuer.next(),
      );
      activeRegistration = effective;
      if (stamp != null) {
        changes.add((
          category: SyncCategory.sources,
          record: SyncRecord(
            key: SyncRecordKeys.activeScriptKey,
            version: effective.version,
            data: {'id': activeId.isEmpty ? null : activeId},
          ),
        ));
      }
    } else {
      effective = stamp;
    }
    records.add(SyncRecord(
      key: SyncRecordKeys.activeScriptKey,
      version: effective.version,
      data: {'id': activeId.isEmpty ? null : activeId},
    ));
    final journal = _journal;
    if (journal != null && changes.isNotEmpty) {
      await journal.appendAll(changes);
    }
    for (final id in removedStamps) {
      _state.removeScriptStamp(id);
    }
    for (final entry in registrations.entries) {
      _state.putScriptStamp(entry.key, entry.value);
    }
    for (final entry in tombstones.entries) {
      _state.putScriptTombstone(entry.key, entry.value);
    }
    if (activeRegistration != null) {
      _state.setActiveScriptStamp(activeRegistration);
    }
    _state.setKnownScriptIds(currentIds);
    return {SyncCategory.sources: records};
  }

  /// 脚本的当前版本：内容哈希变化时取新戳并登记（“脚本被替换”＝本地修改）；
  /// 真实变化（非首次登记）追加日志。登记写进 [registrations]，由调用方在
  /// 日志追加成功后统一落进状态。
  SyncRecord _scriptRecord(
    LxScriptInfo script,
    List<SyncJournalChange> changes,
    Map<String, SyncStamp> registrations,
  ) {
    final hash = _contentHash(script);
    final stamp = _state.scriptStamps[script.id];
    if (stamp != null && stamp.hash == hash) {
      return SyncRecord(
        key: script.id,
        version: stamp.version,
        data: script.toJson(),
      );
    }
    final version = _state.stampIssuer.next();
    registrations[script.id] = SyncStamp(hash: hash, version: version);
    final record = SyncRecord(
      key: script.id,
      version: version,
      data: script.toJson(),
    );
    if (stamp != null) {
      changes.add((category: SyncCategory.sources, record: record));
    }
    return record;
  }

  /// 本机写入脚本（导入 / 更新，组合根在 SourceManager 的写入钩子上接线）：
  /// **立即**取版本 / 登记 / 追加日志——新导入的脚本没有历史登记，若只靠
  /// 下一轮的哈希检测会被当成「首次登记」而不外发。
  Future<void> noteScriptWritten(String id) async {
    if (!ready) return;
    final script = _scriptOf(id);
    if (script == null) return;
    final hash = _contentHash(script);
    final stamp = _state.scriptStamps[id];
    if (stamp != null && stamp.hash == hash) return;
    final version = _state.stampIssuer.next();
    final journal = _journal;
    if (journal != null) {
      // 先追加、后登记：追加失败时保留旧登记，下一轮哈希检测仍会外发。
      await journal.appendAll([
        (
          category: SyncCategory.sources,
          record: SyncRecord(
            key: id,
            version: version,
            data: script.toJson(),
          ),
        ),
      ]);
    }
    _state.putScriptStamp(id, SyncStamp(hash: hash, version: version));
    _state.removeScriptTombstone(id);
    _state.setKnownScriptIds([for (final s in _repository.scripts) s.id]);
  }

  /// 本机删除脚本：**立即**取新戳写墓碑并追加日志（不依赖下一轮检测）。
  Future<void> noteScriptRemoved(String id) async {
    if (!ready) return;
    final version = _state.stampIssuer.next();
    final journal = _journal;
    if (journal != null) {
      // 先追加、后登记：追加失败时保留旧登记，下一轮删除检测仍会外发。
      await journal.appendAll([
        (
          category: SyncCategory.sources,
          record: SyncRecord.tombstone(key: id, version: version),
        ),
      ]);
    }
    _state.putScriptTombstone(id, SyncStamp(version: version));
    _state.removeScriptStamp(id);
    _state.setKnownScriptIds([for (final s in _repository.scripts) s.id]);
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    if (!ready) return SyncApplyOutcome.none;
    var applied = 0;
    var skipped = 0;
    var changed = false;
    for (final record
        in records[SyncCategory.sources] ?? const <SyncRecord>[]) {
      if (_reservedKeys.contains(record.key)) continue;

      if (record.key == SyncRecordKeys.activeScriptKey) {
        final stamp = _state.activeScriptStamp;
        final rawId = record.data?['id'];
        final target = rawId is String && rawId.isNotEmpty ? rawId : null;
        if (stamp != null) {
          if (stamp.version.isNewerThan(record.version)) {
            skipped++;
            continue;
          }
          // 同版本：指针一致 → 幂等跳过；不一致 → 修回去（全量快照权威）。
          if (stamp.version == record.version && stamp.hash == (target ?? '')) {
            skipped++;
            continue;
          }
        }
        if ((_repository.activeId ?? '') != (target ?? '')) {
          // 目标脚本可能在本轮稍后落地（同批记录顺序不保证）；
          // 全部应用完成后由 [onScriptsChanged] 按仓库现状统一刷新。
          await _repository.setActive(target);
          changed = true;
        }
        _state.setActiveScriptStamp(SyncStamp(
          hash: target ?? '',
          version: record.version,
        ));
        applied++;
        continue;
      }

      if (record.deleted) {
        final existing = _scriptOf(record.key);
        final scriptVersion =
            _state.scriptStamps[record.key]?.version ?? SyncVersion.zero;
        if (existing != null && record.version.isNewerThan(scriptVersion)) {
          await _repository.remove(record.key);
          _state.removeScriptStamp(record.key);
          changed = true;
          applied++;
        } else {
          skipped++;
        }
        // 墓碑只在确实更新时覆盖：陈旧远端删除不顶掉本地较新的删除。
        final localTombstone = _state.scriptTombstones[record.key];
        if (localTombstone == null ||
            record.version.isNewerThan(localTombstone.version)) {
          _state.putScriptTombstone(
            record.key,
            SyncStamp(version: record.version),
          );
        }
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
      final stamp = _state.scriptStamps[info.id];
      final hash = _contentHash(info);
      if (stamp != null) {
        if (stamp.version.isNewerThan(record.version)) {
          skipped++;
          continue;
        }
        // 同版本（只会来自全量快照的强制交付）：比较**当前脚本**与登记——
        // 一致则幂等跳过；不一致（脚本被直接改写）用权威视图修回去。
        if (stamp.version == record.version) {
          final current = _scriptOf(info.id);
          if (current != null && stamp.hash == _contentHash(current)) {
            skipped++;
            continue;
          }
        }
      }
      final tombstone = _state.scriptTombstones[info.id];
      if (tombstone != null && !record.version.isNewerThan(tombstone.version)) {
        // 比本地墓碑旧（或同版本）的脚本不落地：导入旧备份 / 陈旧对端都不能
        // 复活本机已删除的脚本。
        skipped++;
        continue;
      }
      await _repository.add(info);
      changed = true;
      applied++;
      _state.putScriptStamp(
        info.id,
        SyncStamp(hash: hash, version: record.version),
      );
      if (tombstone != null) {
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

  /// 脚本内容指纹（变化检测：同一进程 / 跨进程稳定）。
  static String _contentHash(LxScriptInfo info) =>
      sha256.convert(utf8.encode(jsonEncode(info.toJson()))).toString();

  LxScriptInfo? _scriptOf(String id) {
    for (final script in _repository.scripts) {
      if (script.id == id) return script;
    }
    return null;
  }
}
