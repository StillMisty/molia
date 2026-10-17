import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/discover_leaderboards_tab.dart';

/// chip 云两行装箱的边界（纯函数，不建树）：只算宽度，可见前缀长度是契约。
void main() {
  const gap = 8.0;

  int visible(
    List<double> widths, {
    double available = 300,
    int maxRows = 2,
  }) =>
      chipCloudVisibleCount(
        widths: widths,
        availableWidth: available,
        gap: gap,
        maxRows: maxRows,
      );

  test('两行内的 chip 全部保留', () {
    expect(visible(const [100, 100, 100]), 3);
  });

  test('行宽精确到不越界：一行只放两个 100（第三个要 316）', () {
    expect(visible(const [100, 100, 100], maxRows: 1), 2);
  });

  test('超过两行的只保留前缀', () {
    expect(visible(List.filled(10, 90)), 6);
    expect(visible(List.filled(10, 90), maxRows: 1), 3);
  });

  test('行内 gap 计入：三个 150（308 > 300）只能放下两个', () {
    expect(visible(const [150, 150, 150]), 2);
  });

  test('单个 chip 宽过一行：按可用宽封顶占一行，而不是溢出', () {
    expect(visible(const [400, 90], maxRows: 1), 1);
    expect(visible(const [400, 90]), 2);
  });

  test('空列表返回 0', () {
    expect(visible(const []), 0);
  });
}
