import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/lyric_line.dart';

/// 逐字歌词：LX `<相对开始ms,时长ms>` 解析与按时间戳对齐。
void main() {
  test('parseLxWords：相对时间换算为绝对时间', () {
    final words = parseLxWords(
      '<0,500>Hello <500,300>world',
      const Duration(seconds: 10),
    );
    expect(words, isNotNull);
    expect(words!, hasLength(2));
    expect(words[0].text, 'Hello ');
    expect(words[0].start, const Duration(seconds: 10));
    expect(words[0].end, const Duration(seconds: 10, milliseconds: 500));
    expect(words[1].text, 'world');
    expect(words[1].start, const Duration(seconds: 10, milliseconds: 500));
    expect(words[1].end, const Duration(seconds: 10, milliseconds: 800));
  });

  test('parseLxWords：无标签 / 空文本返回 null', () {
    expect(parseLxWords('纯文本', Duration.zero), isNull);
    expect(parseLxWords('<0,100>', Duration.zero), isNull);
  });

  test('attachWordTimings：按行时间戳对齐，缺失行保持无词', () {
    final lines = parseLyrics('[00:10.00]Hello world\n[00:12.00]无逐字行');
    final attached = attachWordTimings(
      lines,
      '[00:10.00]<0,500>Hello <500,300>world\n[00:99.00]<0,1>x',
    );
    expect(attached, hasLength(2));
    expect(attached[0].words, hasLength(2));
    expect(attached[0].words![0].text, 'Hello ');
    expect(attached[1].words, isNull);
  });

  test('attachWordTimings：lxlyric 为空时原样返回', () {
    final lines = parseLyrics('[00:10.00]Hello');
    expect(identical(attachWordTimings(lines, null), lines), isTrue);
    expect(identical(attachWordTimings(lines, ''), lines), isTrue);
  });

  test('词时间与行时间一致性：拼接文本等于主行文本', () {
    final lines = parseLyrics('[00:10.00]你好世界');
    final attached = attachWordTimings(
      lines,
      '[00:10.00]<0,200>你好<200,300>世界',
    );
    final joined = attached[0].words!.map((word) => word.text).join();
    expect(joined, attached[0].text);
  });
}
