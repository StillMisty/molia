/// 年度报告页状态：年份选择、一次性聚合加载与统计变更静默重载。
///
/// 页面打开期间才订阅仓库变更；关闭即取消（与听歌统计页同一策略，避免播放中
/// 每次切歌都触发年度查询）。纯聚合在领域层完成，本类只做调度与代际丢弃。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/play_statistics_repository.dart';
import '../domain/models/annual_report.dart';

class AnnualReportProvider extends ChangeNotifier {
  AnnualReportProvider({
    required PlayStatisticsRepository repository,
    DateTime Function()? clock,
    ValueListenable<bool>? recordingEnabled,
  }) : // 公开参数名保持 repository / clock / recordingEnabled，字段按本类惯例私有。
       // ignore: prefer_initializing_formals
       _repository = repository,
       _clock = clock ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _recordingEnabled = recordingEnabled;

  final PlayStatisticsRepository _repository;
  final DateTime Function() _clock;
  final ValueListenable<bool>? _recordingEnabled;
  final Logger _logger = Logger('molia.annual_report_provider');

  static const Duration watchDebounce = Duration(seconds: 1);

  List<int> _years = const [];
  int _selectedYear = 0;
  Map<String, String> _sourceNames = const {};

  AnnualReport? _report;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  int _loadToken = 0;
  int _disposed = 0;

  StreamSubscription<void>? _subscription;
  Timer? _watchTimer;
  bool _watchReloadRunning = false;
  bool _watchReloadQueued = false;

  List<int> get years => _years;
  int get selectedYear => _selectedYear;
  AnnualReport? get report => _report;
  bool get isLoading => _loading;
  bool get hasLoaded => _loaded;
  bool get hasError => _failed;
  bool get recordingEnabled => _recordingEnabled?.value ?? true;

  /// 页面打开时设置可用年份 / 默认年份；每次打开都从入口推荐年份开始。
  void configure({
    required List<int> years,
    required int featuredYear,
    required Map<String, String> sourceNames,
  }) {
    final sorted = [...years]..sort((a, b) => b.compareTo(a));
    _sourceNames = Map.unmodifiable(sourceNames);
    _years = List.unmodifiable(sorted);
    _selectedYear = _years.contains(featuredYear)
        ? featuredYear
        : (_years.isEmpty ? 0 : _years.first);
    _report = null;
    _loaded = false;
    _failed = false;
    _loadToken++;
    notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (_loaded || _loading || _selectedYear == 0) return;
    await _load();
  }

  Future<void> selectYear(int year) async {
    if (year == _selectedYear || !_years.contains(year)) return;
    _selectedYear = year;
    _report = null;
    _loaded = false;
    _failed = false;
    notifyListeners();
    await _load();
  }

  Future<void> refresh() => _load();

  /// 页面打开：统计变更先攒一个窗口再查询，页面关闭即取消。
  void startWatching() {
    _subscription ??= _repository.changes.listen((_) {
      if (!_loaded) return;
      _watchTimer?.cancel();
      _watchTimer = Timer(watchDebounce, () {
        _watchTimer = null;
        unawaited(_reloadAfterChange());
      });
    });
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

  void _onRecordingChanged() => notifyListeners();

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
    final year = _selectedYear;
    if (year == 0) return;
    final token = ++_loadToken;
    _loading = true;
    notifyListeners();
    try {
      final window = AnnualReportWindow(year);
      final data = await _repository.annualSnapshot(
        since: window.startMs,
        until: window.endMs,
      );
      if (token != _loadToken || _disposed > 0) return;
      _report = buildAnnualReport(
        year: year,
        data: data,
        now: _clock(),
        knownSourceNames: _sourceNames,
        recordingEnabled: recordingEnabled,
      );
      _loaded = true;
      _failed = false;
    } catch (e) {
      if (token != _loadToken || _disposed > 0) return;
      _failed = true;
      _logger.severe('加载年度听歌报告失败', e);
    } finally {
      if (token == _loadToken && _disposed == 0) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed++;
    stopWatching();
    super.dispose();
  }
}
