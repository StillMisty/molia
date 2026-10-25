import 'package:drift/drift.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import '../molia_database.dart';

/// 进程内登记（未注入持久化实现时的默认）：只在本次运行内做变更集判定。
class InMemorySyncKnownStore implements SyncKnownStore {
  final Map<SyncKnownKey, SyncVersion> _versions = {};

  @override
  Future<Map<SyncKnownKey, SyncVersion>> knownVersions() async =>
      Map.of(_versions);

  @override
  Future<void> putKnownVersions(Map<SyncKnownKey, SyncVersion> versions) async {
    _versions.addAll(versions);
  }

  @override
  Future<void> reset() async => _versions.clear();
}

/// drift 持久化登记（生产）：`sync_known` 表，跨重启保持变更集基线。
class SyncKnownRepository implements SyncKnownStore {
  SyncKnownRepository({required this._databaseProvider});

  final MoliaDatabase Function() _databaseProvider;

  @override
  Future<Map<SyncKnownKey, SyncVersion>> knownVersions() async {
    final db = _databaseProvider();
    final rows = await db.select(db.syncKnown).get();
    final result = <SyncKnownKey, SyncVersion>{};
    for (final row in rows) {
      final category = SyncCategory.tryParse(row.category);
      if (category == null) continue;
      result[(category: category, key: row.key)] = row.syncVersion;
    }
    return result;
  }

  @override
  Future<void> putKnownVersions(Map<SyncKnownKey, SyncVersion> versions) async {
    if (versions.isEmpty) return;
    final db = _databaseProvider();
    await db.batch((batch) {
      batch.insertAllOnConflictUpdate(
        db.syncKnown,
        [
          for (final entry in versions.entries)
            SyncKnownCompanion.insert(
              category: entry.key.category.name,
              key: entry.key.key,
              versionPhysical: entry.value.physical,
              versionCounter: Value(entry.value.counter),
              deviceId: Value(entry.value.deviceId),
            ),
        ],
      );
    });
  }

  @override
  Future<void> reset() async {
    final db = _databaseProvider();
    await db.delete(db.syncKnown).go();
  }
}
