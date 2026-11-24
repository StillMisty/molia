/// 年度报告页状态：年份选择、一次性聚合加载与统计变更静默重载。
///
/// 页面打开期间才订阅仓库变更；关闭即取消（与听歌统计页同一策略，避免播放中
/// 每次切歌都触发年度查询）。纯聚合在领域层完成，本类只做调度与代际丢弃。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../domain/models/annual_report.dart';
import '../providers/app_providers.dart';

part 'annual_report_provider.g.dart';

/// 年度报告对 UI 暴露的不可变快照。
@immutable
class AnnualReportState {
  const AnnualReportState({
    required this.years,
    required this.selectedYear,
    required this.report,
    required this.isLoading,
    required this.hasLoaded,
    required this.hasError,
    required this.recordingEnabled,
  });

  final List<int> years;
  final int selectedYear;
  final AnnualReport? report;
  final bool isLoading;
  final bool hasLoaded;
  final bool hasError;
  final bool recordingEnabled;

  AnnualReportState copyWith({
    List<int>? years,
    int? selectedYear,
    AnnualReport? report,
    bool clearReport = false,
    bool? isLoading,
    bool? hasLoaded,
    bool? hasError,
    bool? recordingEnabled,
  }) => AnnualReportState(
    years: years ?? this.years,
    selectedYear: selectedYear ?? this.selectedYear,
    report: clearReport ? null : (report ?? this.report),
    isLoading: isLoading ?? this.isLoading,
    hasLoaded: hasLoaded ?? this.hasLoaded,
    hasError: hasError ?? this.hasError,
    recordingEnabled: recordingEnabled ?? this.recordingEnabled,
  );
}

/// 测试注入的「现在」（年度窗口与年龄口径）。
@Riverpod(keepAlive: true, name: 'annualReportClockProvider')
DateTime Function() annualReportClock(Ref ref) => DateTime.now;

/// 统计采集开关（可空：精简挂载 / 测试没有统计服务）。
final annualReportRecordingEnabledProvider = Provider<ValueListenable<bool>?>(
  (ref) => ref.read(playStatisticsServiceProvider)?.enabledNotifier,
);

@Riverpod(keepAlive: true, name: 'annualReportPageProvider')
class AnnualReportProvider extends _$AnnualReportProvider {
  static const Duration watchDebounce = Duration(seconds: 1);

  late final DateTime Function() _clock;
  final Logger _logger = Logger('molia.annual_report_provider');

  Map<String, String> _sourceNames = const {};
  int _loadToken = 0;
  int _disposed = 0;

  StreamSubscription<void>? _subscription;
  Timer? _watchTimer;
  bool _watchReloadRunning = false;
  bool _watchReloadQueued = false;
  ValueListenable<bool>? _recordingEnabled;

  @override
  AnnualReportState build() {
    _clock = ref.watch(annualReportClockProvider);
    _recordingEnabled = ref.watch(annualReportRecordingEnabledProvider);
    ref.onDispose(() {
      _disposed++;
      stopWatching();
    });
    return const AnnualReportState(
      years: [],
      selectedYear: 0,
      report: null,
      isLoading: false,
      hasLoaded: false,
      hasError: false,
      recordingEnabled: true,
    );
  }

  // 兼容旧读接口：页面辅助函数仍可直接读 notifier。
  List<int> get years => state.years;
  int get selectedYear => state.selectedYear;
  AnnualReport? get report => state.report;
  bool get isLoading => state.isLoading;
  bool get hasLoaded => state.hasLoaded;
  bool get hasError => state.hasError;
  bool get recordingEnabled =>
      _recordingEnabled?.value ?? state.recordingEnabled;

  void _emit() {
    state = AnnualReportState(
      years: state.years,
      selectedYear: state.selectedYear,
      report: state.report,
      isLoading: state.isLoading,
      hasLoaded: state.hasLoaded,
      hasError: state.hasError,
      recordingEnabled: recordingEnabled,
    );
  }

  /// 页面打开时设置可用年份 / 默认年份；每次打开都从入口推荐年份开始。
  void configure({
    required List<int> years,
    required int featuredYear,
    required Map<String, String> sourceNames,
  }) {
    final sorted = [...years]..sort((a, b) => b.compareTo(a));
    _sourceNames = Map.unmodifiable(sourceNames);
    final selected = sorted.contains(featuredYear)
        ? featuredYear
        : (sorted.isEmpty ? 0 : sorted.first);
    _loadToken++;
    state = AnnualReportState(
      years: List.unmodifiable(sorted),
      selectedYear: selected,
      report: null,
      isLoading: false,
      hasLoaded: false,
      hasError: false,
      recordingEnabled: recordingEnabled,
    );
  }

  Future<void> ensureLoaded() async {
    if (state.hasLoaded || state.isLoading || state.selectedYear == 0) return;
    await _load();
  }

  Future<void> selectYear(int year) async {
    if (year == state.selectedYear || !state.years.contains(year)) return;
    _loadToken++;
    state = state.copyWith(
      selectedYear: year,
      clearReport: true,
      hasLoaded: false,
      hasError: false,
    );
    await _load();
  }

  Future<void> refresh() => _load();

  /// 页面打开：统计变更先攒一个窗口再查询，页面关闭即取消。
  void startWatching() {
    _subscription ??= ref.read(playStatisticsRepositoryProvider).changes.listen(
      (_) {
        if (!state.hasLoaded) return;
        _watchTimer?.cancel();
        _watchTimer = Timer(watchDebounce, () {
          _watchTimer = null;
          unawaited(_reloadAfterChange());
        });
      },
    );
    _recordingEnabled?.addListener(_onRecordingChanged);
  }

  void stopWatching() {
    _subscription?.cancel();
    _subscription = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    _watchReloadQueued = false;
    _recordingEnabled?.removeListener(_onRecordingChanged);
  }

  void _onRecordingChanged() => _emit();

  Future<void> _reloadAfterChange() async {
    if (_watchReloadRunning) {
      _watchReloadQueued = true;
      return;
    }
    _watchReloadRunning = true;
    try {
      do {
        _watchReloadQueued = false;
        await _load();
      } while (_watchReloadQueued);
    } finally {
      _watchReloadRunning = false;
    }
  }

  Future<void> _load() async {
    final year = state.selectedYear;
    if (year == 0) return;
    final token = ++_loadToken;
    state = state.copyWith(isLoading: true);
    try {
      final window = AnnualReportWindow(year);
      final data = await ref
          .read(playStatisticsRepositoryProvider)
          .annualSnapshot(since: window.startMs, until: window.endMs);
      if (token != _loadToken || _disposed > 0) return;
      final report = buildAnnualReport(
        year: year,
        data: data,
        now: _clock(),
        knownSourceNames: _sourceNames,
        firstPlayedAt: data.firstPlayedAt,
        recordingEnabled: recordingEnabled,
      );
      state = state.copyWith(
        report: report,
        hasLoaded: true,
        hasError: false,
        isLoading: false,
      );
    } catch (e) {
      if (token != _loadToken || _disposed > 0) return;
      _logger.severe('加载年度听歌报告失败', e);
      state = state.copyWith(hasError: true, isLoading: false);
    }
  }
}
