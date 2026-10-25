import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/window_bounds.dart';
import 'package:molia/services/window/window_bounds_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 窗口几何恢复的纯逻辑：可见性校验、离屏回退（居中 + 最小尺寸 clamp），
/// 以及几何存储的读取规则（四项缺一 / 损坏值按「没有保存过」处理）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 主显示器 1920×1080，副显示器在右侧（2560×1440）。
  const primary = Rect.fromLTWH(0, 0, 1920, 1080);
  const secondary = Rect.fromLTWH(1920, 0, 2560, 1440);
  const displays = [primary, secondary];

  group('可见性校验', () {
    test('交集两个方向都达到 100 像素才算可见', () {
      expect(
        windowBoundsVisibleOn(const Rect.fromLTWH(100, 100, 800, 600), primary),
        isTrue,
      );
      // 顶部出屏、只露 90px：拖动区在顶栏，抓不住，判为不可见。
      expect(
        windowBoundsVisibleOn(
          const Rect.fromLTWH(100, -510, 800, 600),
          primary,
        ),
        isFalse,
      );
      // 横向只露 70px 同理。
      expect(
        windowBoundsVisibleOn(
          const Rect.fromLTWH(1850, 100, 800, 600),
          primary,
        ),
        isFalse,
      );
      // 完全离屏。
      expect(
        windowBoundsVisibleOn(
          const Rect.fromLTWH(5000, 5000, 800, 600),
          primary,
        ),
        isFalse,
      );
    });
  });

  group('resolveRestoredBounds', () {
    test('可见矩形原样恢复（位置与尺寸都不动）', () {
      const saved = Rect.fromLTWH(120, 80, 1280, 800);
      expect(
        resolveRestoredBounds(
          saved: saved,
          displayVisibleAreas: displays,
          primaryVisibleArea: primary,
        ),
        saved,
      );
    });

    test('多显示器：副屏上的窗口不会被拉回主屏', () {
      const saved = Rect.fromLTWH(2000, 200, 1280, 800);
      expect(
        resolveRestoredBounds(
          saved: saved,
          displayVisibleAreas: displays,
          primaryVisibleArea: primary,
        ),
        saved,
      );
    });

    test('显示器拔掉（完全离屏）：回退主屏居中，尺寸不变', () {
      const saved = Rect.fromLTWH(2600, 300, 1280, 800);
      final resolved = resolveRestoredBounds(
        saved: saved,
        displayVisibleAreas: const [primary],
        primaryVisibleArea: primary,
      );
      expect(resolved.size, const Size(1280, 800));
      expect(resolved.center, primary.center);
    });

    test('可见性不足（只露一条边）：同样回退居中', () {
      // 顶部出屏、只露 80px：两个显示器都判为不可见。
      const saved = Rect.fromLTWH(100, -720, 1280, 800);
      final resolved = resolveRestoredBounds(
        saved: saved,
        displayVisibleAreas: displays,
        primaryVisibleArea: primary,
      );
      expect(resolved.center, primary.center);
    });

    test('尺寸小于下限：夹到最小 900×600，位置仍有效时保留位置', () {
      const saved = Rect.fromLTWH(100, 100, 400, 300);
      expect(
        resolveRestoredBounds(
          saved: saved,
          displayVisibleAreas: displays,
          primaryVisibleArea: primary,
        ),
        const Rect.fromLTWH(100, 100, 900, 600),
      );
    });

    test('损坏的存储值（零 / 负尺寸）：按最小尺寸回退居中', () {
      const corrupted = [
        Rect.zero,
        Rect.fromLTWH(0, 0, -100, 600),
        Rect.fromLTWH(0, 0, 800, 0),
      ];
      for (final saved in corrupted) {
        final resolved = resolveRestoredBounds(
          saved: saved,
          displayVisibleAreas: displays,
          primaryVisibleArea: primary,
        );
        expect(resolved.size, kMinimumWindowSize);
        expect(resolved.center, primary.center);
      }
    });
  });

  group('WindowBoundsStore', () {
    test('保存后重新读取：几何与最大化标记都还原', () async {
      SharedPreferences.setMockInitialValues({});
      final store = WindowBoundsStore(
        prefs: await SharedPreferences.getInstance(),
      );
      await store.saveBounds(const Rect.fromLTWH(10, 20, 1280, 800));
      await store.saveMaximized(true);

      final loaded = await store.load();
      expect(loaded?.bounds, const Rect.fromLTWH(10, 20, 1280, 800));
      expect(loaded?.maximized, isTrue);
    });

    test('几何四项缺一：视为没有保存过（走系统默认位置）', () async {
      SharedPreferences.setMockInitialValues({
        WindowBoundsStore.keyX: 10.0,
        WindowBoundsStore.keyY: 20.0,
        WindowBoundsStore.keyWidth: 1280.0,
      });
      final store = WindowBoundsStore(
        prefs: await SharedPreferences.getInstance(),
      );
      expect(await store.load(), isNull);
    });
  });
}
