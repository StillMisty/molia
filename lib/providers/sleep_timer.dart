import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../domain/models/playback.dart';
import '../domain/ports/state_listenable.dart';

final _logger = Logger('molia.sleep_timer');

/// 定时关闭模式。
enum SleepTimerMode {
  /// 未开启。
  off,

  /// 倒计时（仅播放时计时）：到点暂停。
  countdown,

  /// 播完当前歌曲后暂停。
  afterCurrentTrack,
}

/// 定时关闭状态（值变才发）。
///
/// 每秒变化的 [remaining] 只走 [SleepTimerController.state] 这个值通道，
/// 不进任何聚合 `notifyListeners`（架构硬约束：高频数值不进聚合通知）。
@immutable
class SleepTimerState {
  const SleepTimerState({required this.mode, this.remaining, this.duration});

  /// 未开启。
  static const SleepTimerState off = SleepTimerState(mode: SleepTimerMode.off);

  final SleepTimerMode mode;

  /// 剩余播放时长（仅倒计时模式非空；暂停期间冻结）。
  final Duration? remaining;

  /// 武装时的启动时长（仅倒计时非空）：档位 chip 选中态用；取消 / 到点归零。
  ///
  /// 与每秒变化的 [remaining] 同通道发布，但只在武装 / 取消时改变。
  final Duration? duration;

  bool get isActive => mode != SleepTimerMode.off;

  @override
  bool operator ==(Object other) =>
      other is SleepTimerState &&
      other.mode == mode &&
      other.remaining == remaining &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(mode, remaining, duration);

  @override
  String toString() =>
      'SleepTimerState(mode: $mode, remaining: $remaining, duration: $duration)';
}

/// 定时关闭控制器：只决定「什么时候暂停」，暂停动作经注入的 [onFire] 落地
/// （组合根注入 `facade.pause`，测试注入记录型回调）。
///
/// 语义：
/// - **倒计时**：仅播放时计时（暂停冻结、恢复继续）；剩余时间按 `now()`
///   差值累计（进程被系统冻结/doze 不丢时间），每秒变化走 [state] 值通道；
/// - **播完当前歌曲**：纯事件驱动、无定时器——曲目自然播完（切歌前位置已
///   到曲末）到点；手动切歌 / 自动换源替换跟随新曲目重新武装；单曲循环
///   没有曲目切换，用「位置从曲末回跳」兜底。
///
/// 判定用的快照 / 进度必须是**真实播放**的通道（facade），不能用恢复态
/// 覆盖值：冷启动未起播时没有可等待的曲目。
class SleepTimerController implements ValueListenable<SleepTimerState> {
  SleepTimerController({
    required StateListenable<PlaybackSnapshot> snapshot,
    required StateListenable<Duration> position,
    required Future<void> Function() onFire,
    DateTime Function() now = DateTime.now,
  })  : _snapshot = snapshot,
        _position = position,
        _onFire = onFire,
        _now = now {
    _snapshot.addListener(_onSnapshot);
    _position.addListener(_onPosition);
    _lastKnownDuration = snapshot.value.duration;
    _maxPosition = position.value;
  }

  /// 「自然播完」的位置容差：进度通道 ≤4Hz（阈值 250ms），留出富余；
  /// 时长未知或短于容差时不判定（宁可不暂停，也不误暂停）。
  static const Duration _completionTolerance = Duration(seconds: 2);

  /// 单曲循环判定：位置从曲末回跳到小于该间隔视为重播。
  static const Duration _restartGap = Duration(seconds: 5);

  /// 倒计时 tick 周期（剩余时间按 `now()` 差值累计，不依赖 tick 精度）。
  static const Duration _tickInterval = Duration(seconds: 1);

  final StateListenable<PlaybackSnapshot> _snapshot;
  final StateListenable<Duration> _position;
  final Future<void> Function() _onFire;
  final DateTime Function() _now;

  final ValueNotifier<SleepTimerState> _state =
      ValueNotifier<SleepTimerState>(SleepTimerState.off);

  SleepTimerMode _mode = SleepTimerMode.off;
  Duration? _remaining;

  /// 武装时的启动时长（仅倒计时非空）；chip 选中态用。
  Duration? _duration;
  Timer? _ticker;
  DateTime? _lastTickAt;

  /// 武装的曲目 uri（播完当前歌曲模式）。
  String? _armedTrackUri;

  /// 武装曲目观测到的最大进度：曲目切换时进度通道会先对齐到新曲目（≈0），
  /// 取最大值才不会被清零（自然播完判定 + 单曲循环判定共用）。
  Duration _maxPosition = Duration.zero;

  /// 上一次快照事件的时长：切歌事件的快照已带新曲目时长，用它保留
  /// 「刚播完那首」的时长（下一次事件才覆盖）。
  Duration _lastKnownDuration = Duration.zero;

