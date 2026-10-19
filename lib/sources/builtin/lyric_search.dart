/// 内置平台「按歌词搜歌」的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 各平台实现见 `*_lyric_search.dart`：失败抛 `SourceFailure`，曲目复用各平台
/// 既有的曲目构造器（raw 约定一致），命中片段作为结果行副标题。
///
/// 平台矩阵与实现集中在 [BuiltinPlatforms]；本文件只保留「不支持」的失败语义。
///
/// 平台差异（见各实现注释）：
/// - kw `stype=lyric` 为模糊匹配（无意义查询也会返回结果），带 `lrc` 片段；
/// - kg 条目字段与单曲搜索不同（`MixSongID` / `FileHash` + `Res` 等）；
/// - wy 用旧版搜索字段，曲目经 ids → `v3/song/detail` 补规范 raw，片段来自
///   高亮 `lyrics`；
/// - mg 命中排序偏翻唱（平台排序，原样展示）。
library;

import '../../domain/models/failure.dart';
import 'builtin_platforms.dart';
import 'lyric_hit.dart';

class BuiltinLyricSearch {
  BuiltinLyricSearch._();

  static bool isSupported(String sourceKey) =>
      BuiltinPlatforms.lyricSearchFor(sourceKey) != null;

  /// 按歌词搜歌；失败抛 [SourceFailure]（不静默吞成空结果）。
  static Future<LyricSearchPage> searchWithMeta(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final adapter = BuiltinPlatforms.lyricSearchFor(sourceKey);
    if (adapter == null) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '内置平台不支持歌词搜索: $sourceKey',
      );
    }
    return adapter(keyword, page: page, limit: limit);
  }
}
