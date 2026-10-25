import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/state_listenable.dart';
import '../services/sleep_timer_alarm.dart';

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
/// （组合根注入播放命令面的 `pause`，测试注入记录型回调）。
///
/// 语义：
/// - **倒计时**：仅播放时计时（暂停冻结、恢复继续）；剩余时间按 `now()`
///   绝对时刻累计（进程被系统冻结/doze 不丢时间），每秒变化走 [state] 值通道；
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
    required this._onFire,
    this._now = DateTime.now,
    SleepTimerAlarm? alarm,
    Stream<Track>? trackCompletions,
    this._setStopAfterCurrentTrack,
  })  : _snapshot = snapshot,
        _position = position {
    // 原生定时器是熄屏 / Doze 的补触发通道；平台不支持时是 no-op，纯 Dart
    // ticker 仍按原语义工作。
    _alarm = alarm ?? createSleepTimerAlarm();
    _alarm.onFired = _onNativeAlarm;
    // 曲目自然播完事件：熄屏时位置流可能停更，「播完当前歌曲」靠它判定曲末。
    _completionSubscription = trackCompletions?.listen(_onTrackCompleted);
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

  /// 倒计时 tick 周期（tick 只负责刷新剩余时间，到点判定看绝对 deadline）。
  static const Duration _tickInterval = Duration(seconds: 1);

  final StateListenable<PlaybackSnapshot> _snapshot;
  final StateListenable<Duration> _position;
  final Future<void> Function() _onFire;
  final DateTime Function() _now;
  late final SleepTimerAlarm _alarm;

  /// 后端「当前曲目自然播完」事件；null = 后端不支持（走位置回退）。
  StreamSubscription<Track>? _completionSubscription;

  /// 把「播完当前歌曲」停止标志下发给播放后端（null = 测试 / 旧宿主）。
  final void Function(bool enabled)? _setStopAfterCurrentTrack;

  /// 原生定时器代次：覆盖 / 取消时自增，旧回调直接丢弃。
  int _alarmToken = 0;

  final ValueNotifier<SleepTimerState> _state =
      ValueNotifier<SleepTimerState>(SleepTimerState.off);

  SleepTimerMode _mode = SleepTimerMode.off;
  Duration? _remaining;

  /// 武装时的启动时长（仅倒计时非空）；chip 选中态用。
  Duration? _duration;

  /// 到点时刻（绝对时间；仅「倒计时 + 播放中」非空，暂停时折算回 [_remaining]）。
  ///
  /// 为什么是绝对时刻而不是「每次 tick 减一个周期」：熄屏 / 后台时系统会给
  /// Dart 定时器合帧、节流，甚至整段冻结进程（Doze），tick 的**次数**不可信；
  /// 只有「到点时刻 + 每个 tick 先比较」才保证任何一次获得调度的机会
  /// （tick、快照事件、回到前台）都能立即补触发，最多晚到「下一次被调度」。
  DateTime? _deadlineAt;

  Timer? _ticker;

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
    // 与「播完当前歌曲」互斥：切到倒计时时撤销后端的停止标志。
    _setStopAfterCurrentTrack?.call(false);
    _mode = SleepTimerMode.countdown;
    _armedTrackUri = null;
    _duration = duration;
    _remaining = duration;
    // 覆盖旧定时：旧 deadline 必须先失效，否则 _syncTicker 会按它立刻到点。
    _deadlineAt = null;
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
    // 后端在自然播完时停住，不自动切下一首；完成事件负责复位定时。
    _setStopAfterCurrentTrack?.call(true);
    _duration = null;
    _remaining = null;
    _deadlineAt = null;
    _cancelTicker();
    _cancelAlarm();
    _maxPosition = _position.value;
    _publish();
  }

  /// 撤销定时（未开启时为无操作）。
  void cancel() {
    if (_mode == SleepTimerMode.off) return;
    _reset(notify: true);
  }

  void dispose() {
    _completionSubscription?.cancel();
    _completionSubscription = null;
    _setStopAfterCurrentTrack?.call(false);
    _snapshot.removeListener(_onSnapshot);
    _position.removeListener(_onPosition);
    _cancelTicker();
    _alarm.dispose();
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

  /// 后端报告当前曲目自然播完。
  ///
  /// 不能等位置通道走到曲末：熄屏 / 后台时它可能整段停更，而播放器仍会
  /// 继续播放并完成曲目；此时若靠「曲目变了」判断，会被误认为手动切歌，
  /// 把定时重新武装到下一首。
  void _onTrackCompleted(Track _) {
    if (_mode != SleepTimerMode.afterCurrentTrack) return;
    _fire();
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

  /// 应用回到前台（生命周期 resumed）时的补检，由 [SleepTimerLifecycleRecheck]
  /// 在组合根挂接。
  ///
  /// 熄屏 / 后台时 tick 可能被系统节流甚至整段冻结（Doze），回前台的第一件事
  /// 就是按绝对 deadline 补触发，避免「亮屏才发现还在播」。
  void recheckDeadline() {
    if (_mode != SleepTimerMode.countdown) return;
    _syncTicker();
  }

  /// 倒计时 ticker 同步：播放中（重新）武装绝对 deadline，非播放时冻结剩余。
  ///
  /// 每个触发源（tick、快照变化、[recheckDeadline]）都先做一次 deadline 判定，
  /// tick 迟到 / 整段丢失因此都不影响到点时机。
  void _syncTicker() {
    if (_mode != SleepTimerMode.countdown) {
      _cancelTicker();
      _cancelAlarm();
      return;
    }
    if (!_snapshot.value.isPlaying) {
      // 暂停 / 停止：冻结剩余播放时长（暂停期间不计时），原生定时器一并撤销，
      // 避免熄屏时原生到点误暂停。
      final expired = _freeze();
      _cancelTicker();
      _cancelAlarm();
      if (expired) _fire();
      return;
    }
    if (_deadlinePassed) {
      // 已经越过 deadline（冻结期间到点后重新获得调度）：立即补触发。
      _fire();
      return;
    }
    if (_ticker == null) {
      final remaining = _remaining;
      if (remaining == null) return;
      _deadlineAt = _now().add(remaining);
      _ticker = Timer.periodic(_tickInterval, (_) => _onTick());
    }
    // 即使 Dart ticker 已在跑，也重新 arm 原生定时器：通道重建 / 回前台 /
    // 快照变化后都能恢复熄屏补触发。
    _armAlarm();
  }

  /// 武装原生定时器（每次 arm 递增 token，旧回调自动失效）。
  void _armAlarm() {
    final deadline = _deadlineAt;
    if (deadline == null) return;
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero) {
      _fire();
      return;
    }
    _alarmToken++;
    _alarm.arm(remaining, _alarmToken);
  }

  void _cancelAlarm() {
    _alarmToken++;
    _alarm.cancel();
  }

  /// 原生定时器到点：校验代次与 deadline，早到重排、到点暂停。
  void _onNativeAlarm(int token) {
    if (_mode != SleepTimerMode.countdown || token != _alarmToken) return;
    if (!_snapshot.value.isPlaying) {
      _syncTicker();
      return;
    }
    if (!_deadlinePassed) {
      _armAlarm();
      return;
    }
    _fire();
  }

  /// 把绝对 deadline 折算成剩余播放时长（暂停冻结），并清除 deadline。
  ///
  /// 返回 true 表示播放期间 deadline 已经越过（冻结时才发现）——剩余时长已
  /// 耗尽，调用方立即到点。
  bool _freeze() {
    final deadline = _deadlineAt;
    if (deadline == null) return false;
    _deadlineAt = null;
    final left = deadline.difference(_now());
    if (left <= Duration.zero) {
      _remaining = Duration.zero;
      return true;
    }
    _remaining = left;
    // 冻结值精确到 now：暂停时刻落在两次 tick 之间时，剩余时间按真实差值走
    // （旧值最多偏一个 tick）。
    _publish();
    return false;
  }

  /// deadline 是否已越过（未武装时为 false）。
  bool get _deadlinePassed {
    final deadline = _deadlineAt;
    return deadline != null && !_now().isBefore(deadline);
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _onTick() {
    if (_mode != SleepTimerMode.countdown) return;
    if (!_snapshot.value.isPlaying) {
      _syncTicker();
      return;
    }
    final deadline = _deadlineAt;
    if (deadline == null) return;
    final now = _now();
    if (!now.isBefore(deadline)) {
      // tick 迟到（合帧 / 冻结后的首个回调）同样算到点：不等下一次 tick。
      _fire();
      return;
    }
    _remaining = deadline.difference(now);
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
    _setStopAfterCurrentTrack?.call(false);
    _mode = SleepTimerMode.off;
    _remaining = null;
    _duration = null;
    _armedTrackUri = null;
    _deadlineAt = null;
    _cancelTicker();
    _cancelAlarm();
    if (notify) _publish();
  }

  void _publish() => _state.value = SleepTimerState(
        mode: _mode,
        remaining: _remaining,
        duration: _duration,
      );
}

/// 定时关闭 × 应用生命周期：回到前台时按绝对 deadline 补检定时关闭。
///
/// 为什么需要：熄屏 / 后台时系统可能把 Dart `Timer.periodic` 节流（定时器
/// 合帧）甚至整段冻结进程（Doze），1Hz tick 不保证准时；只靠 tick 会出现
/// 「到点没暂停」。回到前台补检一次，把「到点暂停」的迟到上限压到
/// 「下一次获得调度」。
class SleepTimerLifecycleRecheck {
  SleepTimerLifecycleRecheck(this._timer);

  final SleepTimerController _timer;
  AppLifecycleListener? _listener;

  /// 挂接（幂等；组合根在 provider 建好后调用一次，App 生命周期内有效）。
  void attach() {
    _listener ??= AppLifecycleListener(onResume: _timer.recheckDeadline);
  }

  /// 解挂（测试 / 非常规宿主用）。
  void detach() {
    _listener?.dispose();
    _listener = null;
  }
}
