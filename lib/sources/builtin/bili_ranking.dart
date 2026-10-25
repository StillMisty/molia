/// B 站音乐榜单（三天榜，`rid=3&day=3`）。
///
/// B 站榜单接口一次返回整张 100 条列表，没有分页；榜单 id 用 `rid:day`
/// 组合（与脚本源的 `bangid` 约定一致），当前只接「B 站音乐榜」这一张。
library;

import '../../domain/models/discover.dart';
import '../../domain/models/failure.dart';
import '../source_track.dart' show SourceTrack;
import 'bili_client.dart';
import 'bili_track.dart';
import 'builtin_transport.dart';
import 'discover_track_mapper.dart';

class BiliRanking {
  BiliRanking._();

  /// 唯一榜单：音乐区（rid=3）三日榜。
  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(
      id: 'bili__music_3d',
      name: 'B站音乐榜',
      bangid: '3:3',
    ),
  ];

  /// 解析 `rid:day`；省略 day 时按 3 天榜处理。只接受已接入的 3:3。
  static ({int rid, int day})? parseBangid(String bangid) {
    final parts = bangid.trim().split(':');
    if (parts.isEmpty || parts.length > 2) return null;
    final rid = int.tryParse(parts[0].trim());
    final day = parts.length == 2 ? int.tryParse(parts[1].trim()) : 3;
    if (rid == null || day == null) return null;
    if (rid != 3 || day != 3) return null;
    return (rid: rid, day: day);
  }

  /// 榜单曲目（平台一次给全，结果缓存 5 分钟）。
  static Future<List<DiscoverTrack>> leaderboardTracks(String bangid) async {
    final parsed = parseBangid(bangid);
    if (parsed == null) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: 'bili: 不支持的榜单 $bangid',
      );
    }
    final key = 'bili:ranking:${parsed.rid}:${parsed.day}';
    return BiliClient.shared.cached(key, () async {
      final response = await BiliClient.shared.get(
        '/x/web-interface/ranking',
        query: {'rid': '${parsed.rid}', 'day': '${parsed.day}'},
        retries: BuiltinTransport.defaultRetries,
      );
      return parseTracks(response);
    });
  }

  /// 解析榜单响应（供单测 / 调试复用；不读缓存）。
  ///
  /// 业务码已由 client 校验，这里只处理 `data.list` 结构。
  static List<DiscoverTrack> parseTracks(dynamic response) {
    final data = response is Map ? response['data'] : null;
    final list = data is Map ? data['list'] : null;
    if (list is! List) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 音乐榜响应结构不符',
      );
    }
    final tracks = <SourceTrack>[];
    for (final item in list) {
      if (item is! Map) continue;
      final track = biliTrackFromItem(item);
      if (track != null) tracks.add(track);
    }
    return [for (final track in tracks) discoverTrackOf(track)];
  }
}
