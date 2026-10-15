/// 平台歌手列表解析的共享工具（歌手搜索 / 榜单 / 专辑 / 歌词检索共用）。
///
/// 各平台条目形状基本一致（`name` + `id` 字段），差异只在字段名个别大小写、
/// 以及「名字串 + 首位 id」（榜单 / 歌单条目）这一形态——两种形态各一个入口：
/// [artistRefsOfItems] 与 [artistRefsOfNameAndId]。
library;

import '../raw_track.dart';
import 'crypto_utils.dart';

/// `[{name, id}]` 形态 → 歌手引用（名字解码；空名字忽略，空 id 保留名字）。
List<SourceArtistRef> artistRefsOfItems(dynamic items) {
  if (items is! List) return const [];
  final refs = <SourceArtistRef>[];
  for (final item in items) {
    if (item is! Map) continue;
    final name = decodeName(item['name']?.toString());
    if (name.isEmpty) continue;
    final id = item['id']?.toString();
    refs.add(SourceArtistRef(name: name, id: (id?.isEmpty ?? true) ? null : id));
  }
  return refs;
}

/// 「名字串 + 首位 id」形态（kw 榜单 / 歌单条目）→ 歌手引用。
///
/// [artist] 已按平台分隔符拼接（`、`）；[id] 只对应首位歌手，其余保留名字。
List<SourceArtistRef> artistRefsOfNameAndId(String artist, String id) {
  final names = <String>[
    for (final name in artist.split('、'))
      if (name.trim().isNotEmpty) name.trim(),
  ];
  return [
    for (var index = 0; index < names.length; index++)
      SourceArtistRef(
        name: names[index],
        id: index == 0 && id.isNotEmpty ? id : null,
      ),
  ];
}
