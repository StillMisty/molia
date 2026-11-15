import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/window_bounds.dart';

/// 窗口几何恢复的纯逻辑：可见交集、最小尺寸夹取、离屏回退。
void main() {
  group('可见交集', () {
    test('两个方向都至少 100 才算可见', () {
      const area = Rect.fromLTWH(0, 0, 1920, 1080);
      expect(
        windowBoundsVisibleOn(const Rect.fromLTWH(0, 0, 900, 600), area),
        isTrue,
      );
      expect(
        windowBoundsVisibleOn(const Rect.fromLTWH(-800, 0, 900, 600), area),
        isTrue,
        reason: '右侧露出 100 仍可抓住',
      );
      expect(
        windowBoundsVisibleOn(const Rect.fromLTWH(-801, 0, 900, 600), area),
        isFalse,
      );
      expect(
        windowBoundsVisibleOn(const Rect.fromLTWH(0, -501, 900, 600), area),
        isFalse,
        reason: '上下方向不足 100 视为不可见',
      );
    });
  });

  group('恢复矩形', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1040);

    test('副屏上的窗口保持原位置（负坐标）', () {
      const secondary = Rect.fromLTWH(-1920, 0, 1920, 1040);
      final resolved = resolveRestoredBounds(
        saved: const Rect.fromLTWH(-1500, 100, 1000, 700),
        displayVisibleAreas: const [primary, secondary],
        primaryVisibleArea: primary,
      );
      expect(resolved, const Rect.fromLTWH(-1500, 100, 1000, 700));
    });

    test('显示器拔掉 / 完全离屏时回主屏居中', () {
      final resolved = resolveRestoredBounds(
        saved: const Rect.fromLTWH(5000, 5000, 1000, 700),
        displayVisibleAreas: const [primary],
        primaryVisibleArea: primary,
      );
      expect(resolved.center, primary.center);
      expect(resolved.size, const Size(1000, 700));
    });

    test('保存值小于最小窗口时夹到 480×400', () {
      final resolved = resolveRestoredBounds(
        saved: const Rect.fromLTWH(100, 100, 200, 150),
        displayVisibleAreas: const [primary],
        primaryVisibleArea: primary,
      );
      expect(resolved.size, kMinimumWindowSize);
      expect(resolved.left, 100);
      expect(resolved.top, 100);
    });

    test('非法几何按最小尺寸回主屏居中', () {
      for (final saved in [
        const Rect.fromLTWH(double.nan, 0, 900, 600),
        const Rect.fromLTWH(0, 0, 0, 600),
        const Rect.fromLTWH(0, 0, 900, -1),
      ]) {
        final resolved = resolveRestoredBounds(
          saved: saved,
          displayVisibleAreas: const [primary],
          primaryVisibleArea: primary,
        );
        expect(resolved.size, kMinimumWindowSize);
        expect(resolved.center, primary.center);
      }
    });
  });
}
