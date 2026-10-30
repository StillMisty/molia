import 'builtin_search.dart';
import 'builtin_transport.dart';

/// 酷狗封面获取（移植自 lx-music-mobile `kg/pic.js`）。
///
/// 搜索 / 榜单 / 歌单响应里通常已带 `Image` / `sizable_cover`，由
/// `builtin_cover_urls.dart` 直接解析；老 payload、专辑 / 歌手歌曲等没有
/// 封面字段的入口，播放时用 `get_res_privilege` 按 `hash` + `album_id`
/// 拿 `info.image`（`{size}` 占位替换为可用尺寸）。
class KgPic {
  KgPic._();

  static const Map<String, String> _headers = {
    'KG-RC': '1',
    'KG-THash': 'expand_search_manager.cpp:852736169:451',
    'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
  };

  /// 获取封面 URL；失败返回 null。
  static Future<String?> fetch({
    required String songmid,
    String? audioId,
    String? albumId,
    String? hash,
    String? name,
    String? singer,
  }) async {
    // `album_audio_id` 的规范值是 MixSongID（raw.audioId）：搜索结果的
    // `songmid` 是 Audioid，部分存储口径下是 32 位 hash，直接拿它取图会失败。
    // 旧 payload 没有 audioId 时仍按 LX 的兜底逻辑回退到 songmid。
    final audio = audioId?.trim() ?? '';
    final albumAudioId = audio.isNotEmpty ? audio.split('_').first : songmid;

    final body = {
      'appid': 1001,
      'area_code': '1',
      'behavior': 'play',
      'clientver': '9020',
      'need_hash_offset': 1,
      'relate': 1,
      'resource': [
        {
          'album_audio_id': albumAudioId,
          'album_id': albumId ?? '',
          'hash': hash ?? '',
          'id': 0,
          'name': '${singer ?? ''} - ${name ?? ''}.mp3',
          'type': 'audio',
        },
      ],
      'token': '',
      'userid': 2626431536,
      'vip': 1,
    };

    try {
      final json = await lxHttpPost(
        'http://media.store.kugou.com/v1/get_res_privilege',
        body: body,
        headers: _headers,
        retries: BuiltinTransport.defaultRetries,
        retryIf: (value) =>
            value is! Map || (value['error_code'] ?? 0) != 0,
      );
      if (json is! Map || json['error_code'] != 0) return null;
      final data = json['data'];
      if (data is! List || data.isEmpty || data.first is! Map) return null;
      final info = (data.first as Map)['info'];
      if (info is! Map) return null;
      final image = info['image']?.toString();
      if (image == null || image.isEmpty) return null;
      final sizes = info['imgsize'];
      if (sizes is List && sizes.isNotEmpty) {
        final size = sizes.first?.toString();
        if (size != null && size.isNotEmpty) {
          return image.replaceAll('{size}', size);
        }
      }
      return image;
    } catch (_) {
      return null;
    }
  }
}
