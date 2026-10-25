import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/lyric_line.dart';

/// 歌词模型（解析 / 未同步 / 当前行查找）的单一测试面。
void main() {
  group('parseLyrics', () {
    test('解析 2/3 位毫秒并解码 HTML 实体', () {
      final lines = parseLyrics(
        '[00:01.50]第一行 &amp; 二\n'
        '[00:02.123]&lt;三&gt;\n'
        '[00:03]四\n',
      );
      expect(lines, hasLength(3));
      expect(
        lines[0].timestamp,
        const Duration(seconds: 1, milliseconds: 500),
      );
      expect(lines[0].text, '第一行 & 二');
      expect(
        lines[1].timestamp,
        const Duration(seconds: 2, milliseconds: 123),
      );
      expect(lines[1].text, '<三>');
      expect(lines[2].timestamp, const Duration(seconds: 3));
      expect(lines[2].text, '四');
    });

    test('忽略无时间标签 / 空文本行，并按时间戳排序', () {
      final lines = parseLyrics(
        '前置说明\n'
        '[00:05.00]后\n'
        '[00:01.00]先\n'
        '[00:02.00]\n',
      );
      expect(lines.map((line) => line.text).toList(), ['先', '后']);
    });

    test('空输入返回空列表', () {
      expect(parseLyrics(''), isEmpty);
    });

    test('统一时间契约：1 位分钟 / 冒号毫秒 / 行内多标签', () {
      expect(hasLyricTimestamps('[1:02.34]短分钟'), isTrue);
      expect(hasLyricTimestamps('没有时间标签'), isFalse);

      final lines = parseLyrics(
        '[1:02.34]短分钟\n'
        '[00:01][00:05]重复轴\n',
      );
      expect(lines, hasLength(2));
      // 解析后按时间戳排序：1s 的「重复轴」在前，62.34s 的「短分钟」在后。
      expect(lines[0].timestamp, const Duration(seconds: 1));
      expect(lines[0].text, '重复轴');
      expect(
        lines[1].timestamp,
        const Duration(minutes: 1, seconds: 2, milliseconds: 340),
      );
      expect(lines[1].text, '短分钟');
    });
  });

  group('buildUnsyncedLyrics', () {
    test('去空行并给伪时间戳', () {
      final lines = buildUnsyncedLyrics('  a\n\n b \n');
      expect(lines, hasLength(2));
      expect(lines[0].text, 'a');
      expect(lines[0].timestamp, Duration.zero);
      expect(lines[1].text, 'b');
      expect(lines[1].timestamp, const Duration(milliseconds: 1));
    });
  });

  group('lyricLineIndexAt', () {
    const lines = [
      LyricLine(Duration(seconds: 1), 'a'),
      LyricLine(Duration(seconds: 3), 'b'),
      LyricLine(Duration(seconds: 5), 'c'),
    ];

    test('空列表 / 早于首行返回 -1', () {
      expect(lyricLineIndexAt(const <LyricLine>[], Duration.zero), -1);
      expect(lyricLineIndexAt(lines, Duration.zero), -1);
    });

    test('命中区间与边界', () {
      expect(lyricLineIndexAt(lines, const Duration(seconds: 1)), 0);
      expect(lyricLineIndexAt(lines, const Duration(seconds: 2)), 0);
      expect(lyricLineIndexAt(lines, const Duration(seconds: 3)), 1);
      expect(lyricLineIndexAt(lines, const Duration(seconds: 4)), 1);
      expect(lyricLineIndexAt(lines, const Duration(seconds: 5)), 2);
      expect(lyricLineIndexAt(lines, const Duration(seconds: 99)), 2);
    });
  });
}
