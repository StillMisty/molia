/// 咪咕音乐渠道自述：内置搜索 / 按歌词搜歌 / 原生取词取图 / 评论 / 专辑 /
/// 歌手 / 发现。取链由 LX 脚本提供（渠道没有原生 `resolve`）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../mg_album.dart';
import '../mg_artist.dart';
import '../mg_comment.dart';
import '../mg_discover.dart';
import '../mg_lyric_search.dart';
import '../mg_search.dart';
import 'song_channel.dart';

String? _mgPageUrl(Map<String, dynamic> raw) {
  final id = raw['copyrightId']?.toString() ?? '';
  return id.isEmpty ? null : 'https://music.migu.cn/v3/music/song/$id';
}

String? _mgAlbumId(Map<String, dynamic> raw) {
  final id = raw['albumId']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

const SongChannel mgChannel = SongChannel(
  key: 'mg',
  displayName: '咪咕音乐',
  search: MgSearch.searchWithMeta,
  lyricSearch: MgLyricSearch.search,
  lyric: mgBuiltinLyric,
  pic: mgBuiltinPic,
  comments: SongChannelComments(
    rawIdKeys: ['songmid', 'copyrightId'],
    fetch: MgComment.fetch,
  ),
  album: MgAlbum.fetch,
  artist: SongChannelArtist(search: MgArtist.search, fetch: MgArtist.fetch),
  discover: MgDiscoverSource(),
  pageUrl: _mgPageUrl,
  albumId: _mgAlbumId,
);
