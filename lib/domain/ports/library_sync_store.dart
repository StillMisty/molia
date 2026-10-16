import '../models/device_sync.dart';

/// 资料库的同步面端口：类型化 record 出 / 入。
///
/// 列名、行结构与墓碑表只存在于实现内部（`lib/data/library_repository.dart`）；
/// 适配器只表达「导出这些记录 / 应用这些记录」。与 UI 面（[LibraryStore]）
/// 是两条 seam：provider 只依赖 UI 面，同步适配器只依赖本端口。
abstract interface class LibrarySyncStore {
  Future<List<PlaylistSyncRecord>> syncExportPlaylists();
  Future<List<PlaylistTrackSyncRecord>> syncExportPlaylistTracks();
  Future<List<PlayHistorySyncRecord>> syncExportHistory();
  Future<List<SyncTombstoneRecord>> syncExportTombstones(
    Iterable<String> categories,
  );

  /// 类别级廉价指纹（每表 `COUNT(*)` + 最大版本的聚合，不解码任何记录）：
  /// 指纹未变时适配器复用上轮记录，不读行。
  ///
  /// 最大版本用 `versionPhysical * 1000000 + versionCounter` 表达：同一毫秒
  /// 内的多次写入只有计数分量变化，单看 `versionPhysical` 会漏掉。
  /// 任何本地写入都会推进该值（版本戳单调），行数变化由 `COUNT(*)` 覆盖；
  /// 远端应用后的缓存失效由适配器自己处理。
  Future<Map<SyncCategory, String>> syncFingerprints(
    Iterable<SyncCategory> categories,
  );

  /// 应用远端列表 / 曲目 / 墓碑（单事务，幂等）。
  Future<({int applied, int skipped})> syncApplyLibrary({
    List<PlaylistSyncRecord> playlists = const [],
    List<PlaylistTrackSyncRecord> tracks = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  });

  /// 应用远端播放历史（逐条按 `playedAt` 取新，删除经墓碑）。
  Future<({int applied, int skipped})> syncApplyHistory({
    List<PlayHistorySyncRecord> entries = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  });
}
