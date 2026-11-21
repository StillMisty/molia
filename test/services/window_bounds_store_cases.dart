import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/device_settings.dart';
import 'package:molia/services/window/window_bounds_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 窗口几何持久化：几何合并为单键写入，最大化标记独立，旧键只读兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<WindowBoundsStore> buildStore() async => WindowBoundsStore(
    settings: DeviceSettings(
      preferences: await SharedPreferences.getInstance(),
    ),
  );

  test('保存几何只写一个 JSON 字符串键，读取往返一致', () async {
    final store = await buildStore();
    final prefs = await SharedPreferences.getInstance();
    const bounds = Rect.fromLTWH(10, 20, 800, 600);

    expect(await store.load(), isNull, reason: '没有记录时按系统默认位置');

    await store.saveBounds(bounds);

    expect(prefs.getKeys(), {WindowBoundsStore.keyBounds});
    expect(jsonDecode(prefs.getString(WindowBoundsStore.keyBounds)!), {
      'x': 10.0,
      'y': 20.0,
      'w': 800.0,
      'h': 600.0,
    });
    final loaded = await (await buildStore()).load();
    expect(loaded?.bounds, bounds);
    expect(loaded?.maximized, isFalse);
  });

  test('最大化标记仍独立保存并随几何一起读回', () async {
    final store = await buildStore();
    final prefs = await SharedPreferences.getInstance();
    const bounds = Rect.fromLTWH(0, 0, 1024, 768);

    await store.saveBounds(bounds);
    await store.saveMaximized(true);

    expect(prefs.getBool(WindowBoundsStore.keyMaximized), isTrue);
    expect(await store.loadMaximized(), isTrue);
    final loaded = await store.load();
    expect(loaded?.bounds, bounds);
    expect(loaded?.maximized, isTrue);
  });

  test('新键损坏 / 几何非法返回 null', () async {
    SharedPreferences.setMockInitialValues({
      WindowBoundsStore.keyBounds: '{not json',
    });
    expect(await (await buildStore()).load(), isNull);

    SharedPreferences.setMockInitialValues({
      WindowBoundsStore.keyBounds: jsonEncode({
        'x': 0,
        'y': 0,
        'w': 0,
        'h': 100,
      }),
    });
    expect(await (await buildStore()).load(), isNull);
  });

  test('旧版四键只读兜底，不写回也不影响升级后恢复', () async {
    const legacy = {
      'window_bounds_x': 1.0,
      'window_bounds_y': 2.0,
      'window_bounds_width': 640.0,
      'window_bounds_height': 480.0,
    };
    SharedPreferences.setMockInitialValues({...legacy});

    final store = await buildStore();
    final loaded = await store.load();

    expect(loaded?.bounds, const Rect.fromLTWH(1, 2, 640, 480));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(WindowBoundsStore.keyBounds),
      isNull,
      reason: '只读兜底不迁移写；下次拖动落定时才写新键',
    );
  });

  test('旧键几何非法时同样返回 null', () async {
    SharedPreferences.setMockInitialValues({
      'window_bounds_x': 0.0,
      'window_bounds_y': 0.0,
      'window_bounds_width': -1.0,
      'window_bounds_height': 100.0,
    });

    expect(await (await buildStore()).load(), isNull);
  });

  group('按虚拟桌面分组', () {
    const desktopA = 'aaaaaaaa-1111-2222-3333-444444444444';
    const desktopB = 'bbbbbbbb-1111-2222-3333-444444444444';

    test('两个桌面各自保存 / 读取几何，互不覆盖', () async {
      final store = await buildStore();
      const boundsA = Rect.fromLTWH(10, 20, 800, 600);
      const boundsB = Rect.fromLTWH(110, 220, 1000, 700);

      await store.saveBoundsFor(desktopA, boundsA);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.saveBoundsFor(desktopB, boundsB);

      final reopened = await buildStore();
      expect((await reopened.loadPreferred(desktopA))?.bounds, boundsA);
      expect((await reopened.loadPreferred(desktopB))?.bounds, boundsB);
    });

    test('最大化标记按桌面隔离；有几何但无标记视为未最大化', () async {
      final store = await buildStore();
      const boundsA = Rect.fromLTWH(0, 0, 900, 700);
      const boundsB = Rect.fromLTWH(40, 40, 1000, 720);

      await store.saveBoundsFor(desktopA, boundsA);
      await store.saveBoundsFor(desktopB, boundsB);
      await store.saveMaximizedFor(desktopA, true);

      final reopened = await buildStore();
      final stateA = await reopened.loadPreferred(desktopA);
      final stateB = await reopened.loadPreferred(desktopB);
      expect(stateA?.maximized, isTrue);
      expect(stateB?.maximized, isFalse, reason: '另一个桌面从未最大化过');
    });

    test('只有最大化标记时仍能恢复（首启就最大化 → 退出）', () async {
      final store = await buildStore();
      await store.saveMaximizedFor(desktopA, true);

      final state = await (await buildStore()).loadPreferred(desktopA);
      expect(state?.bounds, isNull);
      expect(state?.maximized, isTrue);
    });

    test('没有该桌面记录时回退最近使用的分组，再回退旧全局键', () async {
      final store = await buildStore();
      const boundsA = Rect.fromLTWH(10, 10, 800, 600);
      const boundsB = Rect.fromLTWH(20, 20, 900, 650);

      await store.saveBoundsFor(desktopA, boundsA);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.saveBoundsFor(desktopB, boundsB);

      final unknown = await (await buildStore()).loadPreferred(
        'cccccccc-1111-2222-3333-444444444444',
      );
      expect(unknown?.bounds, boundsB, reason: '最近一次落盘的桌面');

      SharedPreferences.setMockInitialValues({
        'window_bounds_x': 1.0,
        'window_bounds_y': 2.0,
        'window_bounds_width': 640.0,
        'window_bounds_height': 480.0,
      });
      final legacy = await (await buildStore()).loadPreferred(null);
      expect(legacy?.bounds, const Rect.fromLTWH(1, 2, 640, 480));
    });

    test('只读指定桌面：没有记录时不继承其它桌面的几何 / 最大化', () async {
      final store = await buildStore();
      await store.saveBoundsFor(desktopA, const Rect.fromLTWH(1, 2, 800, 600));
      await store.saveMaximizedFor(desktopA, true);

      expect(await store.loadFor(desktopB), isNull);
      final exact = await store.loadFor(desktopA);
      expect(exact?.bounds, const Rect.fromLTWH(1, 2, 800, 600));
      expect(exact?.maximized, isTrue);
    });

    test('分组超过上限时按最近使用淘汰', () async {
      final store = await buildStore();
      for (var i = 0; i < WindowBoundsStore.maxDesktopEntries + 2; i++) {
        await store.saveBoundsFor(
          'desktop-$i',
          Rect.fromLTWH(i.toDouble(), i.toDouble(), 800, 600),
        );
        // savedAt 是毫秒：连续写入要拉开时间，才能确定淘汰顺序。
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(
        prefs.getString(WindowBoundsStore.keyBoundsByDesktop)!,
      ) as Map<String, dynamic>;
      expect(decoded.length, WindowBoundsStore.maxDesktopEntries);
      expect(decoded.containsKey('desktop-0'), isFalse);
      expect(
        decoded.containsKey(
          'desktop-${WindowBoundsStore.maxDesktopEntries + 1}',
        ),
        isTrue,
      );
    });

    test('分组 JSON 损坏 / 条目非法时忽略并回退旧键', () async {
      SharedPreferences.setMockInitialValues({
        WindowBoundsStore.keyBoundsByDesktop: '{oops',
        'window_bounds_x': 5.0,
        'window_bounds_y': 6.0,
        'window_bounds_width': 700.0,
        'window_bounds_height': 500.0,
      });

      final state = await (await buildStore()).loadPreferred(desktopA);
      expect(state?.bounds, const Rect.fromLTWH(5, 6, 700, 500));
    });

    test('空桌面 ID 退回全局键', () async {
      final store = await buildStore();
      await store.saveBoundsFor('', const Rect.fromLTWH(1, 2, 800, 600));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(WindowBoundsStore.keyBoundsByDesktop), isFalse);
      expect(await store.load(), isNotNull);
    });
  });
}
