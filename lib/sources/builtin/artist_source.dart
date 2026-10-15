/// 内置平台歌手获取的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 与专辑同构：歌手只由内置实现提供（LX 脚本 / any-listen 没有稳定的歌手
/// id），解析直接产出领域模型 `ArtistDetail` / `ArtistSummary`，不再经
/// sources → data 的额外映射层。
///
/// 平台能力差异（见各 `*_artist.dart`）：
/// - kg 歌手搜索无总数、`pagesize` 被忽略（平台固定一页 10 条）；
/// - tx 歌手歌曲 `begin` 无效（平台只给一页，`num` 上限 60）；
/// - mg 歌手详情无简介（`description` 为空串）。
library;

import '../../domain/models/artist.dart';
import '../../domain/models/failure.dart';
import 'builtin_search.dart';
import 'kg_artist.dart';
import 'kw_artist.dart';
import 'mg_artist.dart';
import 'tx_artist.dart';
import 'wy_artist.dart';

/// 歌手搜索的一页结果（对齐 `SearchResult` 语义的源层变体）。
class ArtistSearchPage {
  final List<ArtistSummary> items;

  /// 是否还有下一页（平台无分页能力时为 false）。
  final bool hasMore;

  /// 平台返回的结果总数（部分平台不返回时为 null）。
  final int? total;

  const ArtistSearchPage({
    required this.items,
    this.hasMore = false,
    this.total,
  });

  static const ArtistSearchPage empty = ArtistSearchPage(items: []);
}

/// 平台业务拒绝 / 缺少取歌手所需字段的统一失败（可重试：多为平台抖动）。
SourceFailure artistPlatformFailure(String platform, String reason) =>
    builtinPlatformFailure(platform, reason);

class BuiltinArtists {
  BuiltinArtists._();

  /// 具备内置歌手能力的平台（与 `BuiltinSearch.platforms` 一致）。
  static const Set<String> supportedKeys = {'kw', 'kg', 'tx', 'wy', 'mg'};

  static bool isSupported(String sourceKey) => supportedKeys.contains(sourceKey);

  /// 歌手搜索（搜索页「歌手」类型）；失败抛 [SourceFailure]。
  static Future<ArtistSearchPage> search(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (!isSupported(sourceKey)) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '内置平台不支持歌手搜索: $sourceKey',
      );
    }
    switch (sourceKey) {
      case 'kw':
        return KwArtist.search(keyword, page: page, limit: limit);
      case 'kg':
        return KgArtist.search(keyword, page: page, limit: limit);
      case 'tx':
        return TxArtist.search(keyword, page: page, limit: limit);
      case 'wy':
        return WyArtist.search(keyword, page: page, limit: limit);
      case 'mg':
        return MgArtist.search(keyword, page: page, limit: limit);
      default:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '内置平台不支持歌手搜索: $sourceKey',
        );
    }
  }

  /// 取一页歌手详情（歌手页）；[artistId] 为平台内歌手 id。
  static Future<ArtistDetail> fetch(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    if (artistId.trim().isEmpty) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: '缺少歌手 id',
        retryable: true,
      );
    }
    switch (sourceKey) {
      case 'kw':
        return KwArtist.fetch(artistId, page: page, limit: limit);
      case 'kg':
        return KgArtist.fetch(artistId, page: page, limit: limit);
      case 'tx':
        return TxArtist.fetch(artistId, page: page, limit: limit);
      case 'wy':
        return WyArtist.fetch(artistId, page: page, limit: limit);
      case 'mg':
        return MgArtist.fetch(artistId, page: page, limit: limit);
      default:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '内置平台不支持歌手: $sourceKey',
        );
    }
  }
}
