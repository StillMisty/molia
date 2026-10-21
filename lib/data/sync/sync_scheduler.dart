import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import '../../services/battery_probe.dart';
import '../../services/data_saver_service.dart';
import 'sync_state_store.dart';

/// 调度器驱动一轮同步的宿主（生产 = `SyncEngine`；单测注入假实现）。
abstract interface class SyncSchedulerHost {
  bool get syncEnabled;

  /// 跑一轮；[onlyCategories] 非空时只处理这些类别（蜂窝小类别策略）；
  /// [antiEntropy] 允许全量兜底（周期性指纹比对修复静默分歧）。
  Future<SyncRunOutcome> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  });
}

/// 一轮同步的外发结果（调度器据此维护「待外发」标记）。
class SyncRunOutcome {
  const SyncRunOutcome({
    required this.categories,
    required this.delivered,
    this.contacted = true,
    this.contactedLan = false,
  });

  /// 本轮实际外发的类别（蜂窝小类别轮不含历史 / 统计）。
  final Set<SyncCategory> categories;

  /// 本轮是否无失败（失败时待发标记保留，下轮重试）。
  final bool delivered;

  /// 本轮是否接触到了任何对端（探测 / 拉取 / 推送）。
  ///
  /// 默认 true = 不触发「零对端」重连阶梯：测试宿主 / 未提供接触信息的调用
  /// 方不会被调度器额外排一轮。
  final bool contacted;

  /// 本轮是否接触到了局域网对端（重连阶梯据此立即取消）。
  final bool contactedLan;

  static const SyncRunOutcome none =
      SyncRunOutcome(categories: {}, delivered: false);
}

