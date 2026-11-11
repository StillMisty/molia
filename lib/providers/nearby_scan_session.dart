import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'sync_nearby_availability.dart';
import 'sync_provider.dart';
import 'sync_ui_state.dart';

/// 附近设备扫描会话依赖的本机事实与命令。
///
/// 生产实现包 [SyncProvider]（[SyncProviderNearbyScanPort]）；测试注入假端口
/// 即可直接驱动可用性 / 局域网运行状态与 startScan 的返回值，不需要 widget 树。
abstract interface class NearbyScanPort {
  /// 当前能否扫描（开关 / 权限 / 传输 / 移动数据 / 省电 / UDP）。
  SyncNearbyAvailability get availability;

  /// 局域网传输是否真正在运行：授权后开关可能已开但传输尚未起来，
  /// false → true 时需要补一次扫描。
  bool get lanRunning;

  /// 开始扫描；返回 false 表示本机此刻拒绝（后台 / 蜂窝 / 省电 / 端口不可用）。
  Future<bool> startScan();

  /// 停止扫描并清空候选。
  void stopScan();
}

/// 生产端口：只把 [SyncProvider] 的字段投影成会话需要的事实。
///
/// 可用性判定仍只在 provider 里做一份，这里不复制开关 / 权限 / 网络规则，
/// 否则「卡片说可用、会话按另一套判据说不可用」会再次分叉。
class SyncProviderNearbyScanPort implements NearbyScanPort {
  SyncProviderNearbyScanPort(this._provider);

  final SyncProvider _provider;

  @override
  SyncNearbyAvailability get availability => _provider.state.nearbyAvailability;

  @override
  bool get lanRunning {
    final lan = _provider.state.transports[SyncTransportId.lan];
    return lan != null && lan.enabled && lan.running;
  }

  @override
  Future<bool> startScan() => _provider.commands.nearby.start();

  @override
  void stopScan() => _provider.commands.nearby.stop();
}

/// 取消一次待触发的延时回调。
typedef NearbyScanTimerCancel = void Function();

/// 延时调度工厂：测试注入假实现，按虚拟时间推进结算窗口。
typedef NearbyScanTimerFactory = NearbyScanTimerCancel Function(
  Duration delay,
  VoidCallback callback,
);

/// 帧后调度：生产默认 `WidgetsBinding.instance.addPostFrameCallback`。
typedef NearbyScanPostFrame = void Function(VoidCallback callback);

/// 附近设备卡片的扫描状态（页面只读）。
@immutable
class NearbyScanState {
  const NearbyScanState({required this.scanning, required this.settled});

  /// 没有扫描在跑，也没有落到「没发现」。
  static const NearbyScanState idle = NearbyScanState(
    scanning: false,
    settled: false,
  );

  /// 扫描请求已发出且尚未结算（仍在「正在查找」窗口内）。
  final bool scanning;

  /// 扫描窗口已结束（到点或本机拒绝）：空态切到「没有发现 + 重新查找」。
  final bool settled;

  @override
  bool operator ==(Object other) =>
      other is NearbyScanState &&
      other.scanning == scanning &&
      other.settled == settled;

  @override
  int get hashCode => Object.hash(scanning, settled);

  @override
  String toString() =>
      'NearbyScanState(scanning: $scanning, settled: $settled)';
}

/// 附近设备扫描会话：`MSP/1` 探测的**页面级节拍**唯一实现。
///
/// 只拥有「什么时候开始扫、什么时候算没发现、什么时候停」：
/// - 首次 [sync]（页面挂载）在可用时于首帧后启动一次扫描；
/// - 之后每次 [sync]（provider 通知）比对可用性与局域网运行状态：可用性变成
///   available 补扫、变成不可用立即停扫并清掉结算态、LAN false → true 且可用
///   时补扫；
/// - `startScan` 返回 false（后台 / 蜂窝 / 省电 / 端口不可用）立即结算，
///   成功则 [settleDelay] 后结算，空态从「正在查找」切到「没有发现 + 重试」；
/// - [dispose] 取消结算并停扫。
///
/// 为什么单独成模块：这些时序原本散在设置页 State 的字段 + setState 里，
/// 只能靠 pump 整个设置页验证。端口与定时器都注入后，扫描节拍可在纯 Dart
/// 测试里按虚拟时间断言。
///
/// 扫描波次（100 / 500 / 1500ms 与 5 秒补探）属于配对服务的职责，不在本会话：
/// 这里只决定「什么时候发起 / 收回 startScan」。
class NearbyScanSession implements ValueListenable<NearbyScanState> {
  NearbyScanSession({
    required NearbyScanPort port,
    this.settleDelay = const Duration(milliseconds: 1800),
    NearbyScanTimerFactory? timerFactory,
    NearbyScanPostFrame? postFrame,
  }) : _port = port,
       _startTimer = timerFactory ?? _defaultTimerFactory,
       _postFrame = postFrame ?? _defaultPostFrame,
       _availability = port.availability,
       _lanRunning = port.lanRunning;

