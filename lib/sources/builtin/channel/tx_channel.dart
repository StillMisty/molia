/// QQ 音乐渠道自述：内置搜索 / 按歌词搜歌 / 原生取词取图 / 评论 / 专辑 /
/// 歌手 / 发现。取链由 LX 脚本提供（渠道没有原生 `resolve`）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../tx_album.dart';
import '../tx_artist.dart';
import '../tx_comment.dart';
import '../tx_discover.dart';
import '../tx_lyric_search.dart';
import '../tx_search.dart';
import 'song_channel.dart';

String? _txPageUrl(Map<String, dynamic> raw) {
  final mid = raw['songmid']?.toString() ?? '';
  return mid.isEmpty ? null : 'https://y.qq.com/n/ryqq/songDetail/$mid';
}

String? _txAlbumId(Map<String, dynamic> raw) {
  final mid = raw['albumMid']?.toString() ?? '';
  final id = mid.isNotEmpty ? mid : (raw['albumId']?.toString() ?? '');
  return id.isEmpty ? null : id;
}

const SongChannel txChannel = SongChannel(
  key: 'tx',
  displayName: 'QQ音乐',
  search: TxSearch.searchWithMeta,
  lyricSearch: TxLyricSearch.search,
  lyric: txBuiltinLyric,
  pic: txBuiltinPic,
  comments: SongChannelComments(rawIdKeys: ['songId'], fetch: TxComment.fetch),
  album: TxAlbum.fetch,
  artist: SongChannelArtist(search: TxArtist.search, fetch: TxArtist.fetch),
  discover: TxDiscoverSource(),
  pageUrl: _txPageUrl,
  albumId: _txAlbumId,
);
