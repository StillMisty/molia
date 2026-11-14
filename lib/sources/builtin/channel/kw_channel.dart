/// 酷我音乐渠道自述：内置搜索 / 按歌词搜歌 / 原生取词取图 / 评论 / 专辑 /
/// 歌手 / 发现。取链由 LX 脚本提供（渠道没有原生 `resolve`）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../kw_album.dart';
import '../kw_artist.dart';
import '../kw_comment.dart';
import '../kw_discover.dart';
import '../kw_lyric_search.dart';
import '../kw_search.dart';
import 'song_channel.dart';

String? _kwPageUrl(Map<String, dynamic> raw) {
  final songmid = raw['songmid']?.toString() ?? '';
  final id = songmid.isNotEmpty ? songmid : (raw['id']?.toString() ?? '');
  return id.isEmpty ? null : 'https://www.kuwo.cn/play_detail/$id';
}

String? _kwAlbumId(Map<String, dynamic> raw) {
  final id = raw['albumId']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

const SongChannel kwChannel = SongChannel(
  key: 'kw',
  displayName: '酷我音乐',
  search: KwSearch.searchWithMeta,
  lyricSearch: KwLyricSearch.search,
  lyric: kwBuiltinLyric,
  pic: kwBuiltinPic,
  comments: SongChannelComments(rawIdKeys: ['songmid'], fetch: KwComment.fetch),
  album: KwAlbum.fetch,
  artist: SongChannelArtist(search: KwArtist.search, fetch: KwArtist.fetch),
  discover: KwDiscoverSource(),
  pageUrl: _kwPageUrl,
  albumId: _kwAlbumId,
);
