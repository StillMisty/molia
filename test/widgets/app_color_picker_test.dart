import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/app_color_picker.dart';

/// 任意颜色选择器的 Hex 解析契约（6 位保留透明度 / 8 位 AARRGGBB）。
void main() {
  test('#RRGGBB：保留传入透明度', () {
    expect(
      parseColorHex('#FF00FF', keepAlpha: 0.5),
      (0x80 << 24) | 0xFF00FF,
    );
    expect(parseColorHex('ff00ff', keepAlpha: 1), 0xFFFF00FF);
  });

  test('#AARRGGBB：使用输入中的透明度', () {
    expect(parseColorHex('#80FF00FF', keepAlpha: 1), 0x80FF00FF);
  });

  test('三位缩写展开', () {
    expect(parseColorHex('#f0f', keepAlpha: 1), 0xFFFF00FF);
  });

  test('非法输入返回 null', () {
    expect(parseColorHex('', keepAlpha: 1), isNull);
    expect(parseColorHex('#12345', keepAlpha: 1), isNull);
    expect(parseColorHex('zzzzzz', keepAlpha: 1), isNull);
  });
}
