import '../../domain/models/artist.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/comment.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../sources/builtin/artist_source.dart';
import '../../sources/builtin/lyric_hit.dart';
import '../../sources/source_manager.dart';
import '../../sources/source_search_result.dart';
import '../mapping/track_mapper.dart';

/// `SourceManager` → 领域 `MusicSource` 适配器。
///
/// 一个实例对应一个音源 key（builtin 平台 / 脚本自定义源 / any-listen），
/// 所有操作转发给共享的 [SourceManager]，由后者完成具体路由。
/// 能力位由 `SourceManager.capabilitiesFor`（`SourceProfiles` 快照）派生：
/// 脚本源按声明的 action，内置平台按注册表适配器，与路由的实际 gating 一致。
/// `SourceManager` 的生命周期由 composition root 管理：本适配器的
/// [init]/[dispose] 为空实现，不触碰 manager。
class SourceManagerMusicSource implements MusicSource {
  SourceManagerMusicSource(this.key, this._manager);

  /// 音源 key：kw/kg/tx/wy/mg/bili、脚本自定义 key 或 any_listen。
  @override
  final String key;

  final SourceManager _manager;

  @override
  String get displayName =>
      _manager.sourceProfiles.forKey(key)?.displayName ?? key;

  @override
  SourceCapabilities get capabilities => _manager.capabilitiesFor(key);

  @override
  Future<void> init() async {
    // manager 生命周期由 composition root 管理（main.dart）。
  }

  @override
  Future<void> dispose() async {
    // 同上：不释放共享的 manager。
  }

  @override
  Future<SearchResult<Track>> search(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) return SearchResult.empty<Track>();
    final SourceSearchResult result;
    try {
      result = await _manager.searchWithMeta(
        key,
        query.keyword,
        page: query.page,
        limit: query.limit,
      );
    } catch (e) {
      // 边界错误归一化：上层只消费 SourceFailure（kind/retryable）。
      throw SourceFailure.from(e);
    }
    // 协议层不支持取消：以“丢弃结果”等价实现。
    if (cancel?.isCancelled ?? false) return SearchResult.empty<Track>();
    // 平台级失败（风控 / 传输）不能当成「没有结果」：搜索页会把失败
    // 显示成空列表，换源页更会把 B 站等分组静默丢掉。统一在边界抛
    // SourceFailure，由 CatalogService 归一化且不写缓存。
    final failure = result.failure;
    if (failure != null) throw failure;
    return SearchResult(
      items: [for (final track in result.tracks) trackFromSourceTrack(track)],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  @override
  Future<SearchResult<ArtistSummary>> searchArtists(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    if (!capabilities.artist) {
      // 无能力时明确抛 unsupported（与 collection / comments 同一约定）。
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $key 不支持歌手搜索',
      );
    }
    if (cancel?.isCancelled ?? false) {
      return SearchResult.empty<ArtistSummary>();
    }
    final ArtistSearchPage page;
    try {
      page = await _manager.searchArtists(
        key,
        query.keyword,
        page: query.page,
        limit: query.limit,
      );
    } catch (e) {
      // 边界错误归一化：上层只消费 SourceFailure（kind/retryable）。
      throw SourceFailure.from(e);
    }
    // 协议层不支持取消：以“丢弃结果”等价实现。
    if (cancel?.isCancelled ?? false) {
      return SearchResult.empty<ArtistSummary>();
    }
    return SearchResult<ArtistSummary>(
      items: page.items,
      hasMore: page.hasMore,
      total: page.total,
    );
  }

  @override
  Future<SearchResult<LyricHit>> searchLyrics(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    if (!capabilities.lyricSearch) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $key 不支持歌词搜索',
      );
    }
    if (cancel?.isCancelled ?? false) return SearchResult.empty<LyricHit>();
    final LyricSearchPage page;
    try {
      page = await _manager.searchLyrics(
        key,
        query.keyword,
        page: query.page,
        limit: query.limit,
      );
    } catch (e) {
      // 边界错误归一化：上层只消费 SourceFailure（kind/retryable）。
      throw SourceFailure.from(e);
    }
    if (cancel?.isCancelled ?? false) return SearchResult.empty<LyricHit>();
    return SearchResult<LyricHit>(
      items: [
        for (final hit in page.hits)
          LyricHit(
            track: trackFromSourceTrack(hit.track),
            snippet: hit.snippet,
          ),
      ],
      hasMore: page.hasMore,
      total: page.total,
    );
  }

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async {
    try {
      // 直接返回 PlayableStream：headers（B 站 Referer/UA 等）不能在这一层
      // 被拆成 URL 字符串，否则播放与缓存写入都会丢请求头。
      return await _manager.resolveStream(
        sourceTrackFromTrack(track),
        requestedQuality: preferredQuality?.type,
      );
    } catch (e) {
      // 边界错误归一化（幂等：CatalogService 再包一层也不会重复包装）。
      throw SourceFailure.from(e);
    }
  }

  @override
  Future<LyricsDoc?> lyrics(Track track) async {
    final result = await _manager.fetchLyric(sourceTrackFromTrack(track));
    if (result == null) return null;
    return LyricsDoc(lyric: result.lyric, translation: result.tlyric);
  }

  @override
  Future<Artwork?> artwork(Track track) async {
    final url = await _manager.fetchPic(sourceTrackFromTrack(track));
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    return uri == null ? null : Artwork(uri: uri);
  }

  @override
  Future<CommentPage> comments(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = 20,
  }) async {
    if (!capabilities.comment) {
      // 无能力时明确抛 unsupported（与 collection 同一约定，不静默返回空页）。
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $key 不支持评论',
      );
    }
    try {
      return await _manager.fetchComments(
        sourceTrackFromTrack(track),
        kind: kind,
        page: page,
        limit: limit,
      );
    } catch (e) {
      // 边界错误归一化（幂等：CommentsService 再包一层也不会重复包装）。
      throw SourceFailure.from(e);
    }
  }

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) async {
    if (!capabilities.collection) {
      // capabilities.collection == false：明确抛 unsupported，避免静默空结果。
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $key 不支持专辑/歌单详情',
      );
    }
    // 目前只有内置五平台的专辑详情（playlist / artist 尚无实现）。
    if (ref.type != 'album') {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '音源 $key 暂不支持 ${ref.type} 详情',
      );
    }
    try {
      final album =
          await _manager.fetchAlbum(key, ref.id, page: page, limit: limit);
      return CollectionPage(items: album.tracks, hasMore: album.hasMore);
    } catch (e) {
      // 边界错误归一化（幂等：AlbumService 再包一层也不会重复包装）。
      throw SourceFailure.from(e);
    }
  }

  @override
  Track? adopt(Track track) =>
      track.id.sourceKey == key ? track : null;
}
