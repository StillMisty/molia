import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 音频焦点守卫：其他应用夺走音频焦点（来电 / 其他播放器开始出声 / 语音提示）
/// 时暂停本应用播放。
///
/// 为什么单独成模块：中断事件的判读（哪种事件算「丢失焦点」、什么时候不该动）
/// 与「暂停」这个动作解耦——注入 [onFocusLoss] 即可脱离 audio_session 插件单测，
/// 真实接线（`AudioSession.interruptionEventStream`）在
/// `LocalPlaybackService._configureAudioSession`。
///
/// 语义（按平台惯例）：
/// - `begin == true`（丢失焦点）→ 暂停，含 duck 类型：播放后端 just_audio 对
///   `usage=media` 的 duck 事件既不压音量也不暂停（只有 `usage=game` 压半音量），
///   把 duck 放过去等于「和别的应用叠着播」；会话侧再声明
///   `androidWillPauseWhenDucked`（见 `LocalPlaybackService`），系统会把
///   may-duck 请求升级为 transient 满音量，本应用收到 LOSS_TRANSIENT 级别的
///   begin 事件；
/// - `begin == false`（焦点归还）→ **不动作、不自动续播**：永久丢失焦点
///   （用户去听别的应用了）不该抢回播放；transient 丢失（来电 / 导航播报）
///   的续播由 just_audio 内建中断处理负责（`handleInterruptions` 默认开），
///   这里再 play 会与用户的暂停意图打架。
class AudioFocusGuard {
  AudioFocusGuard({required Future<void> Function() onFocusLoss})
      : _onFocusLoss = onFocusLoss;

  /// 丢失焦点时的动作（生产 = `LocalPlaybackService.pause`）。
  ///
  /// 必须是幂等的：中断事件可能连续到达（多次焦点变化、插件重放）。
  final Future<void> Function() _onFocusLoss;

  StreamSubscription<AudioInterruptionEvent>? _subscription;
  bool _detached = false;

  /// 订阅音频中断事件流（真实实现传 `AudioSession.interruptionEventStream`）。
  ///
  /// 重复调用会替换旧订阅（同一守卫只认最后一条流）。
  void attach(Stream<AudioInterruptionEvent> interruptions) {
    _detached = false;
    unawaited(_subscription?.cancel());
    _subscription = interruptions.listen(handleInterruption);
  }

  /// 处理单个中断事件（订阅回调与单测共用同一入口）。
  void handleInterruption(AudioInterruptionEvent event) {
    if (!event.begin) return;
    // 延后一个 microtask 再暂停：just_audio 的中断监听与这里同订一条流，
    // 它要看到「暂停前还在播」才会记账、在焦点归还时续播；我们先暂停会让
    // 它以为本来就没在播（来电结束后音乐停在暂停态）。
    scheduleMicrotask(() {
      if (_detached) return;
      unawaited(Future<void>.sync(_onFocusLoss).catchError((Object e) {
        debugPrint('[AudioFocusGuard] 焦点丢失暂停失败: $e');
      }));
    });
  }

  /// 退订（服务 dispose 时调用）；退订后已排队的暂停动作不再执行。
  Future<void> detach() async {
    _detached = true;
    await _subscription?.cancel();
    _subscription = null;
  }
}
