import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'audio_focus_policy.dart';

/// 焦点动作解析：把事件 + 本守卫当前记账交给纯策略（平台 / 设置差异）。
typedef AudioFocusActionResolver = AudioFocusAction Function(
  AudioInterruptionEvent event, {
  required bool pausedForFocus,
  required bool duckedForFocus,
});

/// 音频焦点守卫：其他应用夺走音频焦点（来电 / 其他播放器开始出声 / 语音提示）
/// 时的暂停 / 压低 / 续播 / 恢复决策。
///
/// 为什么单独成模块：中断事件的判读（哪种事件算「丢失焦点」、什么时候该续播
/// 或恢复音量）与播放动作解耦——注入策略函数与四个动作回调即可脱离
/// audio_session 插件单测，真实接线在 `LocalPlaybackService`。
///
/// 语义（决策表在 `audio_focus_policy.dart` / ADR-0035）：
/// - `begin` 按策略得到 pause / duck / none；只有 pause / duck 会登记记账。
/// - `end` 只在**本守卫真的暂停过 / 压低过**时调用 resume / restore；用户手动
///   操作（暂停、切歌、手动续播）会清掉两种记账，焦点归还不会抢回控制权。
/// - 压低的结束事件丢失时（后续来了永久失焦等）由 [AudioFocusAction.none]
///   分支兜底恢复，避免下一首莫名变轻。
///
/// **just_audio 的内建中断处理与音频会话激活都必须关闭**（生产构造
/// `AudioPlayer(handleInterruptions: false, handleAudioSessionActivation:
/// false)`）：激活归 `AudioSessionLifecycle` 唯一所有，否则打开应用就会抢
/// 音频（ADR-0035）。
class AudioFocusGuard {
  AudioFocusGuard({
    required AudioFocusActionResolver actionFor,
    required Future<bool> Function() onPause,
    required Future<void> Function() onResume,
    required Future<bool> Function() onDuck,
    required Future<void> Function() onRestore,
    Future<void> Function()? onSettled,
    // 私有字段名不能作为调用方参数名；保留可读的公开参数名。
    // ignore: prefer_initializing_formals
  }) : _actionFor = actionFor,
       // ignore: prefer_initializing_formals
       _onPause = onPause,
       // ignore: prefer_initializing_formals
       _onResume = onResume,
       // ignore: prefer_initializing_formals
       _onDuck = onDuck,
       // ignore: prefer_initializing_formals
       _onRestore = onRestore,
       // ignore: prefer_initializing_formals
       _onSettled = onSettled;

  /// 纯策略：事件 + 本守卫记账 → 动作。
  final AudioFocusActionResolver _actionFor;

  /// 暂停动作，返回是否真的暂停了（无曲目 / 本来已暂停 → false）。
  final Future<bool> Function() _onPause;

  /// 续播动作（仅在本守卫暂停过、且系统表示可续播时调用）。
  final Future<void> Function() _onResume;

  /// 压低动作，返回是否真的压低了（暂停 / 停止 / 无曲目 → false）。
  final Future<bool> Function() _onDuck;

  /// 恢复音量的动作（仅在本守卫压低过时调用）。
  final Future<void> Function() _onRestore;

  /// 中断结束且没有续播时的回调（服务据此启动暂停释放宽限期）。
  final Future<void> Function()? _onSettled;

  StreamSubscription<AudioInterruptionEvent>? _subscription;

  /// 中断事件串行链：begin / end 的处理都可能 await 播放器，必须按到达顺序
  /// 完成，避免「暂停还没落地就续播」的竞态。
  Future<void> _serial = Future<void>.value();

  bool _detached = false;

  /// attach 代次：重新订阅后，旧流已排队的回调不再生效。
  int _attachGeneration = 0;

  /// 代次令牌：用户手动操作时自增，使正在执行的暂停 / 压低不再登记记账。
  int _actionGeneration = 0;