  /// 当前是否具备「播完当前歌曲」条件（真实播放已装载曲目）。
  bool get canArmAfterCurrentTrack => _snapshot.value.current != null;

  @override
  SleepTimerState get value => _state.value;

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  /// 开启倒计时（到点暂停）。重复调用覆盖旧定时。
  void startCountdown(Duration duration) {
    if (duration <= Duration.zero) return;
    _mode = SleepTimerMode.countdown;
    _armedTrackUri = null;
    _duration = duration;
    _remaining = duration;
    _cancelTicker();
    _syncTicker();
    _publish();
  }

  /// 开启「播完当前歌曲后暂停」；无真实播放曲目时为无操作。
  void startAfterCurrentTrack() {
    final uri = _snapshot.value.current?.id.uri;
    if (uri == null) return;
    _mode = SleepTimerMode.afterCurrentTrack;
    _armedTrackUri = uri;
    _duration = null;
    _remaining = null;
    _cancelTicker();
    _maxPosition = _position.value;
    _publish();
  }

  /// 撤销定时（未开启时为无操作）。
  void cancel() {
    if (_mode == SleepTimerMode.off) return;
    _reset(notify: true);
  }

  void dispose() {
    _snapshot.removeListener(_onSnapshot);
    _position.removeListener(_onPosition);
    _cancelTicker();
    _state.dispose();
  }

  void _onSnapshot() {
    final snapshot = _snapshot.value;
    switch (_mode) {
      case SleepTimerMode.off:
        break;
      case SleepTimerMode.countdown:
        // 播放/暂停切换：倒计时只在播放中走。
        _syncTicker();
      case SleepTimerMode.afterCurrentTrack:
        _handleAfterTrackSnapshot(snapshot);
    }
    _lastKnownDuration = snapshot.duration;
  }

  void _onPosition() {
    final position = _position.value;
    if (_mode == SleepTimerMode.afterCurrentTrack &&
        _completedArmedTrack &&
        position + _restartGap < _maxPosition) {
      // 单曲循环：曲目没换，位置从曲末回跳 = 已播完一轮。
      _fire();
      return;
    }
    if (position > _maxPosition) _maxPosition = position;
  }

  void _handleAfterTrackSnapshot(PlaybackSnapshot snapshot) {
    final uri = snapshot.current?.id.uri;
    if (uri == null) {
      // 队列被清空 / 播放停止：没有可等待的曲目。
      _reset(notify: true);
      return;
    }
    if (uri != _armedTrackUri) {
      if (_completedArmedTrack) {
        // 自然播完（下一首已装载）：到点暂停。
        _fire();
        return;
      }
      // 手动切歌 / 自动换源替换：跟随新曲目继续等待「这一首播完」。
      _armedTrackUri = uri;
      _maxPosition = _position.value;
      return;
    }
    if (!snapshot.isPlaying && _completedArmedTrack) {
      // 队列自然播完（最后一首结束）：没有下一首要暂停，撤销定时。
      _reset(notify: true);
    }
  }

  /// 武装曲目是否已播到曲末。
  bool get _completedArmedTrack {
    final duration = _lastKnownDuration;
    if (duration <= _completionTolerance) return false;
    return _maxPosition >= duration - _completionTolerance;
  }

  /// 倒计时 ticker：只在播放中运行（暂停冻结，也不空转唤醒）。
  void _syncTicker() {
    if (_mode != SleepTimerMode.countdown || !_snapshot.value.isPlaying) {
      _cancelTicker();
      return;
    }
    if (_ticker != null) return;
    _lastTickAt = _now();
    _ticker = Timer.periodic(_tickInterval, (_) => _onTick());
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
    _lastTickAt = null;
  }

  void _onTick() {
    if (!_snapshot.value.isPlaying) {
      _syncTicker();
      return;
    }
    final now = _now();
    final last = _lastTickAt;
    _lastTickAt = now;
    final remaining = _remaining;
    if (last == null || remaining == null) return;
    final next = remaining - now.difference(last);
    if (next <= Duration.zero) {
      _fire();
      return;
    }
    _remaining = next;
    _publish();
  }

  /// 到点：先回 off（onFire 期间状态不应还显示开启），再执行暂停。
  void _fire() {
    _reset(notify: true);
    unawaited(Future<void>.sync(_onFire).catchError((Object e) {
      _logger.warning('定时关闭到点暂停失败: $e');
    }));
  }

  void _reset({required bool notify}) {
    _mode = SleepTimerMode.off;
    _remaining = null;
    _duration = null;
    _armedTrackUri = null;
    _cancelTicker();
    if (notify) _publish();
  }

  void _publish() => _state.value = SleepTimerState(
        mode: _mode,
        remaining: _remaining,
        duration: _duration,
      );
}
