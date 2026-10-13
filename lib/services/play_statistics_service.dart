/// 听歌统计采集服务：把播放快照 / 进度 tick 转成 `play_events` 写操作。
///
/// 设计要点：
/// - **纯观察者**：不触碰播放内核（lib/playback），只消费组合根接线的
///   [onSnapshot] / [onPosition]；不 import providers，单测可脚本化驱动。
/// - **真正出声才开事件**：首个 `position > 0` 的 tick 才落库，取链失败
///   （没播起来）不产生事件。
/// - 一次播放尝试 = 一行：切歌 / 播完 / 重播 / 停止收尾并开新行；
///   **暂停不切断**（时长停止累计，恢复后继续）；位置回到开头视为重播。
/// - 落盘节流：tick 驱动（≤4Hz）周期 touch（[touchInterval]），
///   播放态变化与生命周期 flush 立即落盘；进程被杀由启动时
///   `PlayStatisticsRepository.closeStaleEvents()` 收尾为 interrupted。
/// - 所有写操作串行化（[_writes]）：同一微任务内的 start → finish 也能
///   拿到正确的行 id；测试可 await [pendingWrites] 后断言数据库。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/play_statistics_repository.dart';
import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';
import '../domain/models/playback.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/track.dart';

class PlayStatisticsService {
  PlayStatisticsService({
    required PlayStatisticsRepository repository,
    SettingsRegistry? settings,
    DateTime Function()? clock,
  })  : _repository = repository,
        _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys),
        _clock = clock ?? DateTime.now {
    _settings.bindReload(kPlayStatisticsEnabled, reloadFromPreferences);
  }


  /// 进行中事件的周期落盘间隔（tick 驱动，无 Timer）。
  static const Duration touchInterval = Duration(seconds: 15);

  /// 正常前进的单次 tick 最大计入时长；更大的位置跳变视为 seek，不计入。
  static const Duration maxCountedDelta = Duration(seconds: 2);

  /// 位置回到开头的判定线：`< restartThreshold` 且此前已播过
  /// [restartMinPosition] 以上，视为重播（含单曲循环的一遍）。
  static const Duration restartThreshold = Duration(seconds: 1);
  static const Duration restartMinPosition = Duration(seconds: 5);

  final PlayStatisticsRepository _repository;
  final DateTime Function() _clock;
  final Logger _logger = Logger('molia.play_statistics_service');

  final SettingsRegistry _settings;

  /// 采集开关的可监听出口（设置页开关绑定；值随 [init]/[setEnabled] 更新）。
  final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(true);

  /// 串行化所有数据库写入（保证 start → touch → finish 顺序）。
  Future<void> _writes = Future<void>.value();

  /// 待落盘的写入链尾（测试 await 后断言数据库）。
  Future<void> get pendingWrites => _writes;

  bool _enabled = true;
  PlaybackSnapshot _snapshot = PlaybackSnapshot.empty;
  bool _wasPlaying = false;

  Track? _openTrack;
  int? _openEventId;
  Duration _listened = Duration.zero;
  Duration _maxPosition = Duration.zero;
  Duration? _lastTickPosition;
  bool _reachedEnd = false;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);

  /// 采集开关当前值。
  bool get enabled => _enabled;

  /// 读取开关持久值（组合根在接线前调用；失败按默认开启处理）。
  Future<void> init() async {
    try {
      _enabled = await _settings.read(kPlayStatisticsEnabled);
    } catch (e) {
      _logger.severe('读取听歌统计开关失败，按默认开启处理', e);
      _enabled = true;
    }
    enabledNotifier.value = _enabled;
  }

  /// 重新读取采集开关（跨设备同步应用远端设置后由组合根调用）。
  Future<void> reloadFromPreferences() => init();

  /// 设置采集开关：关闭时先收尾进行中的事件（已存数据保留）。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    enabledNotifier.value = value;
    if (!value) {
      _finishOpen(reason: PlayEventEndReason.stopped);
    }
    try {
      await _settings.write(kPlayStatisticsEnabled, value);
    } catch (e) {
      _logger.severe('写入听歌统计开关失败', e);
    }
  }

  // 观察入口（组合根接线）。

  /// 播放快照（曲目 / 播放态 / 错误）变化。
  void onSnapshot(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_enabled) return;
    final track = snapshot.current;
    final playing = snapshot.isPlaying;
    final wasPlaying = _wasPlaying;
    _wasPlaying = playing;

    if (snapshot.error != null) {
      // 播放错误终止：收尾（若错误发生在新曲目装载前，open 事件为空不处理）。
      _finishOpen(reason: PlayEventEndReason.error);
      return;
    }
    if (track == null) {
      _finishOpen(
        reason: _reachedEnd
            ? PlayEventEndReason.completed
            : PlayEventEndReason.stopped,
      );
      return;
    }
    if (_openTrack != null && track.id.uri != _openTrack!.id.uri) {
      // 切歌（手动 / 播完自动下一首）：上一行收尾；新行等首个出声 tick。
      _finishOpen(
        reason: _reachedEnd
            ? PlayEventEndReason.completed
            : PlayEventEndReason.skipped,
      );
      return;
    }
    if (_openTrack != null && !playing && wasPlaying) {
      if (_reachedEnd) {
        // 队列末尾自然结束（isPlaying 落 false，位置停在末尾）。
        _finishOpen(reason: PlayEventEndReason.completed);
      } else {
        // 暂停：不切断事件，落盘当前进度并重置累计基线。
        _touch(force: true);
        _lastTickPosition = null;
      }
    }
  }

  /// 播放进度 tick（≤4Hz）。
  void onPosition(Duration position) {
    if (!_enabled) return;
    final snapshot = _snapshot;
    final track = snapshot.current;
    if (track == null || !snapshot.isPlaying) return;
    if (position <= Duration.zero) {
      _lastTickPosition = null;
      return;
    }

    final duration = snapshot.duration > Duration.zero
        ? snapshot.duration
        : (track.duration ?? Duration.zero);

    // 位置回到开头：重播（含单曲循环的一遍）→ 收尾 + 开新事件。
    if (_openTrack != null &&
        position < restartThreshold &&
        _maxPosition > restartMinPosition) {
      _finishOpen(
        reason: _reachedEnd
            ? PlayEventEndReason.completed
            : PlayEventEndReason.restart,
      );
    }

    if (_openTrack == null) {
      _startEvent(track, duration);
    }

    // 累计收听时长：只在正常前进时计入（seek 跳变不计）。
    final last = _lastTickPosition;
    if (last != null) {
      final delta = position - last;
      if (delta > Duration.zero && delta <= maxCountedDelta) {
        _listened += delta;
      }
    }
    _lastTickPosition = position;
    if (position > _maxPosition) _maxPosition = position;
    if (duration > Duration.zero &&
        _maxPosition >=
            duration -
                const Duration(
                  milliseconds: PlayStatisticsLimits.completionToleranceMs,
                )) {
      _reachedEnd = true;
    }
    _touch();
  }

  /// 立即落盘进行中事件（生命周期 paused / 后台时由组合根调用）。
  void flush() => _touch(force: true);

  void _startEvent(Track track, Duration duration) {
    final now = _clock();
    _openTrack = track;
    _listened = Duration.zero;
    _maxPosition = Duration.zero;
    _reachedEnd = false;
    _lastTouch = now;
    final raw = Map<String, dynamic>.from(track.payload);
    final durationMs = duration > Duration.zero
        ? duration.inMilliseconds
        : track.duration?.inMilliseconds;
    _enqueue(() async {
      _openEventId = await _repository.startEvent(
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
        title: track.title,
        artist: track.artists.map((artist) => artist.name).join(', '),
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: durationMs,
        raw: raw,
        startedAt: now.millisecondsSinceEpoch,
      );
    });
  }

  /// 收尾进行中的事件（同步撤下状态 + 入队写库，顺序由 [_writes] 保证）。
  void _finishOpen({required PlayEventEndReason reason}) {
    if (_openTrack == null) return;
    final listenedMs = _listened.inMilliseconds;
    final maxPositionMs = _maxPosition.inMilliseconds;
    final endedAt = _clock().millisecondsSinceEpoch;
    _openTrack = null;
    _lastTickPosition = null;
    _listened = Duration.zero;
    _maxPosition = Duration.zero;
    _reachedEnd = false;
    _enqueue(() async {
      final id = _openEventId;
      _openEventId = null;
      if (id == null) return;
      await _repository.finishEvent(
        id,
        reason: reason,
        listenedMs: listenedMs,
        maxPositionMs: maxPositionMs,
        endedAt: endedAt,
      );
    });
  }

  /// 进行中事件的进度落盘（默认按 [touchInterval] 节流）。
  void _touch({bool force = false}) {
    if (_openTrack == null) return;
    final now = _clock();
    if (!force && now.difference(_lastTouch) < touchInterval) return;
    _lastTouch = now;
    final listenedMs = _listened.inMilliseconds;
    final maxPositionMs = _maxPosition.inMilliseconds;
    _enqueue(() async {
      final id = _openEventId;
      if (id == null) return;
      await _repository.touchEvent(
        id,
        listenedMs: listenedMs,
        maxPositionMs: maxPositionMs,
      );
    });
  }

  /// 数据库写入串行化：一次失败只记日志，不影响后续写入与播放主流程。
  void _enqueue(Future<void> Function() action) {
    _writes = _writes.then((_) => action()).catchError(
      (Object error, StackTrace stackTrace) {
        _logger.severe('听歌统计写入失败', error, stackTrace);
      },
    );
  }
}
