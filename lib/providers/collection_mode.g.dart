// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'collection_mode.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(CollectionModeStore)
final collectionModeProvider = CollectionModeStoreProvider._();

final class CollectionModeStoreProvider
    extends $NotifierProvider<CollectionModeStore, CollectionModeState> {
  CollectionModeStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'collectionModeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$collectionModeStoreHash();

  @$internal
  @override
  CollectionModeStore create() => CollectionModeStore();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CollectionModeState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CollectionModeState>(value),
    );
  }
}

String _$collectionModeStoreHash() =>
    r'009827d2ee46827ca12c97a895f42d55498938a6';

abstract class _$CollectionModeStore extends $Notifier<CollectionModeState> {
  CollectionModeState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<CollectionModeState, CollectionModeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CollectionModeState, CollectionModeState>,
              CollectionModeState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
