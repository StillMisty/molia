/// Widget / 单元测试的 Riverpod 宿主：一个容器 + 一份可填的启动期注册表。
///
/// 迁移前的测试用 `MultiProvider` 注入实例；现在等价于把同一批实例
/// `put` 进 [AppRuntime]，再用 `UncontrolledProviderScope` 挂容器。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:molia/app/bootstrap/app_runtime.dart';
import 'package:molia/app/bootstrap/runtime_providers.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/providers/theme_provider.dart';

import 'settings_test_support.dart';

class ProviderTestScope {
  ProviderTestScope({
    SettingsRegistry? registry,
    List<Override> overrides = const [],
  }) : registry = registry ?? testSettingsRegistry() {
    container = ProviderContainer(
      overrides: [
        appRuntimeProvider.overrideWithValue(runtime),
        settingsRegistryProvider.overrideWithValue(this.registry),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
  }

  final AppRuntime runtime = AppRuntime();
  final SettingsRegistry registry;
  late final ProviderContainer container;

  /// 登记启动期实例（等价于旧的 `Provider.value` / `ChangeNotifierProvider.value`）。
  void put<T>(T value) => runtime.put<T>(value);

  /// 主题 notifier（测试需要 await preferencesReady / 直接调命令）。
  ThemeProvider get theme => container.read(themeProvider.notifier);

  Widget wrap(Widget child) =>
      UncontrolledProviderScope(container: container, child: child);
}
