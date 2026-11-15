import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/window_controls.dart';

/// 最大化键贴靠区：矩形随布局更新、同一矩形不重复上报、卸载时清空。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('上报按钮全局矩形，尺寸变化后更新，卸载时清空', (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Rect? last;
    var reports = 0;

    Widget host({ValueChanged<Rect?>? onChanged}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topRight,
        child: MaximizeButtonSnapRegion(
          onChanged:
              onChanged ??
              (rect) {
                last = rect;
                reports++;
              },
          child: const SizedBox(width: 48, height: 48),
        ),
      ),
    );

    await tester.pumpWidget(host());
    await tester.pump();

    expect(
      last,
      const Rect.fromLTWH(352, 0, 48, 48),
      reason: '矩形必须是按钮在窗口内容区里的全局位置',
    );
    expect(reports, 1);

    // 布局没变时不重复上报（FFI 不做每帧调用）。
    await tester.pump();
    expect(reports, 1);

    // 窗口变宽：按钮跟着右移，上报更新后的矩形。
    tester.view.physicalSize = const Size(500, 200);
    await tester.pump();
    await tester.pump();
    expect(last, const Rect.fromLTWH(452, 0, 48, 48));
    expect(reports, 2);

    // 卸载（如收进托盘后的休眠树）时清空原生命中区。
    await tester.pumpWidget(const SizedBox.shrink());
    expect(last, isNull);
  });
}
