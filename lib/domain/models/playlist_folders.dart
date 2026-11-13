/// 列表分组的存储归一、校验、排序与纯投影（纯 Dart，无 Flutter 依赖）。
///
/// 分组只是列表行上的一个字符串：没有分组实体、没有空分组、没有嵌套。
/// 「写入 / 应用远端 / 投影 / 重命名扇出」共用同一份归一规则，避免一个
/// `" Work "` 在侧栏显示为 `Work`、扇出却按原始字符串查不到。
library;

import 'library.dart';
export 'playlist_cover_keys.dart';

/// 分组名长度上限（UI 校验与存储归一同一口径）。
const int kPlaylistFolderNameMaxLength = 40;

final RegExp _controlCharacters = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]',
);

/// 存储 / 同步应用用的归一：去控制字符、trim、按 rune 截到 40。
///
/// 远端记录可能来自旧版本或其它客户端，写库前统一收敛；读取投影时也走同一
/// 函数，因此历史上已经落库的未 trim 值仍能正确分组。
String normalizePlaylistFolderName(String raw) {
  final withoutControls = raw.replaceAll(_controlCharacters, '');
  final trimmed = withoutControls.trim();
  if (trimmed.runes.length <= kPlaylistFolderNameMaxLength) return trimmed;
  return String.fromCharCodes(trimmed.runes.take(kPlaylistFolderNameMaxLength))
      .trim();
}

/// 分组名校验问题（UI 映射本地化文案）。
enum PlaylistFolderNameIssue { tooLong, controlCharacters }

/// 校验结果：归一值 + 问题（null = 通过）。
class PlaylistFolderNameCheck {
  const PlaylistFolderNameCheck({required this.normalized, this.issue});

  final String normalized;
  final PlaylistFolderNameIssue? issue;

  bool get isValid => issue == null;
}

/// 校验分组名（重命名 / 详情输入共用）。
///
/// [allowEmpty] 为 true 时空白 = 未分组；为 false 时空白也算通过归一的空串，
/// 由调用方决定是否拒绝（重命名对话框拒绝空值）。
PlaylistFolderNameCheck checkPlaylistFolderName(String raw) {
  if (_controlCharacters.hasMatch(raw)) {
    return PlaylistFolderNameCheck(
      normalized: normalizePlaylistFolderName(raw),
      issue: PlaylistFolderNameIssue.controlCharacters,
    );
  }
  final normalized = normalizePlaylistFolderName(raw);
  if (raw.trim().runes.length > kPlaylistFolderNameMaxLength) {
    return PlaylistFolderNameCheck(
      normalized: normalized,
      issue: PlaylistFolderNameIssue.tooLong,
    );
  }
  return PlaylistFolderNameCheck(normalized: normalized);
}

/// 分组名排序：忽略大小写与首尾空白，稳定；相同小写名按原字符串兜底。
///
/// 没有引入 ICU / intl collator：中文等语言在这里按 Unicode 码位排序，
/// 不是完整 locale collation。分组名通常很短，稳定的可预测顺序优先于
/// 语言敏感排序；需要时再换带 collator 的依赖。
int compareFolderNames(String a, String b) {
  final left = a.trim();
  final right = b.trim();
  final byLower = left.toLowerCase().compareTo(right.toLowerCase());
  if (byLower != 0) return byLower;
  return left.compareTo(right);
}

/// 一个分组及其列表（未分组用 [folder] 为空串）。
class PlaylistFolderGroup {
  const PlaylistFolderGroup({required this.folder, required this.playlists});

  /// 分组名；空串 = 未分组。
  final String folder;

  final List<PlaylistInfo> playlists;

  bool get isUngrouped => folder.isEmpty;
}

/// 按分组投影列表：命名分组按 [compareFolderNames] 排序，未分组最后；组内
/// 保持传入顺序。
///
/// [playlists] 不应包含收藏（收藏固定在分组之上）；即使传入，调用方也可以
/// 用 [excludePlaylistIds] 过滤。
List<PlaylistFolderGroup> groupPlaylistsByFolder(
  List<PlaylistInfo> playlists, {
  Set<int> excludePlaylistIds = const {},
}) {
  final named = <String, List<PlaylistInfo>>{};
  final ungrouped = <PlaylistInfo>[];
  for (final playlist in playlists) {
    if (excludePlaylistIds.contains(playlist.id)) continue;
    final folder = normalizePlaylistFolderName(playlist.folder);
    if (folder.isEmpty) {
      ungrouped.add(playlist);
    } else {
      named.putIfAbsent(folder, () => []).add(playlist);
    }
  }
  final folders = named.keys.toList()..sort(compareFolderNames);
  return [
    for (final folder in folders)
      PlaylistFolderGroup(folder: folder, playlists: named[folder]!),
    if (ungrouped.isNotEmpty)
      PlaylistFolderGroup(folder: '', playlists: ungrouped),
  ];
}

/// 是否存在命名分组（决定侧栏是否隐藏单列表拖动排序）。
bool hasNamedPlaylistFolders(List<PlaylistInfo> playlists) => playlists.any(
  (playlist) => normalizePlaylistFolderName(playlist.folder).isNotEmpty,
);
