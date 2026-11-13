/// 播放列表文件导入流水线：解析条目 → 本机路径 / Molia 键解析 → 复核。
///
/// 只解析「已知且确定」的条目：本机路径走现有本地导入端口，`#MOLIA` 键走
/// 注入的解析端口；普通在线 URL 不抓取、不猜标题，未解析条目全部进入复核
/// 列表。创建列表与批量加入由调用方经 [PlaylistImportTarget] 执行，失败时
/// 删除刚建的空列表（不留半成品）。
library;

import '../../domain/models/library.dart';
import 'playlist_file_codec.dart';

/// 未解析原因（UI 映射本地化文案）。
enum PlaylistImportIssueReason {
  /// 本机路径不存在 / 不可读 / 不是音频。
  localUnavailable,

  /// `#MOLIA` 键在资料库 / 历史 / 下载里找不到。
  keyUnresolved,

  /// 只有在线地址（或未知 scheme）：导入不抓取任意页面。
  onlineUrl,

  /// 条目本身缺位置 / 坏行。
  malformed,

  /// 既没有本机路径也没有可解析的 Molia 键。
  noLocation,
}

/// 一条未解析条目（复核列表的一项）。
class PlaylistImportIssue {
  const PlaylistImportIssue({
    required this.displayName,
    required this.reason,
    this.detail = '',
    this.line = 0,
  });

  final String displayName;
  final PlaylistImportIssueReason reason;

  /// 内部细节（位置 / 键），只用于日志与测试，不直接展示。
  final String detail;

  final int line;
}

/// 导入计划：解析完成的曲目 + 未解析条目（不创建任何数据）。
class PlaylistImportPlan {
  const PlaylistImportPlan({
    required this.name,
    required this.resolved,
    required this.issues,
    required this.totalEntries,
  });

  final String name;

  /// 去重后的已解析列表行（顺序保持文件顺序）。
  final List<PlaylistTrack> resolved;

  final List<PlaylistImportIssue> issues;

  /// 文件里的条目总数（含坏行与未解析项）。
  final int totalEntries;

  int get unresolvedCount => issues.length;

  bool get canImport => resolved.isNotEmpty;

  int get skippedCount => totalEntries - resolved.length;
}

/// 本机路径导入端口（生产实现包住下载服务的本地导入路径）。
abstract interface class PlaylistLocalImporter {
  /// 导入 / 复用该路径的本地记录；不可用时返回 null。
  Future<PlaylistTrack?> importPath(String path);
}

/// `#MOLIA` 键解析端口（生产实现查资料库 / 历史 / 下载记录）。
abstract interface class PlaylistKeyResolver {
  Future<PlaylistTrack?> resolve(String moliaKey);
}

/// 导入执行端口（新建列表 / 批量加入 / 失败清理）。
abstract interface class PlaylistImportTarget {
  Future<int> createPlaylist(String name);

  /// 返回实际新增数（重复键由存储层跳过）。
  Future<int> addTracks(int playlistId, List<PlaylistTrack> tracks);

  Future<void> deletePlaylist(int playlistId);
}

/// 导入结果。
class PlaylistImportResult {
  const PlaylistImportResult({
    required this.playlistId,
    required this.name,
    required this.added,
    required this.skipped,
  });

  final int playlistId;
  final String name;
  final int added;

  /// 文件里未导入的条目数 + 新列表内被去重的曲目数。
  final int skipped;
}

/// 解析后的导入计划 + 执行。
class PlaylistImportService {
  const PlaylistImportService({
    required this.localImporter,
    required this.resolver,
  });

  final PlaylistLocalImporter localImporter;
  final PlaylistKeyResolver resolver;