  final NearbyScanPort _port;

  /// 扫描成功到「没有发现」的结算窗口（生产默认 1.8 秒）。
  final Duration settleDelay;
  final NearbyScanTimerFactory _startTimer;
  final NearbyScanPostFrame _postFrame;

  final ValueNotifier<NearbyScanState> _state = ValueNotifier<NearbyScanState>(
    NearbyScanState.idle,
  );

  /// 上一次 [sync] 观察到的可用性与局域网运行状态。
  SyncNearbyAvailability _availability;
  bool _lanRunning;

  /// 首次 [sync] 只建立基线并决定是否开局扫描，不按「可用性变化」处理：
  /// 此时还没有发起过任何扫描，停扫 / 结算都无从谈起。
  bool _synced = false;

  /// 扫描代次：新扫描、可用性失效、dispose 都自增。
  ///
  /// 为什么需要：`startScan` 是异步的，可用性可能在等待期间变化。没有代次
  /// 守卫时，旧请求返回 true 会重新武装结算定时器，把已经「不可用」的页面
  /// 翻回「正在查找」，甚至在离开页面后继续持有定时器。
  int _generation = 0;

  NearbyScanTimerCancel? _cancelSettle;

  /// 同一帧内多次 [sync] 只排一次首帧扫描，避免重复 startScan。
  bool _postFramePending = false;

  bool _disposed = false;

  @override
  NearbyScanState get value => _state.value;

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  /// 页面挂载与 provider 每次通知后调用：只消费「与上次同步的差异」。
  void sync() {
    if (_disposed) return;
    final availability = _port.availability;
    final lanRunning = _port.lanRunning;
    final firstSync = !_synced;
    _synced = true;
    final availabilityChanged = _availability != availability;
    final becameRunning = lanRunning && !_lanRunning;
    _availability = availability;
    _lanRunning = lanRunning;

    if (firstSync) {
      // 打开同步页 = 扫描的真实起点：不可用时不调用 startScan（它只会立即
      // 失败），空态直接说明本机原因。
      if (availability == SyncNearbyAvailability.available) _scheduleScan();
      return;
    }
    if (availabilityChanged) {
      if (availability == SyncNearbyAvailability.available) {
        _scheduleScan();
      } else {
        _stopAndReset();
      }
      return;
    }
    // 授权成功等场景：开关早已打开、可用性结论没变，但传输从「未运行」
    // 变成「运行」——此时必须补一次，否则附近设备一直停在旧候选。
    if (becameRunning && availability == SyncNearbyAvailability.available) {
      _scheduleScan();
    }
  }

  /// 用户点「重新查找」：立即发起（不排首帧，动作就发生在点击回调里）。
  Future<void> rescan() async {
    if (_disposed) return;
    await _startScan();
  }

  /// 取消结算、停扫、清掉结算态；可用性失效时调用。
  void _stopAndReset() {
    _generation++;
    _cancelSettleScan();
    _publish(scanning: false, settled: false);
    _port.stopScan();
  }

  /// 传输开关 / 权限变化发生在 provider 通知里：排到本帧之后再探测，避免在
  /// build / didChangeDependencies 期间同步推流触发重入。
  void _scheduleScan() {
    if (_postFramePending) return;
    _postFramePending = true;
    _postFrame(() {
      _postFramePending = false;
      if (_disposed) return;
      if (_port.availability != SyncNearbyAvailability.available) return;
      unawaited(_startScan());
    });
  }

  Future<void> _startScan() async {
    if (_disposed) return;
    if (_port.availability != SyncNearbyAvailability.available) return;

    final generation = ++_generation;
    _cancelSettleScan();
    // 先切回「正在查找」再 await：重新查找时用户立即看到反馈，不能等
    // startScan 返回后才清掉上一次的「没有发现」。
    _publish(scanning: true, settled: false);

    final started = await _port.startScan();
    if (_disposed || generation != _generation) return;
    if (!started) {
      // 后台 / 蜂窝 / 省电 / 传输刚停 / 探测端口不可用 / 可用性刚变化都会
      // 拒绝扫描：直接落到「没发现 + 重试」，不能停在「正在查找」。
      _publish(scanning: false, settled: true);
      return;
    }
    _cancelSettle = _startTimer(settleDelay, () {
      if (_disposed || generation != _generation) return;
      _cancelSettle = null;
      _publish(scanning: false, settled: true);
    });
  }

  void _cancelSettleScan() {
    _cancelSettle?.call();
    _cancelSettle = null;
  }

  void _publish({required bool scanning, required bool settled}) {
    _state.value = NearbyScanState(scanning: scanning, settled: settled);
  }

  /// 离开同步页：候选只服务这一页，后台不保留。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelSettleScan();
    _port.stopScan();
    _state.dispose();
  }

  static NearbyScanTimerCancel _defaultTimerFactory(
    Duration delay,
    VoidCallback callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }

  static void _defaultPostFrame(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}
