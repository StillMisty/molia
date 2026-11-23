import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:molia/app/bootstrap/app_runtime.dart';
import 'package:molia/app/bootstrap/runtime_providers.dart';
import 'package:molia/services/covers/custom_cover_store.dart';

import 'provider_test_scope.dart';
import 'settings_test_support.dart';

/// 测试用封面存储登记（替代旧的 `coverStoreProvider()`）。
///
/// 生产组合根在 `local_data_stack` 构造唯一实例后登记；展示用例只关心
/// 「能解析封面」时用这个空索引实例，需要真实自定义封面的用例把自己构造的
/// store 传进来。
CustomCoverStore putCoverStore(
  ProviderTestScope scope, [
  CustomCoverStore? store,
]) {
  final value = store ?? CustomCoverStore();
  scope.put<CustomCoverStore>(value);
  return value;
}

/// 给没有宿主容器的展示用例包一层（只登记封面存储）。
Widget withCoverStore(Widget child, {CustomCoverStore? store}) {
  final runtime = AppRuntime()
    ..put<CustomCoverStore>(store ?? CustomCoverStore());
  return ProviderScope(
    overrides: [
      appRuntimeProvider.overrideWithValue(runtime),
      settingsRegistryProvider.overrideWithValue(testSettingsRegistry()),
    ],
    child: child,
  );
}
