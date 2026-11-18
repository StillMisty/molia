/// 音频会话生命周期：状态机、20 秒暂停宽限、立即停止释放、启动重配置 /
/// 释放、代次守卫与激活拒绝重试。真实 collaborator + 记录型假端口 + fake_async。
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_session_lifecycle.dart';

import '../support/fake_platform_audio_port.dart';

void main() {
  late FakePlatformAudioPort port;
  late ValueNotifier<bool> settings;
  late AudioSessionLifecycle lifecycle;

  setUp(() {
    port = FakePlatformAudioPort();
    settings = ValueNotifier<bool>(true);
    lifecycle = AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
    );
  });

  tearDown(() {
    // 有些用例在 fake_async 内触发 dispose；其未来由 fake 时钟驱动，这里
    // 不再 await（否则测试结束后挂在一个已退出的 zone 上）。
    unawaited(lifecycle.dispose());
    settings.dispose();
  });

  /// 在 fake_async 里启动一个异步调用并跑完它的微任务。
  bool startNowOn(FakeAsync async, AudioSessionLifecycle target) {
    var granted = false;
    unawaited(target.onStartRequested().then((value) => granted = value));
    async.flushMicrotasks();
    return granted;
  }

  bool startNow(FakeAsync async) => startNowOn(async, lifecycle);

  test('起播前先配置再激活；宽限期内暂停不释放', () {
    fakeAsync((async) {
      expect(startNow(async), isTrue);
      expect(port.calls, ['start', 'configure', 'activate']);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 19));
      expect(port.deactivateCalls, 0);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(port.deactivateCalls, 1);
      expect(port.deactivateNotifyOthers, [true]);
    });
  });

  test('宽限期内重新起播取消释放，之后不会把新会话关掉', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 19));
      expect(startNow(async), isTrue, reason: '已激活时直接放行，不重复 activate');
      expect(port.activateCalls, 1);
      async.elapse(const Duration(seconds: 5));
      expect(port.deactivateCalls, 0);
    });
  });

  test('恢复后再暂停重新计一整段宽限', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      async.elapse(const Duration(seconds: 10));

      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      async.elapse(const Duration(seconds: 19));
      expect(port.deactivateCalls, 0);

      async.elapse(const Duration(seconds: 2));
      expect(port.deactivateCalls, 1);
    });
  });

  test('中断暂停未结算（永久失焦）：下一次起播重新激活焦点', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      // 永久失焦没有 end 事件：onInterruptionSettled 永远不会到。
      lifecycle.onPaused(deferRelease: true);
      async.elapse(const Duration(minutes: 2));
      expect(port.deactivateCalls, 0, reason: '中断未结算不释放');

      expect(startNow(async), isTrue);
      expect(port.activateCalls, 2, reason: '不能走已激活快速路径，必须重新请求焦点');
      expect(port.deactivateCalls, 0, reason: '重新请求前不主动释放旧会话');
      lifecycle.onPlaybackStarted();
    });
  });

  test('中断结算后焦点已回：宽限内起播不重复激活', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused(deferRelease: true);
      lifecycle.onInterruptionSettled();
      async.flushMicrotasks();

      expect(startNow(async), isTrue);
      expect(port.activateCalls, 1);
      expect(port.deactivateCalls, 0);
    });
  });

  test('停止立即释放（不等宽限）', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      unawaited(lifecycle.onStopped());
      async.flushMicrotasks();

      expect(port.deactivateCalls, 1);
      async.elapse(const Duration(seconds: 30));
      expect(port.deactivateCalls, 1, reason: '待释放定时器已经取消');
    });
  });

  test('dispose 与退出收尾幂等：只释放一次、只关端口一次', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      unawaited(lifecycle.dispose());
      unawaited(lifecycle.dispose());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));

      expect(port.deactivateCalls, 1);
      expect(port.disposeCalls, 1);
    });
  });

  test('停止后 dispose 不再重复释放', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      unawaited(lifecycle.onStopped());
      async.flushMicrotasks();
      unawaited(lifecycle.dispose());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));

      expect(port.deactivateCalls, 1);
    });
  });

  test('被取代的释放定时器不会关掉刚激活的会话', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      async.elapse(const Duration(seconds: 19));

      expect(startNow(async), isTrue);
      lifecycle.onPlaybackStarted();
      // 原本 1 秒后到点的旧 timer 已被代次守卫丢弃。
      async.elapse(const Duration(seconds: 10));
      expect(port.deactivateCalls, 0);
    });
  });

  test('播放中切换混播设置：重配置并在 Android 重新请求一次焦点', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      settings.value = false;
      async.flushMicrotasks();

      expect(port.configureCalls, 2);
      expect(
        port.configurations.last.androidAudioFocusGainType,
        AndroidAudioFocusGainType.gain,
      );
      expect(port.configurations.last.androidWillPauseWhenDucked, isTrue);
      expect(port.activateCalls, 2, reason: 'Android 放弃旧焦点后重新请求');
      expect(port.deactivateCalls, 1);
    });
  });

  test('暂停中切换设置只重配置，不重新抢焦点', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      settings.value = false;
      async.flushMicrotasks();

      expect(port.configureCalls, 2);
      expect(port.activateCalls, 1);
      expect(port.deactivateCalls, 0, reason: '暂停宽限期内还没有释放');
    });
  });

  test('播放中重配置焦点被拒：标记焦点丢失，下一次起播重新请求', () {
    fakeAsync((async) {
      port.activateResults.addAll([true, false]);
      startNow(async);
      lifecycle.onPlaybackStarted();

      settings.value = false;
      async.flushMicrotasks();
      expect(port.activateCalls, 2, reason: '放弃旧焦点后重新请求一次');

      port.activateResult = true;
      expect(startNow(async), isTrue);
      expect(port.activateCalls, 3, reason: '下一次起播不能假定仍持有焦点');
    });
  });

  test('端口激活抛异常（插件不可用）→ 降级为无会话播放，不等待 5 秒', () {
    fakeAsync((async) {
      port.throwOnActivate = true;
      bool? granted;
      unawaited(lifecycle.onStartRequested().then((value) => granted = value));
      async.flushMicrotasks();

      expect(granted, isTrue);
      expect(port.activateCalls, 1);
      // 不应留下等待中断的定时器。
      async.elapse(const Duration(seconds: 5));
      expect(granted, isTrue);
    });
  });

  test('激活被拒后保留意图，中断结束时重试一次并成功', () {
    fakeAsync((async) {
      port.activateResults.addAll([false, true]);
      bool? granted;
      unawaited(lifecycle.onStartRequested().then((value) => granted = value));
      async.flushMicrotasks();
      expect(granted, isNull, reason: '等待中断结束，不立即失败');
      expect(port.activateCalls, 1);

      port.emitInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(port.activateCalls, 2);
      expect(granted, isTrue);
    });
  });

  test('激活被拒且 5 秒内没有中断结束 → 可重试失败，意图被清掉', () {
    fakeAsync((async) {
      port.activateResults.add(false);
      bool? granted;
      unawaited(lifecycle.onStartRequested().then((value) => granted = value));
      async.flushMicrotasks();
      expect(granted, isNull);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(granted, isFalse);

      // 超时后再起播会重新尝试（不会复用挂起的 Completer）。
      port.activateResult = true;
      expect(startNow(async), isTrue);
      expect(port.activateCalls, 2);
    });
  });

  test('端口配置 / 释放抛错只吞掉，不影响生命周期推进', () {
    fakeAsync((async) {
      port.throwOnConfigure = true;
      expect(startNow(async), isTrue);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused();
      port.throwOnDeactivate = true;
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();

      expect(port.deactivateCalls, 1);
    });
  });

  test('中断暂停先不释放：守卫结算后才开始宽限计时', () {
    fakeAsync((async) {
      startNow(async);
      lifecycle.onPlaybackStarted();
      lifecycle.onPaused(deferRelease: true);
      async.elapse(const Duration(minutes: 1));
      expect(port.deactivateCalls, 0, reason: '中断未结束不能放弃焦点');

      lifecycle.onInterruptionSettled();
      async.elapse(const Duration(seconds: 19));
      expect(port.deactivateCalls, 0);
      async.elapse(const Duration(seconds: 2));
      expect(port.deactivateCalls, 1);
    });
  });

  test('iOS 冷启动：先重配置，没有播放就带 notify 立即释放', () {
    final iosPort = FakePlatformAudioPort();
    final iosLifecycle = AudioSessionLifecycle(
      port: iosPort,
      playWithOtherApps: settings,
      platform: TargetPlatform.iOS,
    );
    addTearDown(iosLifecycle.dispose);
    fakeAsync((async) {
      unawaited(iosLifecycle.onSystemMediaSessionActivated());
      async.flushMicrotasks();

      expect(iosPort.calls, ['start', 'configure', 'deactivate:notify']);
      expect(iosPort.activateCalls, 0);
      expect(iosPort.deactivateNotifyOthers, [true]);
    });
  });

  test('iOS 媒体会话激活时已在播放：只重配置，不释放', () {
    final iosPort = FakePlatformAudioPort();
    final iosLifecycle = AudioSessionLifecycle(
      port: iosPort,
      playWithOtherApps: settings,
      platform: TargetPlatform.iOS,
    );
    addTearDown(iosLifecycle.dispose);
    fakeAsync((async) {
      expect(startNowOn(async, iosLifecycle), isTrue);
      iosLifecycle.onPlaybackStarted();
      final before = iosPort.configureCalls;

      unawaited(iosLifecycle.onSystemMediaSessionActivated());
      async.flushMicrotasks();

      expect(iosPort.configureCalls, before + 1);
      expect(iosPort.deactivateCalls, 0);
    });
  });

  test('Android 媒体会话激活不触发会话重配置 / 释放', () {
    fakeAsync((async) {
      unawaited(lifecycle.onSystemMediaSessionActivated());
      async.flushMicrotasks();

      expect(port.calls, isEmpty, reason: 'Android 媒体会话后端不请求音频焦点');
    });
  });

  test('桌面 no-op 端口：全部调用立即成功且不产生平台动作', () {
    fakeAsync((async) {
      final noop = AudioSessionLifecycle(
        port: FakePlatformAudioPort(supported: false),
        playWithOtherApps: settings,
        platform: TargetPlatform.linux,
      );
      var granted = false;
      unawaited(noop.onStartRequested().then((value) => granted = value));
      async.flushMicrotasks();
      expect(granted, isTrue);
      noop.onPlaybackStarted();
      noop.onPaused();
      async.elapse(const Duration(minutes: 1));
      unawaited(noop.dispose());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
    });
  });
}
