/// 汽水音乐渠道自述：搜索 / 原生取词取图 / 评论 / 专辑 / 歌手 / 发现。
///
/// 与音乐五平台的关键差异：
/// - **取链由音源脚本提供**：渠道不声明 `resolve`。匿名接口只给会员曲目的
///   30 秒试听流；完整播放走脚本自己的签名链路，与网易渠道同一模式；
/// - **没有匿名歌词搜索接口**：不声明 `lyricSearch`，搜索页不出「歌词」分段；
/// - **没有匿名榜单目录与热搜词**：发现页只有推荐歌单 / 分类 / 歌单搜索。
///
/// 曲目 / 歌单 / 专辑 id 都是 64 位数字的字符串，raw 里一律按字符串保存，
/// 不经数值转换（浮点会丢精度）。
library;

import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import '../qs_album.dart';
import '../qs_artist.dart';
import '../qs_comment.dart';
import '../qs_discover.dart';
import '../qs_search.dart';
import 'song_channel.dart';

String? _qsPageUrl(Map<String, dynamic> raw) {
  final trackId = raw['track_id']?.toString() ?? '';
  final id = trackId.isNotEmpty ? trackId : (raw['id']?.toString() ?? '');
  return id.isEmpty ? null : 'https://www.qishui.com/share/track?track_id=$id';
}

String? _qsAlbumId(Map<String, dynamic> raw) {
  final id = raw['albumId']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

const SongChannel qsChannel = SongChannel(
  key: 'qs',
  displayName: '汽水音乐',
  search: QsSearch.searchWithMeta,
  lyric: qsBuiltinLyric,
  pic: qsBuiltinPic,
  comments: SongChannelComments(
    rawIdKeys: ['track_id', 'id'],
    fetch: QsComment.fetch,
  ),
  album: QsAlbum.fetch,
  artist: SongChannelArtist(search: QsArtist.search, fetch: QsArtist.fetch),
  discover: QsDiscoverSource(),
  pageUrl: _qsPageUrl,
  albumId: _qsAlbumId,
);
