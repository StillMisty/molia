/// 歌曲相似匹配（LX `findMusic` 核心判定的**唯一实现**）。
///
/// 两个消费面：
/// - 歌词搜索回退（`lyrics/lyrics_match.dart`）：**非严格**，无命中回退首个
///   候选，保证至少不比第一个候选差；
/// - 自动换源（`source_swap/auto_source_swap_service.dart`）：**严格**，
///   无命中返回 null —— 宁可不换，也不换错版本。
///
/// 判定维度：时长（±5s；任一侧未知视为通过）、归一化歌名、歌手（多歌手
/// 排序后包含）、专辑、版本词（live/remix/伴奏…必须「同时包含或同时不含」）。
library;

/// 匹配用的最小曲目元数据（领域 Track / 歌词候选各自适配后进入）。
class SongMatchInfo {
  const SongMatchInfo({
    required this.title,
    required this.artist,
    this.album,
    this.duration,
  });

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
}

/// 在候选中挑出「同一首歌」：[requireStrictMatch] 为 true 时无命中返回
/// null（自动换源）；为 false 时回退首个候选（歌词搜索下限）。
///
/// 优先级阶梯（与 LX `findMusic` 一致，先过滤时长再逐阶取首个命中）：
/// 1) 同名 + 歌手包含；2) 同歌手 + 歌名包含；3) 同专辑 + 歌名包含 + 歌手包含。
T? pickBestSongMatchBy<T>(
  List<T> candidates, {
  required SongMatchInfo target,
  required SongMatchInfo Function(T candidate) info,
  required bool requireStrictMatch,
}) {
  if (candidates.isEmpty) return null;
  // 非严格模式单候选直接采用（歌词搜索的「至少不比首个候选差」）；
  // 严格模式必须继续走完整校验——否则唯一一条搜索结果即使是另一首歌
  // 也会被自动换源 / 跨渠道补封面采用。
  if (candidates.length == 1 && !requireStrictMatch) return candidates.first;

  final targetName = normalizeSongText(target.title).toLowerCase();
  final targetSinger =
      normalizeSongText(sortSingerNames(target.artist)).toLowerCase();
  final targetAlbum = normalizeSongText(target.album ?? '').toLowerCase();

  bool equalsInterval(T candidate) => similarDuration(
        info(candidate).duration,
        target.duration,
      );

  bool includesName(T candidate) {
    final name = normalizeSongText(info(candidate).title).toLowerCase();
    if (targetName.isEmpty || name.isEmpty) return true;
    final includes = targetName.contains(name) || name.contains(targetName);
    return includes && sameVersionChars(name, targetName);
  }

  bool includesSinger(T candidate) {
    final singer =
        normalizeSongText(sortSingerNames(info(candidate).artist))
            .toLowerCase();
    if (targetSinger.isEmpty || singer.isEmpty) return true;
    return targetSinger.contains(singer) || singer.contains(targetSinger);
  }

  bool equalsAlbum(T candidate) {
    final value = normalizeSongText(info(candidate).album ?? '').toLowerCase();
    if (targetAlbum.isEmpty || value.isEmpty) return true;
    return value == targetAlbum;
  }

  final byInterval = [for (final c in candidates) if (equalsInterval(c)) c];
  if (byInterval.isEmpty) {
    return requireStrictMatch ? null : candidates.first;
  }

  // 1) 同名 + 歌手包含
  for (final candidate in byInterval) {
    if (normalizeSongText(info(candidate).title).toLowerCase() ==
            targetName &&
        includesSinger(candidate)) {
      return candidate;
    }
  }
  // 2) 同歌手 + 歌名包含
  for (final candidate in byInterval) {
    final singer =
        normalizeSongText(sortSingerNames(info(candidate).artist))
            .toLowerCase();
    if (singer == targetSinger && includesName(candidate)) {
      return candidate;
    }
  }
  // 3) 同专辑 + 歌手包含 + 歌名包含
  for (final candidate in byInterval) {
    if (equalsAlbum(candidate) &&
        includesSinger(candidate) &&
        includesName(candidate)) {
      return candidate;
    }
  }
  return requireStrictMatch ? null : candidates.first;
}

/// 多歌手串排序（`、`/`&`/`;`/`；`/`/`/`,`/`，`/`|` 分隔，排序后比较，与 LX 一致）。
String sortSingerNames(String singer) {
  final regexp = RegExp(r'、|&|;|；|/|,|，|\|');
  if (!regexp.hasMatch(singer)) return singer;
  final parts = singer.split(regexp)..sort();
  return parts.join('、');
}

/// 归一化：去空白 / 引号 / 常见标点（LX `filterStr`）。
String normalizeSongText(String value) => value.replaceAll(
      RegExp(r'''[\s'".,，&、()（）`~\-<>|/\[\]!！]'''),
      '',
    );

/// 版本词一致性：目标与候选必须「同时包含或同时不包含」某个版本词。
bool sameVersionChars(String candidate, String target) {
  for (final char in versionChars) {
    if (candidate.contains(char) != target.contains(char)) return false;
  }
  return true;
}

/// 时长近似：±[toleranceSeconds] 秒；任一侧未知（null / 0）视为通过。
bool similarDuration(
  Duration? candidate,
  Duration? target, {
  int toleranceSeconds = 5,
}) {
  final a = candidate?.inSeconds ?? 0;
  final b = target?.inSeconds ?? 0;
  if (a == 0 || b == 0) return true;
  return (a - b).abs() <= toleranceSeconds;
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
