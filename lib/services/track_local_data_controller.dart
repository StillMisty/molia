/// 单曲本地数据的刷新控制器：把「加载 [TrackLocalData] + 跟着下载记录 /
/// 缓存修订重算」的时序收敛到一处，供播放页信息 tab 与「本地数据」页共用。
///
/// 为什么需要这层：两个消费面原本各写了一套监听 / 防抖 / 单飞逻辑，其中
/// 「本地数据」页会并发发起目录扫描，也没有切歌后的过期结果守卫。刷新规则
/// 一旦分叉，同一首歌在信息行与页内就会出现不同的「已下载 / 已缓存」结论。
///
/// 三条时序规则（唯一实现）：
/// - **下载记录变化**：防抖（默认 300ms）合并同批通知——一次重算要递归列举
///   音频缓存目录并逐文件统计，下载完成 / 删除 / 分项落库连着来时不值得每
///   条都扫一遍；任务进度不经过记录模块，不会触发这里；
/// - **缓存修订变化**（[CacheService.revision]）：立即重载，并撤销待执行的
///   防抖（清理 / LRU / 边播边缓存落成要立刻可见）；
/// - **加载单飞 + 尾随一次**：加载进行中再收到请求只记一个标记，当前加载
///   结束后按最新曲目补跑一次，绝不并发扫描。
///
/// 切歌 / 封面变化时同步暴露 [TrackLocalDataService.downloadState] 作为种子
/// （下载记录在内存里，同步可读），避免首帧把「已下载」闪成「未下载」；在途
/// 结果按曲目代次丢弃，旧曲目永远不会覆盖新曲目的状态。
///
/// 读模型仍是 [TrackLocalDataService]：本控制器只负责「什么时候读、读到的
/// 结果要不要采纳」，不搬运任何存储判据。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/track.dart';
import 'cache_service.dart';
import 'download/download_records.dart';
import 'track_local_data_service.dart';

/// 取消一次待触发的延时回调。
typedef TrackLocalDataTimerCancel = void Function();

/// 延时调度工厂：测试注入假实现，按虚拟时间结算下载记录防抖窗口。
typedef TrackLocalDataTimerFactory = TrackLocalDataTimerCancel Function(
  Duration delay,
  VoidCallback callback,
);

/// 本地数据页的下载音质选择顺序（纯函数，UI 与测试共用）。
///
/// 顺序：显式选择 → 已下载记录的音质 → 第一条命中完整的缓存音质 → 下载
/// 偏好音质 → 曲目第一个可用音质；都没有返回空串。显式 / 已下载 / 偏好
/// 的空串按「未设置」处理；缓存命中优先于偏好，是为了让「已缓存」的曲目
/// 默认转存它真正命中的那一档，而不是偏好里另一档（那会触发一次联网下载）。
String selectLocalDataQuality({
  String? explicitChoice,
  String downloadedQuality = '',
  Iterable<String> cachedQualities = const <String>[],
  String preferredQuality = '',
  Iterable<String> availableQualities = const <String>[],
}) {
  if (explicitChoice != null && explicitChoice.isNotEmpty) {
    return explicitChoice;
  }
  if (downloadedQuality.isNotEmpty) return downloadedQuality;
  // 与旧页面口径一致：命中列表非空就取第一条，不再二次过滤。
  if (cachedQualities.isNotEmpty) return cachedQualities.first;
  if (preferredQuality.isNotEmpty) return preferredQuality;
  if (availableQualities.isNotEmpty) return availableQualities.first;
  return '';
}

/// 控制器发布给页面的不可变状态。
@immutable
class TrackLocalDataState {
  const TrackLocalDataState({this.data, this.audioEnabled = true});

  /// 空态（没有当前曲目 / 服务不可用）。
  static const TrackLocalDataState empty = TrackLocalDataState();

  /// 当前曲目的本地数据；尚未加载完成时可能只有下载档种子，没有当前曲目
  /// 或服务不可用时为 null。
  final TrackLocalData? data;

  /// 音频缓存开关（「未下载」时解释原因用）。
  final bool audioEnabled;

  @override
  bool operator ==(Object other) =>
      other is TrackLocalDataState &&
      identical(other.data, data) &&
      other.audioEnabled == audioEnabled;

  @override
  int get hashCode => Object.hash(data, audioEnabled);

  @override
  String toString() =>
      'TrackLocalDataState(data: $data, audioEnabled: $audioEnabled)';
}

/// 单曲本地数据刷新控制器：监听、防抖、单飞与代次守卫的唯一实现。
///
/// 消费方只做三件事：`setTrack(当前曲目)`、读 [value]、[dispose]。
class TrackLocalDataController implements ValueListenable<TrackLocalDataState> {
  TrackLocalDataController({
    required this._service,
    required this._cacheService,
    this._downloadRecords,
    this.recordsDebounce = const Duration(milliseconds: 300),
    TrackLocalDataTimerFactory? timerFactory,
  }) : _startTimer = timerFactory ?? _defaultTimerFactory {
    _downloadRecords?.addListener(_onDownloadRecordsChanged);
    _cacheService.revision.addListener(_onCacheRevisionChanged);
  }

