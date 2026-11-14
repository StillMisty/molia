/// 哔哩哔哩渠道自述：全站视频搜索 / 原生取链 / CC·AI 字幕取词 / 封面 /
/// 评论 / UP 主 / 发现。
///
/// 与音乐平台的能力差异写在 `bili_*` 各实现里：没有专辑、没有按歌词搜歌
/// （这里是视频站，搜索结果不是「同一首歌」）。
library;

import '../bili_artist.dart';
import '../bili_comment.dart';
import '../bili_discover.dart';
import '../bili_play.dart';
import '../bili_search.dart';
import '../builtin_lyric_adapters.dart';
import '../builtin_pic_adapters.dart';
import 'song_channel.dart';

String? _biliPageUrl(Map<String, dynamic> raw) {
  final bvid = raw['bvid']?.toString() ?? '';
  if (bvid.isNotEmpty) return 'https://www.bilibili.com/video/$bvid';
  final aid = raw['aid']?.toString() ?? '';
  return aid.isEmpty ? null : 'https://www.bilibili.com/video/av$aid';
}

const SongChannel biliChannel = SongChannel(
  key: 'bili',
  displayName: '哔哩哔哩',
  search: BiliSearch.searchWithMeta,
  resolve: BiliPlay.resolve,
  lyric: biliBuiltinLyric,
  pic: biliBuiltinPic,
  comments: SongChannelComments(
    // 评论接口的 oid 只用 aid；部分 raw 只带通用 id 字段时兜底。
    rawIdKeys: ['aid', 'id'],
    fetch: BiliComment.fetch,
  ),
  artist: SongChannelArtist(
    search: BiliSearch.searchUsers,
    fetch: BiliArtist.fetch,
  ),
  discover: BiliDiscoverSource(),
  pageUrl: _biliPageUrl,
);
