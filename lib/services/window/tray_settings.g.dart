// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tray_settings.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 托盘行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。

@ProviderFor(TraySettings)
final traySettingsProvider = TraySettingsProvider._();

/// 托盘行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。
final class TraySettingsProvider
    extends $NotifierProvider<TraySettings, TraySettingsState> {
  /// 托盘行为偏好：读写设备本地设置，变更即时生效
  /// （`WindowChrome` 的关闭策略每次读取）。
  TraySettingsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'traySettingsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$traySettingsHash();

  @$internal
  @override
  TraySettings create() => TraySettings();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(TraySettingsState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<TraySettingsState>(value),
    );
  }
}

String _$traySettingsHash() => r'd237928930971972afe78600b1065ba5fcaddbea';

/// 托盘行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。

abstract class _$TraySettings extends $Notifier<TraySettingsState> {
  TraySettingsState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<TraySettingsState, TraySettingsState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<TraySettingsState, TraySettingsState>,
              TraySettingsState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
