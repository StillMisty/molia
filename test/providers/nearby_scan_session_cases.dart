import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:molia/providers/nearby_scan_session.dart';
import 'package:molia/providers/sync_nearby_availability.dart';

/// 附近设备扫描会话：页面级扫描节拍（首帧启动 / 结算 / 可用性失效 /
/// LAN 恢复 / 代次守卫 / dispose）在纯 Dart 下按虚拟时间断言。
///
/// 生产端的扫描波次属于配对服务，这里只验证本会话何时发起 / 收回 startScan。
void main() {
  const settleDelay = Duration(milliseconds: 1800);

  /// 让 startScan 的 await 续体与 post-frame 回调里的 unawaited future 落地。
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('首次 sync：可用时首帧后启动扫描，不在同步调用里重入', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);

    ctx.session.sync();
    expect(ctx.port.startCalls, 0, reason: 'provider 通知里不能同步起扫');

    ctx.scheduler.flushFrame();
    await flush();

    expect(ctx.port.startCalls, 1);
    expect(ctx.session.value.scanning, isTrue);
    expect(ctx.session.value.settled, isFalse);
  });

  test('首次 sync：不可用时不扫描', () async {
    final ctx = _SessionHarness(
      availability: SyncNearbyAvailability.lanOff,
      lanRunning: false,
    );
    addTearDown(ctx.session.dispose);

    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();

    expect(ctx.port.startCalls, 0);
    expect(ctx.session.value, NearbyScanState.idle);
  });

  test('成功的扫描在 1.8 秒结算窗口后切到「没发现」', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);
    await ctx.start();

    expect(ctx.session.value.scanning, isTrue);
    ctx.scheduler.elapse(settleDelay - const Duration(milliseconds: 1));
    expect(ctx.session.value.settled, isFalse, reason: '不到窗口结束不结算');

    ctx.scheduler.elapse(const Duration(milliseconds: 1));
    expect(ctx.session.value.scanning, isFalse);
    expect(ctx.session.value.settled, isTrue);
  });

  test('startScan 被拒绝：立即结算，不停在「正在查找」', () async {
    final ctx = _SessionHarness(startResult: false);
    addTearDown(ctx.session.dispose);

    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();

    expect(ctx.port.startCalls, 1);
    expect(ctx.session.value.scanning, isFalse);
    expect(ctx.session.value.settled, isTrue);
    expect(ctx.scheduler.activeTimers, isEmpty, reason: '拒绝的扫描不排结算');
  });

  test('可用性失效：停扫、取消结算并清掉 scanning / settled', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);
    await ctx.start();
    expect(ctx.session.value.scanning, isTrue);

    // 扫描途中失效：结算定时器必须撤销，旧波次不能把页面留在「正在查找」。
    ctx.port.availability = SyncNearbyAvailability.lanOff;
    ctx.session.sync();
    expect(ctx.port.stopCalls, 1);
    expect(ctx.session.value, NearbyScanState.idle);
    ctx.scheduler.elapse(settleDelay);
    expect(ctx.session.value, NearbyScanState.idle);

    // 恢复可用并真正结算后再失效：settled 也要一起清掉。
    ctx.port.availability = SyncNearbyAvailability.available;
    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();
    ctx.scheduler.elapse(settleDelay);
    expect(ctx.session.value.settled, isTrue);

    ctx.port.availability = SyncNearbyAvailability.lanOff;
    ctx.session.sync();
    expect(ctx.port.stopCalls, 2);
    expect(ctx.session.value, NearbyScanState.idle);
  });

  test('LAN 从 false 变 true：仅在可用时补扫', () async {
    final ctx = _SessionHarness(lanRunning: false);
    addTearDown(ctx.session.dispose);
    await ctx.start();
    expect(ctx.port.startCalls, 1);

    // 不可用时 LAN 起来也不扫：会话不越过可用性结论。
    ctx.port.availability = SyncNearbyAvailability.lanOff;
    ctx.session.sync();
    expect(ctx.port.stopCalls, 1);
    ctx.port.lanRunning = true;
    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();
    expect(ctx.port.startCalls, 1, reason: '不可用时 LAN 运行也不扫描');

    // 可用性恢复后补扫。
    ctx.port.availability = SyncNearbyAvailability.available;
    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();
    expect(ctx.port.startCalls, 2);
  });

  test('startScan 等待期间可用性失效：旧结果不能复活扫描态', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);
    final gate = Completer<bool>();
    ctx.port.pendingStart = gate;

    ctx.session.sync();
    ctx.scheduler.flushFrame();
    await flush();
    expect(ctx.port.startCalls, 1);
    expect(ctx.session.value.scanning, isTrue);

    ctx.port.availability = SyncNearbyAvailability.lanOff;
    ctx.session.sync();
    expect(ctx.session.value, NearbyScanState.idle);
    expect(ctx.port.stopCalls, 1);

    gate.complete(true);
    await flush();
    expect(
      ctx.session.value,
      NearbyScanState.idle,
      reason: '代次已变，迟到的 true 不能再武装结算',
    );
    expect(ctx.scheduler.activeTimers, isEmpty);
  });

  test('dispose：停扫并取消结算（重复调用幂等）', () async {
    final ctx = _SessionHarness();
    await ctx.start();
    expect(ctx.session.value.scanning, isTrue);

    ctx.session.dispose();
    expect(ctx.port.stopCalls, 1);
    expect(ctx.scheduler.activeTimers, isEmpty, reason: '离开页面不留结算定时器');

    ctx.session.dispose();
    expect(ctx.port.stopCalls, 1);
  });

  test('重新查找：结算后立即重扫，不可用时不发起', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);
    await ctx.start();
    ctx.scheduler.elapse(settleDelay);
    expect(ctx.session.value.scanning, isFalse);
    expect(ctx.session.value.settled, isTrue);

    // rescan 是点击动作：同步段立即调用 startScan，不走 post-frame。
    final pending = ctx.session.rescan();
    expect(ctx.port.startCalls, 2);
    expect(ctx.scheduler.pendingFrames, 0, reason: '重新查找不排首帧');
    expect(ctx.session.value.scanning, isTrue);
    expect(ctx.session.value.settled, isFalse);
    await pending;
    expect(ctx.scheduler.activeTimers, hasLength(1), reason: '重新武装结算');

    // 新扫描照常结算：重新查找不能变成「永远正在查找」。
    ctx.scheduler.elapse(settleDelay);
    expect(ctx.session.value.scanning, isFalse);
    expect(ctx.session.value.settled, isTrue);

    // 不可用时点击同款入口：不调用 startScan（它只会立即失败）。
    ctx.port.availability = SyncNearbyAvailability.lanOff;
    await ctx.session.rescan();
    expect(ctx.port.startCalls, 2);
  });

  test('重复 sync 且状态未变：不重启扫描，已武装的结算照常生效', () async {
    final ctx = _SessionHarness();
    addTearDown(ctx.session.dispose);
    await ctx.start();
    expect(ctx.port.startCalls, 1);

    // provider 通知很频繁：没有差异时只读状态，不能每次通知都重跑 startScan。
    for (var i = 0; i < 3; i++) {
      ctx.session.sync();
    }
    ctx.scheduler.flushFrame();
    await flush();

    expect(ctx.port.startCalls, 1);
    expect(ctx.scheduler.pendingFrames, 0, reason: '无差异不排首帧');
    expect(ctx.session.value.scanning, isTrue, reason: '重复 sync 不重置扫描态');

    // 首次扫描武装的结算不能被空转 sync 撤销。
    ctx.scheduler.elapse(settleDelay);
    expect(ctx.session.value.scanning, isFalse);
    expect(ctx.session.value.settled, isTrue);
  });
}

