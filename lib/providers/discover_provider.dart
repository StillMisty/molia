import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/mapping/track_mapper.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../domain/models/discover.dart';
import '../domain/models/failure.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../models/play_mode.dart';
import '../sources/builtin/builtin_search.dart';
import '../sources/builtin/discover_source.dart';
import '../sources/raw_track.dart';
import '../sources/source_track.dart';
import 'library_outcome.dart';
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
    this._settings,
    String? initialChannelKey,
  }) : _playback = playbackProvider,
       _library = libraryProvider,
       _sources = sources ?? BuiltinDiscover.sources {
    // 测试 / 恢复场景显式指定的初始渠道优先，且不被异步恢复覆盖。
    _hasExplicitInitialChannel =
        initialChannelKey != null && _sources.containsKey(initialChannelKey);
    // 默认选中规范顺序里的第一个可用平台（当前为 QQ）。
    _channelKey = _hasExplicitInitialChannel
        ? initialChannelKey!
        : _firstAvailableChannelKey();
    final settings = _settings;
    if (settings != null) {
      settings.bindReload(kDiscoverChannelKey, _reloadChannelFromSettings);
      unawaited(_restoreChannelFromSettings());
    }
    // 收藏状态 / 我的列表变化时转发通知，让发现页的收藏按钮与「加入列表」
    // 弹层保持响应。历史写入（每首歌一次）不转发——发现页对历史无依赖，
    // 无脑转发会让整页（含全部 tab 与 AI 推荐卡片）随每次切歌重建。
    _lastFavoritesRevision = _library.favoritesRevision;
    _lastPlaylistsRevision = _library.playlistsRevision;
    _library.addListener(_onLibraryChanged);
  }

  void _onLibraryChanged() {
    final favorites = _library.favoritesRevision;
    final playlists = _library.playlistsRevision;
    if (favorites == _lastFavoritesRevision &&
        playlists == _lastPlaylistsRevision) {
      return;
    }
    _lastFavoritesRevision = favorites;
    _lastPlaylistsRevision = playlists;
    notifyListeners();
  }

  int _lastFavoritesRevision = 0;
  int _lastPlaylistsRevision = 0;

  final PlaybackProvider _playback;
  final LibraryProvider _library;
  final Map<String, DiscoverSource> _sources;

  /// 渠道偏好（跨重启记住）；null = 测试 / 无持久化场景。
  final SettingsAccess? _settings;

  bool _hasExplicitInitialChannel = false;

  /// 恢复 / 用户选择的代际：异步读偏好不得覆盖用户刚做出的选择。
  int _channelGeneration = 0;

  bool _disposed = false;

  String _channelKey = '';

  /// 当前渠道 key（默认规范顺序里的第一个可用平台，当前为 QQ）。
  ///
  /// 这是全局唯一的渠道偏好：同时决定热榜 / 歌单与搜索（Ctrl+F / 搜索 tab
  /// 都只搜当前渠道）。资料页的渠道集合是「可搜索源 + 内置发现平台」的并集：
  /// 脚本扩展源 / any-listen 等没有内置发现能力的渠道也可选，此时
  /// `supports*` 全部为 false，UI 自动隐藏热榜 / 歌单（含热搜词）。
  String get channelKey => _channelKey;

  String _firstAvailableChannelKey() {
    for (final key in BuiltinDiscover.sourceKeys) {
      if (_sources.containsKey(key)) return key;
    }
    return BuiltinDiscover.sourceKeys.first;
  }

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
  /// 同时决定热榜 / 歌单与搜索：组合根 / 资料页监听 channelKey 变化，把
  /// 同一个 key 同步给 SearchProvider.setActiveSource。偏好异步落盘（失败吞掉）。
  void selectChannel(String sourceKey) {
    if (sourceKey.isEmpty || sourceKey == _channelKey) return;
    _channelGeneration++;
    _channelKey = sourceKey;
    notifyListeners();
    final settings = _settings;
    if (settings == null) return;
    unawaited(
      settings.write(kDiscoverChannelKey, sourceKey).catchError((Object _) {}),
    );
  }

  Future<void> _restoreChannelFromSettings() async {
    final settings = _settings;
    if (settings == null) return;
    final generation = _channelGeneration;
    try {
      final value = (await settings.read(kDiscoverChannelKey)).trim();
      if (_disposed ||
          _hasExplicitInitialChannel ||
          generation != _channelGeneration ||
          value.isEmpty ||
          value == _channelKey) {
        return;
      }
      // 无效渠道由资料页现有的 fallback 纠正（渠道集合包含脚本源等
      // DiscoverProvider 不认识但用户可能选过的 key）。
      _channelKey = value;
      notifyListeners();
    } catch (_) {
      // 读取失败保持默认渠道。
    }
  }

  /// 同步应用远端值后的重载入口。
  Future<void> _reloadChannelFromSettings() async {
    final settings = _settings;
    if (settings == null) return;
    final generation = _channelGeneration;
    try {
      final value = (await settings.read(kDiscoverChannelKey)).trim();
      if (_disposed ||
          _hasExplicitInitialChannel ||
          generation != _channelGeneration ||
          value.isEmpty ||
          value == _channelKey) {
        return;
      }
      _channelKey = value;
      notifyListeners();
    } catch (_) {}
  }

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

  /// 已解析的榜单封面（按 board.id 缓存；null = 已失败 / 无封面）。
  final Map<String, String?> _leaderboardCovers = {};

  /// 进行中的榜单封面请求（按 board.id single-flight）。
  final Map<String, Future<String?>> _leaderboardCoverLoads = {};

  /// 已缓存的榜单封面；未加载 / 失败返回 null。
  String? leaderboardCoverOf(DiscoverLeaderboard board) =>
      _leaderboardCovers[board.id];

  /// 按需加载榜单封面：先问平台的轻量接口，失败再用首曲封面兜底。
  ///
  /// 只由可见磁贴触发（SliverGrid 懒构建），不会在打开热榜 tab 时并发拉
  /// 全部榜单的完整曲目列表；成功封面按 board.id 缓存，失败不缓存以便重试。
  Future<String?> loadLeaderboardCover(DiscoverLeaderboard board) {
    if (_leaderboardCovers.containsKey(board.id)) {
      return Future.value(_leaderboardCovers[board.id]);
    }
    final existing = _leaderboardCoverLoads[board.id];
    if (existing != null) return existing;
    final source = _source;
    if (source == null) return Future.value(null);
    late final Future<String?> request;
    request = _resolveLeaderboardCover(source, board)
        .then((value) {
          // 只缓存成功结果：失败 / 无封面时下一次调用可以重试，避免一次
          // 瞬时网络错误把占位钉死到本次会话结束。
          if (value != null && value.isNotEmpty) {
            _leaderboardCovers[board.id] = value;
          }
          return value;
        })
        .catchError((Object _) => null)
        .whenComplete(() {
          _leaderboardCoverLoads.remove(board.id);
        });
    _leaderboardCoverLoads[board.id] = request;
    return request;
  }

  Future<String?> _resolveLeaderboardCover(
    DiscoverSource source,
    DiscoverLeaderboard board,
  ) async {
    var directFailed = false;
    try {
      final direct = (await source.leaderboardCover(board.bangid))?.trim();
      if (direct != null && direct.isNotEmpty) return direct;
    } catch (_) {
      directFailed = true;
    }
    // 有轻量封面接口但请求异常：不回退完整曲目列表，避免网络异常时多个
    // 可见磁贴同时拉整张榜单；等下一次可见 / 详情页打开时再重试。
    if (directFailed && source.hasLeaderboardCoverEndpoint) return null;
    try {
      final tracks = await source.leaderboardTracks(board.bangid);
      for (final track in tracks) {
        final cover = track.coverUrl?.trim() ?? '';
        if (cover.isNotEmpty) return cover;
      }
    } catch (_) {
      // 首曲也失败：磁贴保留平台色占位，不阻塞列表。
    }
    return null;
  }

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

  /// 播放发现曲目队列（测试 / 兼容入口；生产页面走 `TrackHandoff`）。
  ///
  /// 与 [domainTracksOf] 共用同一份领域曲目转换和 `playDomainTracks` 后端，
  /// 与 [domainTracksOf] 共用同一份领域曲目转换和播放后端。`mode` 非空时
  /// 先切换播放模式。
  Future<void> playTracks(
    List<DiscoverTrack> tracks,
    int index, {
    String? contextName,
    PlayMode? mode,
  }) async {
    final domainTracks = domainTracksOf(tracks);
    if (domainTracks.isEmpty) return;
    if (mode != null) {
      await _playback.setPlayMode(mode);
    }
    await _playback.playDomainTracks(
      domainTracks,
      index.clamp(0, domainTracks.length - 1),
      contextName: contextName,
    );
  }

  /// 发现曲目 → 领域曲目（`TrackHandoff` 播放入口的统一形状）。
  ///
  /// raw 由 [_toSourceTrack] 原样透传，页面只拿领域 `Track`（不读 payload）；
  /// 与 [playTracks] 共用同一份曲目转换，不产生第二条映射口径。
  List<Track> domainTracksOf(List<DiscoverTrack> tracks) => [
    for (final track in tracks) trackFromSourceTrack(_toSourceTrack(track)),
  ];

  /// 收藏 / 取消收藏；仓库写失败以 failed 结果返回（图标态保持原样）。
  Future<FavoriteToggleOutcome> toggleFavorite(DiscoverTrack track) =>
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
    _disposed = true;
    _library.removeListener(_onLibraryChanged);
    super.dispose();
  }
}
