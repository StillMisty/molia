import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/widgets/lyric_karaoke_text.dart';

/// 逐字歌词测试面：LX `<相对开始ms,时长ms>` 标签解析与按时间戳对齐
/// （数据装配），以及 `KaraokeLyricText` 词级颜色随 position 推进
/// （已唱 / 未唱 / 当前词插值）的渲染。
void main() {
  // 数据装配：parseLxWords / attachWordTimings。
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

  // 渲染：词级颜色随 position 推进（已唱 / 未唱 / 当前词插值）。
  testWidgets('已唱词 / 未唱词 / 当前词插值随进度更新', (tester) async {
    final position =
        ValueNotifier<Duration>(const Duration(milliseconds: 600));
    addTearDown(position.dispose);

    final words = [
      LyricWord(
        start: Duration.zero,
        end: const Duration(milliseconds: 500),
        text: '你',
      ),
      LyricWord(
        start: const Duration(milliseconds: 500),
        end: const Duration(milliseconds: 1000),
        text: '好',
      ),
    ];

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: KaraokeLyricText(
        words: words,
        position: position,
        playedColor: Colors.red,
        unplayedColor: Colors.grey,
      ),
    ));

    List<TextSpan> spans() => _spansOf(tester, words.length);

    // 600ms：第一个词已唱（红）；第二个词进行到 20%（灰→红插值）。
    expect(spans()[0].style!.color, Colors.red);
    expect(
      spans()[1].style!.color,
      Color.lerp(Colors.grey, Colors.red, 0.2),
    );

    // 推进到 1200ms（越过整行）：两个词都变为已唱色。
    position.value = const Duration(milliseconds: 1200);
    await tester.pumpAndSettle();
    expect(spans()[0].style!.color, Colors.red);
    expect(spans()[1].style!.color, Colors.red);

    // 回跳到 0：全部未唱色。
    position.value = Duration.zero;
    await tester.pumpAndSettle();
    expect(spans()[0].style!.color, Colors.grey);
    expect(spans()[1].style!.color, Colors.grey);
  });

  testWidgets('lead：插值目标前移，抵消补间慢一拍', (tester) async {
    final position =
        ValueNotifier<Duration>(const Duration(milliseconds: 600));
    addTearDown(position.dispose);

    final words = [
      LyricWord(
        start: Duration.zero,
        end: const Duration(milliseconds: 500),
        text: '你',
      ),
      LyricWord(
        start: const Duration(milliseconds: 500),
        end: const Duration(milliseconds: 1000),
        text: '好',
      ),
    ];

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: KaraokeLyricText(
        words: words,
        position: position,
        playedColor: Colors.red,
        unplayedColor: Colors.grey,
        lead: const Duration(milliseconds: 200),
      ),
    ));

    // 600 + 200 = 800ms：第二个词进行到 60%（不提前时是 20%）。
    expect(
      _spansOf(tester, words.length)[1].style!.color,
      Color.lerp(Colors.grey, Colors.red, 0.6),
    );

    // 越过整行：目标同样前移（1200 + 200 = 1400ms）。
    position.value = const Duration(milliseconds: 1200);
    await tester.pumpAndSettle();
    expect(_spansOf(tester, words.length)[0].style!.color, Colors.red);
    expect(_spansOf(tester, words.length)[1].style!.color, Colors.red);

    // 回跳：整条时间轴平移，不累积 —— 0 + 200ms 时首词进行到 40%。
    position.value = Duration.zero;
    await tester.pumpAndSettle();
    expect(
      _spansOf(tester, words.length)[0].style!.color,
      Color.lerp(Colors.grey, Colors.red, 0.4),
    );
    expect(_spansOf(tester, words.length)[1].style!.color, Colors.grey);
  });
}

/// 逐字歌词渲染出的词级 [TextSpan]（按叶子数匹配词数挑选）。
List<TextSpan> _spansOf(WidgetTester tester, int wordCount) {
  List<TextSpan> flatten(InlineSpan span) {
    if (span is! TextSpan) return const [];
    final children = span.children;
    if (children == null || children.isEmpty) return [span];
    return [for (final child in children) ...flatten(child)];
  }

  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    final leaves = flatten(richText.text);
    if (leaves.length == wordCount) return leaves;
  }
  fail('未找到逐字歌词 RichText');
}
