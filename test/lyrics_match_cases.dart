import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_match.dart';

/// 歌词搜索相似度匹配（移植 LX findMusic 核心判定）单测。
void main() {
  SongMatch match(
    String title, {
    String artist = '周杰伦',
    String? album,
    int? seconds,
    String id = 'id',
  }) =>
      SongMatch(
        songId: id,
        title: title,
        artist: artist,
        album: album,
        duration: seconds == null ? null : Duration(seconds: seconds),
      );

  test('时长 ±5s 内优先；同名同歌手胜出', () {
    final best = pickBestSongMatch(
      [
        match('晴天', seconds: 100),
        match('晴天', seconds: 269, id: 'correct'),
      ],
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(seconds: 269),
    );
    expect(best?.songId, 'correct');
  });

  test('版本词不一致的候选被排除（live / 伴奏）', () {
    final best = pickBestSongMatch(
      [
        match('晴天 (Live)', seconds: 269, id: 'live'),
        match('晴天', seconds: 269, id: 'studio'),
      ],
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(seconds: 269),
    );
    expect(best?.songId, 'studio');
  });

  test('时长差异 >5s 的候选不参与匹配', () {
    final best = pickBestSongMatch(
      [
        match('晴天', seconds: 100, id: 'short'),
        match('晴天', seconds: 269, id: 'correct'),
      ],
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(seconds: 269),
    );
    expect(best?.songId, 'correct');
  });

  test('歌手包含匹配（多歌手排序后比较）', () {
    final best = pickBestSongMatch(
      [
        match('以父之名', artist: '其他歌手', seconds: 300, id: 'other'),
        match('以父之名', artist: '周杰伦、方文山', seconds: 300, id: 'multi'),
      ],
      title: '以父之名',
      artist: '方文山、周杰伦',
      duration: const Duration(seconds: 300),
    );
    expect(best?.songId, 'multi');
  });

  test('全部不匹配时回退首个候选（保持旧行为下限）', () {
    final best = pickBestSongMatch(
      [
        match('完全不同的歌', artist: '别人', seconds: 10, id: 'first'),
        match('另一首', artist: '别人', seconds: 20, id: 'second'),
      ],
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(seconds: 269),
    );
    expect(best?.songId, 'first');
  });

  test('空候选返回 null；单候选直接返回', () {
    expect(pickBestSongMatch(const [], title: 'a', artist: 'b'), isNull);
    final only = match('晴天');
    expect(
      pickBestSongMatch([only], title: '晴天', artist: '周杰伦')?.songId,
      'id',
    );
  });
}
