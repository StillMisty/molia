/// 汽水音乐曲目的归一化：平台 track 实体 → [SourceTrack]。
///
/// 同一份 track 实体出现在搜索 / 歌单 / 专辑 / 歌手 / 发现五类响应里，
/// 字段完全一致，因此解析只写这一份（与 wy 的 `wy_music_detail.dart` 同角色）。
///
/// raw 约定（LX 脚本取链读取）：
/// - 原样保留平台实体（`id` / `vid` / `preview` / `audition_info` 等）；
/// - 追加 `track_id`（脚本更常用的键名）与 `albumId`（专辑页跳转用）；
/// - 追加 `_artists`（名字 + 平台歌手 id），`track_mapper` 据此填歌手入口。
library;

import '../source_track.dart';
import '../raw_track.dart';
import 'builtin_search.dart';

/// 汽水音乐曲目解析。
abstract final class QsTrack {
  /// 平台音质档位 → LX 音质名。`spatial` 是空间音频，不当作普通音质。
  static const Map<String, String> _qualityByGear = {
    'medium': '128k',
    'higher': '192k',
    'highest': '320k',
    'lossless': 'flac',
    'hi_res': 'flac24bit',
  };

  /// 平台图片对象 → 可直接加载的 URL。
  ///
  /// 图片对象形如 `{uri, urls: [https://p3-luna.douyinpic.com/img/], ...}`；
  /// 播放 / 封面的尺寸模板统一用 `~c5_<size>.jpg`（与分享页下发的封面一致）。
  static String? imageUrlOf(
    Object? image, {
    String suffix = '~c5_375x375.jpg',
  }) {
    if (image is String) {
      final text = image.trim();
      return text.isEmpty ? null : text;
    }
    if (image is! Map) return null;
    final uri = image['uri']?.toString().trim() ?? '';
    if (uri.isEmpty) return null;
    final urls = image['urls'];
    if (urls is List) {
      for (final prefix in urls) {
        final text = prefix?.toString() ?? '';
        if (text.isNotEmpty) return '$text$uri$suffix';
      }
    }
    return 'https://p3-luna.douyinpic.com/img/$uri$suffix';
  }

  /// 歌手名拼接（`、` 分隔，与 LX `getSinger` 一致）。
  static String joinArtists(Object? artists) {
    final names = artistRefsOf(artists).map((ref) => ref.name);
    return names.join('、');
  }

  /// 歌手引用（名字 + 平台内 id），写入 raw 的 [_artists]。
  static List<Map<String, dynamic>> rawArtistsOf(Object? artists) {
    return [
      for (final ref in artistRefsOf(artists))
        {
          'name': ref.name,
          if (ref.id != null && ref.id!.isNotEmpty) 'id': ref.id,
        },
    ];
  }

  /// 平台歌手列表 → 名字 / id 对（名字为空时丢弃）。
  static List<SourceArtistRef> artistRefsOf(Object? artists) {
    if (artists is! List) return const [];
    final refs = <SourceArtistRef>[];
    for (final artist in artists) {
      if (artist is! Map) continue;
      final name = artist['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final id = artist['id']?.toString();
      refs.add(SourceArtistRef(name: name, id: id));
    }
    return refs;
  }

  /// `bit_rates` → `_types` 映射（LX musicInfo 约定：音质类型 → 大小）。
  static Map<String, Map<String, dynamic>> qualityMapOf(Object? bitRates) {
    final byType = <String, Map<String, dynamic>>{};
    if (bitRates is List) {
      for (final item in bitRates) {
        if (item is! Map) continue;
        final gear = item['quality']?.toString() ?? '';
        final type = _qualityByGear[gear];
        if (type == null || byType.containsKey(type)) continue;
        byType[type] = {'size': item['size']};
      }
    }
    return byType;
  }

  /// `_types` 映射 → 音质列表（按 LX 音质顺序）。
  static List<SourceQuality> qualitiesOf(Object? bitRates) {
    final byType = qualityMapOf(bitRates);
    return [
      for (final type in kLxQualityOrder)
        if (byType.containsKey(type))
          SourceQuality(type: type, size: byType[type]!['size']?.toString()),
    ];
  }

  /// 单条 track 实体 → 音源曲目；缺 id / 歌名时返回 null。
  ///
  /// [albumName] / [albumId] / [cover] 供外层「整张专辑」场景补齐实体里
  /// 可能缺失的专辑信息（例如歌单媒体流只带 track 本身）。
  static SourceTrack? parse(
    Object? track, {
    String? albumName,
    String? albumId,
    String? cover,
  }) {
    if (track is! Map) return null;
    final id = track['id']?.toString() ?? '';
    final title = track['name']?.toString() ?? '';
    if (id.isEmpty || title.isEmpty) return null;

    final album = track['album'];
    final albumMap = album is Map ? album : const {};
    final resolvedAlbumId = albumId ?? (albumMap['id']?.toString() ?? '');
    final resolvedAlbumName = albumName ?? (albumMap['name']?.toString() ?? '');
    final resolvedCover =
        cover ?? imageUrlOf(albumMap['url_cover'] ?? albumMap['url_player_bg']);

    final durationMs = _intOf(track['duration']);
    final artists = artistRefsOf(track['artists']);

    final qualityMap = qualityMapOf(track['bit_rates']);
    final raw = Map<String, dynamic>.from(track);
    raw['track_id'] = id;
    raw['source'] = 'qs';
    raw['albumName'] = resolvedAlbumName;
    raw['img'] = resolvedCover;
    raw['_types'] = qualityMap;
    raw['types'] = [
      for (final entry in qualityMap.entries)
        {'type': entry.key, 'size': entry.value['size']},
    ];
    if (resolvedAlbumId.isNotEmpty) raw['albumId'] = resolvedAlbumId;
    raw[kRawArtistsField] = rawArtistsOf(track['artists']);

    return SourceTrack(
      sourceKey: 'qs',
      origin: 'builtin',
      title: title,
      artist: artists.map((ref) => ref.name).join('、'),
      album: resolvedAlbumName,
      coverUrl: resolvedCover,
      duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
      qualities: buildQualities(qualityMap),
      raw: raw,
    );
  }

  /// 列表解析（跳过结构不符的条目）。
  static List<SourceTrack> parseList(
    Object? tracks, {
    String? albumName,
    String? albumId,
    String? cover,
  }) {
    if (tracks is! List) return const [];
    return [
      for (final track in tracks)
        ?parse(track, albumName: albumName, albumId: albumId, cover: cover),
    ];
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
