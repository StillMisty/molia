/// 听歌统计页状态：范围切换、数据加载、清空与导出。
///
/// 纯数据状态（不持有播放/资料库）：播放动作由页面经
/// `LibraryProvider.sourceTrackFromRaw` + `PlaybackProvider` 完成。
/// 页面打开期间订阅仓库 [PlayStatisticsRepository.changes]（收尾/清空后
/// 静默重载）；页面关闭后取消订阅，避免播放中每个切歌都触发全量查询。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/models/play_statistics.dart';
import '../providers/app_providers.dart';
import '../services/play_statistics_export.dart';
import '../services/statistics/listening_statistics.dart';

part 'play_statistics_provider.g.dart';

/// 热力图的取值维度。
enum PlayStatisticsValueMode { duration, count }

/// 统计页对 UI 暴露的不可变快照。
@immutable
class PlayStatisticsState {
  const PlayStatisticsState({
    required this.range,
    required this.valueMode,
    required this.isLoading,
    required this.hasLoaded,
    required this.hasError,
    required this.view,
  });

  final PlayStatisticsRange range;
  final PlayStatisticsValueMode valueMode;
  final bool isLoading;
  final bool hasLoaded;
  final bool hasError;

  /// 最近一次被接受的加载（快照 + 窗口一次算好；null = 尚未加载）。
  final ListeningStatisticsView? view;

  ListeningStatisticsSnapshot? get snapshot => view?.snapshot;
  ListeningStatisticsWindow? get window => view?.window;
  bool get isEmpty =>
      hasLoaded && !isLoading && (snapshot?.summary.playCount ?? 0) == 0;

  PlayStatisticsState copyWith({
    PlayStatisticsRange? range,
    PlayStatisticsValueMode? valueMode,
    bool? isLoading,
    bool? hasLoaded,
    bool? hasError,
    ListeningStatisticsView? view,
  }) => PlayStatisticsState(
    range: range ?? this.range,
    valueMode: valueMode ?? this.valueMode,
    isLoading: isLoading ?? this.isLoading,
    hasLoaded: hasLoaded ?? this.hasLoaded,
    hasError: hasError ?? this.hasError,
    view: view ?? this.view,
  );
}

/// 统计加载窗口 / 导出时间戳的时钟源；测试注入固定值。
@Riverpod(keepAlive: true, name: 'playStatisticsClockProvider')
DateTime Function() playStatisticsClock(Ref ref) => DateTime.now;

@Riverpod(keepAlive: true, name: 'playStatisticsPageProvider')
class PlayStatisticsProvider extends _$PlayStatisticsProvider {
  final Logger _logger = Logger('molia.play_statistics_provider');
  StreamSubscription<void>? _subscription;

  /// 页面打开期间的变更重载防抖窗口：一次播放收尾会连续广播多条变更，
  /// 全部查询（汇总 / 榜单 / 热力图）不应跟着每条变更各跑一遍。
  static const Duration watchDebounce = Duration(seconds: 1);

  Timer? _watchTimer;
  bool _watchReloadRunning = false;
  bool _watchReloadQueued = false;
  int _loadToken = 0;
  late final DateTime Function() _clock;

  @override
  PlayStatisticsState build() {
    _clock = ref.watch(playStatisticsClockProvider);
    ref.onDispose(stopWatching);
    return const PlayStatisticsState(
      range: PlayStatisticsRange.month,
      valueMode: PlayStatisticsValueMode.duration,
      isLoading: false,
      hasLoaded: false,
      hasError: false,
      view: null,
    );
  }

  // 兼容旧读接口：页面辅助函数仍可直接读 notifier。
  PlayStatisticsRange get range => state.range;
  PlayStatisticsValueMode get valueMode => state.valueMode;
  bool get isLoading => state.isLoading;
  bool get hasLoaded => state.hasLoaded;
  bool get hasError => state.hasError;
  ListeningStatisticsSnapshot? get snapshot => state.snapshot;
  ListeningStatisticsWindow? get window => state.window;
  ListeningStatisticsView? get view => state.view;
  bool get isEmpty => state.isEmpty;

