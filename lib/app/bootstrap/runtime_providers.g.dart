// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'runtime_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 组合根在启动阶段填写的可变依赖表（见 [AppRuntime]）。
///
/// 生产由 `app_bootstrap.dart` override；测试直接 override 为只填了 fake
/// 的 `AppRuntime`。迁移批次推进时，具体依赖会逐步改为独立 provider。

@ProviderFor(appRuntime)
final appRuntimeProvider = AppRuntimeProvider._();

/// 组合根在启动阶段填写的可变依赖表（见 [AppRuntime]）。
///
/// 生产由 `app_bootstrap.dart` override；测试直接 override 为只填了 fake
/// 的 `AppRuntime`。迁移批次推进时，具体依赖会逐步改为独立 provider。

final class AppRuntimeProvider
    extends $FunctionalProvider<AppRuntime, AppRuntime, AppRuntime>
    with $Provider<AppRuntime> {
  /// 组合根在启动阶段填写的可变依赖表（见 [AppRuntime]）。
  ///
  /// 生产由 `app_bootstrap.dart` override；测试直接 override 为只填了 fake
  /// 的 `AppRuntime`。迁移批次推进时，具体依赖会逐步改为独立 provider。
  AppRuntimeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appRuntimeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appRuntimeHash();

  @$internal
  @override
  $ProviderElement<AppRuntime> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppRuntime create(Ref ref) {
    return appRuntime(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppRuntime value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppRuntime>(value),
    );
  }
}

String _$appRuntimeHash() => r'6623a3f9cae2b18d59d371f2ecc9d41e18f6ba27';

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

/// 设备本地设置入口（SharedPreferences）。测试可 override 为内存实现。

@ProviderFor(deviceSettings)
final deviceSettingsProvider = DeviceSettingsProvider._();

/// 设备本地设置入口（SharedPreferences）。测试可 override 为内存实现。

final class DeviceSettingsProvider
    extends $FunctionalProvider<DeviceSettings, DeviceSettings, DeviceSettings>
    with $Provider<DeviceSettings> {
  /// 设备本地设置入口（SharedPreferences）。测试可 override 为内存实现。
  DeviceSettingsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deviceSettingsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deviceSettingsHash();

  @$internal
  @override
  $ProviderElement<DeviceSettings> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  DeviceSettings create(Ref ref) {
    return deviceSettings(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DeviceSettings value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DeviceSettings>(value),
    );
  }
}

String _$deviceSettingsHash() => r'173a162b5c75388ede60280c9ce85fd4b7386130';
