import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/lyric_line.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';

/// 歌词投送快照：集合字段只读，且不与歌词模型 / 调用方列表共享引用。
void main() {
  LyricsPresentation presentation({
    required List<String> extended,
    required List<String> upcoming,
    List<LyricWord>? words,
  }) => LyricsPresentation(
    trackId: 'kw:1',
    title: '歌名',
    line: '当前行',
    extended: extended,
    upcoming: upcoming,
    words: words,
    isPlaying: true,
    hasLyrics: true,
  );

  test('LyricsPresentation 冻结扩展行 / 后续行 / 逐字轴', () {
    final extended = ['翻译'];
    final upcoming = ['下一句'];
    final words = [
      const LyricWord(
        start: Duration.zero,
        end: Duration(seconds: 1),
        text: '逐字',
      ),
    ];
    final value = presentation(
      extended: extended,
      upcoming: upcoming,
      words: words,
    );

    expect(() => value.extended.add('新翻译'), throwsUnsupportedError);
    expect(() => value.upcoming.add('再下一句'), throwsUnsupportedError);
    expect(() => value.words!.add(words.first), throwsUnsupportedError);

    extended.add('新翻译');
    upcoming.clear();
    words.clear();
    expect(value.extended, ['翻译']);
    expect(value.upcoming, ['下一句']);
    expect(value.words, hasLength(1));
  });

  test('LyricsPresentation 无逐字轴时保持 null', () {
    final value = presentation(extended: const [], upcoming: const []);
    expect(value.words, isNull);
  });
}
