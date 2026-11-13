/// 列表分组的纯投影与封面键命名空间（纯 Dart，无 Flutter / 存储依赖）。
///
/// 分组只是列表行上的一个字符串：没有分组实体、没有空分组、没有嵌套。
/// 投影规则只写在这里，侧栏 / 弹层 / 测试共用同一份「分组在前、未分组最后」
/// 的顺序，避免两处各自排序后出现顺序漂移。
library;

import 'library.dart';

/// 列表封面键的保留前缀。
///
/// 键形如 `playlist:<syncId>`；封面字节仍走 `covers` 同步类别，列表记录只
/// 保存这个稳定指针。未来封面键消费方必须把它当作不透明字符串。
const String kPlaylistCoverKeyPrefix = 'playlist:';

/// 由列表 syncId 构造封面键；空 syncId 返回 null。
String? playlistCoverKeyForSyncId(String? syncId) {
  if (syncId == null || syncId.isEmpty) return null;
  return '$kPlaylistCoverKeyPrefix$syncId';
}

/// 是否为列表封面键。
bool isPlaylistCoverKey(String key) => key.startsWith(kPlaylistCoverKeyPrefix);

/// 一个分组及其列表（未分组用 [folder] 为空串）。
class PlaylistFolderGroup {
  const PlaylistFolderGroup({required this.folder, required this.playlists});

  /// 分组名；空串 = 未分组。
  final String folder;

  final List<PlaylistInfo> playlists;

  bool get isUngrouped => folder.isEmpty;
}

/// 按分组投影列表：命名分组按本地化字面顺序，未分组最后；组内保持传入顺序。
///
/// [playlists] 不应包含收藏（收藏固定在分组之上）；即使传入，调用方也可以
/// 用 [excludePlaylistIds] 过滤。分组名区分大小写、比较前 trim，与存储口径
/// 一致。
List<PlaylistFolderGroup> groupPlaylistsByFolder(
  List<PlaylistInfo> playlists, {
  Set<int> excludePlaylistIds = const {},
}) {
  final named = <String, List<PlaylistInfo>>{};
  final ungrouped = <PlaylistInfo>[];
  for (final playlist in playlists) {
    if (excludePlaylistIds.contains(playlist.id)) continue;
    final folder = playlist.folder.trim();
    if (folder.isEmpty) {
      ungrouped.add(playlist);
    } else {
      named.putIfAbsent(folder, () => []).add(playlist);
    }
  }
  final folders = named.keys.toList()..sort();
  return [
    for (final folder in folders)
      PlaylistFolderGroup(folder: folder, playlists: named[folder]!),
    if (ungrouped.isNotEmpty)
      PlaylistFolderGroup(folder: '', playlists: ungrouped),
  ];
}

/// 是否存在命名分组（决定侧栏是否隐藏单列表拖动排序）。
bool hasNamedPlaylistFolders(List<PlaylistInfo> playlists) =>
    playlists.any((playlist) => playlist.folder.trim().isNotEmpty);
