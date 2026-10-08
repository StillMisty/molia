import '../models/catalog.dart';
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

/// 最小歌词文档（阶段 2 由歌词子系统扩展；本波仅定义端口形状）。
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
/// 阶段 0 只定义契约，尚无实现；阶段 2 由 data/catalog 适配器落地。
abstract interface class MusicSource {
  String get key;
  String get displayName;
  SourceCapabilities get capabilities;

  Future<void> init();
  Future<void> dispose();

  /// 不支持 search 时抛 `SourceFailure(kind: unsupported)`。
  Future<SearchResult<Track>> search(SearchQuery query, {CancelToken? cancel});

  /// 取本地可播流；仅 `capabilities.resolveUrl` 为 true 时调用。
  Future<PlayableStream> resolve(Track track, {AudioQuality? preferredQuality});

  /// 无能力或无结果返回 null。
  Future<LyricsDoc?> lyrics(Track track);
  Future<Artwork?> artwork(Track track);
  Future<CollectionPage> collection(CollectionRef ref,
      {int page = 1, int limit = 50});

  /// 把任意 Track 归一化到本源的 payload（如平台 id → Track）。
  Track? adopt(Track track) => null;
}