/// 固定 1.8 秒窗口（与生产默认一致）的会话 + 假端口 / 假调度器。
class _SessionHarness {
  _SessionHarness({
    SyncNearbyAvailability availability = SyncNearbyAvailability.available,
    bool lanRunning = true,
    bool startResult = true,
  }) : port = _FakeNearbyScanPort()
         ..availability = availability
         ..lanRunning = lanRunning
         ..startResult = startResult,
       scheduler = _FakeScheduler() {
    session = NearbyScanSession(
      port: port,
      settleDelay: const Duration(milliseconds: 1800),
      timerFactory: scheduler.createTimer,
      postFrame: scheduler.postFrame,
    );
  }

  final _FakeNearbyScanPort port;
  final _FakeScheduler scheduler;
  late final NearbyScanSession session;

  /// 首次同步 + 首帧启动 + 等待 startScan 返回。
  Future<void> start() async {
    session.sync();
    scheduler.flushFrame();
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeNearbyScanPort implements NearbyScanPort {
  @override
  SyncNearbyAvailability availability = SyncNearbyAvailability.available;

  @override
  bool lanRunning = true;

  bool startResult = true;

  /// 非空时 [startScan] 挂起，直到用例主动完成（模拟可用性变化时仍在途）。
  Completer<bool>? pendingStart;

  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> startScan() {
    startCalls++;
    final pending = pendingStart;
    return pending == null ? Future<bool>.value(startResult) : pending.future;
  }

  @override
  void stopScan() => stopCalls++;
}

/// 虚拟时间调度：结算定时器按累计时间触发，首帧回调攒到 [flushFrame]。
class _FakeScheduler {
  final List<_FakeTimer> _timers = [];
  final List<VoidCallback> _frameCallbacks = [];
  Duration _now = Duration.zero;

  Iterable<_FakeTimer> get activeTimers =>
      _timers.where((timer) => timer.active);

  int get pendingFrames => _frameCallbacks.length;

  NearbyScanTimerCancel createTimer(Duration delay, VoidCallback callback) {
    final timer = _FakeTimer(_now + delay, callback);
    _timers.add(timer);
    return timer.cancel;
  }

  void postFrame(VoidCallback callback) => _frameCallbacks.add(callback);

  void flushFrame() {
    final callbacks = List<VoidCallback>.of(_frameCallbacks);
    _frameCallbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void elapse(Duration duration) {
    _now += duration;
    for (final timer in List<_FakeTimer>.of(_timers)) {
      if (timer.active && timer.dueAt <= _now) timer.fire();
    }
  }
}

class _FakeTimer {
  _FakeTimer(this.dueAt, this.callback);

  final Duration dueAt;
  final VoidCallback callback;
  bool active = true;

  void cancel() => active = false;

  void fire() {
    if (!active) return;
    active = false;
    callback();
  }
}
