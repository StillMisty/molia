// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'runtime_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 全应用唯一的设置注册表。
///
/// 生产由组合根 override；测试按需 override 为 `testSettingsRegistry()`。

@ProviderFor(settingsRegistry)
final settingsRegistryProvider = SettingsRegistryProvider._();

/// 全应用唯一的设置注册表。
///
/// 生产由组合根 override；测试按需 override 为 `testSettingsRegistry()`。

final class SettingsRegistryProvider
    extends
        $FunctionalProvider<
          SettingsRegistry,
          SettingsRegistry,
          SettingsRegistry
        >
    with $Provider<SettingsRegistry> {
  /// 全应用唯一的设置注册表。
  ///
  /// 生产由组合根 override；测试按需 override 为 `testSettingsRegistry()`。
  SettingsRegistryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'settingsRegistryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$settingsRegistryHash();

  @$internal
  @override
  $ProviderElement<SettingsRegistry> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  SettingsRegistry create(Ref ref) {
    return settingsRegistry(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SettingsRegistry value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SettingsRegistry>(value),
    );
  }
}

String _$settingsRegistryHash() => r'02409dbe7e4c796bf753f3acc3635a42caffd311';
