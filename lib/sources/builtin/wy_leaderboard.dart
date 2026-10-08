import '../../data/cache/request_cache.dart';
import '../../domain/models/discover.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'wy_music_detail.dart';

/// 网易云排行榜（移植自 lx-music-mobile `wy/leaderboard.js`）。
///
/// - 榜单表为 LX 内置静态列表（官方 `weapi/toplist` 接口需要登录态，
///   LX 已改为静态表，见其 `getBoards` 注释）；
/// - `getTracks(bangid)`：weapi v3 歌单详情 → trackIds → 批量歌曲详情；
/// - 结果缓存 5 分钟（[RequestCache]，single-flight + LRU + TTL）。
class WyLeaderboard {
  WyLeaderboard._();

  /// 结果缓存时长（对齐本项目搜索/取链缓存的 5 分钟约定）。
  static const Duration cacheTtl = Duration(minutes: 5);

  static final RequestCache _cache =
      RequestCache(maxEntries: 16, ttl: cacheTtl);

  /// LX 静态榜单表（`wy/leaderboard.js` 的 topList 原样移植）。
  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(id: 'wy__19723756', name: '飙升榜', bangid: '19723756'),
    DiscoverLeaderboard(id: 'wy__3779629', name: '新歌榜', bangid: '3779629'),
    DiscoverLeaderboard(id: 'wy__2884035', name: '原创榜', bangid: '2884035'),
    DiscoverLeaderboard(id: 'wy__3778678', name: '热歌榜', bangid: '3778678'),
    DiscoverLeaderboard(id: 'wy__991319590', name: '说唱榜', bangid: '991319590'),
    DiscoverLeaderboard(id: 'wy__71384707', name: '古典榜', bangid: '71384707'),
    DiscoverLeaderboard(
        id: 'wy__1978921795', name: '电音榜', bangid: '1978921795'),
    DiscoverLeaderboard(
        id: 'wy__5453912201', name: '黑胶VIP爱听榜', bangid: '5453912201'),
    DiscoverLeaderboard(id: 'wy__71385702', name: 'ACG榜', bangid: '71385702'),
    DiscoverLeaderboard(id: 'wy__745956260', name: '韩语榜', bangid: '745956260'),
    DiscoverLeaderboard(id: 'wy__10520166', name: '国电榜', bangid: '10520166'),
    DiscoverLeaderboard(
        id: 'wy__180106', name: 'UK排行榜周榜', bangid: '180106'),
    DiscoverLeaderboard(
        id: 'wy__60198', name: '美国Billboard榜', bangid: '60198'),
    DiscoverLeaderboard(
        id: 'wy__3812895', name: 'Beatport全球电子舞曲榜', bangid: '3812895'),
    DiscoverLeaderboard(id: 'wy__21845217', name: 'KTV唛榜', bangid: '21845217'),
    DiscoverLeaderboard(id: 'wy__60131', name: '日本Oricon榜', bangid: '60131'),
    DiscoverLeaderboard(
        id: 'wy__2809513713', name: '欧美热歌榜', bangid: '2809513713'),
    DiscoverLeaderboard(
        id: 'wy__2809577409', name: '欧美新歌榜', bangid: '2809577409'),
    DiscoverLeaderboard(
        id: 'wy__27135204', name: '法国 NRJ Vos Hits 周榜', bangid: '27135204'),
    DiscoverLeaderboard(
        id: 'wy__3001835560', name: 'ACG动画榜', bangid: '3001835560'),
    DiscoverLeaderboard(
        id: 'wy__3001795926', name: 'ACG游戏榜', bangid: '3001795926'),
    DiscoverLeaderboard(
        id: 'wy__3001890046', name: 'ACG VOCALOID榜', bangid: '3001890046'),
    DiscoverLeaderboard(
        id: 'wy__3112516681', name: '中国新乡村音乐排行榜', bangid: '3112516681'),
    DiscoverLeaderboard(id: 'wy__5059644681', name: '日语榜', bangid: '5059644681'),
    DiscoverLeaderboard(id: 'wy__5059633707', name: '摇滚榜', bangid: '5059633707'),
    DiscoverLeaderboard(id: 'wy__5059642708', name: '国风榜', bangid: '5059642708'),
    DiscoverLeaderboard(
        id: 'wy__5338990334', name: '潜力爆款榜', bangid: '5338990334'),
    DiscoverLeaderboard(id: 'wy__5059661515', name: '民谣榜', bangid: '5059661515'),
    DiscoverLeaderboard(
        id: 'wy__6688069460', name: '听歌识曲榜', bangid: '6688069460'),
    DiscoverLeaderboard(
        id: 'wy__6723173524', name: '网络热歌榜', bangid: '6723173524'),
    DiscoverLeaderboard(id: 'wy__6732051320', name: '俄语榜', bangid: '6732051320'),
    DiscoverLeaderboard(
        id: 'wy__6732014811', name: '越南语榜', bangid: '6732014811'),
    DiscoverLeaderboard(id: 'wy__6886768100', name: '中文DJ榜', bangid: '6886768100'),
    DiscoverLeaderboard(
        id: 'wy__6939992364',
        name: '俄罗斯top hit流行音乐榜',
        bangid: '6939992364'),
    DiscoverLeaderboard(id: 'wy__7095271308', name: '泰语榜', bangid: '7095271308'),
    DiscoverLeaderboard(
        id: 'wy__7356827205', name: 'BEAT排行榜', bangid: '7356827205'),
    DiscoverLeaderboard(
        id: 'wy__7325478166',
        name: '编辑推荐榜VOL.44 天才女子摇滚乐队boygenius剖白卑微心迹',
        bangid: '7325478166'),
    DiscoverLeaderboard(
        id: 'wy__7603212484', name: 'LOOK直播歌曲榜', bangid: '7603212484'),
    DiscoverLeaderboard(id: 'wy__7775163417', name: '赏音榜', bangid: '7775163417'),
    DiscoverLeaderboard(
        id: 'wy__7785123708', name: '黑胶VIP新歌榜', bangid: '7785123708'),
    DiscoverLeaderboard(
        id: 'wy__7785066739', name: '黑胶VIP热歌榜', bangid: '7785066739'),
    DiscoverLeaderboard(
        id: 'wy__7785091694', name: '黑胶VIP爱搜榜', bangid: '7785091694'),
  ];

  /// 榜单曲目（带 5 分钟缓存；[bangid] 为榜单 id，如 `3778678`）。
  static Future<List<SourceTrack>> getTracks(String bangid) {
    return _cache.getOrCreate(
      'wy:leaderboard:$bangid',
      () => _fetch(bangid),
    );
  }

  /// 与 LX 一致：详情失败重试至多 6 次，歌曲详情失败同样重试。
  static Future<List<SourceTrack>> _fetch(String bangid) {
    return retryRequest(
      maxTries: 6,
      attempt: (_) async {
        dynamic body;
        try {
          body = await lxHttpPost(
            'https://music.163.com/weapi/v3/playlist/detail',
            form: true,
            body: weapiForm({'id': bangid, 'n': 100000, 'p': 1}),
          );
        } catch (_) {
          return null;
        }
        if (body is! Map || body['code'] != 200) return null;
        final playlist = body['playlist'];
        final trackIds = (playlist is Map ? playlist['trackIds'] : null);
        if (trackIds is! List) return null;
        final ids = <Object>[
          for (final trackId in trackIds)
            if (trackId is Map && trackId['id'] != null) trackId['id'],
        ];
        try {
          return await WyMusicDetail.getList(ids);
        } catch (e) {
          if (e is StateError && e.message == 'try max num') rethrow;
          return null;
        }
      },
    );
  }
}
