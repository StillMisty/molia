import 'package:flutter/foundation.dart';

import '../domain/models/discover.dart';
import '../domain/models/failure.dart';
import '../domain/models/library.dart';
import '../sources/builtin/builtin_search.dart';
import '../sources/builtin/discover_source.dart';
import '../sources/raw_track.dart';
import '../sources/source_track.dart';
import 'library_provider.dart';
import 'playback_provider.dart';

/// 发现能力失败（领域 [SourceFailure] 的 provider 包装，UI 只读 kind/retryable）。
class DiscoverFailure implements Exception {
  final SourceFailure failure;

  const DiscoverFailure(this.failure);

  @override
  String toString() =>
      'DiscoverFailure(${failure.kind.name}): ${failure.message}';
}

/// 发现页 UI 门面（多平台）：
/// - 统一渠道选择（默认可发现平台，也允许脚本扩展源 / any-listen 等无发现
///   能力的渠道——此时 `supports*` 全为 false，UI 自动隐藏热榜 / 歌单）；
/// - 热榜（静态表 + 详情曲目）、歌单（热门标签/标签目录、标签浏览、
///   链接/ID 详情、搜索）、热搜词；
/// - 曲目播放/收藏/加入列表复用 [PlaybackProvider] 与 [LibraryProvider]；
/// - 错误统一归一化为 [DiscoverFailure]（内部 [SourceFailure]）。
class DiscoverProvider extends ChangeNotifier {
  DiscoverProvider({
    required PlaybackProvider playbackProvider,
    required LibraryProvider libraryProvider,
    Map<String, DiscoverSource>? sources,
    void Function(String channelKey)? onChannelChanged,
  })  : _playback = playbackProvider,
        _library = libraryProvider,
        _sources = sources ?? BuiltinDiscover.sources,
        _onChannelChanged = onChannelChanged {
    // 收藏状态/我的列表变化时转发通知，让发现页的收藏按钮保持响应。
    _library.addListener(_onLibraryChanged);
  }

  void _onLibraryChanged() => notifyListeners();

  final PlaybackProvider _playback;
  final LibraryProvider _library;
  final Map<String, DiscoverSource> _sources;

  /// 渠道变化回调（composition root 注入）：搜索源跟随渠道的唯一规则点。
  final void Function(String channelKey)? _onChannelChanged;

  String _channelKey = 'wy';

  /// 当前渠道 key（默认 `wy`）。
  ///
  /// 资料页的渠道集合是「可搜索源 + 内置发现平台」的并集：脚本扩展源 /
  /// any-listen 等没有内置发现能力的渠道也可选，此时 `supports*` 全部为
  /// false，UI 自动隐藏热榜 / 歌单（含热搜词）。
  String get channelKey => _channelKey;

  /// 可用平台（保持内置注册顺序，注入的假数据源同样适用）。
  List<String> get sourceKeys => [
        for (final key in BuiltinDiscover.sourceKeys)
          if (_sources.containsKey(key)) key,
      ];

  /// 平台展示名（与「音源」页一致：酷我/酷狗/QQ/网易/咪咕）。
  String sourceDisplayName(String sourceKey) =>
      BuiltinSearch.displayName(sourceKey);

  /// 当前渠道对应的发现数据源；无发现能力（非内置平台）时为 null。
  DiscoverSource? get _source => _sources[_channelKey];

  /// 当前渠道是否具备发现能力（热榜 / 歌单 / 热搜）。
  bool get hasDiscoverSource => _source != null;

  /// 切换渠道（空值或同值忽略；允许无发现能力的渠道——相关能力降级）。
  ///
  /// 渠道变化经 [onChannelChanged] 通知组合根（搜索源跟随规则在那里，
  /// 页面不再自行同步两个 provider）。
  void selectChannel(String sourceKey) {
    if (sourceKey.isEmpty || sourceKey == _channelKey) return;
    _channelKey = sourceKey;
    _onChannelChanged?.call(sourceKey);
    notifyListeners();
  }

  /// 让搜索源跟随当前渠道（页面挂载 / 渠道恢复时调用一次；幂等由调用方
  /// 的比较条件保证）。
  void syncSearchSource() => _onChannelChanged?.call(_channelKey);

  bool get supportsLeaderboards => _source?.supportsLeaderboards ?? false;
  bool get supportsPlaylists => _source?.supportsPlaylists ?? false;
  bool get supportsPlaylistSearch => _source?.supportsPlaylistSearch ?? false;
  bool get supportsHotSearch => _source?.supportsHotSearch ?? false;

  /// 静态榜单表（无需网络；随当前渠道变化）。
  List<DiscoverLeaderboard> get leaderboards =>
      _source?.leaderboards ?? const [];

  /// 热搜词（搜索框下方展示；失败静默为空；按平台分别缓存）。
  final Map<String, List<String>> _hotSearchesBySource = {};
  bool _hotSearchLoading = false;

  List<String> get hotSearches => _hotSearchesBySource[_channelKey] ?? const [];

