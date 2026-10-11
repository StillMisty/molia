import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/widgets/lyric_karaoke_text.dart';

/// 逐字歌词渲染：词级颜色随 position 推进（已唱 / 未唱 / 当前词插值）。
void main() {
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

    List<TextSpan> spans() {
      List<TextSpan> flatten(InlineSpan span) {
        if (span is! TextSpan) return const [];
        final children = span.children;
        if (children == null || children.isEmpty) return [span];
        return [for (final child in children) ...flatten(child)];
      }

      for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
        final leaves = flatten(richText.text);
        if (leaves.length == words.length) return leaves;
      }
      fail('未找到逐字歌词 RichText');
    }

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
}
