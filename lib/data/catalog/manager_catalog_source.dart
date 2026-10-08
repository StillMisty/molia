import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../sources/source_manager.dart';
import '../../sources/source_search_result.dart';
import '../mapping/track_mapper.dart';

/// `SourceManager` → 领域 `MusicSource` 适配器（阶段 2，施工图 §2.3.2）。
///
/// 一个实例对应一个音源 key（builtin 平台 / 脚本自定义源 / any-listen），
/// 所有操作转发给共享的 [SourceManager]，由后者完成具体路由。
/// 能力位由 `SourceManager.capabilitiesFor` 按脚本声明的 action 派生，
/// 与路由的实际 gating 一致（不谎报歌词/封面能力）。
/// `SourceManager` 的生命周期由 composition root 管理：本适配器的
/// [init]/[dispose] 为空实现，不触碰 manager。
class SourceManagerMusicSource implements MusicSource {
  SourceManagerMusicSource(this.key, this._manager);

  /// 音源 key：kw/kg/tx/wy/mg、脚本自定义 key 或 any_listen。
  @override
  final String key;

  final SourceManager _manager;

  @override
  String get displayName {
    for (final option in _manager.searchableSources) {
      if (option.key == key) return option.name;
    }
    return key;
  }

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
    return SearchResult(
      items: [for (final track in result.tracks) trackFromSourceTrack(track)],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async {
    final String url;
    try {
      url = await _manager.resolveUrl(
        sourceTrackFromTrack(track),
        requestedQuality: preferredQuality?.type,
      );
      return PlayableStream(Uri.parse(url));
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
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) {
    // capabilities.collection == false：明确抛 unsupported，避免静默空结果。
    return Future.error(const SourceFailure(
      kind: FailureKind.unsupported,
      message: 'SourceManagerMusicSource does not support collection',
    ));
  }

  @override
  Track? adopt(Track track) =>
      track.id.sourceKey == key ? track : null;
}
