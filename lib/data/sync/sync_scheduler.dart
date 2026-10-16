import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../services/battery_probe.dart';
import '../../services/data_saver_service.dart';
import 'sync_state_store.dart';

/// 调度器驱动一轮同步的宿主（生产 = `SyncEngine`；单测注入假实现）。
abstract interface class SyncSchedulerHost {
  bool get syncEnabled;

  /// 跑一轮；[onlyCategories] 非空时只处理这些类别（蜂窝小类别策略）。
  Future<void> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    Set<SyncCategory>? onlyCategories,
  });
}

/// 同步调度器：按同步等级决定何时跑、跑什么范围。
///
/// 时钟、网络类型、电量探针与播放状态全部注入（单测不碰平台通道）：
/// - 活跃等级由「可见 + 最近交互 / 正在播放」判定，变更去抖 3–5s；
/// - 空闲等级的退避每次翻倍到上限；无本地变更且不允许 anti-entropy 时
///   唤醒后不做任何网络动作；
/// - 后台等级不创建任何定时器；
/// - 省电等级（低电量未充电 / 系统省电模式）与「移动数据下暂停」策略下
///   自动同步整体暂停，手动同步不受限制。
class SyncScheduler {
  SyncScheduler({
    required SyncSchedulerHost host,
    required SyncStateStore state,
    Future<bool> Function()? cellularProbe,
    Future<BatterySnapshot> Function()? batteryProbe,
    bool Function()? isPlaying,
    DateTime Function()? clock,
    Duration activeDebounce = const Duration(seconds: 4),
    Duration activeWindow = const Duration(minutes: 1),
    Duration idleBackoffStart = const Duration(minutes: 10),
    Duration idleBackoffMax = const Duration(minutes: 60),
    int lowBatteryPercent = 20,
  })  : _host = host,
        _state = state,
        _cellularProbe = cellularProbe ?? _defaultCellularProbe,
        _batteryProbe = batteryProbe ?? BatteryProbe().read,
        _isPlaying = isPlaying,
        _clock = clock ?? DateTime.now,
        _activeDebounce = activeDebounce,
        _activeWindowMs = activeWindow.inMilliseconds,
        _idleBackoffStart = idleBackoffStart,
        _idleBackoffMax = idleBackoffMax,
        _lowBatteryPercent = lowBatteryPercent {
    _backoff = idleBackoffStart;
    _lastInteractionAt = _nowMs();
  }

  /// 蜂窝网络下只同步的小类别：设置 / 音源 / 凭证 / 歌单 / 会话；
  /// 统计与历史等大类别留到 Wi-Fi。
  static const Set<SyncCategory> smallCategories = {
    SyncCategory.settings,
    SyncCategory.sources,
    SyncCategory.credentials,
    SyncCategory.playlists,
    SyncCategory.playlistTracks,
    SyncCategory.session,
  };

  final SyncSchedulerHost _host;
  final SyncStateStore _state;
  final Future<bool> Function() _cellularProbe;
  final Future<BatterySnapshot> Function() _batteryProbe;
  final bool Function()? _isPlaying;
  final DateTime Function() _clock;
  final Duration _activeDebounce;
  final int _activeWindowMs;
  final Duration _idleBackoffStart;
  final Duration _idleBackoffMax;
  final int _lowBatteryPercent;
  final Logger _logger = Logger('molia.sync.scheduler');

  SyncLevel _level = SyncLevel.idle;
  bool _visible = true;
  bool _dirty = false;
  bool _onCellular = false;
  bool _batteryLow = false;
  bool _charging = false;
  bool _systemPowerSave = false;
  int _lastInteractionAt = 0;
  Duration _backoff = const Duration(minutes: 10);
  Timer? _debounceTimer;
  Timer? _idleTimer;
  Timer? _activeTimer;
  bool _started = false;
  bool _disposed = false;

  /// 当前同步等级。
  SyncLevel get level => _level;

  /// 系统省电模式或低电量未充电。
  bool get powerSaveActive => _systemPowerSave || (_batteryLow && !_charging);

  /// 当前是否在移动数据上（观测面展示用）。
  bool get onCellular => _onCellular;

  /// 蜂窝策略是否正在限制类别范围（只同步小类别）。
  bool get cellularRestricted =>
      _onCellular && _state.cellularPolicy == SyncCellularPolicy.auto;

  /// 是否处于「零定时唤醒」等级（后台 / 省电）。
  bool get zeroTimerLevel =>
      _level == SyncLevel.background || _level == SyncLevel.powerSave;

  /// 是否还有未外发的本地变更。
  bool get dirty => _dirty;

  /// 是否存在调度器定时器（单测断言「后台零定时」用）。
  bool get hasPendingTimer =>
      _debounceTimer != null || _idleTimer != null || _activeTimer != null;

  /// 当前空闲退避（观测与测试用；进入空闲等级时重置到起点）。
  Duration get idleBackoff => _backoff;

