/// 内置平台「按歌词搜歌」的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 各平台实现见 `*_lyric_search.dart`：失败抛 `SourceFailure`，曲目复用各平台
/// 既有的曲目构造器（raw 约定一致），命中片段作为结果行副标题。
///
/// 平台差异（见各实现注释）：
/// - kw `stype=lyric` 为模糊匹配（无意义查询也会返回结果），带 `lrc` 片段；
/// - kg 条目字段与单曲搜索不同（`MixSongID` / `FileHash` + `Res` 等）；
/// - wy 用旧版搜索字段，曲目经 ids → `v3/song/detail` 补规范 raw，片段来自
///   高亮 `lyrics`；
/// - mg 命中排序偏翻唱（平台排序，原样展示）。
library;

import '../../domain/models/failure.dart';
import 'kg_lyric_search.dart';
import 'kw_lyric_search.dart';
import 'lyric_hit.dart';
import 'mg_lyric_search.dart';
import 'tx_lyric_search.dart';
import 'wy_lyric_search.dart';

class BuiltinLyricSearch {
  BuiltinLyricSearch._();

  /// 具备歌词搜索能力的平台（与 `BuiltinSearch.platforms` 一致）。
  static const Set<String> supportedKeys = {'kw', 'kg', 'tx', 'wy', 'mg'};

  static bool isSupported(String sourceKey) => supportedKeys.contains(sourceKey);

  /// 按歌词搜歌；失败抛 [SourceFailure]（不静默吞成空结果）。
  static Future<LyricSearchPage> searchWithMeta(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (!isSupported(sourceKey)) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '内置平台不支持歌词搜索: $sourceKey',
      );
    }
    switch (sourceKey) {
      case 'kw':
        return KwLyricSearch.search(keyword, page: page, limit: limit);
      case 'kg':
        return KgLyricSearch.search(keyword, page: page, limit: limit);
      case 'tx':
        return TxLyricSearch.search(keyword, page: page, limit: limit);
      case 'wy':
        return WyLyricSearch.search(keyword, page: page, limit: limit);
      case 'mg':
        return MgLyricSearch.search(keyword, page: page, limit: limit);
      default:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '内置平台不支持歌词搜索: $sourceKey',
        );
    }
  }
}
