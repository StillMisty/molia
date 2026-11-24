// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'play_statistics_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 统计加载窗口 / 导出时间戳的时钟源；测试注入固定值。

@ProviderFor(playStatisticsClock)
final playStatisticsClockProvider = PlayStatisticsClockProvider._();

/// 统计加载窗口 / 导出时间戳的时钟源；测试注入固定值。

final class PlayStatisticsClockProvider
    extends
        $FunctionalProvider<
          DateTime Function(),
          DateTime Function(),
          DateTime Function()
        >
    with $Provider<DateTime Function()> {
  /// 统计加载窗口 / 导出时间戳的时钟源；测试注入固定值。
  PlayStatisticsClockProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'playStatisticsClockProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$playStatisticsClockHash();

  @$internal
  @override
  $ProviderElement<DateTime Function()> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  DateTime Function() create(Ref ref) {
    return playStatisticsClock(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DateTime Function() value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DateTime Function()>(value),
    );
  }
}

String _$playStatisticsClockHash() =>
    r'67ee8a50fa58dd10b5bf65725ce7d24eda2ab5ff';

@ProviderFor(PlayStatisticsProvider)
final playStatisticsPageProvider = PlayStatisticsProviderProvider._();

final class PlayStatisticsProviderProvider
    extends $NotifierProvider<PlayStatisticsProvider, PlayStatisticsState> {
  PlayStatisticsProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'playStatisticsPageProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$playStatisticsProviderHash();

  @$internal
  @override
  PlayStatisticsProvider create() => PlayStatisticsProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PlayStatisticsState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PlayStatisticsState>(value),
    );
  }
}

String _$playStatisticsProviderHash() =>
    r'4e600619c161c445c29c5e2e523eabe4a0e7c20d';

abstract class _$PlayStatisticsProvider extends $Notifier<PlayStatisticsState> {
  PlayStatisticsState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<PlayStatisticsState, PlayStatisticsState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<PlayStatisticsState, PlayStatisticsState>,
              PlayStatisticsState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