  /// 生成计划：不创建任何列表 / 记录。
  Future<PlaylistImportPlan> plan(
    PlaylistFileParseResult parsed, {
    required String fallbackName,
    required int addedAt,
  }) async {
    final resolved = <PlaylistTrack>[];
    final issues = <PlaylistImportIssue>[
      for (final problem in parsed.problems)
        PlaylistImportIssue(
          displayName: problem.text.trim().isEmpty
              ? fallbackName
              : problem.text.trim(),
          reason: PlaylistImportIssueReason.malformed,
          detail: problem.reason,
          line: problem.line,
        ),
    ];
    final seenKeys = <String>{};

    for (final entry in parsed.entries) {
      final track = await _resolveEntry(entry);
      if (track == null) {
        issues.add(
          PlaylistImportIssue(
            displayName: entry.displayName,
            reason: _reasonFor(entry),
            detail: entry.moliaKey ?? entry.location,
            line: entry.line,
          ),
        );
        continue;
      }
      final key = '${track.sourceKey}:${track.songId}';
      if (!seenKeys.add(key)) continue;
      resolved.add(
        PlaylistTrack(
          playlistId: 0,
          sourceKey: track.sourceKey,
          songId: track.songId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          durationMs: track.durationMs,
          raw: track.raw,
          addedAt: addedAt,
        ),
      );
    }

    final name = (parsed.name ?? fallbackName).trim();
    return PlaylistImportPlan(
      name: name.isEmpty ? fallbackName : name,
      resolved: resolved,
      issues: issues,
      totalEntries: parsed.entries.length + parsed.problems.length,
    );
  }

  Future<PlaylistTrack?> _resolveEntry(PlaylistFileEntry entry) async {
    if (entry.kind == PlaylistLocationKind.localPath) {
      final imported = await localImporter.importPath(entry.location);
      if (imported != null) return imported;
    }
    final moliaKey =
        entry.moliaKey ??
        (entry.kind == PlaylistLocationKind.moliaUri ? entry.location : null);
    if (moliaKey != null && moliaKey.isNotEmpty) {
      return resolver.resolve(moliaKey);
    }
    return null;
  }

  PlaylistImportIssueReason _reasonFor(PlaylistFileEntry entry) {
    if (entry.kind == PlaylistLocationKind.onlineUrl) {
      return PlaylistImportIssueReason.onlineUrl;
    }
    if (entry.moliaKey != null && entry.moliaKey!.isNotEmpty) {
      return PlaylistImportIssueReason.keyUnresolved;
    }
    if (entry.kind == PlaylistLocationKind.localPath) {
      return PlaylistImportIssueReason.localUnavailable;
    }
    return PlaylistImportIssueReason.noLocation;
  }

  /// 执行导入：只写已解析条目；创建成功后批量加入失败会删除新列表。
  ///
  /// [existingNames] 只用于同名冲突时追加数字后缀；始终新建列表，不合并到
  /// 已有列表，也不做破坏性去重。
  Future<PlaylistImportResult> commit({
    required PlaylistImportPlan plan,
    required PlaylistImportTarget target,
    Iterable<String> existingNames = const [],
  }) async {
    if (!plan.canImport) {
      throw StateError('没有可导入的曲目');
    }
    final name = uniquePlaylistName(plan.name, existingNames);
    final playlistId = await target.createPlaylist(name);
    try {
      final added = await target.addTracks(playlistId, plan.resolved);
      return PlaylistImportResult(
        playlistId: playlistId,
        name: name,
        added: added,
        skipped: plan.skippedCount + (plan.resolved.length - added),
      );
    } catch (_) {
      // 不能把「创建了但没写进去」的空列表留在侧栏里。
      try {
        await target.deletePlaylist(playlistId);
      } catch (_) {
        // 清理失败不覆盖原始失败。
      }
      rethrow;
    }
  }
}

/// 同名冲突时追加 ` (2)` / ` (3)` …；输入已 trim。
String uniquePlaylistName(String base, Iterable<String> existingNames) {
  final name = base.trim().isEmpty ? 'Playlist' : base.trim();
  final existing = {for (final value in existingNames) value.trim()};
  if (!existing.contains(name)) return name;
  var suffix = 2;
  while (existing.contains('$name ($suffix)')) {
    suffix++;
  }
  return '$name ($suffix)';
}
