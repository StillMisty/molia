import '../../../domain/models/device_sync.dart';
import '../../library_repository.dart';
import '../sync_adapter.dart';

/// 歌单 / 收藏 / 列表曲目适配器：直接复用资料库仓库的同步读写。
///
/// 合并键：列表 = `syncId`（收藏固定常量，其余为随机 UUID，跨设备稳定）；
/// 曲目 = `syncId + sourceKey + songId` 复合键；删除经 `sync_tombstones`。
class PlaylistSyncAdapter implements SyncAdapter {
  PlaylistSyncAdapter({required LibraryRepository repository})
      : _repository = repository;

  final LibraryRepository _repository;

  @override
  Set<SyncCategory> get categories => const {
        SyncCategory.playlists,
        SyncCategory.playlistTracks,
      };

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final playlists = <SyncRecord>[];
    for (final row in await _repository.syncExportPlaylists()) {
      final syncId = row['syncId'] as String? ?? '';
      if (syncId.isEmpty) continue;
      playlists.add(SyncRecord(
        key: syncId,
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: row['updatedBy'] as String? ?? '',
        data: {
          'syncId': syncId,
          'name': row['name'] as String? ?? '',
          'createdAt': (row['createdAt'] as num?)?.toInt() ?? 0,
          'updatedAt': (row['updatedAt'] as num?)?.toInt() ?? 0,
          'updatedBy': row['updatedBy'] as String? ?? '',
        },
      ));
    }

    final tracks = <SyncRecord>[];
    for (final row in await _repository.syncExportPlaylistTracks()) {
      final playlistSyncId = row['playlistSyncId'] as String? ?? '';
      final sourceKey = row['sourceKey'] as String? ?? '';
      final songId = row['songId'] as String? ?? '';
      if (playlistSyncId.isEmpty || sourceKey.isEmpty || songId.isEmpty) {
        continue;
      }
      tracks.add(SyncRecord(
        key: SyncRecordKeys.playlistTrack(playlistSyncId, sourceKey, songId),
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: row['updatedBy'] as String? ?? '',
        data: {
          'playlistSyncId': playlistSyncId,
          'sourceKey': sourceKey,
          'songId': songId,
          'title': row['title'] as String? ?? '',
          'artist': row['artist'] as String? ?? '',
          'album': row['album'] as String? ?? '',
          'coverUrl': row['coverUrl'] as String?,
          'durationMs': (row['durationMs'] as num?)?.toInt(),
          'raw': row['raw'] as String? ?? '{}',
          'addedAt': (row['addedAt'] as num?)?.toInt() ?? 0,
          'sortOrder': (row['sortOrder'] as num?)?.toInt() ?? 0,
          'updatedAt': (row['updatedAt'] as num?)?.toInt() ?? 0,
          'updatedBy': row['updatedBy'] as String? ?? '',
        },
      ));
    }

    final tombstones = <SyncRecord>[];
    for (final row in await _repository.syncExportTombstones([
      SyncCategory.playlists.name,
      SyncCategory.playlistTracks.name,
    ])) {
      tombstones.add(SyncRecord.tombstone(
        key: row['key'] as String? ?? '',
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: row['updatedBy'] as String? ?? '',
      ));
    }

    return {
      SyncCategory.playlists: [...playlists, ..._tombstonesFor(tombstones, true)],
      SyncCategory.playlistTracks:
          [...tracks, ..._tombstonesFor(tombstones, false)],
    };
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final playlistRows = <Map<String, Object?>>[];
    final trackRows = <Map<String, Object?>>[];
    final tombstones = <Map<String, Object?>>[];
    for (final entry in records.entries) {
      for (final record in entry.value) {
        if (record.deleted) {
          tombstones.add({
            'category': entry.key.name,
            'key': record.key,
            'updatedAt': record.updatedAt,
            'updatedBy': record.updatedBy,
          });
        } else if (entry.key == SyncCategory.playlistTracks) {
          trackRows.add(record.data ?? const <String, Object?>{});
        } else {
          playlistRows.add(record.data ?? const <String, Object?>{});
        }
      }
    }
    if (playlistRows.isEmpty && trackRows.isEmpty && tombstones.isEmpty) {
      return SyncApplyOutcome.none;
    }
    final result = await _repository.syncApplyLibrary(
      playlists: playlistRows,
      tracks: trackRows,
      tombstones: tombstones,
    );
    return SyncApplyOutcome(applied: result.applied, skipped: result.skipped);
  }

  static List<SyncRecord> _tombstonesFor(
    List<SyncRecord> tombstones,
    bool playlistLevel,
  ) =>
      [
        for (final record in tombstones)
          if ((SyncRecordKeys.parsePlaylistTrack(record.key) == null) ==
              playlistLevel)
            record,
      ];
}
