import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/song_match.dart';

/// 共享歌曲匹配（LX findMusic 判定）：严格 / 非严格两种消费面。
void main() {
  SongMatchInfo info(
    String title, {
    String artist = '周杰伦',
    String? album,
    int? seconds,
  }) =>
      SongMatchInfo(
        title: title,
        artist: artist,
        album: album,
        duration: seconds == null ? null : Duration(seconds: seconds),
      );

  test('严格模式：同名 + 歌手包含（阶梯 1）', () {
    final best = pickBestSongMatchBy(
      [
        info('完全不同的歌', artist: '别人', seconds: 10),
        info('晴天', artist: '周杰伦', seconds: 269),
      ],
      target: info('晴天', seconds: 269),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(best?.title, '晴天');
  });

  test('严格模式：同歌手 + 歌名包含（阶梯 2）', () {
    final best = pickBestSongMatchBy(
      [
        info('完全不同的歌', artist: '别人', seconds: 269),
        info('晴天（2023 重制）', artist: '周杰伦', seconds: 269),
      ],
      target: info('晴天', seconds: 269),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(best?.title, '晴天（2023 重制）', reason: '歌名包含且无版本词差异');
  });

  test('严格模式：全部不匹配 → null；非严格 → 首个候选', () {
    final candidates = [
      info('完全不同的歌', artist: '别人', seconds: 10),
      info('另一首', artist: '别人', seconds: 20),
    ];
    expect(
      pickBestSongMatchBy(
        candidates,
        target: info('晴天', seconds: 269),
        info: (candidate) => candidate,
        requireStrictMatch: true,
      ),
      isNull,
    );
    expect(
      pickBestSongMatchBy(
        candidates,
        target: info('晴天', seconds: 269),
        info: (candidate) => candidate,
        requireStrictMatch: false,
      )?.title,
      '完全不同的歌',
    );
  });

  test('时长 ±5s 过滤；任一侧未知视为通过', () {
    final best = pickBestSongMatchBy(
      [info('晴天', seconds: 100), info('晴天', seconds: 269)],
      target: info('晴天', seconds: 269),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(best?.duration, const Duration(seconds: 269));

    final unknown = pickBestSongMatchBy(
      [info('晴天', seconds: 100)],
      target: info('晴天'),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(unknown?.title, '晴天', reason: '目标时长未知：不按时长过滤');
  });

  test('版本词一致性：live / 伴奏 与目标不一致则排除', () {
    final best = pickBestSongMatchBy(
      [
        info('晴天 (Live)', seconds: 269),
        info('晴天 伴奏', seconds: 269),
        info('晴天', seconds: 269),
      ],
      target: info('晴天', seconds: 269),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(best?.title, '晴天');
  });

  test('多歌手排序后包含匹配', () {
    final best = pickBestSongMatchBy(
      [info('以父之名', artist: '周杰伦、方文山', seconds: 300)],
      target: info('以父之名', artist: '方文山、周杰伦', seconds: 300),
      info: (candidate) => candidate,
      requireStrictMatch: true,
    );
    expect(best?.title, '以父之名');
  });

  test('空候选返回 null', () {
    expect(
      pickBestSongMatchBy<SongMatchInfo>(
        const [],
        target: info('晴天'),
        info: (candidate) => candidate,
        requireStrictMatch: false,
      ),
      isNull,
    );
  });

  test('helpers：归一化 / 多歌手排序 / 时长近似', () {
    expect(normalizeSongText("My Song (Live)!"), 'MySongLive');
    expect(sortSingerNames('B&A'), 'A、B');
    expect(sortSingerNames('A/B/C'), 'A、B、C');
    expect(similarDuration(const Duration(seconds: 200),
        const Duration(seconds: 205)), isTrue);
    expect(similarDuration(const Duration(seconds: 200),
        const Duration(seconds: 206)), isFalse);
    expect(similarDuration(null, const Duration(seconds: 206)), isTrue);
  });
}
