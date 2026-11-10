import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/window_bounds_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 窗口几何持久化：几何合并为单键写入，最大化标记独立，旧键只读兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<WindowBoundsStore> buildStore() async =>
      WindowBoundsStore(prefs: await SharedPreferences.getInstance());

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
}
