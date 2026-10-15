import '../models/artist.dart';
import '../models/catalog.dart';
import '../models/comment.dart';
import '../models/source.dart';
import '../models/track.dart';

/// 本地可播流（headers / expiresIn 为 any-listen 等鉴权/缓存预留）。
class PlayableStream {
  final Uri uri;
  final Map<String, String> headers;
  final Duration? expiresIn;

  const PlayableStream(this.uri, {this.headers = const {}, this.expiresIn});

  @override
  bool operator ==(Object other) =>
      other is PlayableStream &&
      other.uri == uri &&
      other.headers == headers &&
      other.expiresIn == expiresIn;

  @override
  int get hashCode => Object.hash(uri, headers, expiresIn);

  @override
  String toString() => uri.toString();
}

/// 请求取消令牌（协议不支持取消时由实现方“丢弃结果”实现）。
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 最小歌词文档（音源端口只暴露正文 + 可选翻译）。
class LyricsDoc {
  final String lyric;
  final String? translation;

  const LyricsDoc({required this.lyric, this.translation});
}

/// 收藏/专辑/歌单引用（最小定义）。
class CollectionRef {
  final String type; // album / playlist / artist
  final String id;

  const CollectionRef({required this.type, required this.id});
}

/// 集合分页（最小定义）。
class CollectionPage {
  final List<Track> items;
  final bool hasMore;

  const CollectionPage({this.items = const [], this.hasMore = false});
}

/// 音源（目录源）：搜索 + 元数据 + 取链。任何可搜索/可播放的来源都实现它。
///
/// 当前实现：data/catalog 的 `SourceManagerMusicSource`（适配 `SourceManager`）。
abstract interface class MusicSource {
  String get key;
  String get displayName;
  SourceCapabilities get capabilities;

  Future<void> init();
  Future<void> dispose();

  /// 不支持 search 时抛 `SourceFailure(kind: unsupported)`。
  Future<SearchResult<Track>> search(SearchQuery query, {CancelToken? cancel});

  /// 歌手搜索（搜索页「歌手」分段）；仅 `capabilities.artist` 为 true 时调用。
  ///
  /// 无能力的音源抛 `SourceFailure(kind: unsupported)`
  /// （与 [collection] / [comments] 同一约定）。
  Future<SearchResult<ArtistSummary>> searchArtists(
    SearchQuery query, {
    CancelToken? cancel,
  });

  /// 按歌词搜歌（搜索页「歌词」分段）；仅 `capabilities.lyricSearch` 为 true
  /// 时调用。无能力的音源抛 `SourceFailure(kind: unsupported)`。
  Future<SearchResult<LyricHit>> searchLyrics(
    SearchQuery query, {
    CancelToken? cancel,
  });

  /// 取本地可播流；仅 `capabilities.resolveUrl` 为 true 时调用。
  Future<PlayableStream> resolve(Track track, {AudioQuality? preferredQuality});

  /// 无能力或无结果返回 null。
  Future<LyricsDoc?> lyrics(Track track);
  Future<Artwork?> artwork(Track track);

  /// 取曲目评论（热门 / 最新，分页）；仅 `capabilities.comment` 为 true 时调用。
  ///
  /// 无能力时抛 `SourceFailure(kind: unsupported)`；平台业务失败同样归一化为
  /// [SourceFailure]（失败不缓存由 `CommentsService` 保证）。
  Future<CommentPage> comments(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = 20,
  });

  Future<CollectionPage> collection(CollectionRef ref,
      {int page = 1, int limit = 50});

  /// 把任意 Track 归一化到本源的 payload（如平台 id → Track）。
  Track? adopt(Track track) => null;
}
