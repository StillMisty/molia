// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'comments_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(CommentsProvider)
final commentsProvider = CommentsProviderProvider._();

final class CommentsProviderProvider
    extends $NotifierProvider<CommentsProvider, CommentsState> {
  CommentsProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'commentsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$commentsProviderHash();

  @$internal
  @override
  CommentsProvider create() => CommentsProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CommentsState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CommentsState>(value),
    );
  }
}

String _$commentsProviderHash() => r'25cb68f9ac8c3d7c01caa8ab2158a0365a6b4349';

abstract class _$CommentsProvider extends $Notifier<CommentsState> {
  CommentsState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<CommentsState, CommentsState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CommentsState, CommentsState>,
              CommentsState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
