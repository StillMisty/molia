// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_library_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(localLibraryDebounce)
final localLibraryDebounceProvider = LocalLibraryDebounceProvider._();

final class LocalLibraryDebounceProvider
    extends $FunctionalProvider<Duration, Duration, Duration>
    with $Provider<Duration> {
  LocalLibraryDebounceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localLibraryDebounceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localLibraryDebounceHash();

  @$internal
  @override
  $ProviderElement<Duration> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  Duration create(Ref ref) {
    return localLibraryDebounce(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Duration value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Duration>(value),
    );
  }
}

String _$localLibraryDebounceHash() =>
    r'b652fb7f3d2346400ebc5da14b608176477dde14';

/// 曲库聚合读取的「资料库」输入；测试 / 性能场景可替换为真实内存库。

@ProviderFor(localLibraryLibrary)
final localLibraryLibraryProvider = LocalLibraryLibraryProvider._();

/// 曲库聚合读取的「资料库」输入；测试 / 性能场景可替换为真实内存库。

final class LocalLibraryLibraryProvider
    extends
        $FunctionalProvider<LibraryProvider, LibraryProvider, LibraryProvider>
    with $Provider<LibraryProvider> {
  /// 曲库聚合读取的「资料库」输入；测试 / 性能场景可替换为真实内存库。
  LocalLibraryLibraryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localLibraryLibraryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localLibraryLibraryHash();

  @$internal
  @override
  $ProviderElement<LibraryProvider> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  LibraryProvider create(Ref ref) {
    return localLibraryLibrary(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LibraryProvider value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LibraryProvider>(value),
    );
  }
}

String _$localLibraryLibraryHash() =>
    r'b68b1c37a39118de39598c6d67cc4735670df0ef';

@ProviderFor(localLibraryIsolateThreshold)
final localLibraryIsolateThresholdProvider =
    LocalLibraryIsolateThresholdProvider._();

final class LocalLibraryIsolateThresholdProvider
    extends $FunctionalProvider<int, int, int>
    with $Provider<int> {
  LocalLibraryIsolateThresholdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localLibraryIsolateThresholdProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localLibraryIsolateThresholdHash();

  @$internal
  @override
  $ProviderElement<int> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  int create(Ref ref) {
    return localLibraryIsolateThreshold(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$localLibraryIsolateThresholdHash() =>
    r'71489d50ac05a13b880739abad881520fa64941f';

@ProviderFor(LocalLibraryProvider)
final localLibraryProvider = LocalLibraryProviderProvider._();

final class LocalLibraryProviderProvider
    extends $NotifierProvider<LocalLibraryProvider, LocalLibraryState> {
  LocalLibraryProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localLibraryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localLibraryProviderHash();

  @$internal
  @override
  LocalLibraryProvider create() => LocalLibraryProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalLibraryState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalLibraryState>(value),
    );
  }
}

String _$localLibraryProviderHash() =>
    r'd5816e81ba782e095e9d20b1ff0df7ee7f4bdc94';

abstract class _$LocalLibraryProvider extends $Notifier<LocalLibraryState> {
  LocalLibraryState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<LocalLibraryState, LocalLibraryState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LocalLibraryState, LocalLibraryState>,
              LocalLibraryState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