  /// 加载当前平台热搜词（幂等；失败静默，不影响搜索）。
  Future<void> loadHotSearches({bool force = false}) async {
    final source = _source;
    if (source == null || !source.supportsHotSearch) return;
    if (_hotSearchLoading) return;
    if (!force && _hotSearchesBySource.containsKey(_channelKey)) return;
    final key = _channelKey;
    _hotSearchLoading = true;
    try {
      final words = await source.hotSearches();
      _hotSearchesBySource[key] = words;
      if (key == _channelKey) notifyListeners();
    } catch (e) {
      debugPrint('[Discover] 加载热搜词失败($key): $e');
    } finally {
      _hotSearchLoading = false;
    }
  }

  /// 榜单曲目（静态表 → 详情曲目）。
  Future<List<DiscoverTrack>> loadLeaderboardTracks(String bangid) =>
      _guard((source) => source.leaderboardTracks(bangid));

  /// 歌单标签（热门 + 分类目录）。
  Future<DiscoverTags> loadTags() => _guard((source) => source.tags());

  /// 标签歌单列表（[tagId] 为空表示平台默认推荐）。
  Future<DiscoverPlaylistPage> loadPlaylists(String tagId, int page) =>
      _guard((source) => source.playlists(tagId, page));

  /// 歌单搜索。
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) =>
      _guard((source) => source.searchPlaylists(keyword, page));

  /// 歌单详情（支持链接 / ID / 平台内合成 id）。
  Future<DiscoverDetail> loadPlaylistDetail(String rawId, int page) =>
      _guard((source) => source.playlistDetail(rawId, page));

  // ——————————————————————— 播放 / 资料库 ———————————————————————

  /// 播放发现曲目队列（[index] 为起始下标）。
  Future<void> playTracks(
    List<DiscoverTrack> tracks,
    int index, {
    String? contextName,
  }) {
    if (tracks.isEmpty) return Future.value();
    return _playback.playSourceTracks(
      [for (final track in tracks) _toSourceTrack(track)],
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  /// 收藏 / 取消收藏。
  Future<bool> toggleFavorite(DiscoverTrack track) =>
      _library.toggleFavoriteSourceTrack(_toSourceTrack(track));

  bool isFavorite(DiscoverTrack track) =>
      _library.isFavorite(track.sourceKey, track.songId);

  /// 把歌单详情导入本地列表（同名列表复用）。
  ///
  /// 返回 `(playlistId, 新增数, 曲目总数)`。
  Future<({int playlistId, int added, int total})> importDetailToLibrary(
    DiscoverDetail detail, {
    String? fallbackName,
  }) {
    final name = detail.info.name.trim().isNotEmpty
        ? detail.info.name
        : (fallbackName ?? detail.info.id);
    return _library.importTracksAsPlaylist(
      name: name,
      tracks: [for (final track in detail.tracks) toPlaylistTrack(track)],
    );
  }

  /// 按指定平台链接/ID 拉取歌单并导入本地列表。
  Future<({int playlistId, int added, int total})> importPlaylistFromLink(
    String sourceKey,
    String rawId, {
    String? fallbackName,
  }) async {
    final source = _sourceFor(sourceKey);
    final DiscoverDetail detail;
    try {
      detail = await source.playlistDetail(rawId, 1);
    } catch (e) {
      throw DiscoverFailure(SourceFailure.from(e));
    }
    return importDetailToLibrary(detail, fallbackName: fallbackName);
  }

  /// 我的列表（自建列表，不含默认收藏）。
  List<PlaylistInfo> get playlists => _library.customPlaylists;

  /// 新建列表（「加入列表」弹层内联创建）。
  Future<int> createPlaylist(String name) => _library.createPlaylist(name);

  /// 刷新我的列表（打开「加入列表」弹层前调用）。
  Future<void> refreshPlaylists() => _library.refreshPlaylists(force: true);

  // ——————————————————————— 内部 ———————————————————————

  /// 指定平台的数据源；无内置发现能力时抛 [DiscoverFailure]。
  DiscoverSource _sourceFor(String sourceKey) {
    final source = _sources[sourceKey];
    if (source == null) {
      throw DiscoverFailure(
        SourceFailure(
          kind: FailureKind.unsupported,
          message: '渠道「$sourceKey」不支持发现内容',
        ),
      );
    }
    return source;
  }

  Future<T> _guard<T>(Future<T> Function(DiscoverSource source) action) async {
    final source = _source;
    if (source == null) {
      throw DiscoverFailure(
        SourceFailure(
          kind: FailureKind.unsupported,
          message: '渠道「$_channelKey」不支持发现内容',
        ),
      );
    }
    try {
      return await action(source);
    } catch (e) {
      throw DiscoverFailure(SourceFailure.from(e));
    }
  }

  SourceTrack _toSourceTrack(DiscoverTrack track) => SourceTrack(
        sourceKey: track.sourceKey,
        origin: 'builtin',
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: (track.coverUrl?.isNotEmpty ?? false) ? track.coverUrl : null,
        duration: (track.durationMs != null && track.durationMs! > 0)
            ? Duration(milliseconds: track.durationMs!)
            : null,
        qualities: qualitiesFromRaw(track.raw),
        raw: track.raw,
      );

  /// 发现曲目 → 资料库列表曲目（「加入列表」统一流程使用）。
  PlaylistTrack toPlaylistTrack(DiscoverTrack track) => PlaylistTrack(
        playlistId: 0,
        sourceKey: track.sourceKey,
        songId: track.songId,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.durationMs,
        raw: track.raw,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    super.dispose();
  }
}
