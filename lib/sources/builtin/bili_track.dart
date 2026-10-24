/// B 站条目 → 统一的 [SourceTrack] 映射（搜索 / 收藏夹 / 榜单 / UP 投稿共用）。
///
/// 各入口的字段名并不一致（搜索用 `author/mid`，收藏夹用 `upper.mid`，
/// 榜单用 `aid/cid`），但曲目标题、封面、时长与 raw 约定必须一致；映射只写
/// 这一份，后续阶段新增入口只需挑字段传进来。
library;

import 'package:molia/utils/html_unescape/html_unescape.dart';

import '../raw_track.dart';
import '../source_track.dart';

final HtmlUnescape _htmlUnescape = HtmlUnescape();
final RegExp _htmlTag = RegExp(r'<[^>]*>');

/// B 站音轨支持的音质（从高到低；播放地址按音频流 id 选档）。
const List<String> kBiliQualityTypes = ['192k', '128k', '64k'];

/// raw `_types`：给下载 / 音质选择一条稳定的可选音质表。
const Map<String, Map<String, dynamic>> _biliTypes = {
  '192k': <String, dynamic>{},
  '128k': <String, dynamic>{},
  '64k': <String, dynamic>{},
};

/// 标题清洗：搜索接口会用 `<em class="keyword">` 包关键词，必须先剥标签再
/// 反转义，否则标题里的 `&amp;` / `&quot;` 会原样显示。
String biliText(Object? raw) {
  final text = raw?.toString() ?? '';
  if (text.isEmpty) return '';
  return _htmlUnescape.convert(text.replaceAll(_htmlTag, '')).trim();
}

/// 封面归一化：B 站返回 `//i1.hdslb.com/...` 协议相对地址；只接受 http(s)，
/// 其余（空值 / 非法地址）返回 null，交给上层隐藏封面而不是显示坏图。
String? biliCoverUrl(Object? raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final url = text.startsWith('//') ? 'https:$text' : text;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return url;
}

/// 时长解析：B 站同时返回秒数（收藏夹 / 榜单）与 `mm:ss` / `hh:mm:ss`
/// （搜索 / UP 投稿）；解析失败返回 null（列表照常展示，只是没有时长）。
Duration? biliDuration(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final seconds = raw.toInt();
    return seconds > 0 ? Duration(seconds: seconds) : null;
  }
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  final plainSeconds = int.tryParse(text);
  if (plainSeconds != null) {
    return plainSeconds > 0 ? Duration(seconds: plainSeconds) : null;
  }
  final parts = text.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final values = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 0) return null;
    values.add(value);
  }
  final hours = values.length == 3 ? values[0] : 0;
  final minutes = values.length == 3 ? values[1] : values[0];
  final seconds = values.last;
  final total = hours * 3600 + minutes * 60 + seconds;
  return total > 0 ? Duration(seconds: total) : null;
}

/// 搜索条目 → 曲目（`data.result[]`）。
SourceTrack? biliTrackFromSearchItem(dynamic item) {
  if (item is! Map) return null;
  return biliTrackFromItem(item);
}

/// 通用条目 → 曲目。
///
/// 显式参数用于字段名不同的入口（如收藏夹 `id` 是 aid、榜单 `cid` 直接随条目
/// 返回）；缺省时回退条目自身的标准字段。没有 bvid/aid 的条目无法取链，返回
/// null（收藏夹里的番剧 / 课程等非视频条目走这条分支）。
SourceTrack? biliTrackFromItem(
  Map item, {
  String? title,
  String? cover,
  String? author,
  String? authorMid,
  Object? duration,
  Object? aid,
  Object? bvid,
  Object? cid,
}) {
  final upper = item['upper'];
  final upperMap = upper is Map ? upper : const {};

  final titleText = biliText(title ?? item['title']);
  if (titleText.isEmpty) return null;

  final authorText = biliText(_firstText([
    author,
    item['author'],
    item['author_name'],
    item['uname'],
    upperMap['name'],
    upperMap['uname'],
  ]));
  final authorId = _firstText([
    authorMid,
    item['mid'],
    item['author_mid'],
    item['uid'],
    upperMap['mid'],
    upperMap['uid'],
  ]);
  final bvidText = _firstText([bvid, item['bvid']]);
  final aidText = _firstText([aid, item['aid'], item['avid'], item['id']]);
  final cidText = _firstText([cid, item['cid']]);
  if (bvidText.isEmpty && aidText.isEmpty) return null;

  final coverText = biliCoverUrl(_firstText([
    cover,
    item['pic'],
    item['cover'],
    item['img'],
  ]));
  final durationValue =
      biliDuration(duration ?? item['duration'] ?? item['length']);

  final raw = <String, dynamic>{
    ...item,
    'source': 'bili',
    if (bvidText.isNotEmpty) 'bvid': bvidText,
    if (aidText.isNotEmpty) 'aid': aidText,
    if (cidText.isNotEmpty) 'cid': cidText,
    '_types': _biliTypes,
    if (authorText.isNotEmpty)
      kRawArtistsField: [
        {
          'name': authorText,
          if (authorId.isNotEmpty) 'id': authorId,
        },
      ],
  };

  return SourceTrack(
    sourceKey: 'bili',
    origin: 'builtin',
    title: titleText,
    artist: authorText,
    album: '',
    coverUrl: coverText,
    duration: durationValue,
    qualities: [
      for (final type in kBiliQualityTypes) SourceQuality(type: type)
    ],
    raw: raw,
  );
}

/// 取第一个非空文本（数值 id 统一转字符串，raw 侧才能按同一优先级取键）。
String _firstText(List<Object?> values) {
  for (final value in values) {
    if (value == null) continue;
    final text = value is Map ? '' : value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}
