/// 组合根在 runApp 前创建、由 Riverpod 容器共享的基础依赖。
///
/// 这些值来自启动阶段（数据库、设置注册表、平台服务），不属于某个功能模块，
/// 因此由 `app_bootstrap.dart` 在创建 [ProviderContainer] 时 override；
/// 功能 provider 只通过 `ref.watch(...)` 读取，不再各自 new 一份。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/settings/settings_registry.dart';

part 'runtime_providers.g.dart';

/// 全应用唯一的设置注册表。
///
/// 生产由组合根 override；测试按需 override 为 `testSettingsRegistry()`。
@Riverpod(keepAlive: true, name: 'settingsRegistryProvider')
SettingsRegistry settingsRegistry(Ref ref) => throw StateError(
  'settingsRegistryProvider 必须由组合根（ProviderScope override）注入',
);
