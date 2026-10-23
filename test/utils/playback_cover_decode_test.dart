import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/utils/playback_cover_decode.dart';

void main() {
  testWidgets('桌面窗口按 600 逻辑像素上限 × DPR 解码', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(
        size: Size(1440, 900),
        devicePixelRatio: 1.5,
      ),
      child: SizedBox(),
    ));
    final context = tester.element(find.byType(SizedBox));
    expect(playbackCoverDecodeEdge(context), 900);
  });

  testWidgets('窄屏手机按屏幕短边 × DPR，不放大到 600', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(
        size: Size(360, 800),
        devicePixelRatio: 3,
      ),
      child: SizedBox(),
    ));
    final context = tester.element(find.byType(SizedBox));
    expect(playbackCoverDecodeEdge(context), 1080);
  });
}
