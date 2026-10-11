import 'lyric_provider.dart';

/// 歌词搜索结果相似度匹配（移植 lx-music-mobile `musicSdk/index.js`
/// `findMusic` 的核心判定）。
///
/// 目标：在名字搜索的候选里挑出「同一首歌」，避免取到 live / 翻唱 / 伴奏
/// 等版本差异的歌词。判定维度：时长（±5s）、归一化歌名、歌手（含多歌手
/// 排序）、专辑、版本词（live/remix/伴奏…）。
///
/// 与 LX 的差异：LX 在无候选命中时放弃该来源；这里回退到首个候选
/// （保持旧行为的下限——至少不比现状差，命中时更准）。
SongMatch? pickBestSongMatch(
  List<SongMatch> candidates, {
  required String title,
  required String artist,
  String? album,
  Duration? duration,
}) {
  if (candidates.isEmpty) return null;
  if (candidates.length == 1) return candidates.first;

  final targetName = _filter(title).toLowerCase();
  final targetSinger = _filter(_sortSingle(artist)).toLowerCase();
  final targetAlbum = _filter(album ?? '').toLowerCase();
  final targetInterval = duration?.inSeconds ?? 0;

  bool equalsInterval(SongMatch match) {
    final candidate = match.duration?.inSeconds ?? 0;
    if (targetInterval == 0 || candidate == 0) return true;
    return (targetInterval - candidate).abs() <= 5;
  }

  bool includesName(SongMatch match) {
    final name = _filter(match.title).toLowerCase();
    if (targetName.isEmpty || name.isEmpty) return true;
    final includes = targetName.contains(name) || name.contains(targetName);
    return includes && _sameVersionChars(name, targetName);
  }

  bool includesSinger(SongMatch match) {
    final singer = _filter(_sortSingle(match.artist)).toLowerCase();
    if (targetSinger.isEmpty || singer.isEmpty) return true;
    return targetSinger.contains(singer) || singer.contains(targetSinger);
  }

  bool equalsAlbum(SongMatch match) {
    final value = _filter(match.album ?? '').toLowerCase();
    if (targetAlbum.isEmpty || value.isEmpty) return true;
    return value == targetAlbum;
  }

  final byInterval = candidates.where(equalsInterval).toList();
  if (byInterval.isEmpty) return candidates.first;

  // 1) 同名 + 歌手包含
  for (final match in byInterval) {
    if (_filter(match.title).toLowerCase() == targetName &&
        includesSinger(match)) {
      return match;
    }
  }
  // 2) 同歌手 + 歌名包含
  for (final match in byInterval) {
    final singer = _filter(_sortSingle(match.artist)).toLowerCase();
    if (singer == targetSinger && includesName(match)) {
      return match;
    }
  }
  // 3) 同专辑 + 歌手包含 + 歌名包含
  for (final match in byInterval) {
    if (equalsAlbum(match) && includesSinger(match) && includesName(match)) {
      return match;
    }
  }
  return candidates.first;
}

/// 多歌手串排序（`、`/`&`/`;`/`/`/`,`/`|` 分隔，排序后比较，与 LX 一致）。
String _sortSingle(String singer) {
  final regexp = RegExp(r'、|&|;|；|/|,|，|\|');
  if (!regexp.hasMatch(singer)) return singer;
  final parts = singer.split(regexp)..sort();
  return parts.join('、');
}

/// 归一化：去空白 / 引号 / 常见标点（LX `filterStr`）。
String _filter(String value) => value.replaceAll(
      RegExp(r'''[\s'".,，&、()（）`~\-<>|/\[\]!！]'''),
      '',
    );

/// 版本词一致性：目标与候选必须「同时包含或同时不包含」某个版本词。
bool _sameVersionChars(String candidate, String target) {
  for (final char in versionChars) {
    if (candidate.contains(char) != target.contains(char)) return false;
  }
  return true;
}

/// 版本词表（lx-music-mobile `versionChars.ts` 原样：伴奏/现场/翻唱/混音/
/// 原声/Demo/变速/特殊乐器版）。
const List<String> versionChars = [
  'instrumental', 'inst', 'karaoke', 'backing track', 'minus one',
  'minus vocal', 'no vocal', 'off vocal', 'vocal removed', '伴奏', '伴唱',
  '卡拉ok', '纯音乐', '无人声', '去人声', '消音', 'オフボーカル', 'インスト',
  '반주', '노래방', 'live', 'concert', 'tour', 'festival', 'stage', 'session',
  '现场', '演唱会', '巡演', '音乐会', 'ライブ', '공연', '라이브', 'cover',
  'tribute', 'rendition', 'remake', '翻唱', '致敬', '改编', 'カバー', '커버',
  'remix', 'mix', 'club', 'dance', 'extended', 'house', 'edm', 'dj', 'dub',
  'trap', '混音', '重混', '电音', 'リミックス', '리믹스', 'acoustic',
  'unplugged', 'stripped', '原声', '不插电', 'アコースティック', '어쿠스틱',
  'demo', '小样', '试听', 'デモ', '데모', 'slowed', 'slowed reverb',
  'sped up', 'speed up', 'nightcore', '慢速', '加速', '变速', 'ナイトコア',
  'piano', 'guitar', 'orchestra', 'symphony', 'violin', '钢琴', '吉他',
  '管弦乐', '小提琴', 'ピアノ', 'ギター', '피아노', '기타',
];
