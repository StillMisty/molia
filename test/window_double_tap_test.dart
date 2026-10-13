import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/window/window_chrome.dart';

/// 拖动区双击最大化（`WindowDoubleTapMaximize`）：被动 Listener 实现，
/// 不参与手势竞技场——单击、按钮点击、拖动都不被双击判定拖慢。
void main() {
  testWidgets('双击触发；单击立即生效、慢速双点与拖动都不触发', (tester) async {
    var doubleTaps = 0;
    var childTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: WindowDoubleTapMaximize(
            onDoubleTap: () => doubleTaps++,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => childTaps++,
              child: const SizedBox(width: 320, height: 56),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(WindowDoubleTapMaximize));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);

    // 单击：子点击立即触发（若误用 onDoubleTap，这里会等到 300ms 之后）。
    await gesture.down(center, timeStamp: Duration.zero);
    await gesture.up(timeStamp: const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 16));
    expect(childTaps, 1, reason: '单击被双击判定延迟');
    expect(doubleTaps, 0);

    // 双击：300ms 内两次原地「按下 + 抬起」→ 触发一次。
    await gesture.down(center, timeStamp: const Duration(milliseconds: 100));
    await gesture.up(timeStamp: const Duration(milliseconds: 140));
    await gesture.down(center, timeStamp: const Duration(milliseconds: 250));
    await gesture.up(timeStamp: const Duration(milliseconds: 290));
    await tester.pump();
    expect(doubleTaps, 1);

    // 慢速两次点击（间隔 > 300ms）→ 不触发。
    await gesture.down(center, timeStamp: const Duration(seconds: 2));
    await gesture.up(timeStamp: const Duration(milliseconds: 2020));
    await gesture.down(center, timeStamp: const Duration(seconds: 3));
    await gesture.up(timeStamp: const Duration(milliseconds: 3020));
    await tester.pump();
    expect(doubleTaps, 1);

    // 拖动（抬起点位移 > 12dp）→ 不触发（窗口拖动不是点击）。
    await gesture.down(center, timeStamp: const Duration(seconds: 4));
    await gesture.moveBy(
      const Offset(40, 0),
      timeStamp: const Duration(milliseconds: 4100),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 4200));
    await tester.pump();
    expect(doubleTaps, 1);

    // 拖动之后再快速点击两下仍然有效（拖动只打断当前序列，不残留状态）。
    await gesture.down(center, timeStamp: const Duration(seconds: 5));
    await gesture.up(timeStamp: const Duration(milliseconds: 5020));
    await gesture.down(center, timeStamp: const Duration(milliseconds: 5100));
    await gesture.up(timeStamp: const Duration(milliseconds: 5150));
    await tester.pump();
    expect(doubleTaps, 2);
  });
}
