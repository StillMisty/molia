/// 听歌统计页状态：范围切换、数据加载、清空与导出。
///
/// 纯数据状态（不持有播放/资料库）：播放动作由页面经
/// `LibraryProvider.sourceTrackFromRaw` + `PlaybackProvider` 完成。
/// 页面打开期间订阅仓库 [PlayStatisticsRepository.changes]（收尾/清空后
/// 静默重载）；页面关闭后取消订阅，避免播放中每个切歌都触发全量查询。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/play_statistics_repository.dart';
import '../domain/models/play_statistics.dart';
import '../services/play_statistics_export.dart';

/// 热力图的取值维度。
enum PlayStatisticsValueMode { duration, count }

class PlayStatisticsProvider extends ChangeNotifier {
  PlayStatisticsProvider({required PlayStatisticsRepository repository})
      : _repository = repository;

  final PlayStatisticsRepository _repository;
  final Logger _logger = Logger('molia.play_statistics_provider');
  StreamSubscription<void>? _subscription;

  PlayStatisticsRange _range = PlayStatisticsRange.month;
  PlayStatisticsValueMode _valueMode = PlayStatisticsValueMode.duration;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  int _loadToken = 0;

  /// 最近一次加载完成的聚合快照（null = 尚未加载）。
  ListeningStatisticsSnapshot? _snapshot;

  PlayStatisticsRange get range => _range;
  PlayStatisticsValueMode get valueMode => _valueMode;
  bool get isLoading => _loading;
  bool get hasLoaded => _loaded;
  bool get hasError => _failed;
  /// 聚合快照（汇总 / 榜单 / 日历 / 作息热力图 / 来源分布一次取回）。
  ListeningStatisticsSnapshot? get snapshot => _snapshot;

  /// 范围内没有任何已收尾事件（加载完成的前提下）。
  bool get isEmpty =>
      _loaded && !_loading && (_snapshot?.summary.playCount ?? 0) == 0;

  /// 范围起点（本地时间；`null` = 全部）。热力图高亮与查询共用同一窗口。
  DateTime? get rangeStart => _range.startOf(DateTime.now());

  int? get _since => _range.sinceMs(DateTime.now());

  /// 首次打开页面时调用（已加载过则跳过）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await _load();
  }

  /// 页面打开时订阅仓库变更（收尾/清空后静默重载）。
  void startWatching() {
    _subscription ??= _repository.changes.listen((_) {
      if (_loaded) unawaited(_load(silent: true));
    });
  }

  /// 页面关闭时取消订阅。
  void stopWatching() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> setRange(PlayStatisticsRange value) async {
    if (_range == value) return;
    _range = value;
    notifyListeners();
    await _load();
  }

  void setValueMode(PlayStatisticsValueMode value) {
    if (_valueMode == value) return;
    _valueMode = value;
    notifyListeners();
  }

  /// 手动刷新（下拉/重试）。
  Future<void> refresh() => _load();

  /// 某一天的播放明细（热力图点按弹层按需加载）。
  Future<DayPlayEvents> loadDay(DateTime day) => _repository.dayEvents(day);

  /// 清空全部统计事件（不可撤销；调用方负责二次确认）。
  Future<void> clearAll() async {
    await _repository.clearAll();
    await _load();
  }

  /// 导出**全量**听歌数据 JSON 并分享（汇总 + 榜单 + 最近明细）。
  Future<bool> export() async {
    try {
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
        exportedAt: DateTime.now(),
      );
      const jsonEncoder = JsonEncoder.withIndent('  ');
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/molia_listening_$timestamp.json';
      await File(filePath).writeAsString(jsonEncoder.convert(payload));
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath, mimeType: 'application/json')],
          subject: 'Molia Listening Stats $timestamp',
        ),
      );
      return result.status == ShareResultStatus.success;
    } catch (e) {
      _logger.fine('导出听歌数据失败: $e');
      return false;
    }
  }

  Future<void> _load({bool silent = false}) async {
    final token = ++_loadToken;
    if (!silent) {
      _loading = true;
      notifyListeners();
    }
    try {
      // 一次快照：查询集合与范围语义都由领域层与仓库承担。
      final snapshot = await _repository.snapshot(since: _since);
      if (token != _loadToken) return; // 范围已切换：丢弃过期结果。
      _snapshot = snapshot;
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
  }

  @override
  void dispose() {
    stopWatching();
    super.dispose();
  }
}
