/// 「新建列表 + 批量写入，失败清理空列表」的唯一编排。
library;

/// 列表批量写入失败（创建成功但写曲目失败）。
class PlaylistBatchWriteException implements Exception {
  const PlaylistBatchWriteException(this.cause);

  final Object? cause;

  @override
  String toString() => 'PlaylistBatchWriteException($cause)';
}

/// 执行一次批写入；[write] 抛错时 best-effort 删除刚创建的列表。
///
/// 导入列表文件与「队列存为列表」共用，避免两处各写一份 create/rollback。
Future<T> createPlaylistWithRollback<T>({
  required String name,
  required Future<int> Function(String name) createPlaylist,
  required Future<T> Function(int playlistId) write,
  required Future<void> Function(int playlistId) deletePlaylist,
}) async {
  final playlistId = await createPlaylist(name);
  try {
    return await write(playlistId);
  } catch (_) {
    try {
      await deletePlaylist(playlistId);
    } catch (_) {
      // 清理失败不覆盖原始失败。
    }
    rethrow;
  }
}
