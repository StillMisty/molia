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

  /// 等当前曲目自然播完再暂停（倒计时到点后的等待阶段也用它）。
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

  /// 武装时的启动时长（倒计时非空；到点后进入「等本曲播完」时保留）。
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
    this._onExit,
    this._now = DateTime.now,
    SleepTimerAlarm? alarm,
    Stream<Track>? trackCompletions,
    this._setStopAfterCurrentTrack,
    // 定时只负责「什么时候开始 / 撤销淡出」；音频动作全部交给命令面注入的
    // 回调，定时器自己不碰播放器。
    this._onFadeStart,
    this._onFadeCancel,
    bool Function()? isForeground,
    bool exitAppByDefault = false,
    bool waitForTrackEndByDefault = false,
  }) : exitApp = ValueNotifier<bool>(exitAppByDefault),
       waitForTrackEnd = ValueNotifier<bool>(waitForTrackEndByDefault),
       _snapshot = snapshot,
       _position = position,
       _isForeground = isForeground ?? _alwaysForeground {
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

  /// 倒计时最后几秒开始淡出：先降音量，到点再停。
  static const Duration _countdownFadeWindow = Duration(seconds: 5);

  /// 剩余时间短于可听窗口时不做补淡：直接到点暂停。
  static const Duration _countdownMinFade = Duration(milliseconds: 300);

  /// 「播完当前歌曲」的淡出窗口（实时位置可靠时）。
  static const Duration _endFadeWindow = Duration(seconds: 3);

  /// 位置通道多久没更新算「不新鲜」：熄屏节流后不拿旧进度赌曲末。
  static const Duration _positionFreshness = Duration(milliseconds: 2500);

  final StateListenable<PlaybackSnapshot> _snapshot;
  final StateListenable<Duration> _position;
  final Future<void> Function() _onFire;

  /// 开始一次专用淡出（与普通淡入淡出设置无关）。
  final void Function(Duration duration)? _onFadeStart;

  /// 撤销淡出；[restore] = true 回到用户音量，false 保持当前电平等暂停。
  final void Function({required bool restore})? _onFadeCancel;

  /// 到点暂停落地后，若勾选了「退出应用」，再执行这里。
  ///
  /// 只注入平台无关的退出动作；会话落盘 / 音频收尾由组合根的统一退出路径
  /// （`buildDesktopStack` 的 `quitApp`）负责。
  final Future<void> Function()? _onExit;

  final DateTime Function() _now;
  late final SleepTimerAlarm _alarm;

  /// 后端「当前曲目自然播完」事件；null = 后端不支持（走位置回退）。
  StreamSubscription<Track>? _completionSubscription;

  /// 把「播完当前歌曲」停止标志下发给播放后端（null = 测试 / 旧宿主）。
  final void Function(bool enabled)? _setStopAfterCurrentTrack;

  /// 应用是否在前台：原生定时的 wake lock 只在后台 / 息屏时持有。
  ///
  /// 前台屏幕亮着，Handler 不会被 Doze 冻结，长期持有 partial wake lock
  /// 只会白耗电（一小时的定时关闭就是一小时不让 CPU 深睡）。
  final bool Function() _isForeground;

  static bool _alwaysForeground() => true;

  /// 原生定时器代次：覆盖 / 取消时自增，旧回调直接丢弃。
  int _alarmToken = 0;

  /// 计时结束后是否退出应用。
  ///
  /// 独立于 [SleepTimerState] 的值通道：勾选状态在定时未开启时也可修改，
  /// 且不参与每秒 tick 的状态比较；默认值由构造参数 [exitAppByDefault] 决定
  /// （生产环境默认勾选，测试 / 无壳宿主默认关闭）。
  final ValueNotifier<bool> exitApp;

  /// 倒计时到点后是否等当前曲目自然播完再暂停。
  ///
  /// 与 [exitApp] 一样独立于状态通道：未开启定时时也能修改；生产环境默认
  /// 勾选、仅本次运行，不落盘、不参与同步。
  final ValueNotifier<bool> waitForTrackEnd;

  final ValueNotifier<SleepTimerState> _state = ValueNotifier<SleepTimerState>(
    SleepTimerState.off,
  );

  SleepTimerMode _mode = SleepTimerMode.off;
  Duration? _remaining;

  /// 武装时的启动时长（倒计时非空；到点后等本曲播完时保留）。
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

  /// 当前等待是否由倒计时到点触发（用于取消「本曲播完再停」时立即暂停）。
  bool _waitingAfterDeadline = false;

  /// 武装曲目观测到的最大进度：曲目切换时进度通道会先对齐到新曲目（≈0），
  /// 取最大值才不会被清零（自然播完判定 + 单曲循环判定共用）。
  Duration _maxPosition = Duration.zero;

  /// 上一次快照事件的时长：切歌事件的快照已带新曲目时长，用它保留
  /// 「刚播完那首」的时长（下一次事件才覆盖）。
  Duration _lastKnownDuration = Duration.zero;

  /// 倒计时淡出是否已启动（一次倒计时只启动一次；暂停 / 取消 / 重开时清）。
  bool _countdownFadeStarted = false;

  /// 「播完当前歌曲」的 3 秒淡出是否已启动（切歌 / 后退 seek 时清）。
  bool _endFadeStarted = false;

  /// 位置通道最近一次真值变化的时间：判断曲末淡出用的进度是否新鲜。
  DateTime? _positionChangedAt;
  Duration _previousPosition = Duration.zero;

  /// 进度是否在最近一次更新中前进（时钟在走，而不是停在旧值）。
  bool _positionAdvancing = false;

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
    // 覆盖旧定时前先把它的淡出还回去，否则新定时会从静音开始。
    _cancelFade(restore: true);
    _countdownFadeStarted = false;
    _endFadeStarted = false;
    // 与「播完当前歌曲」互斥：切到倒计时时撤销后端的停止标志。
    _setStopAfterCurrentTrack?.call(false);
    _mode = SleepTimerMode.countdown;
    _armedTrackUri = null;
    _waitingAfterDeadline = false;
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
    _startAfterTrackWait();
  }

  /// 进入等待阶段：后端自然播完时停住，完成事件负责复位定时。
  ///
  /// [keepDuration] 让倒计时到点后的等待保留启动时长，重新打开弹层时滑杆
  /// 仍停在原位置；[afterDeadline] 标记这轮等待来自倒计时。
  void _startAfterTrackWait({
    Duration? keepDuration,
    bool afterDeadline = false,
  }) {
    final uri = _snapshot.value.current?.id.uri;
    if (uri == null) return;
    // 从倒计时 / 其它模式切进等待阶段时，已有淡出必须撤回：音乐还要继续，
    // 不能静音等到曲末。普通「播完当前歌曲」进入时本来就没有淡出。
    _cancelFade(restore: true);
    _countdownFadeStarted = false;
    _endFadeStarted = false;
    _mode = SleepTimerMode.afterCurrentTrack;
    _armedTrackUri = uri;
    _setStopAfterCurrentTrack?.call(true);
    _duration = keepDuration;
    _remaining = null;
    _deadlineAt = null;
    _cancelTicker();
    _cancelAlarm();
    _maxPosition = _position.value;
    _waitingAfterDeadline = afterDeadline;
    _publish();
  }

  /// 撤销定时（未开启时为无操作）。
  void cancel() {
    if (_mode == SleepTimerMode.off) return;
    _reset(notify: true);
  }

  /// 设置「计时结束后退出应用」；已开启的定时在到点时按最新值执行。
  void setExitApp(bool value) => exitApp.value = value;

  /// 设置「到点后等当前曲目播完再暂停」。
  ///
  /// 如果已经处于倒计时到点后的等待阶段，取消勾选立即暂停——否则用户会看到
  /// 勾选已取消、却还在等下一首播完。
  void setWaitForTrackEnd(bool value) {
    if (waitForTrackEnd.value == value) return;
    waitForTrackEnd.value = value;
    if (!value &&
        _waitingAfterDeadline &&
        _mode == SleepTimerMode.afterCurrentTrack) {
      _fireNow();
      return;
    }
    // 倒计时途中取消「等本曲播完」：若已进入最后 5 秒，下一次 tick 之前
    // 也应立即开始淡出。
    if (_mode == SleepTimerMode.countdown) _syncTicker();
  }

  void dispose() {
    _countdownFadeStarted = false;
    _endFadeStarted = false;
    _completionSubscription?.cancel();
    _completionSubscription = null;
    _setStopAfterCurrentTrack?.call(false);
    _snapshot.removeListener(_onSnapshot);
    _position.removeListener(_onPosition);
    _cancelTicker();
    _alarm.dispose();
    exitApp.dispose();
    waitForTrackEnd.dispose();
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
    // 曲末早于预期到达（淡出还没跑完）：取消淡出并立即暂停，不再补一次。
    if (_endFadeStarted) {
      _cancelFade(restore: false);
    }
    _fireNow();
  }

  void _onPosition() {
    final position = _position.value;
    final changed = position != _previousPosition;
    if (changed) {
      _positionAdvancing = position > _previousPosition;
      _previousPosition = position;
      _positionChangedAt = _now();
    }
    final backwardSeek = changed && !_positionAdvancing;
    if (_mode == SleepTimerMode.afterCurrentTrack &&
        backwardSeek &&
        _endFadeStarted) {
      // 回到开头（单曲循环重播）仍是「这一遍结束」；退回曲中才是用户
      // 后退 seek。两者都表现为位置从曲末回跳，只能按落点区分。
      if (position < const Duration(seconds: 1)) {
        _cancelFade(restore: false);
        _fireNow();
        return;
      }
      // 后退 seek 是对「旧曲末」的否定：撤销淡出，重新等新的曲末。
      _cancelFade(restore: true);
      if (position > _maxPosition) _maxPosition = position;
      _maybeStartEndFade();
      return;
    }
    if (_mode == SleepTimerMode.afterCurrentTrack &&
        _completedArmedTrack &&
        position + _restartGap < _maxPosition) {
      // 单曲循环：曲目没换，位置从曲末回跳 = 已播完一轮。
      _cancelFade(restore: false);
      _fireNow();
      return;
    }
    if (position > _maxPosition) _maxPosition = position;
    if (_mode == SleepTimerMode.afterCurrentTrack) {
      _maybeStartEndFade();
    }
  }

  void _handleAfterTrackSnapshot(PlaybackSnapshot snapshot) {
    // 用户在曲末淡出途中手动暂停：撤销淡出；恢复播放后位置事件会按新的
    // 剩余时间重新进入 3 秒窗口。
    if (!snapshot.isPlaying && _endFadeStarted) {
      _cancelFade(restore: true);
    }
    final uri = snapshot.current?.id.uri;
    if (uri == null) {
      // 队列被清空 / 播放停止：没有可等待的曲目。
      _reset(notify: true);
      return;
    }
    if (uri != _armedTrackUri) {
      if (_completedArmedTrack) {
        // 自然播完（下一首已装载）：早于淡出结束就进入完成 → 撤销淡出并
        // 立即暂停（保持当前低电平，不再补一次）。
        if (_endFadeStarted) {
          _cancelFade(restore: false);
        }
        _fireNow();
        return;
      }
      // 手动切歌 / 自动换源替换：撤销旧曲目的淡出（否则新歌从静音开始），
      // 跟随新曲目继续等待「这一首播完」。
      if (_endFadeStarted) {
        _cancelFade(restore: true);
      }
      _armedTrackUri = uri;
      _maxPosition = _position.value;
      _positionChangedAt = null;
      return;
    }
    if (!snapshot.isPlaying && _completedArmedTrack) {
      // 队列自然播完（最后一首结束）：没有下一首要暂停。勾选「退出应用」
      // 时仍按定时到点处理（暂停对已停止的后端是幂等的），否则只撤销定时。
      if (exitApp.value) {
        _fireNow();
      } else {
        _reset(notify: true);
      }
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
  ///
  /// [foreground] 是生命周期回调**当时**的前后台事实（null = 读注入的策略）：
  /// 同一次 `onPause` 里组合根的策略监听可能还没跑（事件监听顺序不保证），
  /// 不能等 `PlaybackPowerPolicy` 更新后再决定要不要持 wake lock。
  void recheckDeadline({bool? foreground}) {
    if (_mode != SleepTimerMode.countdown) return;
    _syncTicker(foregroundOverride: foreground);
  }

  /// 倒计时 ticker 同步：播放中（重新）武装绝对 deadline，非播放时冻结剩余。
  ///
  /// 每个触发源（tick、快照变化、[recheckDeadline]）都先做一次 deadline 判定，
  /// tick 迟到 / 整段丢失因此都不影响到点时机。
  void _syncTicker({bool? foregroundOverride}) {
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
      if (expired) {
        _onCountdownDeadline();
      } else if (_countdownFadeStarted) {
        // 用户在淡出途中手动暂停：撤销淡出并恢复音量，恢复播放后会按剩余
        // 时间重新进入窗口。到点冻结时不走这里（暂停要立即落地）。
        _cancelFade(restore: true);
      }
      return;
    }
    if (_deadlinePassed) {
      // 已经越过 deadline（冻结期间到点后重新获得调度）：立即补触发，
      // 不做一次「补淡」——不能把已经过去的几秒装成渐变。
      _onCountdownDeadline();
      return;
    }
    if (_ticker == null) {
      final remaining = _remaining;
      if (remaining == null) return;
      _deadlineAt = _now().add(remaining);
      _ticker = Timer.periodic(_tickInterval, (_) => _onTick());
    }
    _maybeStartCountdownFade();
    // 即使 Dart ticker 已在跑，也重新 arm 原生定时器：通道重建 / 回前台 /
    // 快照变化后都能恢复熄屏补触发。
    _armAlarm(foregroundOverride: foregroundOverride);
  }

  /// 武装原生定时器（每次 arm 递增 token，旧回调自动失效）。
  void _armAlarm({bool? foregroundOverride}) {
    final deadline = _deadlineAt;
    if (deadline == null) return;
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero) {
      _onCountdownDeadline();
      return;
    }
    _alarmToken++;
    _alarm.arm(
      remaining,
      _alarmToken,
      keepAwake: !(foregroundOverride ?? _isForeground()),
    );
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
      // 原生定时器只在当前 deadline 触发；提前醒来时补一次窗口检查。
      _maybeStartCountdownFade();
      _armAlarm();
      return;
    }
    _onCountdownDeadline();
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
      _onCountdownDeadline();
      return;
    }
    _remaining = deadline.difference(now);
    _maybeStartCountdownFade();
    _publish();
  }

  /// 倒计时进入最后 5 秒时启动一次淡出。
  ///
  /// 倒计时淡出是定时关闭承诺的一部分，不受普通「淡入淡出」设置影响；
  /// 但用户勾了「等当前曲目播完」时不做——那段时间音乐还要继续，最后
  /// 再由 after-current-track 的 3 秒淡出收尾。
  void _maybeStartCountdownFade() {
    if (_mode != SleepTimerMode.countdown ||
        _countdownFadeStarted ||
        waitForTrackEnd.value ||
        !_snapshot.value.isPlaying) {
      return;
    }
    final deadline = _deadlineAt;
    if (deadline == null) return;
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero ||
        remaining < _countdownMinFade ||
        remaining > _countdownFadeWindow) {
      return;
    }
    _countdownFadeStarted = true;
    _onFadeStart?.call(remaining);
  }

  /// after-current-track：位置新鲜且确实在前进时，曲末前 3 秒淡出。
  ///
  /// 位置未知 / 停更（熄屏节流）时不猜：宁可等完成事件立即停，也不在
  /// 一首歌的中间误降音量。
  void _maybeStartEndFade() {
    if (_mode != SleepTimerMode.afterCurrentTrack ||
        _endFadeStarted ||
        !_snapshot.value.isPlaying) {
      return;
    }
    final changedAt = _positionChangedAt;
    if (changedAt == null ||
        !_positionAdvancing ||
        _now().difference(changedAt) > _positionFreshness) {
      return;
    }
    final duration = _lastKnownDuration > _completionTolerance
        ? _lastKnownDuration
        : (_snapshot.value.duration > _completionTolerance
              ? _snapshot.value.duration
              : null);
    if (duration == null) return;
    final remaining = duration - _position.value;
    if (remaining <= Duration.zero ||
        remaining < _countdownMinFade ||
        remaining > _endFadeWindow) {
      return;
    }
    _endFadeStarted = true;
    _onFadeStart?.call(remaining < _endFadeWindow ? remaining : _endFadeWindow);
  }

  /// 撤销当前淡出（if any）；不影响定时模式本身。
  void _cancelFade({required bool restore}) {
    if (!_countdownFadeStarted && !_endFadeStarted) return;
    _countdownFadeStarted = false;
    _endFadeStarted = false;
    _onFadeCancel?.call(restore: restore);
  }

  /// 倒计时到点：勾选「本曲播完再停」且当前有真实播放曲目时，转入等待阶段；
  /// 否则立即暂停（无曲目 / 已暂停 / 曲目已播完时等待没有意义）。
  void _onCountdownDeadline() {
    if (_mode != SleepTimerMode.countdown) return;
    final snapshot = _snapshot.value;
    if (waitForTrackEnd.value &&
        snapshot.isPlaying &&
        snapshot.current != null &&
        !_completedArmedTrack) {
      // 还要继续听：把最后几秒的淡出还回去，进入等待阶段。
      _cancelFade(restore: true);
      _startAfterTrackWait(keepDuration: _duration, afterDeadline: true);
      return;
    }
    // 淡出已接近静音（或刚好还差一点）：直接落静音，让随后暂停立即生效，
    // 不再补第二次淡出。没开始过淡出时由服务按普通暂停路径处理。
    if (_countdownFadeStarted) {
      _countdownFadeStarted = false;
      _onFadeCancel?.call(restore: false);
    }
    _fireNow();
  }

  /// 真正到点：先回 off（onFire 期间状态不应还显示开启），再执行暂停；
  /// 勾选了「退出应用」时，暂停落地后再走统一退出路径。
  ///
  /// 暂停失败不阻止退出：用户已经选择了「到点退出」，卡在暂停上比直接退出
  /// 更糟；两个动作各自记日志。
  void _fireNow() {
    final shouldExit = exitApp.value;
    // 不撤销淡出：到点时若淡出已经跑完，暂停路径会跳过第二次淡出；
    // 若还没跑完，也让暂停从当前电平继续。
    _reset(notify: true, cancelFade: false);
    unawaited(() async {
      try {
        await _onFire();
      } catch (e) {
        _logger.warning('定时关闭到点暂停失败: $e');
      }
      if (shouldExit) await _runExit();
    }());
  }

  /// 执行注入的退出动作；未装配（测试 / 无壳宿主）时静默跳过。
  Future<void> _runExit() async {
    final exit = _onExit;
    if (exit == null) return;
    try {
      await exit();
    } catch (e) {
      _logger.warning('定时关闭到点退出应用失败: $e');
    }
  }

  void _reset({required bool notify, bool cancelFade = true}) {
    if (cancelFade) _cancelFade(restore: true);
    _countdownFadeStarted = false;
    _endFadeStarted = false;
    _setStopAfterCurrentTrack?.call(false);
    _mode = SleepTimerMode.off;
    _remaining = null;
    _duration = null;
    _armedTrackUri = null;
    _waitingAfterDeadline = false;
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
///
/// 退后台 / 息屏（`onPause` / `onHide`）也要补检一次：原生定时器的
/// wake lock 只在后台持有，前台已撤销；进入后台必须按新的前后台状态重排
/// （[SleepTimerController.recheckDeadline] 会重新 arm），否则熄屏后可能
/// 根本收不到到点回调。
class SleepTimerLifecycleRecheck {
  SleepTimerLifecycleRecheck(this._timer);

  final SleepTimerController _timer;
  AppLifecycleListener? _listener;

  /// 挂接（幂等；组合根在 provider 建好后调用一次，App 生命周期内有效）。
  void attach() {
    _listener ??= AppLifecycleListener(
      onResume: () => _timer.recheckDeadline(foreground: true),
      onPause: () => _timer.recheckDeadline(foreground: false),
      onHide: () => _timer.recheckDeadline(foreground: false),
    );
  }

  /// 解挂（测试 / 非常规宿主用）。
  void detach() {
    _listener?.dispose();
    _listener = null;
  }
}