  bool _pausedForInterruption = false;
  bool _duckedForInterruption = false;

  /// 订阅音频中断事件流（真实实现传端口的中断流）。
  ///
  /// 重复调用会替换旧订阅（同一守卫只认最后一条流），并清掉上一轮记账。
  void attach(Stream<AudioInterruptionEvent> interruptions) {
    _attachGeneration++;
    cancelPendingInterruption();
    _detached = false;
    unawaited(_subscription?.cancel());
    _subscription = interruptions.listen(
      handleInterruption,
      onError: (Object e) => debugPrint('[AudioFocusGuard] 中断事件流错误: $e'),
    );
  }

  /// 处理单个中断事件（订阅回调与单测共用同一入口）。
  void handleInterruption(AudioInterruptionEvent event) {
    final generation = _attachGeneration;
    _serial = _serial
        .then((_) => _handleInterruption(event, generation))
        .catchError((Object e) => debugPrint('[AudioFocusGuard] 中断处理失败: $e'));
  }

  Future<void> _handleInterruption(
    AudioInterruptionEvent event,
    int attachGeneration,
  ) async {
    if (_detached || attachGeneration != _attachGeneration) return;

    if (event.begin) {
      final action = _actionFor(
        event,
        pausedForFocus: _pausedForInterruption,
        duckedForFocus: _duckedForInterruption,
      );
      switch (action) {
        case AudioFocusAction.pause:
          // 暂停落地即撤销 duck 记账：播放服务会同时把 duck 倍数复位。
          final wasDucked = _duckedForInterruption;
          _duckedForInterruption = false;
          if (wasDucked) await _onRestore();
          if (_detached || attachGeneration != _attachGeneration) return;
          final actionGeneration = _actionGeneration;
          final paused = await _onPause();
          if (_detached || attachGeneration != _attachGeneration) return;
          if (actionGeneration != _actionGeneration) return;
          if (paused) _pausedForInterruption = true;
          return;
        case AudioFocusAction.duck:
          final actionGeneration = _actionGeneration;
          final ducked = await _onDuck();
          if (_detached || attachGeneration != _attachGeneration) return;
          if (actionGeneration != _actionGeneration) return;
          if (ducked) _duckedForInterruption = true;
          return;
        case AudioFocusAction.none:
          // 永久失焦等被忽略的事件也要清掉可能中的 duck，否则 duck-end
          // 丢失后下一首会一直很轻。
          if (_duckedForInterruption) {
            _duckedForInterruption = false;
            await _onRestore();
          }
          return;
        case AudioFocusAction.resume:
        case AudioFocusAction.restore:
          return;
      }
    }

    final action = _actionFor(
      event,
      pausedForFocus: _pausedForInterruption,
      duckedForFocus: _duckedForInterruption,
    );
    final wasPaused = _pausedForInterruption;
    final wasDucked = _duckedForInterruption;
    _pausedForInterruption = false;
    _duckedForInterruption = false;
    if (action == AudioFocusAction.resume && wasPaused) {
      await _onResume();
    } else if (wasDucked) {
      // 正常 duck-end 或丢失的 duck-end（永久失焦）都恢复；只会恢复本守卫
      // 压过的那一次。
      await _onRestore();
    }
    if (_detached || attachGeneration != _attachGeneration) return;
    await _onSettled?.call();
  }

  /// 用户主动操作（暂停 / 切歌 / 停止）后取消所有待恢复记账。
  ///
  /// 代次自增同时让正在执行的暂停 / 压低结果失效，避免它们把记账又写回来。
  void cancelPendingInterruption() {
    _actionGeneration++;
    _pausedForInterruption = false;
    _duckedForInterruption = false;
  }

  /// 退订（服务 dispose 时调用）；退订后已排队的事件不再执行。
  Future<void> detach() async {
    _detached = true;
    _attachGeneration++;
    cancelPendingInterruption();
    await _subscription?.cancel();
    _subscription = null;
  }
}
