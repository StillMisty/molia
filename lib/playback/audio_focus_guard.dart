import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 音频焦点守卫：其他应用夺走音频焦点（来电 / 其他播放器开始出声 / 语音提示）
/// 时的暂停 / 续播决策。
///
/// 为什么单独成模块：中断事件的判读（哪种事件算「丢失焦点」、什么时候该续播）
/// 与播放动作解耦——注入 [shouldPause] / [onFocusLoss] / [onFocusGain] 即可
/// 脱离 audio_session 插件单测，真实接线在
/// `LocalPlaybackService._configureAudioSession`。
///
/// 语义：
/// - `begin == true`（丢失焦点）且 [shouldPause] 为真 → 暂停；duck 类型也按
///   暂停处理（just_audio 对 `usage=media` 的 duck 不压音量，放过去等于和
///   别的应用叠着播；会话侧再声明 `androidWillPauseWhenDucked`，系统会把
///   may-duck 请求升级为 transient 暂停事件）。
/// - `begin == false`（焦点归还）且系统表示可续播（`type == pause`）→ 仅当
///   **本守卫真的暂停过**才续播；用户手动暂停不会因为焦点归还被抢回。
///   不可续播（`unknown`）与 duck 结束不动作。
/// - [shouldPause] 在事件到达时读取，设置切换即时生效。
///
/// **just_audio 的内建中断处理必须关闭**（生产构造
/// `AudioPlayer(handleInterruptions: false)`）：它也会订阅同一条中断流并
/// 直接暂停，只绕开本守卫无法做到「其他应用出声时继续播放」。
class AudioFocusGuard {
  AudioFocusGuard({
    required bool Function() shouldPause,
    required Future<bool> Function() onFocusLoss,
    required Future<void> Function() onFocusGain,
  })  : _shouldPause = shouldPause,
        _onFocusLoss = onFocusLoss,
        _onFocusGain = onFocusGain;

  /// 当前策略是否允许因焦点丢失暂停（设置 / 平台差异由调用方决定）。
  final bool Function() _shouldPause;

  /// 暂停动作，返回是否真的暂停了（无曲目 / 本来已暂停 → false）。
  final Future<bool> Function() _onFocusLoss;

  /// 续播动作（仅在本守卫暂停过、且系统表示可续播时调用）。
  final Future<void> Function() _onFocusGain;

  StreamSubscription<AudioInterruptionEvent>? _subscription;

  /// 中断事件串行链：begin / end 的处理都可能 await 播放器，必须按到达顺序
  /// 完成，避免「暂停还没落地就续播」的竞态。
  Future<void> _serial = Future<void>.value();

  bool _detached = false;

  /// attach 代次：重新订阅后，旧流已排队的回调不再生效。
  int _attachGeneration = 0;

  /// 代次令牌：用户手动暂停时自增，使正在执行的暂停不再登记「待续播」。
  int _resumeGeneration = 0;

  bool _pausedForInterruption = false;

  /// 订阅音频中断事件流（真实实现传 `AudioSession.interruptionEventStream`）。
  ///
  /// 重复调用会替换旧订阅（同一守卫只认最后一条流），并清掉上一轮待续播。
  void attach(Stream<AudioInterruptionEvent> interruptions) {
    _attachGeneration++;
    cancelPendingResume();
    _detached = false;
    unawaited(_subscription?.cancel());
    _subscription = interruptions.listen(handleInterruption);
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
      if (!_shouldPause()) return;
      final resumeGeneration = _resumeGeneration;
      final paused = await _onFocusLoss();
      if (_detached || attachGeneration != _attachGeneration) return;
      // 用户已经手动暂停 / 恢复过：这次中断的暂停结果不再登记续播。
      if (resumeGeneration != _resumeGeneration) return;
      if (paused) _pausedForInterruption = true;
      return;
    }

    final shouldResume =
        _pausedForInterruption && event.type == AudioInterruptionType.pause;
    _pausedForInterruption = false;
    if (!shouldResume || _detached || attachGeneration != _attachGeneration) {
      return;
    }
    await _onFocusGain();
  }

  /// 用户主动操作（暂停 / 切歌 / 手动续播）后取消「中断结束自动续播」。
  void cancelPendingResume() {
    _resumeGeneration++;
    _pausedForInterruption = false;
  }

  /// 退订（服务 dispose 时调用）；退订后已排队的事件不再执行。
  Future<void> detach() async {
    _detached = true;
    _attachGeneration++;
    cancelPendingResume();
    await _subscription?.cancel();
    _subscription = null;
  }
}
