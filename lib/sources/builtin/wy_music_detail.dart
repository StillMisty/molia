import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 网易云歌曲详情（移植自 lx-music-mobile `wy/musicDetail.js`，weapi 协议）。
///
/// 供热榜 / 歌单详情批量取歌曲元数据与封面（`al.picUrl`），
/// 并产出与 LX `musicInfo` 一致的 `types/_types`（音质）字段。
class WyMusicDetail {
  WyMusicDetail._();

  /// 批量获取歌曲详情。
  ///
  /// [ids] 元素为平台 song id（int/string 均可）。失败抛 [StateError]，
  /// 由调用方（热榜/歌单）决定重试策略。
  static Future<List<SourceTrack>> getList(List<Object> ids) async {
    if (ids.isEmpty) return const [];

    final result = await lxHttpPost(
      'https://music.163.com/weapi/v3/song/detail',
      form: true,
      headers: {'origin': 'https://music.163.com'},
      body: weapiForm({
        // 与 LX 一致：c 为手工拼接的 JSON 串（非 jsonEncode）。
        'c': '[${ids.map((id) => '{"id":$id}').join(',')}]',
        'ids': '[${ids.join(',')}]',
      }),
    );
    if (result is! Map || result['code'] != 200) {
      throw StateError('获取歌曲详情失败');
    }
    return filterList(
      songs: (result['songs'] as List?) ?? const [],
      privileges: (result['privileges'] as List?) ?? const [],
    );
  }

  /// 解析歌曲详情响应（独立出来便于单元测试）。
  static List<SourceTrack> filterList({
    required List<dynamic> songs,
    required List<dynamic> privileges,
  }) {
    final list = <SourceTrack>[];
    for (var index = 0; index < songs.length; index++) {
      final raw = songs[index];
      if (raw is! Map) continue;

      // privilege 优先按下标对应，id 不匹配时按 id 查找（与 LX 一致）。
      Map<dynamic, dynamic>? privilege =
          index < privileges.length && privileges[index] is Map
              ? privileges[index] as Map
              : null;
      if (privilege == null || privilege['id'] != raw['id']) {
        privilege = privileges.whereType<Map>().firstWhere(
              (p) => p['id'] == raw['id'],
              orElse: () => const {},
            );
        if (privilege.isEmpty) continue;
      }

      final typeMap = buildTypes(
        privilege: privilege,
        song: raw,
        flacSize: _sizeOf(raw['sq']),
      );
      final reversedTypes = typeList(typeMap);

      final album = raw['al'];
      final albumId = album is Map ? album['id'] : null;
      final img = album is Map ? (album['picUrl'] ?? '') : '';
      final dt = raw['dt'];
      final durationMs =
          dt is num ? dt.toInt() : int.tryParse('$dt') ?? 0;

      final String singer;
      final String name;
      final String albumName;
      final Object? cover;
      final pc = raw['pc'];
      if (pc is Map) {
        singer = (pc['ar'] ?? '').toString();
        name = (pc['sn'] ?? '').toString();
        albumName = (pc['alb'] ?? '').toString();
        cover = img;
      } else {
        singer = _joinSingers(raw['ar']);
        name = (raw['name'] ?? '').toString();
        albumName = album is Map ? (album['name'] ?? '').toString() : '';
        cover = img;
      }

      list.add(buildTrack(
        songId: raw['id'],
        name: name,
        singer: singer,
        albumName: albumName,
        albumId: albumId,
        img: cover,
        intervalText: formatPlayTime(durationMs / 1000),
        duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
        types: reversedTypes,
        typeMap: typeMap,
      ));
    }
    return list;
  }

  /// 按 privilege 构建 wy 音质映射（与 LX switch fallthrough 语义一致：
  /// 高码率依次向下补全）。[flacSize] 传 `sq.size`；歌单详情按 LX 原样固定 null。
  static Map<String, Map<String, dynamic>> buildTypes({
    required Map privilege,
    required Map song,
    Object? flacSize,
  }) {
    final typeMap = <String, Map<String, dynamic>>{};

    void addType(String type, Object? size) {
      final sizeNum = size is num ? size : num.tryParse('$size') ?? 0;
      typeMap[type] = {'size': sizeNum > 0 ? sizeFormat(sizeNum) : null};
    }

    if (privilege['maxBrLevel'] == 'hires') {
      addType('flac24bit', _sizeOf(song['hr']));
    }
    final maxbr = privilege['maxbr'];
    if (maxbr == 999000) {
      addType('flac', flacSize);
      addType('320k', _sizeOf(song['h']));
      addType('128k', _sizeOf(song['l']));
    } else if (maxbr == 320000) {
      addType('320k', _sizeOf(song['h']));
      addType('128k', _sizeOf(song['l']));
    } else if (maxbr == 192000 || maxbr == 128000) {
      addType('128k', _sizeOf(song['l']));
    }
    return typeMap;
  }

  /// 音质列表（`types` 数组形态）：由 [buildTypes] 的映射反转得到。
  static List<Map<String, dynamic>> typeList(
    Map<String, Map<String, dynamic>> typeMap,
  ) =>
      [
        for (final entry in typeMap.entries)
          {'type': entry.key, 'size': entry.value['size']},
      ].reversed.toList();

  /// 由已解析字段构建 wy 曲目（搜索 / 歌曲详情 / 歌单详情共用同一 raw 约定）。
  static SourceTrack buildTrack({
    required Object? songId,
    required String name,
    required String singer,
    required String albumName,
    required Object? albumId,
    required Object? img,
    required String? intervalText,
    required Duration? duration,
    required List<Map<String, dynamic>> types,
    required Map<String, Map<String, dynamic>> typeMap,
  }) {
    final rawInfo = <String, dynamic>{
      'singer': singer,
      'name': name,
      'albumName': albumName,
      'albumId': albumId,
      'source': 'wy',
      'interval': intervalText,
      'songmid': songId,
      'img': img,
      'lrc': null,
      'otherSource': null,
      'types': types,
      '_types': typeMap,
      'typeUrl': <String, dynamic>{},
    };

    return SourceTrack(
      sourceKey: 'wy',
      origin: 'builtin',
      title: name,
      artist: singer,
      album: albumName,
      coverUrl: (img is String && img.isNotEmpty) ? img : null,
      duration: duration,
      qualities: buildQualities(typeMap),
      raw: rawInfo,
    );
  }

  static Object? _sizeOf(Object? quality) =>
      quality is Map ? quality['size'] : null;

  /// 歌手名拼接（`、` 分隔，与 LX `getSinger` 一致）。
  static String _joinSingers(Object? artists) {
    if (artists is! List) return '';
    final names = <String>[];
    for (final artist in artists) {
      final name = artist is Map ? artist['name'] : null;
      if (name != null && name.toString().isNotEmpty) {
        names.add(name.toString());
      }
    }
    return names.join('、');
  }
}
