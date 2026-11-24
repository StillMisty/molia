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
    r'02615f36b19a3433a506a1ae4c43135b91c53da4';

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
