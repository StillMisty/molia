// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'discover_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(DiscoverProvider)
final discoverProvider = DiscoverProviderProvider._();

final class DiscoverProviderProvider
    extends $NotifierProvider<DiscoverProvider, DiscoverState> {
  DiscoverProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'discoverProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$discoverProviderHash();

  @$internal
  @override
  DiscoverProvider create() => DiscoverProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DiscoverState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DiscoverState>(value),
    );
  }
}

String _$discoverProviderHash() => r'ddb0be73b10110dd287cb56bdff748dc8ba6d2e5';

abstract class _$DiscoverProvider extends $Notifier<DiscoverState> {
  DiscoverState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<DiscoverState, DiscoverState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<DiscoverState, DiscoverState>,
              DiscoverState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
