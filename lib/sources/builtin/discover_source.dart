import '../../domain/models/discover.dart';
import 'channel/channels.dart';

/// 内置平台「发现」能力抽象：热榜 / 歌单（标签浏览、搜索、详情）/ 热搜词。
///
/// 每个平台一个实现（与 `builtin_search.dart` 的平台注册一致：wy/tx/kg/kw/mg/bili），
/// 由 [BuiltinDiscover] 统一注册；能力差异通过 `supports*` 暴露给 UI 做降级
/// （隐藏入口而不是展示报错）。
abstract class DiscoverSource {
  const DiscoverSource();

  /// 平台键（`wy` / `tx` / `kg` / `kw` / `mg` / `bili`）。
  String get sourceKey;

  /// 静态榜单表（无网络）。
  List<DiscoverLeaderboard> get leaderboards;

  /// 榜单曲目（[bangid] 为平台原始榜单 id）。
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid);

  /// 榜单封面（轻量请求；平台没有榜单封面时返回 null）。
  ///
  /// 默认 null：发现页会用第一首曲目的封面兜底；平台能直接给出榜单封面时
  /// 覆写本方法，避免为了一个缩略图拉完整曲目列表。
  Future<String?> leaderboardCover(String bangid) async => null;

  /// 是否有轻量榜单封面接口。
  ///
  /// 为 true 时，封面请求异常不再回退完整曲目列表（网络异常时 30 个可见
  /// 磁贴并发拉全量榜单压力太大）；只有接口正常返回空字段才用首曲封面兜底。
  /// 为 false（如 B 站）时直接走首曲封面。
  bool get hasLeaderboardCoverEndpoint => false;

  /// 歌单标签（热门 + 分类目录）。
  Future<DiscoverTags> tags();

  /// 标签歌单列表（[tagId] 为空表示推荐/全部）。
  Future<DiscoverPlaylistPage> playlists(String tagId, int page);

  /// 歌单搜索。
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page);

  /// 歌单详情（支持平台 ID / 链接）。
  Future<DiscoverDetail> playlistDetail(String rawId, int page);

  /// 热搜词。
  Future<List<String>> hotSearches();

  bool get supportsLeaderboards => leaderboards.isNotEmpty;
  bool get supportsPlaylists => true;
  bool get supportsPlaylistSearch => true;
  bool get supportsHotSearch => true;
}

/// 内置平台发现注册表。
///
/// 平台顺序/实现由 `SongChannels` 的同一份条目提供：发现族不再单独维护
/// 一份平台表，避免与搜索/评论等能力族静默漂移。
class BuiltinDiscover {
  BuiltinDiscover._();

  /// 平台顺序与内置搜索一致（QQ 在前）。只含真的声明了 `discover` 的渠道。
  static final Map<String, DiscoverSource> sources = Map.unmodifiable({
    for (final channel in SongChannels.all)
      if (channel.discover != null) channel.key: channel.discover!,
  });

  /// 只列真正有发现适配器的渠道：能力矩阵以 `SongChannels` 的自述为准，
  /// 不存在「可搜索但还没有发现页」的隐式例外。
  static final List<String> sourceKeys = List.unmodifiable(sources.keys);

  static bool isSupported(String sourceKey) =>
      SongChannels.forKey(sourceKey)?.discover != null;

  static DiscoverSource of(String sourceKey) {
    final source = SongChannels.forKey(sourceKey)?.discover;
    if (source == null) {
      throw UnsupportedError('不支持的内置发现平台: $sourceKey');
    }
    return source;
  }
}