/// 同步调度器：按同步等级决定何时跑、跑什么范围。
///
/// 时钟、网络类型、电量探针与播放状态全部注入（单测不碰平台通道）：
/// - 活跃等级由「可见 + 最近交互 / 正在播放」判定，变更去抖 3–5s；
/// - 空闲等级的退避每次翻倍到上限；**非蜂窝网络**（Wi-Fi / 以太网 / 桌面）
///   的唤醒即使没有本地变更也照常探测 / 拉取（对端变化在退避周期内收敛），
///   移动端蜂窝下才按「无本地变更零流量」处理；
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
    Stream<void>? networkChanges,
    Stream<void>? peerSightings,
    Duration networkDebounce = const Duration(milliseconds: 1500),
    Duration peerSightDebounce = const Duration(seconds: 1),
    Duration peerSightCooldown = const Duration(seconds: 10),
    List<Duration> reconnectLadder = const [
      Duration(seconds: 5),
      Duration(seconds: 20),
      Duration(seconds: 60),
      Duration(seconds: 180),
    ],
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
        _lowBatteryPercent = lowBatteryPercent,
        _networkChanges = networkChanges,
        _peerSightings = peerSightings,
        _networkDebounce = networkDebounce,
        _peerSightDebounce = peerSightDebounce,
        _peerSightCooldown = peerSightCooldown,
        _reconnectLadder = List.unmodifiable(reconnectLadder) {
    _backoff = idleBackoffStart;
    _lastInteractionAt = _nowMs();
  }

  /// 蜂窝网络下只同步的小类别：设置 / 音源 / 凭证 / 歌单与曲目 / 会话；
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
  final Stream<void>? _networkChanges;
  final Stream<void>? _peerSightings;
  final Duration _networkDebounce;
  final Duration _peerSightDebounce;
  final Duration _peerSightCooldown;
  final List<Duration> _reconnectLadder;
  final Logger _logger = Logger('molia.sync.scheduler');

  SyncLevel _level = SyncLevel.idle;
  bool _visible = true;

  /// 待外发的类别（空 = 没有本地变更待发）。
  final Set<SyncCategory> _dirtyCategories = {};

  /// 其中「需要即时外发」的类别（高优先级变更；低优先级只标记不排轮次）。
  final Set<SyncCategory> _immediateCategories = {};

  bool _onCellular = false;
  bool _batteryLow = false;
  bool _charging = false;
  bool _systemPowerSave = false;
  int _lastInteractionAt = 0;
  Duration _backoff = const Duration(minutes: 10);
  Timer? _debounceTimer;
  Timer? _idleTimer;
  Timer? _activeTimer;
  Timer? _networkTimer;
  Timer? _peerSightTimer;
  Timer? _peerSightCooldownTimer;
  Timer? _reconnectTimer;
  StreamSubscription<void>? _networkSub;
  StreamSubscription<void>? _peerSightSub;
  int _reconnectStep = 0;
  int _lastDiscoveryAt = 0;
  bool _peerSightPending = false;
  bool _roundRunning = false;
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

  /// 是否还有未外发的本地变更。
  bool get dirty => _dirtyCategories.isNotEmpty;

  /// 待外发的类别（观测与测试用）。
  Set<SyncCategory> get dirtyCategories => Set.unmodifiable(_dirtyCategories);

  /// 是否存在调度器定时器（单测断言「后台零定时」用）。
  bool get hasPendingTimer =>
      _debounceTimer != null ||
      _idleTimer != null ||
      _activeTimer != null ||
      _networkTimer != null ||
      _peerSightTimer != null ||
      _peerSightCooldownTimer != null ||
      _reconnectTimer != null;

  /// 当前空闲退避（观测与测试用；进入空闲等级时重置到起点）。
  Duration get idleBackoff => _backoff;

  /// 启动：探测环境、订阅网络 / 对端公告事件并按等级排定定时器。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _networkSub = _networkChanges?.listen(
      (_) => unawaited(onNetworkChanged()),
      onError: (Object error) {
        _logger.fine(() => '同步调度：网络事件流错误: $error');
      },
    );
    _peerSightSub = _peerSightings?.listen(
      (_) => notifyPeerSighted(),
      onError: (Object error) {
        _logger.fine(() => '同步调度：对端公告流错误: $error');
      },
    );
    await refreshEnvironment();
  }

  /// 重新探测电量 / 网络类型并重排定时器（前台恢复、定时唤醒时调用）。
  Future<void> refreshEnvironment() async {
    if (_disposed) return;
    try {
      final battery = await _batteryProbe();
      _batteryLow = battery.level >= 0 && battery.level <= _lowBatteryPercent;
      // 电量未知（桌面无电池 / 探测失败）按外部供电等价处理：不参与低电量
      // 判定，也不把桌面当成「未充电」。
      _charging = battery.charging || battery.level < 0;
      _systemPowerSave = battery.powerSave;
    } catch (e) {
      _logger.fine(() => '电量探测失败（按外部供电处理）: $e');
      _batteryLow = false;
      _charging = true;
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

  /// 数据变更：标记待外发类别。
  ///
  /// [categories] 省略时标记全部启用类别；[immediate] 为 false 时只标记、
  /// 不续期活跃窗口也不排去抖轮次（高频写入如播放会话进度用）。
  void notifyLocalChange({
    Set<SyncCategory>? categories,
    bool immediate = true,
  }) {
    if (_disposed) return;
    final enabled = _state.enabledCategories;
    final pending =
        categories == null ? enabled : categories.intersection(enabled);
    _dirtyCategories.addAll(pending);
    if (!immediate) return;
    _immediateCategories.addAll(pending);
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
  }

  /// 用户交互（界面操作）。
  void notifyInteraction() {
    if (_disposed) return;
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
  }

  /// 回到前台：重新探测环境并拉一次（有本地变更时一并推送）。
  void onAppVisible() {
    if (_disposed) return;
    _visible = true;
    // 用户回到前台视为最近交互：等级先按活跃处理，交互窗口过后自动降级。
    _lastInteractionAt = _nowMs();
    _applyLevel(_evaluate());
    unawaited(_resumeAfterRefresh());
  }

  Future<void> _resumeAfterRefresh() async {
    // Android 在后台不再广播网络变化：回前台必须重新探测电量与网络类型，
    // 否则「离开 Wi-Fi 后仍按 Wi-Fi 判定」。
    await refreshEnvironment();
    if (_disposed || !_canRunAutomatically) return;
    final push = dirty;
    await _runAndMark(
      SyncTrigger.resume,
      push: push,
      armLadderOnZeroPeers: true,
    );
  }

  /// 网络变化（connectivity 原始事件）：重估环境 → 重置退避 → 去抖跑一轮。
  ///
  /// 蜂窝布尔值没变（Wi-Fi 重连 / 换网）时也要走这里：退避可能已经退到
  /// 一小时，回到内网不能等下一次空闲唤醒。后台 / 省电 / 蜂窝下不排轮次，
  /// 也不 arm 重连阶梯（移动端保持零后台定时器与蜂窝零广播）。
  Future<void> onNetworkChanged() async {
    if (_disposed) return;
    await refreshEnvironment();
    if (_disposed) return;
    _backoff = _idleBackoffStart;
    // 空闲等级下重排唤醒：退避虽已归零，旧 timer 可能还停在 60 分钟处。
    if (_level == SyncLevel.idle && _canRunAutomatically) _armIdle();
    if (_visible && _canRunAutomatically && !_onCellular) {
      _networkTimer?.cancel();
      _networkTimer = Timer(_networkDebounce, () {
        _networkTimer = null;
        if (!_visible || !_canRunAutomatically || _onCellular) return;
        unawaited(_runAndMark(SyncTrigger.network, push: true));
      });
    }
    _armReconnectLadder();
  }

  /// 收到认证通过的对端公告：1s 去抖 + 10s 冷却后跑一轮发现。
  ///
  /// 冷却未到时延后到冷却结束，不在窗口内重复发轮次；后台 / 省电 / 蜂窝
  /// 直接忽略。
  void notifyPeerSighted() {
    if (_disposed || !_visible || !_canRunAutomatically || _onCellular) return;
    _peerSightTimer?.cancel();
    _peerSightTimer = Timer(_peerSightDebounce, _firePeerSight);
  }

  void _firePeerSight() {
    _peerSightTimer = null;
    // 每次重新计算冷却：冷却计时器还在等待时又来了公告，不能排两轮。
    _peerSightCooldownTimer?.cancel();
    _peerSightCooldownTimer = null;
    if (_disposed || !_visible || !_canRunAutomatically || _onCellular) return;
    final now = _nowMs();
    final remaining =
        _lastDiscoveryAt + _peerSightCooldown.inMilliseconds - now;
    if (_lastDiscoveryAt > 0 && remaining > 0) {
      _peerSightCooldownTimer = Timer(
        Duration(milliseconds: remaining),
        _firePeerSight,
      );
      return;
    }
    // 冷却起点在真正开跑时由 `_runAndMark` 记录：上一轮未结束时本轮不会
    // 实际开跑，pending 的公告不能因此被冷却窗口吞掉。
    unawaited(_runAndMark(SyncTrigger.discovery, push: true));
  }

  /// 退后台 / 锁屏：取消全部定时器，有本地变更时尽力推一次。
  void onAppHidden() {
    if (_disposed) return;
    if (!_visible) return;
    _visible = false;
    _cancelAuxiliaryTimers();
    _peerSightPending = false;
    _applyLevel(_evaluate());
    if (!_canRunAutomatically || !dirty) return;
    unawaited(_runAndMark(SyncTrigger.pause, push: true));
  }

  /// 手动触发（不受等级、省电与蜂窝暂停策略限制）。
  Future<void> syncNow() async {
    if (!_host.syncEnabled) return;
    await _runAndMark(SyncTrigger.manual, push: true);
  }

  /// 启动后首轮（受省电与蜂窝暂停策略约束）。
  Future<void> syncStartup() async {
    if (!_canRunAutomatically) return;
    await _runAndMark(SyncTrigger.startup, push: true);
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeTimer?.cancel();
    _activeTimer = null;
    _cancelAuxiliaryTimers();
    unawaited(_networkSub?.cancel());
    _networkSub = null;
    unawaited(_peerSightSub?.cancel());
    _peerSightSub = null;
  }

  /// 取消网络 / 公告 / 重连阶梯相关定时器（后台、省电、销毁共用）。
  void _cancelAuxiliaryTimers() {
    _networkTimer?.cancel();
    _networkTimer = null;
    _peerSightTimer?.cancel();
    _peerSightTimer = null;
    _peerSightCooldownTimer?.cancel();
    _peerSightCooldownTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectStep = 0;
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

  /// anti-entropy：空闲唤醒在无本地变更时仍探测 / 拉取，并允许全量兜底
  /// （比对 `snapshotId` 修复静默分歧）。
  ///
  /// 条件：非蜂窝（Wi-Fi / 以太网 / 桌面）+ 未处于省电等级，且（充电中或
  /// 前台可见）——移动端蜂窝下按「无本地变更零流量」处理（省电与省流），
  /// 后台不可见时不主动做全量校验。桌面电量探针不可用（未知）等价于外部
  /// 供电，不会因此被关掉。
  bool get _antiEntropyAllowed =>
      !_onCellular && !powerSaveActive && (_charging || _visible);

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
    // 后台 / 省电：网络去抖、公告冷却与重连阶梯一并取消（零定时器）。
    if (next == SyncLevel.background || next == SyncLevel.powerSave) {
      _cancelAuxiliaryTimers();
    }
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
        if (_immediateCategories.isNotEmpty && _canRunAutomatically) {
          _armDebounce();
        }
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
      unawaited(_runAndMark(SyncTrigger.debounce, push: true));
    });
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_backoff, () {
      _idleTimer = null;
      if (_level != SyncLevel.idle) return;
      unawaited(_onIdleWake());
    });
  }

  Future<void> _onIdleWake() async {
    // 定时唤醒时重新探测电量 / 网络：anti-entropy 与「蜂窝下无变更零流量」
    // 都依赖当前环境。
    await refreshEnvironment();
    if (_disposed || _level != SyncLevel.idle) return;
    if (!dirty && !_antiEntropyAllowed) {
      // 蜂窝 + 无本地变更不广播、不发 PROPFIND：退避翻倍后继续等待。
      _growBackoff();
      _armIdle();
      return;
    }
    _backoff = _idleBackoffStart;
    _armIdle();
    await _runAndMark(
      SyncTrigger.timer,
      push: true,
      armLadderOnZeroPeers: true,
    );
  }

  void _growBackoff() {
    final next = _backoff * 2;
    _backoff = next > _idleBackoffMax ? _idleBackoffMax : next;
  }

  Future<SyncRunOutcome?> _runAndMark(
    SyncTrigger trigger, {
    required bool push,
    bool armLadderOnZeroPeers = false,
  }) async {
    if (_roundRunning) {
      // 一轮未结束不并发再跑；对端公告留到本轮结束后补一次（重新走 1s 去抖
      // + 10s 冷却），其余触发按「本轮已覆盖同一环境」丢弃。
      if (trigger == SyncTrigger.discovery) _peerSightPending = true;
      return null;
    }
    _roundRunning = true;
    if (trigger == SyncTrigger.discovery) _lastDiscoveryAt = _nowMs();
    final SyncRunOutcome outcome;
    try {
      outcome = await _run(trigger, push: push);
    } finally {
      _roundRunning = false;
    }
    if (_disposed) return outcome;
    _markDelivered(outcome);
    if (outcome.contactedLan) {
      // 局域网已经看到对端：后续阶梯档位没有意义。
      _cancelReconnectLadder();
    } else if (armLadderOnZeroPeers && !outcome.contacted) {
      // 「已配对但零对端」：从 5s 档开始重连，任何一轮 LAN 接触成功即取消。
      _armReconnectLadder();
    }
    if (_peerSightPending) {
      _peerSightPending = false;
      notifyPeerSighted();
    }
    return outcome;
  }

  /// 重连阶梯的前置条件：前台、非省电、非蜂窝、LAN 启用且有已知对端。
  bool get _reconnectEligible {
    if (_disposed || !_visible) return false;
    if (!_host.syncEnabled || powerSaveActive || _onCellular) return false;
    if (!_state.enabledTransports.contains(SyncTransportKind.lan)) return false;
    return _state.lanEndpoints.isNotEmpty || _state.manualPeers.isNotEmpty;
  }

  /// 从第一档（5s）重新 arm 重连阶梯。
  void _armReconnectLadder() {
    if (!_reconnectEligible) {
      _cancelReconnectLadder();
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectStep = 0;
    _scheduleReconnectStep();
  }

  void _scheduleReconnectStep() {
    if (_disposed || !_reconnectEligible) {
      _cancelReconnectLadder();
      return;
    }
    if (_reconnectStep >= _reconnectLadder.length) {
      _reconnectTimer = null;
      return;
    }
    final delay = _reconnectLadder[_reconnectStep];
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_onReconnectTick());
    });
  }

  Future<void> _onReconnectTick() async {
    if (_disposed) return;
    if (!_reconnectEligible) {
      _cancelReconnectLadder();
      return;
    }
    final outcome = await _runAndMark(SyncTrigger.discovery, push: true);
    if (_disposed) return;
    if (outcome == null) {
      // 上一轮还没结束：稍后重试同一档，不推进阶梯。
      _scheduleReconnectStep();
      return;
    }
    if (outcome.contactedLan) {
      _cancelReconnectLadder();
      return;
    }
    _reconnectStep++;
    _scheduleReconnectStep();
  }

  void _cancelReconnectLadder() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectStep = 0;
  }

  /// 按本轮外发结果清待发标记：只清「本轮外发过」的类别。
  ///
  /// 蜂窝小类别轮不含历史 / 统计，这些类别的标记保留到 Wi-Fi 轮；失败轮
  /// 整体保留（下轮重试）；类别被关闭时对应标记直接丢弃（不再外发）。
  void _markDelivered(SyncRunOutcome outcome) {
    final enabled = _state.enabledCategories;
    _dirtyCategories.removeWhere((category) => !enabled.contains(category));
    _immediateCategories
        .removeWhere((category) => !enabled.contains(category));
    if (!outcome.delivered) return;
    _dirtyCategories.removeAll(outcome.categories);
    _immediateCategories.removeAll(outcome.categories);
  }

  Future<SyncRunOutcome> _run(
    SyncTrigger trigger, {
    required bool push,
  }) async {
    if (!_host.syncEnabled) return SyncRunOutcome.none;
    try {
      return await _host.runSyncRound(
        trigger: trigger,
        push: push,
        // 手动轮总是允许全量兜底（用户显式要求）；自动轮按环境策略。
        antiEntropy: trigger == SyncTrigger.manual || _antiEntropyAllowed,
        onlyCategories: cellularRestricted ? smallCategories : null,
      );
    } catch (e) {
      // 一轮内部失败已由引擎计入报告；这里只兜异常不中断调度。
      _logger.warning('同步调度：一轮执行失败', e);
      return SyncRunOutcome.none;
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
