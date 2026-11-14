/// 酷狗音乐渠道自述：内置搜索 / 按歌词搜歌 / 原生取词取图 / 评论 / 专辑 /
/// 歌手 / 发现。取链由 LX 脚本提供（渠道没有原生 `resolve`）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../kg_album.dart';
import '../kg_artist.dart';
import '../kg_comment.dart';
import '../kg_discover.dart';
import '../kg_lyric_search.dart';
import '../kg_search.dart';
import 'song_channel.dart';

String? _kgPageUrl(Map<String, dynamic> raw) {
  final hash = raw['hash']?.toString() ?? '';
  return hash.isEmpty ? null : 'https://www.kugou.com/song/#hash=$hash';
}

String? _kgAlbumId(Map<String, dynamic> raw) {
  final id = raw['albumId']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

const SongChannel kgChannel = SongChannel(
  key: 'kg',
  displayName: '酷狗音乐',
  search: KgSearch.searchWithMeta,
  lyricSearch: KgLyricSearch.search,
  lyric: kgBuiltinLyric,
  pic: kgBuiltinPic,
  comments: SongChannelComments(rawIdKeys: ['hash'], fetch: KgComment.fetch),
  album: KgAlbum.fetch,
  artist: SongChannelArtist(search: KgArtist.search, fetch: KgArtist.fetch),
  discover: KgDiscoverSource(),
  pageUrl: _kgPageUrl,
  albumId: _kgAlbumId,
);
