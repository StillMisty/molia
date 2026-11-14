/// 网易云音乐渠道自述：内置搜索 / 按歌词搜歌 / 原生取词取图 / 评论 /
/// 专辑 / 歌手 / 发现。取链由 LX 脚本提供（渠道没有原生 `resolve`）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../wy_album.dart';
import '../wy_artist.dart';
import '../wy_comment.dart';
import '../wy_discover.dart';
import '../wy_lyric_search.dart';
import '../wy_search.dart';
import 'song_channel.dart';

String? _wyPageUrl(Map<String, dynamic> raw) {
  final id = raw['songId'] ?? raw['id'] ?? raw['songmid'];
  final text = id?.toString() ?? '';
  return text.isEmpty ? null : 'https://music.163.com/#/song?id=$text';
}

String? _wyAlbumId(Map<String, dynamic> raw) {
  final id = raw['albumId']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

const SongChannel wyChannel = SongChannel(
  key: 'wy',
  displayName: '网易音乐',
  search: WySearch.searchWithMeta,
  lyricSearch: WyLyricSearch.search,
  lyric: wyBuiltinLyric,
  pic: wyBuiltinPic,
  comments: SongChannelComments(
    rawIdKeys: ['songmid', 'id'],
    fetch: WyComment.fetch,
  ),
  album: WyAlbum.fetch,
  artist: SongChannelArtist(search: WyArtist.search, fetch: WyArtist.fetch),
  discover: WyDiscoverSource(),
  pageUrl: _wyPageUrl,
  albumId: _wyAlbumId,
);
