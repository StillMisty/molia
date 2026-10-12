import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/library_sync_store.dart';
import '../sync_adapter.dart';

/// 歌单 / 收藏 / 列表曲目适配器：只依赖同步面端口（[LibrarySyncStore]）。
///
/// 合并键：列表 = `syncId`（收藏固定常量，其余为随机 UUID，跨设备稳定）；
/// 曲目 = `syncId + sourceKey + songId` 复合键；删除经 `sync_tombstones`。
/// 记录的形状由类型化 record 承担，适配器不接触列名。
class PlaylistSyncAdapter implements SyncAdapter {
  PlaylistSyncAdapter({required LibrarySyncStore repository})
      : _repository = repository;

  final LibrarySyncStore _repository;

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
    for (final playlist in await _repository.syncExportPlaylists()) {
      if (playlist.syncId.isEmpty) continue;
      playlists.add(SyncRecord(
        key: playlist.syncId,
        updatedAt: playlist.updatedAt,
        updatedBy: playlist.updatedBy,
        data: playlist.toJson(),
      ));
    }

    final tracks = <SyncRecord>[];
    for (final track in await _repository.syncExportPlaylistTracks()) {
      if (track.playlistSyncId.isEmpty ||
          track.sourceKey.isEmpty ||
          track.songId.isEmpty) {
        continue;
      }
      tracks.add(SyncRecord(
        key: SyncRecordKeys.playlistTrack(
          track.playlistSyncId,
          track.sourceKey,
          track.songId,
        ),
        updatedAt: track.updatedAt,
        updatedBy: track.updatedBy,
        data: track.toJson(),
      ));
    }

    final tombstones = <SyncRecord>[];
    for (final tombstone in await _repository.syncExportTombstones([
      SyncCategory.playlists.name,
      SyncCategory.playlistTracks.name,
    ])) {
      tombstones.add(SyncRecord.tombstone(
        key: tombstone.key,
        updatedAt: tombstone.updatedAt,
        updatedBy: tombstone.updatedBy,
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
    final playlists = <PlaylistSyncRecord>[];
    final tracks = <PlaylistTrackSyncRecord>[];
    final tombstones = <SyncTombstoneRecord>[];
    for (final entry in records.entries) {
      for (final record in entry.value) {
        if (record.deleted) {
          tombstones.add(SyncTombstoneRecord(
            category: entry.key.name,
            key: record.key,
            updatedAt: record.updatedAt,
            updatedBy: record.updatedBy,
          ));
        } else if (entry.key == SyncCategory.playlistTracks) {
          tracks.add(PlaylistTrackSyncRecord.fromJson(
            record.data ?? const <String, Object?>{},
          ));
        } else {
          playlists.add(PlaylistSyncRecord.fromJson(
            record.data ?? const <String, Object?>{},
          ));
        }
      }
    }
    if (playlists.isEmpty && tracks.isEmpty && tombstones.isEmpty) {
      return SyncApplyOutcome.none;
    }
    final result = await _repository.syncApplyLibrary(
      playlists: playlists,
      tracks: tracks,
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
