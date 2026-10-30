/// 内置平台响应内嵌封面 URL 的提取与规整。
///
/// 酷狗 / 酷我各入口（搜索、榜单、歌单、专辑、歌手）给封面的字段名不一致，
/// 尺寸写法也不同（相对路径、`120/...` 尺寸段、`{size}` 占位符）。
/// 列表行只消费 `SourceTrack.coverUrl`，不会逐行再发网络请求，因此响应里
/// 已经带了的封面必须在这里解析出来；否则搜索 / 发现页只有占位图。
library;

/// 酷狗封面尺寸：`stdmusic` 的 `{size}` 占位换成列表可用的清晰档。
const String _kugouCoverSize = '480';

/// 酷我封面尺寸：相对路径与 `star/albumcover/<size>/` 统一到 500。
const String _kuwoCoverSize = '500';

/// 相对路径首段可能是尺寸档（`120/...`）；只剥离已知档位，避免把真正的
/// 首段路径（如 `3/8/xxx.jpg`）误当尺寸删掉。
const Set<String> _kuwoCoverSizes = {
  '90',
  '100',
  '120',
  '150',
  '200',
  '240',
  '300',
  '320',
  '400',
  '480',
  '500',
  '600',
  '800',
  '1000',
};

/// 从酷狗响应条目取封面。
///
/// 搜索用 `Image`，榜单用 `album_sizable_cover`，歌单详情在
/// `album_info.sizable_cover`，专辑 / 歌手信息用 `imgurl`；`trans_param` 里
/// 的 `union_cover` 是同一张图的兜底字段。
String? kgCoverUrlOf(dynamic raw) {
  if (raw is! Map) return null;
  final candidates = <Object?>[
    raw['Image'],
    raw['album_sizable_cover'],
    raw['sizable_cover'],
    raw['imgurl'],
    raw['img'],
    if (raw['trans_param'] is Map) (raw['trans_param'] as Map)['union_cover'],
  ];
  for (final candidate in candidates) {
    final url = candidate?.toString().trim() ?? '';
    if (url.isEmpty) continue;
    return url.replaceAll('{size}', _kugouCoverSize);
  }
  return null;
}

/// 从酷我响应条目取封面。
///
/// 搜索 / 榜单用 `web_albumpic_short`（相对路径，首段是尺寸档），歌单详情用
/// `albumpic`，专辑歌曲用 `pic120`，歌手歌曲用 `pic300`；`img` / `hts_img`
/// 作为最后兜底。结果统一到 500 尺寸，避免列表用小图糊成色块。
String? kwCoverUrlOf(dynamic raw) {
  if (raw is! Map) return null;
  final short = _nonEmpty(raw['web_albumpic_short']);
  if (short != null) {
    final url = _kuwoCoverUrl(short);
    if (url != null) return url;
  }
  for (final key in const ['albumpic', 'pic120', 'pic300', 'img', 'hts_img']) {
    final url = _kuwoCoverUrl(_nonEmpty(raw[key]));
    if (url != null) return url;
  }
  return null;
}

String? _kuwoCoverUrl(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  if (text.startsWith('//')) return _withKuwoSize('https:$text');
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return _withKuwoSize(text);
  }
  // 相对路径：`120/s4s94/93/xxx.jpg` 或直接 `s4s94/93/xxx.jpg`。
  final segments = text.replaceFirst(RegExp(r'^/+'), '').split('/');
  if (segments.length > 1 && _kuwoCoverSizes.contains(segments.first)) {
    segments.removeAt(0);
  }
  final path = segments.join('/');
  if (path.isEmpty) return null;
  return 'https://img1.kuwo.cn/star/albumcover/$_kuwoCoverSize/$path';
}

/// 把 `star/albumcover/<n>/...` 的尺寸段换成 500。
///
/// 酷我多个接口返回的封面是同一路径的不同尺寸（搜索 120、专辑 120/240），
/// 只改尺寸段就能拿到 500 档，不需要另发取图请求。
String _withKuwoSize(String url) => url.replaceFirstMapped(
  RegExp(r'(star/albumcover/)\d+/'),
  (match) => '${match[1]}$_kuwoCoverSize/',
);

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
