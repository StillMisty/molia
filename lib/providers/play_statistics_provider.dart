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

import '../app/perf/data_path_trace.dart';
import '../data/play_statistics_repository.dart';
import '../domain/models/play_statistics.dart';
import '../services/play_statistics_export.dart';
import '../services/statistics/listening_statistics.dart';

/// 热力图的取值维度。
enum PlayStatisticsValueMode { duration, count }

class PlayStatisticsProvider extends ChangeNotifier {
  PlayStatisticsProvider({
    required PlayStatisticsRepository repository,
    DateTime Function()? clock,
  }) : // 公开参数名保持 repository / clock，字段按本类惯例私有。
       // ignore: prefer_initializing_formals
       _repository = repository,
       _clock = clock ?? DateTime.now;

  final PlayStatisticsRepository _repository;

  /// 统计加载窗口与导出时间戳共用的时钟源；测试注入固定值。
  final DateTime Function() _clock;
  final Logger _logger = Logger('molia.play_statistics_provider');
  StreamSubscription<void>? _subscription;

  /// 页面打开期间的变更重载防抖窗口：一次播放收尾会连续广播多条变更，
  /// 全部查询（汇总 / 榜单 / 热力图）不应跟着每条变更各跑一遍。
  static const Duration watchDebounce = Duration(seconds: 1);

  Timer? _watchTimer;
  bool _watchReloadRunning = false;
  bool _watchReloadQueued = false;

  PlayStatisticsRange _range = PlayStatisticsRange.month;
  PlayStatisticsValueMode _valueMode = PlayStatisticsValueMode.duration;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  int _loadToken = 0;

  /// 最近一次被接受的加载（快照 + 窗口一次算好；null = 尚未加载）。
  ///
  /// 只有查询成功且未被新加载取代时才替换：失败或过期结果不会让窗口
  /// 先于页面显示的视图前移。
  ListeningStatisticsView? _view;

  PlayStatisticsRange get range => _range;
  PlayStatisticsValueMode get valueMode => _valueMode;
  bool get isLoading => _loading;
  bool get hasLoaded => _loaded;
  bool get hasError => _failed;

  /// 聚合快照（汇总 / 榜单 / 日历 / 作息热力图 / 来源分布一次取回）。
  ListeningStatisticsSnapshot? get snapshot => _view?.snapshot;

  /// 最近一次被接受的窗口；与 [view] 永远同一代。
  ListeningStatisticsWindow? get window => _view?.window;

  /// 最近一次被接受的页面投影；同一快照 + 同一窗口只算一次。
  ListeningStatisticsView? get view => _view;

  /// 范围内没有任何已收尾事件（加载完成的前提下）。
  bool get isEmpty =>
      _loaded && !_loading && (snapshot?.summary.playCount ?? 0) == 0;

  /// 首次打开页面时调用（已加载过则跳过）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await _loadNow();
  }

  /// 页面打开时订阅仓库变更（收尾/清空后静默重载）。
  ///
  /// 变更先攒一个防抖窗口再查：收尾链路会连续广播多条事件，逐条查询会把
  /// 同一份快照重复算多次；窗口内的新事件继续顺延，页面关闭即取消。
  void startWatching() {
    _subscription ??= _repository.changes.listen((_) {
      if (!_loaded) return;
      _watchTimer?.cancel();
      _watchTimer = Timer(watchDebounce, () {
        _watchTimer = null;
        unawaited(_reloadAfterChange());
      });
    });
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
    if (_range == value) return;
    _range = value;
    notifyListeners();
    await _loadNow();
  }

  void setValueMode(PlayStatisticsValueMode value) {
    if (_valueMode == value) return;
    _valueMode = value;
    notifyListeners();
  }

  /// 手动刷新（下拉/重试）：不走防抖，立即查询。
  Future<void> refresh() => _loadNow();

  /// 某一天的播放明细（热力图点按弹层按需加载）。
  Future<DayPlayEvents> loadDay(DateTime day) => _repository.dayEvents(day);

  /// 清空全部统计事件（不可撤销；调用方负责二次确认）。
  Future<void> clearAll() async {
    await _repository.clearAll();
    await _loadNow();
  }

  /// 构建**全量**听歌数据 JSON（汇总 + 榜单 + 最近明细）。
  ///
  /// 只负责取数与序列化；写到哪个目录由页面的 `SaveAs` 决定（桌面可弹
  /// “另存为”，移动端直接写公共下载目录）。
  ///
  /// 时间戳（载荷 `exportedAt` 与文件名）都取已接受窗口的 [window.now]：
  /// 失败 / 过期加载不会推进窗口，导出也就不会用另一次时钟读数。
  /// 尚未有已接受视图时（首次加载失败 / 仍在加载）直接失败，而不是退回墙钟。
  Future<({String json, DateTime exportedAt})> buildExportJson() async {
    final window = _view?.window;
    if (window == null) throw StateError('统计窗口尚未加载，无法导出');
    final results = await Future.wait([
      _repository.summary(),
      _repository.topTracks(limit: 20),
      _repository.topArtists(limit: 20),
      _repository.listenedByDay(),
      _repository.listenedByHour(),
      _repository.sourceDistribution(),
      _repository.listEventsForExport(),
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
    // 手动加载已经拿到最新快照，排队中的自动重载没有意义。
    _watchReloadQueued = false;
    return _load();
  }

  /// 防抖后的自动重载：单飞 + 排队一次。
  ///
  /// 查询未完成时又来变更，只记一个 queued 标记，当前查询结束后再补一次，
  /// 避免并发跑整份聚合；多次变更最终收敛成一次（或两次）查询。
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
        // 一次加载只读一次时钟：查询起点、日历高亮与「今天」必须属于同一窗口，
        // 否则两次读取跨过午夜会出现范围 / 高亮 / 年度入口各说各话。
        final window = ListeningStatisticsWindow(range: _range, now: _clock());
        if (!silent) {
          _loading = true;
          notifyListeners();
        }
        try {
          // 一次快照：查询集合与范围语义都由领域层与仓库承担。
          final snapshot = await _repository.snapshot(since: window.sinceMs);
          if (token != _loadToken) return; // 范围已切换：丢弃过期结果。
          _view = ListeningStatisticsView.from(snapshot, window);
          _loaded = true;
          _failed = false;
        } catch (e) {
          if (token != _loadToken) return;
          _failed = true;
          _logger.severe('加载听歌统计失败', e);
        } finally {
          if (token == _loadToken) {
            _loading = false;
            notifyListeners();
          }
        }
      }, fields: () => {'silent': silent ? 1 : 0});

  @override
  void dispose() {
    stopWatching();
    super.dispose();
  }
}
