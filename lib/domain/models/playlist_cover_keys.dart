/// 列表封面键命名空间（纯 Dart，无存储 / UI 依赖）。
///
/// 键形如 `playlist:<syncId>`；封面字节仍走 `covers` 同步类别，列表记录只保存
/// 这个稳定指针。未来封面键消费方必须把它当作不透明字符串。
library;

/// 列表封面键的保留前缀。
const String kPlaylistCoverKeyPrefix = 'playlist:';

/// 由列表 syncId 构造封面键；空 syncId 返回 null。
String? playlistCoverKeyForSyncId(String? syncId) {
  if (syncId == null || syncId.isEmpty) return null;
  return '$kPlaylistCoverKeyPrefix$syncId';
}

/// 是否为列表封面键。
bool isPlaylistCoverKey(String key) => key.startsWith(kPlaylistCoverKeyPrefix);

/// 列表封面键 → syncId；非列表键返回 null。
String? playlistSyncIdFromCoverKey(String? key) {
  if (key == null || !isPlaylistCoverKey(key)) return null;
  final syncId = key.substring(kPlaylistCoverKeyPrefix.length);
  return syncId.isEmpty ? null : syncId;
}