  /// 启动：探测环境并按等级排定定时器。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refreshEnvironment();
  }

  /// 重新探测电量 / 网络类型并重排定时器（前台恢复、定时唤醒时调用）。
  Future<void> refreshEnvironment() async {
    if (_disposed) return;
    try {
      final battery = await _batteryProbe();
      _batteryLow = battery.level >= 0 && battery.level <= _lowBatteryPercent;
      _charging = battery.charging;
      _systemPowerSave = battery.powerSave;
    } catch (e) {
      _logger.fine(() => '电量探测失败（按未知处理）: $e');
      _batteryLow = false;
      _charging = false;
      _systemPowerSave = false;
    }
    try {
      _onCellular = await _cellularProbe();
    } catch (e) {
      _logger.fine(() => '网络类型探测失败（按非蜂窝处理）: $e');
      _onCellular = false;
    }
    _applyLevel(_evaluate());
  }

  /// 数据变更（资料库 / 统计 / 音源配置的 changes 事件）。
  void notifyLocalChange() {
    if (_disposed) return;
    _dirty = true;
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
  }

  /// 用户交互（界面操作）。
  void notifyInteraction() {
    if (_disposed) return;
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
  }

  /// 回到前台：拉一次（有本地变更时一并推送）。
  void onAppVisible() {
    if (_disposed) return;
    _visible = true;
    // 用户回到前台视为最近交互：等级先按活跃处理，交互窗口过后自动降级。
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
    if (!_canRunAutomatically) return;
    final push = _dirty;
    _dirty = false;
    unawaited(_run(SyncTrigger.resume, push: push));
  }

  /// 退后台 / 锁屏：取消全部定时器，有本地变更时尽力推一次。
  void onAppHidden() {
    if (_disposed) return;
    if (!_visible) return;
    _visible = false;
    _applyLevel(_evaluate());
    if (!_canRunAutomatically || !_dirty) return;
    _dirty = false;
    unawaited(_run(SyncTrigger.pause, push: true));
  }

  /// 手动触发（不受等级、省电与蜂窝暂停策略限制）。
  Future<void> syncNow() async {
    if (!_host.syncEnabled) return;
    _dirty = false;
    await _run(SyncTrigger.manual, push: true);
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeTimer?.cancel();
    _activeTimer = null;
  }

  /// 自动同步当前是否允许（省电等级与「移动数据下暂停」策略下暂停）。
  bool get _canRunAutomatically {
    if (!_host.syncEnabled) return false;
    if (powerSaveActive) return false;
    if (_onCellular && _state.cellularPolicy == SyncCellularPolicy.pause) {
      return false;
    }
    return true;
  }

  /// 充电 + Wi-Fi（非蜂窝）时允许 anti-entropy 全量校验。
  bool get _antiEntropyAllowed =>
      _charging && !_onCellular && !powerSaveActive;

  SyncLevel _evaluate() {
    if (powerSaveActive) return SyncLevel.powerSave;
    if (!_visible) return SyncLevel.background;
    if (_isPlaying?.call() ?? false) return SyncLevel.active;
    final idleFor = _nowMs() - _lastInteractionAt;
    return idleFor <= _activeWindowMs ? SyncLevel.active : SyncLevel.idle;
  }

  void _applyLevel(SyncLevel next) {
    final changed = next != _level;
    _level = next;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeTimer?.cancel();
    _activeTimer = null;
    // 进入空闲等级时退避从起点重新开始；同一等级内的重排保留当前退避。
    if (changed && next == SyncLevel.idle) _backoff = _idleBackoffStart;
    switch (next) {
      case SyncLevel.active:
        // 交互窗口过后自动降级为空闲（否则等级只会在事件到达时重估）。
        _armActiveDemote();
        if (_dirty && _canRunAutomatically) _armDebounce();
      case SyncLevel.idle:
        if (_canRunAutomatically) _armIdle();
      case SyncLevel.background:
      case SyncLevel.powerSave:
        break;
    }
  }

  void _armActiveDemote() {
    _activeTimer?.cancel();
    _activeTimer = Timer(Duration(milliseconds: _activeWindowMs), () {
      _activeTimer = null;
      if (_level != SyncLevel.active) return;
      _applyLevel(_evaluate());
    });
  }

  void _armDebounce() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_activeDebounce, () {
      _debounceTimer = null;
      if (_level != SyncLevel.active || !_canRunAutomatically) return;
      _dirty = false;
      unawaited(_run(SyncTrigger.debounce, push: true));
    });
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_backoff, () {
      _idleTimer = null;
      if (_level != SyncLevel.idle) return;
      if (!_dirty && !_antiEntropyAllowed) {
        // 无本地变更不广播、不发 PROPFIND：退避翻倍后继续等待。
        _growBackoff();
        _armIdle();
        return;
      }
      _dirty = false;
      unawaited(_run(SyncTrigger.timer, push: true));
      _backoff = _idleBackoffStart;
      _armIdle();
    });
  }

  void _growBackoff() {
    final next = _backoff * 2;
    _backoff = next > _idleBackoffMax ? _idleBackoffMax : next;
  }

  Future<void> _run(SyncTrigger trigger, {required bool push}) async {
    if (!_host.syncEnabled) return;
    try {
      await _host.runSyncRound(
        trigger: trigger,
        push: push,
        onlyCategories: cellularRestricted ? smallCategories : null,
      );
    } catch (e) {
      // 一轮内部失败已由引擎计入报告；这里只兜异常不中断调度。
      _logger.warning('同步调度：一轮执行失败', e);
    }
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// 默认蜂窝探针：复用省流模式的网络类型判定。
  static Future<bool> _defaultCellularProbe() async {
    try {
      return DataSaverService.resultsAreCellular(
        await DataSaverService.probeConnectivity(),
      );
    } catch (_) {
      return false;
    }
  }
}
