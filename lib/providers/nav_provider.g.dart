// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'nav_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
/// SharedPreferences 持久化。

@ProviderFor(NavProvider)
final navProvider = NavProviderProvider._();

/// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
/// SharedPreferences 持久化。
final class NavProviderProvider
    extends $NotifierProvider<NavProvider, NavState> {
  /// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
  /// SharedPreferences 持久化。
  NavProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'navProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$navProviderHash();

  @$internal
  @override
  NavProvider create() => NavProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NavState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NavState>(value),
    );
  }
}

String _$navProviderHash() => r'5f060b8caa657540d6240fac5ff75cd68f21b42d';

/// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
/// SharedPreferences 持久化。

abstract class _$NavProvider extends $Notifier<NavState> {
  NavState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<NavState, NavState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<NavState, NavState>,
              NavState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
