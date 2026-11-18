import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'audio_focus_policy.dart';
import 'platform_audio_port.dart';

/// 音频会话生命周期的唯一所有者（ADR-0035）。
///
/// 只有它决定「什么时候配置 / 激活 / 释放平台音频会话」。播放服务在每次
/// 起播前经 [onStartRequested] 请求激活，在暂停 / 停止 / 退出时报告状态；
/// 组合根在系统媒体会话激活成功后调用 [onSystemMediaSessionActivated]。
/// 队列、会话存储、provider 与 UI 都不感知这里。
///
/// 状态机：`inactive → active → releasePending → inactive`。
/// 暂停后等 [pauseGrace] 再释放（给「暂停一下马上继续」留出无感窗口），
/// 停止 / 退出立即释放。所有定时器都带代次，取消的释放绝不会晚到一步把
/// 刚激活的会话又关掉。
class AudioSessionLifecycle {
  AudioSessionLifecycle({
    required PlatformAudioPort port,
    required ValueListenable<bool> playWithOtherApps,
    TargetPlatform? platform,
    this.pauseGrace = defaultPauseGrace,
    this.activationWait = defaultActivationWait,
    // 私有字段名不能作为调用方参数名；保留可读的公开参数名。
    // ignore: prefer_initializing_formals
  }) : _port = port,
       // ignore: prefer_initializing_formals
       _playWithOtherApps = playWithOtherApps,
       platform = platform ?? defaultTargetPlatform;

  /// 暂停后保留会话的默认宽限期：足够覆盖「暂停听一句再继续」，又不至于
  /// 让暂停的应用长时间占着焦点 / 音频资源。
  static const Duration defaultPauseGrace = Duration(seconds: 20);

  /// 激活被拒后等待中断结束的上限；超时按可重试播放失败处理，不能静默挂起。
  static const Duration defaultActivationWait = Duration(seconds: 5);

  final PlatformAudioPort _port;
  final ValueListenable<bool> _playWithOtherApps;

  /// 决策表使用的平台（生产 = `defaultTargetPlatform`；测试可注入。
  ///
  /// 播放服务也读同一个值，避免测试为了覆盖策略去改全局平台、连带切换
  /// 缓存 / 播放后端）。
  final TargetPlatform platform;

  final Duration pauseGrace;
  final Duration activationWait;

  _AudioSessionState _state = _AudioSessionState.inactive;
  bool _playing = false;

  /// 最近一次暂停是中断造成的，且还没有结算 / 重新拿回焦点。
  ///
  /// 永久失焦（`unknown`）在 Android 上没有对应的 `end` 事件：暂停后
  /// `_state` 仍是 active，但平台焦点已经不在本应用手里。下一次起播必须
  /// 重新请求一次，不能走「已激活」的快速路径。
  bool _focusMayBeLost = false;

  bool _configured = false;
  bool _configDirty = false;
  bool _disposed = false;
  Future<void>? _startFuture;

  Timer? _releaseTimer;
  int _releaseGeneration = 0;

  Completer<bool>? _pendingActivation;
  Timer? _activationTimer;
  bool _retryingActivation = false;

  StreamSubscription<AudioInterruptionEvent>? _interruptions;

  /// 端口是否具备真实平台实现（桌面 no-op 为 false）。
  bool get supported => _port.supported;

  Stream<AudioInterruptionEvent> get interruptions => _port.interruptions;
  Stream<void> get outputLost => _port.outputLost;
  Stream<AudioDevicesChangedEvent> get deviceChanges => _port.deviceChanges;

