// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'source_swap_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(SourceSwapProvider)
final sourceSwapProvider = SourceSwapProviderProvider._();

final class SourceSwapProviderProvider
    extends $NotifierProvider<SourceSwapProvider, SourceSwapState> {
  SourceSwapProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'sourceSwapProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$sourceSwapProviderHash();

  @$internal
  @override
  SourceSwapProvider create() => SourceSwapProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SourceSwapState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SourceSwapState>(value),
    );
  }
}

String _$sourceSwapProviderHash() =>
    r'2b91fdc08ec4cca2c898743eb7f3ab84f3aa8321';

abstract class _$SourceSwapProvider extends $Notifier<SourceSwapState> {
  SourceSwapState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<SourceSwapState, SourceSwapState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<SourceSwapState, SourceSwapState>,
              SourceSwapState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
