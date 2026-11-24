// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'annual_report_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 测试注入的「现在」（年度窗口与年龄口径）。

@ProviderFor(annualReportClock)
final annualReportClockProvider = AnnualReportClockProvider._();

/// 测试注入的「现在」（年度窗口与年龄口径）。

final class AnnualReportClockProvider
    extends
        $FunctionalProvider<
          DateTime Function(),
          DateTime Function(),
          DateTime Function()
        >
    with $Provider<DateTime Function()> {
  /// 测试注入的「现在」（年度窗口与年龄口径）。
  AnnualReportClockProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'annualReportClockProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$annualReportClockHash();

  @$internal
  @override
  $ProviderElement<DateTime Function()> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  DateTime Function() create(Ref ref) {
    return annualReportClock(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DateTime Function() value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DateTime Function()>(value),
    );
  }
}

String _$annualReportClockHash() => r'b21820a25999d3e3333b251094b0e83c6145f639';

@ProviderFor(AnnualReportProvider)
final annualReportPageProvider = AnnualReportProviderProvider._();

final class AnnualReportProviderProvider
    extends $NotifierProvider<AnnualReportProvider, AnnualReportState> {
  AnnualReportProviderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'annualReportPageProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$annualReportProviderHash();

  @$internal
  @override
  AnnualReportProvider create() => AnnualReportProvider();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AnnualReportState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AnnualReportState>(value),
    );
  }
}

String _$annualReportProviderHash() =>
    r'2e863252c462e3f069fc8921dd781837d233d1b7';

abstract class _$AnnualReportProvider extends $Notifier<AnnualReportState> {
  AnnualReportState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AnnualReportState, AnnualReportState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AnnualReportState, AnnualReportState>,
              AnnualReportState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
