import '../../domain/models/discover.dart';
import 'kg_discover.dart';
import 'kw_discover.dart';
import 'mg_discover.dart';
import 'tx_discover.dart';
import 'wy_discover.dart';

/// 内置平台「发现」能力抽象：热榜 / 歌单（标签浏览、搜索、详情）/ 热搜词。
///
/// 每个平台一个实现（与 `builtin_search.dart` 的平台注册一致：wy/tx/kg/kw/mg），
/// 由 [BuiltinDiscover] 统一注册；能力差异通过 `supports*` 暴露给 UI 做降级
/// （隐藏入口而不是展示报错）。
abstract class DiscoverSource {
  const DiscoverSource();

  /// 平台键（`wy` / `tx` / `kg` / `kw` / `mg`）。
  String get sourceKey;

  /// 静态榜单表（无网络）。
  List<DiscoverLeaderboard> get leaderboards;

  /// 榜单曲目（[bangid] 为平台原始榜单 id）。
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid);

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
class BuiltinDiscover {
  BuiltinDiscover._();

  /// 平台顺序与内置搜索一致（wy 在前：默认平台）。
  static const Map<String, DiscoverSource> sources = {
    'wy': WyDiscoverSource(),
    'tx': TxDiscoverSource(),
    'kg': KgDiscoverSource(),
    'kw': KwDiscoverSource(),
    'mg': MgDiscoverSource(),
  };

  static const List<String> sourceKeys = ['wy', 'tx', 'kg', 'kw', 'mg'];

  static bool isSupported(String sourceKey) => sources.containsKey(sourceKey);

  static DiscoverSource of(String sourceKey) {
    final source = sources[sourceKey];
    if (source == null) {
      throw UnsupportedError('不支持的内置发现平台: $sourceKey');
    }
    return source;
  }
}
