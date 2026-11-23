// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'track_info_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 信息页控制器：跟随播放器切歌，转发本地数据 ValueListenable。

@ProviderFor(TrackInfoController)
final trackInfoControllerProvider = TrackInfoControllerProvider._();

/// 信息页控制器：跟随播放器切歌，转发本地数据 ValueListenable。
final class TrackInfoControllerProvider
    extends $NotifierProvider<TrackInfoController, TrackInfoState> {
  /// 信息页控制器：跟随播放器切歌，转发本地数据 ValueListenable。
  TrackInfoControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'trackInfoControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$trackInfoControllerHash();

  @$internal
  @override
  TrackInfoController create() => TrackInfoController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(TrackInfoState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<TrackInfoState>(value),
    );
  }
}

String _$trackInfoControllerHash() =>
    r'3ae9fcf0bc4ddf35339a159f3b04fdc7d0d8aa3b';

/// 信息页控制器：跟随播放器切歌，转发本地数据 ValueListenable。

abstract class _$TrackInfoController extends $Notifier<TrackInfoState> {
  TrackInfoState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<TrackInfoState, TrackInfoState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<TrackInfoState, TrackInfoState>,
              TrackInfoState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