  final TrackLocalDataService? _service;
  final CacheService _cacheService;
  final DownloadRecords? _downloadRecords;

  /// 下载记录防抖窗口。
  final Duration recordsDebounce;
  final TrackLocalDataTimerFactory _startTimer;

  final ValueNotifier<TrackLocalDataState> _state =
      ValueNotifier<TrackLocalDataState>(TrackLocalDataState.empty);

  Track? _track;

  /// 当前本地数据对应的封面地址（封面补取回写会换 URL，同一曲目也要重算）。
  String? _artwork;

  /// 曲目代次：切歌 / 封面变化都自增；在途结果只回填同代次的状态。
  int _generation = 0;

  TrackLocalDataTimerCancel? _debounce;
  bool _loading = false;
  bool _queued = false;
  Completer<void>? _trailing;
  bool _disposed = false;

  @override
  TrackLocalDataState get value => _state.value;

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  /// 切换当前曲目（null = 没有当前曲目）。
  ///
  /// 曲目 id 与封面地址都没变时是空操作（播放进度通知很频繁，不能每次都
  /// 扫目录）。变化时立即发布下载档同步种子并马上发起一次重载，同时撤销
  /// 待执行的记录防抖——切歌要立刻看到新曲目的状态。
  void setTrack(Track? track) {
    if (_disposed) return;
    final artwork = track?.artwork?.uri.toString();
    if (_track?.id == track?.id && _artwork == artwork) return;

    _generation++;
    _cancelDebounce();
    _track = track;
    _artwork = artwork;
    if (track == null) {
      _publish(TrackLocalDataState(audioEnabled: _audioEnabled));
      return;
    }
    _publish(
      TrackLocalDataState(
        data: _service?.downloadState(track),
        audioEnabled: _audioEnabled,
      ),
    );
    unawaited(_requestReload());
  }

  /// 立即重载当前曲目（动作完成后的显式刷新）。
  ///
  /// 返回的 future 在本次请求被满足（含排队等待的在途加载与尾随重载）后
  /// 完成，供页面在清理 / 删除后等待新状态落地。
  Future<void> refreshNow() {
    if (_disposed) return Future<void>.value();
    _cancelDebounce();
    return _requestReload();
  }

  bool get _audioEnabled => _state.value.audioEnabled;

  /// 下载记录变化：防抖后重算。没有当前曲目时不排定时器。
  void _onDownloadRecordsChanged() {
    if (_disposed || _track == null) return;
    _cancelDebounce();
    _debounce = _startTimer(recordsDebounce, () {
      _debounce = null;
      if (_disposed) return;
      unawaited(_requestReload());
    });
  }

  /// 缓存修订等即时变化：撤销防抖，立即重算。
  void _onCacheRevisionChanged() {
    if (_disposed) return;
    _cancelDebounce();
    unawaited(_requestReload());
  }

  /// 加载单飞 + 尾随一次：加载中只记标记，结束后按最新曲目补跑。
  Future<void> _requestReload() {
    if (_disposed || _track == null) return Future<void>.value();
    if (_loading) {
      _queued = true;
      return (_trailing ??= Completer<void>()).future;
    }
    return _drain();
  }

  Future<void> _drain() async {
    _loading = true;
    try {
      do {
        _queued = false;
        if (_disposed) break;
        final track = _track;
        if (track == null) break;
        await _load(track, _generation);
      } while (_queued && !_disposed);
    } finally {
      _loading = false;
      final trailing = _trailing;
      _trailing = null;
      if (trailing != null && !trailing.isCompleted) trailing.complete();
    }
  }

  Future<void> _load(Track track, int generation) async {
    final service = _service;
    if (service == null) return;
    try {
      final results = await Future.wait<Object?>([
        service.load(track),
        _cacheService.audioEnabled(),
      ]);
      if (!_isCurrent(track, generation)) return;
      _publish(
        TrackLocalDataState(
          data: results[0] as TrackLocalData,
          audioEnabled: results[1] as bool,
        ),
      );
    } catch (_) {
      // 占用查询失败按「无缓存」呈现；清理动作本身仍可尝试。
      if (!_isCurrent(track, generation)) return;
      _publish(
        TrackLocalDataState(
          data: service.downloadState(track),
          audioEnabled: _audioEnabled,
        ),
      );
    }
  }

  /// 结果归属守卫：同一代次且曲目 id 未变才允许回填。
  bool _isCurrent(Track track, int generation) =>
      !_disposed && generation == _generation && _track?.id == track.id;

  void _publish(TrackLocalDataState next) {
    if (_state.value == next) return;
    _state.value = next;
  }

  void _cancelDebounce() {
    _debounce?.call();
    _debounce = null;
  }

  /// 退订记录 / 缓存修订、撤销防抖并作废在途结果（重复调用幂等）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelDebounce();
    _downloadRecords?.removeListener(_onDownloadRecordsChanged);
    _cacheService.revision.removeListener(_onCacheRevisionChanged);
    final trailing = _trailing;
    _trailing = null;
    if (trailing != null && !trailing.isCompleted) trailing.complete();
    _state.dispose();
  }

  static TrackLocalDataTimerCancel _defaultTimerFactory(
    Duration delay,
    VoidCallback callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }
}
