import 'builtin_search.dart';
import 'builtin_transport.dart';

/// 酷狗封面获取（移植自 lx-music-mobile `kg/pic.js`）。
///
/// 搜索/榜单响应本身不带封面（`img: null`），播放时用 `get_res_privilege`
/// 按 `hash` + `album_id` 拿 `info.image`（`{size}` 占位替换为可用尺寸）。
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
    // 修复歌曲 ID 存储变更导致的封面获取失败（LX `kg/pic.js` 同款兜底）。
    var albumAudioId = songmid;
    if (songmid.length == 32) {
      final audio = audioId ?? '';
      if (audio.contains('_')) {
        albumAudioId = audio.split('_').first;
      } else if (audio.isNotEmpty) {
        albumAudioId = audio;
      }
    }

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
