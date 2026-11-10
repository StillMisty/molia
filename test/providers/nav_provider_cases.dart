/// NavProvider 启动首页契约：默认值、持久化往返、显示/隐藏锁定与
/// 「同步隐藏存储首页」不一致态的兜底（不改写存储、有效值取首个可见项）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 按真实注册表构造并等待偏好加载（与组合根装配方式一致）。
  Future<NavProvider> buildProvider() async {
    final nav = NavProvider(
      settings: testSettingsRegistry(
        preferences: await SharedPreferences.getInstance(),
      ),
    );
    await nav.preferencesReady;
    addTearDown(nav.dispose);
    return nav;
  }

  test('默认启动首页：nowPlaying，有效值同值', () async {
    final nav = await buildProvider();

    expect(nav.homeDestination, ShellDestination.nowPlaying);
    expect(nav.effectiveHomeDestination, ShellDestination.nowPlaying);
  });

  test('设置启动首页：持久化往返（重建 provider 读回）', () async {
    final nav = await buildProvider();
    await nav.setHomeDestination(ShellDestination.library);

    expect(nav.homeDestination, ShellDestination.library);
    expect(nav.effectiveHomeDestination, ShellDestination.library);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {kShellNavLayout.name}, reason: '一次编辑只写一个键');
    expect(jsonDecode(prefs.getString(kShellNavLayout.name)!), {
      'order': ['library', 'nowPlaying', 'favorites'],
      'hidden': <String>[],
      'home': 'library',
    });

    final reloaded = await buildProvider();
    expect(reloaded.homeDestination, ShellDestination.library);
  });

  test('隐藏启动首页被拒：返回 false、仍可见、不写 hidden', () async {
    final nav = await buildProvider();

    final accepted = await nav.setVisible(ShellDestination.nowPlaying, false);

    expect(accepted, isFalse);
    expect(nav.isVisible(ShellDestination.nowPlaying), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kShellNavLayout.name), isNull);
  });

  test('同步不一致：存储首页保持原值，有效首页回退首个可见项', () async {
    // 模拟同步推来的 hidden 隐藏了本机存储的启动首页。
    final layout = jsonEncode({
      'order': ['library', 'nowPlaying', 'favorites'],
      'hidden': [ShellDestination.nowPlaying.name],
      'home': ShellDestination.nowPlaying.name,
    });
    SharedPreferences.setMockInitialValues({kShellNavLayout.name: layout});
    final nav = await buildProvider();

    expect(nav.homeDestination, ShellDestination.nowPlaying);
    // 默认顺序 library 在前：兜底取第一个可见项。
    expect(nav.effectiveHomeDestination, ShellDestination.library);
    expect(nav.effectiveHomeDestination, nav.visibleDestinations.first);

    // 运行时不改写存储：写回会与同步应用互为触发造成回环。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kShellNavLayout.name), layout);

    // 出路：不一致态下仍可把存储首页重新显示（不被锁定堵死）。
    expect(await nav.setVisible(ShellDestination.nowPlaying, true), isTrue);
    expect(nav.isVisible(ShellDestination.nowPlaying), isTrue);
  });

  test('旧版三键只读兜底：恢复定制但不迁移写', () async {
    SharedPreferences.setMockInitialValues({
      kShellNavOrder.name: [
        ShellDestination.favorites.name,
        ShellDestination.library.name,
        ShellDestination.nowPlaying.name,
      ],
      kShellNavHidden.name: [ShellDestination.library.name],
      kShellHomeDestination.name: ShellDestination.favorites.name,
    });
    final nav = await buildProvider();

    expect(nav.order, [
      ShellDestination.favorites,
      ShellDestination.library,
      ShellDestination.nowPlaying,
    ]);
    expect(nav.isVisible(ShellDestination.library), isFalse);
    expect(nav.homeDestination, ShellDestination.favorites);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kShellNavLayout.name),
      isNull,
      reason: '只读兜底不迁移写；下次编辑才写新键',
    );
  });
}
