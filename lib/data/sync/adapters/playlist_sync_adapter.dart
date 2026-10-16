import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../../domain/ports/library_sync_store.dart';
import '../sync_adapter.dart';

/// 歌单 / 收藏 / 列表曲目适配器：只依赖同步面端口（[LibrarySyncStore]）。
///
/// 合并键：列表 = `syncId`（收藏固定常量，其余为随机 UUID，跨设备稳定）；
/// 曲目 = `syncId + sourceKey + songId` 复合键；胜负按记录版本三元组，
/// 删除经 `sync_tombstones`（`createdAt` / `addedAt` 是内容时间）。
/// 记录的形状由类型化 record 承担，适配器不接触列名。
///
/// 本地下载曲目（`sourceKey = local`）不同步：文件是设备本机的持久副本，
/// 导出与应用两侧都过滤（含其墓碑），避免把「本机路径」带到其它设备。
class PlaylistSyncAdapter implements SyncAdapter {
  PlaylistSyncAdapter({required LibrarySyncStore repository})
      : _repository = repository;

  final LibrarySyncStore _repository;

  /// 上轮记录缓存：键 = 类别指纹（`COUNT(*) + MAX(versionPhysical)` 聚合）。
  /// 指纹未变时直接复用，不读行。
  String? _cacheKey;
  Map<SyncCategory, List<SyncRecord>>? _cached;

  @override
  Set<SyncCategory> get categories => const {
        SyncCategory.playlists,
        SyncCategory.playlistTracks,
      };

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final key = syncFingerprintKey(
      await _repository.syncFingerprints(categories),
    );
    final cached = _cached;
    if (cached != null && _cacheKey == key) return cached;
    final records = await _readRecords();
    _cacheKey = key;
    _cached = records;
    return records;
  }

  Future<Map<SyncCategory, List<SyncRecord>>> _readRecords() async {
    final playlists = <SyncRecord>[];
    for (final playlist in await _repository.syncExportPlaylists()) {
      if (playlist.syncId.isEmpty) continue;
      playlists.add(SyncRecord(
        key: playlist.syncId,
        version: playlist.version,
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
      // 本地下载曲目不同步（文件是设备本机的持久副本）。
      if (track.sourceKey == kLocalSourceKey) continue;
      tracks.add(SyncRecord(
        key: SyncRecordKeys.playlistTrack(
          track.playlistSyncId,
          track.sourceKey,
          track.songId,
        ),
        version: track.version,
        data: track.toJson(),
      ));
    }

    final tombstones = <SyncRecord>[];
    for (final tombstone in await _repository.syncExportTombstones([
      SyncCategory.playlists.name,
      SyncCategory.playlistTracks.name,
    ])) {
      // 本地下载曲目的墓碑同样不同步（对端没有对应条目）。
      final parsed = SyncRecordKeys.parsePlaylistTrack(tombstone.key);
      if (parsed != null && parsed.sourceKey == kLocalSourceKey) continue;
      tombstones.add(SyncRecord.tombstone(
        key: tombstone.key,
        version: tombstone.version,
        deletedAt: tombstone.deletedAt,
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
          // 本地下载曲目的墓碑不落地（对端不会有对应条目）。
          final parsed = SyncRecordKeys.parsePlaylistTrack(record.key);
          if (parsed != null && parsed.sourceKey == kLocalSourceKey) continue;
          tombstones.add(SyncTombstoneRecord(
            category: entry.key.name,
            key: record.key,
            version: record.version,
            deletedAt: record.deletedAt,
          ));
        } else if (entry.key == SyncCategory.playlistTracks) {
          final track = PlaylistTrackSyncRecord.fromJson(
            record.data ?? const <String, Object?>{},
            version: record.version,
          );
          // 本地下载曲目不同步：对端没有本机文件。
          if (track.sourceKey == kLocalSourceKey) continue;
          tracks.add(track);
        } else {
          playlists.add(PlaylistSyncRecord.fromJson(
            record.data ?? const <String, Object?>{},
            version: record.version,
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
    // 落地了远端记录：指纹的 MAX(versionPhysical) 不一定变化（远端版本可能
    // 小于本机最大值），缓存必须显式失效。
    if (result.applied > 0) _invalidateCache();
    return SyncApplyOutcome(applied: result.applied, skipped: result.skipped);
  }

  void _invalidateCache() {
    _cacheKey = null;
    _cached = null;
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