  /// 建立端口连接并订阅激活重试所需的结束事件。幂等。
  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    _playWithOtherApps.addListener(_onSettingChanged);
    try {
      await _port.start();
    } catch (e) {
      debugPrint('[AudioSessionLifecycle] 启动音频端口失败: $e');
    }
    if (!_port.supported || _disposed) return;
    _interruptions = _port.interruptions.listen(
      _onInterruptionForActivation,
      onError: (Object e) => debugPrint('[AudioSessionLifecycle] 中断事件流错误: $e'),
    );
  }

  /// 起播前的唯一入口：取消待释放 → 必要时配置 → 激活。
  ///
  /// 返回 false 表示激活被拒且等待窗口内没有恢复（电压 / 通话占用焦点），
  /// 调用方不得起播，应把播放意图保留为用户可重试的失败。
  Future<bool> onStartRequested() async {
    if (!_port.supported) return true;
    await start();
    _cancelRelease();
    if (_state == _AudioSessionState.active && !_focusMayBeLost) {
      return true;
    }

    final pending = _pendingActivation;
    if (pending != null && !pending.isCompleted) return pending.future;

    await _ensureConfigured();
    if (await _tryActivate()) {
      _state = _AudioSessionState.active;
      _focusMayBeLost = false;
      return true;
    }
    if (_disposed) return false;
    return _waitForActivation();
  }

  /// 播放真正开始（播放器已下发 play）：保持会话、取消待释放。
  void onPlaybackStarted() {
    _playing = true;
    _focusMayBeLost = false;
    if (!_port.supported) return;
    _cancelRelease();
    _completePendingActivation(false);
  }

  /// 暂停：默认在宽限期后释放；[deferRelease] 用于「中断导致的暂停」。
  ///
  /// 中断期间不能放弃焦点：Android 上放弃焦点会把本应用移出焦点栈，系统
  /// 不会再发 gain 事件，通话结束后就不会自动续播。要等守卫结算完这次
  /// 中断（[onInterruptionSettled]）再开始计时。
  void onPaused({bool deferRelease = false}) {
    _playing = false;
    if (!_port.supported) return;
    if (deferRelease) {
      // 永久失焦没有 end 事件；记录「焦点可能已丢」，下一次起播重新激活。
      _focusMayBeLost = true;
      return;
    }
    if (_state == _AudioSessionState.releasePending) return;
    if (_state != _AudioSessionState.active) return;
    _scheduleRelease();
  }

  /// 中断结束且没有续播：此时才允许开始暂停释放计时。
  void onInterruptionSettled() {
    if (!_port.supported || _playing || _disposed) return;
    _focusMayBeLost = false;
    if (_state != _AudioSessionState.active) return;
    _scheduleRelease();
  }

  /// 停止：立即释放（取消待释放 / 待激活）。
  Future<void> onStopped() async {
    _playing = false;
    _focusMayBeLost = false;
    _cancelRelease();
    _completePendingActivation(false);
    await _deactivate();
  }

  /// 系统媒体会话（iOS Darwin 后端）激活成功后由组合根通知。
  ///
  /// iOS 的媒体会话后端会自行 `setCategory(.playback)` + `setActive(true)`，
  /// 覆盖 `audio_session` 的 `mixWithOthers` 并打断其他应用。这里恢复配置；
  /// 若还没有播放就带 notify-others 立刻释放，让冷启动保持安静。
  Future<void> onSystemMediaSessionActivated() async {
    // 只有 iOS 的 Darwin 后端会在激励媒体会话时自行激活 AVAudioSession；
    // Android 的媒体会话后端不请求焦点，也没有需要恢复的 mix 选项。
    if (platform != TargetPlatform.iOS) return;
    if (!_port.supported || _disposed) return;
    await start();
    await _ensureConfigured(force: true);
    if (_playing ||
        _state == _AudioSessionState.active ||
        _state == _AudioSessionState.releasePending) {
      return;
    }
    // 媒体会话后端在端口背后激活了平台会话：状态是 inactive，但必须显式
    // 释放一次，否则「打开应用就抢音频」的问题仍在。
    await _deactivate(force: true);
  }

  void _onSettingChanged() {
    _configDirty = true;
    if (!_port.supported || _disposed || !_configured) return;
    unawaited(_reconfigureForCurrentSetting());
  }

  Future<void> _reconfigureForCurrentSetting() async {
    await _ensureConfigured();
    if (!_playing || _state != _AudioSessionState.active) return;
    if (platform != TargetPlatform.android) return;
    // Android 的 gain 类型属于焦点请求本身：配置改了必须放弃再请求一次，
    // 否则设置切换只改文件、不改当前焦点。
    try {
      await _port.deactivate(notifyOthers: false);
      final granted = await _port.activate();
      if (!granted) {
        // 旧焦点已放弃、新请求被拒：播放还在继续但已经没有焦点。标记后
        // 下一次起播会重新请求，不留在静默无焦点状态。
        _focusMayBeLost = true;
        _state = _AudioSessionState.inactive;
        debugPrint('[AudioSessionLifecycle] 重配置后重新获取音频焦点被拒');
      }
    } catch (e) {
      _focusMayBeLost = true;
      debugPrint('[AudioSessionLifecycle] 重新请求音频焦点失败: $e');
    }
  }

  Future<void> _ensureConfigured({bool force = false}) async {
    if (!_port.supported || _disposed) return;
    if (!force && _configured && !_configDirty) return;
    _configDirty = false;
    try {
      await _port.configure(
        audioSessionConfigurationFor(
          playWithOtherApps: _playWithOtherApps.value,
          platform: platform,
        ),
      );
      _configured = true;
    } catch (e) {
      // 平台失败只记日志：播放能继续就继续，生命周期不能成为新的崩溃点。
      debugPrint('[AudioSessionLifecycle] 配置音频会话失败: $e');
    }
  }

  Future<bool> _tryActivate() async {
    try {
      return await _port.activate();
    } catch (e) {
      // 端口异常（插件缺失 / 平台通道坏）不是焦点被拒：降级为「无声会
      // 话也能播」，否则一次插件故障会永久挡住播放。显式 false 才是拒绝。
      debugPrint('[AudioSessionLifecycle] 音频会话不可用，降级为无会话播放: $e');
      return true;
    }
  }

  /// 激活被拒：保留起播意图，等一次中断结束再重试；超时返回 false。
  Future<bool> _waitForActivation() {
    final existing = _pendingActivation;
    if (existing != null && !existing.isCompleted) return existing.future;
    final completer = Completer<bool>();
    _pendingActivation = completer;
    _activationTimer?.cancel();
    _activationTimer = Timer(activationWait, () {
      _completePendingActivation(false);
    });
    return completer.future;
  }

  void _onInterruptionForActivation(AudioInterruptionEvent event) async {
    // 只有结束事件意味着「通话 / 提示可能结束了」；重试一次，成败都收口。
    if (event.begin || _disposed) return;
    final pending = _pendingActivation;
    if (pending == null || pending.isCompleted || _retryingActivation) return;
    _retryingActivation = true;
    final granted = await _tryActivate();
    _retryingActivation = false;
    if (_disposed) return;
    if (granted) {
      _state = _AudioSessionState.active;
      _focusMayBeLost = false;
    }
    _completePendingActivation(granted);
  }

  void _completePendingActivation(bool granted) {
    _activationTimer?.cancel();
    _activationTimer = null;
    final pending = _pendingActivation;
    _pendingActivation = null;
    if (pending != null && !pending.isCompleted) pending.complete(granted);
  }

  void _scheduleRelease() {
    _state = _AudioSessionState.releasePending;
    final generation = ++_releaseGeneration;
    _releaseTimer?.cancel();
    _releaseTimer = Timer(pauseGrace, () {
      if (_disposed ||
          generation != _releaseGeneration ||
          _state != _AudioSessionState.releasePending) {
        return;
      }
      _releaseTimer = null;
      unawaited(_deactivate());
    });
  }

  void _cancelRelease() {
    _releaseGeneration++;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (_state == _AudioSessionState.releasePending) {
      _state = _AudioSessionState.active;
    }
  }

  Future<void> _deactivate({bool force = false}) async {
    if (!_port.supported) {
      _state = _AudioSessionState.inactive;
      return;
    }
    if (!force && _state == _AudioSessionState.inactive) return;
    _state = _AudioSessionState.inactive;
    try {
      // 每次 iOS 释放都通知其他应用可以恢复（Android 忽略该参数）。
      await _port.deactivate(notifyOthers: true);
    } catch (e) {
      debugPrint('[AudioSessionLifecycle] 释放音频会话失败: $e');
    }
  }

  /// 退订、释放会话与端口。幂等；退出收尾与 provider dispose 都会调用。
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void>? _disposeFuture;

  Future<void> _dispose() async {
    _disposed = true;
    _releaseGeneration++;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _completePendingActivation(false);
    _playWithOtherApps.removeListener(_onSettingChanged);
    final interruptions = _interruptions;
    _interruptions = null;
    // 不 await 取消：fake_async 下 StreamSubscription.cancel 的完成依赖真实
    // 事件循环；销毁流程不能让一次退订把释放卡住。
    unawaited(interruptions?.cancel());
    _playing = false;
    _focusMayBeLost = false;
    await _deactivate();
    try {
      await _port.dispose();
    } catch (e) {
      debugPrint('[AudioSessionLifecycle] 释放音频端口失败: $e');
    }
  }
}

enum _AudioSessionState { inactive, active, releasePending }