  /// 首次打开页面时调用（已加载过则跳过）。
  Future<void> ensureLoaded() async {
    if (state.hasLoaded) return;
    await _loadNow();
  }

  /// 页面打开时订阅仓库变更（收尾/清空后静默重载）。
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
  }

  /// 页面关闭时取消订阅，并丢掉还没触发的防抖重载。
  void stopWatching() {
    _subscription?.cancel();
    _subscription = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    _watchReloadQueued = false;
  }

  Future<void> setRange(PlayStatisticsRange value) async {
    if (state.range == value) return;
    state = state.copyWith(range: value);
    await _loadNow();
  }

  void setValueMode(PlayStatisticsValueMode value) {
    if (state.valueMode == value) return;
    state = state.copyWith(valueMode: value);
  }

  /// 手动刷新（下拉/重试）：不走防抖，立即查询。
  Future<void> refresh() => _loadNow();

  /// 某一天的播放明细（热力图点按弹层按需加载）。
  Future<DayPlayEvents> loadDay(DateTime day) =>
      ref.read(playStatisticsRepositoryProvider).dayEvents(day);

  /// 清空全部统计事件（不可撤销；调用方负责二次确认）。
  Future<void> clearAll() async {
    await ref.read(playStatisticsRepositoryProvider).clearAll();
    await _loadNow();
  }

  /// 构建**全量**听歌数据 JSON（汇总 + 榜单 + 最近明细）。
  Future<({String json, DateTime exportedAt})> buildExportJson() async {
    final window = state.window;
    if (window == null) throw StateError('统计窗口尚未加载，无法导出');
    final repository = ref.read(playStatisticsRepositoryProvider);
    final results = await Future.wait([
      repository.summary(),
      repository.topTracks(limit: 20),
      repository.topArtists(limit: 20),
      repository.listenedByDay(),
      repository.listenedByHour(),
      repository.sourceDistribution(),
      repository.listEventsForExport(),
    ]);
    final payload = buildPlayStatisticsExport(
      summary: results[0] as PlayStatisticsSummary,
      topTracks: results[1] as List<PlayStatTrackEntry>,
      topArtists: results[2] as List<PlayStatArtistEntry>,
      daily: results[3] as List<DayListened>,
      hourly: results[4] as List<HourListened>,
      sources: results[5] as List<SourceListened>,
      recentEvents: results[6] as List<PlayEvent>,
      exportedAt: window.now,
    );
    const jsonEncoder = JsonEncoder.withIndent('  ');
    return (json: jsonEncoder.convert(payload), exportedAt: window.now);
  }

  /// 立即加载：取消防抖窗口（手动刷新 / 范围切换 / 清空后的数据必须立刻可见）。
  Future<void> _loadNow() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _watchReloadQueued = false;
    return _load();
  }

  /// 防抖后的自动重载：单飞 + 排队一次。
  Future<void> _reloadAfterChange() async {
    if (_watchReloadRunning) {
      _watchReloadQueued = true;
      return;
    }
    _watchReloadRunning = true;
    try {
      do {
        _watchReloadQueued = false;
        await _load(silent: true);
      } while (_watchReloadQueued);
    } finally {
      _watchReloadRunning = false;
    }
  }

  Future<void> _load({bool silent = false}) =>
      DataPathTrace.async('play_statistics.load', () async {
        final token = ++_loadToken;
        // 一次加载只读一次时钟：查询起点、日历高亮与「今天」必须属于同一窗口。
        final window = ListeningStatisticsWindow(
          range: state.range,
          now: _clock(),
        );
        if (!silent) state = state.copyWith(isLoading: true);
        try {
          final snapshot = await ref
              .read(playStatisticsRepositoryProvider)
              .snapshot(since: window.sinceMs);
          if (token != _loadToken) return;
          state = state.copyWith(
            view: ListeningStatisticsView.from(snapshot, window),
            hasLoaded: true,
            hasError: false,
          );
        } catch (e) {
          if (token != _loadToken) return;
          _logger.severe('加载听歌统计失败', e);
          state = state.copyWith(hasError: true);
        } finally {
          if (token == _loadToken) {
            state = state.copyWith(isLoading: false);
          }
        }
      }, fields: () => {'silent': silent ? 1 : 0});
}
