/// 桌面输出监听端口：Windows / macOS 走原生通道，Linux 走 `pactl subscribe`。
///
/// 只实现 [PlatformAudioPort] 的 `outputLost` 能力：`supported` 仍为 false，
/// 表明它不提供 `audio_session` 的配置 / 激活 / 释放；`emitsOutputLost` 为
/// true，播放服务据此在桌面也订阅输出丢失事件（ADR-0036）。
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pactl_output_watcher.dart';
import 'platform_audio_port.dart';

/// 与 Windows runner / macOS AppDelegate 的通道名成对出现，改一处必须改两处。
const String desktopAudioOutputChannelName =
    'top.stillmisty.molia/audio_output';

/// 桌面输出丢失端口。
///
/// 失败静默：平台通道未注册、`pactl` 缺失或沙箱拒绝都只记一行日志，不阻塞
/// 播放，也不向 UI 暴露错误。事件只表示「之前的默认输出已不可用」，不表示
/// 「有设备变化」；重复事件由幂等的 `pause(urgent: true)` 消化。
class DesktopAudioOutputPort implements PlatformAudioPort {
  DesktopAudioOutputPort({
    MethodChannel? channel,
    TargetPlatform? platform,
    PactlOutputWatcher? pactlWatcher,
  }) : _channel =
           channel ??
           const MethodChannel(
             desktopAudioOutputChannelName,
             StandardMethodCodec(),
           ),
       _platform = platform ?? defaultTargetPlatform,
       // ignore: prefer_initializing_formals
       _pactlWatcher = pactlWatcher;

  final MethodChannel _channel;
  final TargetPlatform _platform;
  PactlOutputWatcher? _pactlWatcher;

  final StreamController<void> _outputLost = StreamController<void>.broadcast();

  bool _started = false;
  bool _disposed = false;

  @override
  bool get supported => false;

  @override
  bool get emitsOutputLost => true;

  @override
  Stream<AudioInterruptionEvent> get interruptions => const Stream.empty();

  @override
  Stream<void> get outputLost => _outputLost.stream;

  @override
  Stream<AudioDevicesChangedEvent> get deviceChanges => const Stream.empty();

  @override
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    switch (_platform) {
      case TargetPlatform.windows || TargetPlatform.macOS:
        _channel.setMethodCallHandler(_handleMethodCall);
      case TargetPlatform.linux:
        final watcher =
            _pactlWatcher ?? PactlOutputWatcher(onOutputLost: _emitOutputLost);
        _pactlWatcher = watcher;
        try {
          await watcher.start();
        } catch (e) {
          // 契约要求静默；watcher 内部已收口，这里只兜住意外异常。
          debugPrint('[DesktopAudioOutput] 启动输出监听失败: $e');
        }
      default:
        break;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    // 只有一种事件；未知方法忽略（原生可能先于 Dart 增加新事件）。
    if (call.method != 'outputLost') return;
    _emitOutputLost();
  }

  void _emitOutputLost() {
    if (_disposed || _outputLost.isClosed) return;
    _outputLost.add(null);
  }

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}

  @override
  Future<bool> activate() async => true;

  @override
  Future<void> deactivate({required bool notifyOthers}) async {}

  /// 摘掉通道处理函数 / 结束 `pactl` 子进程，并让晚到的事件失效。幂等。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started &&
        (_platform == TargetPlatform.windows ||
            _platform == TargetPlatform.macOS)) {
      _channel.setMethodCallHandler(null);
    }
    final watcher = _pactlWatcher;
    _pactlWatcher = null;
    try {
      await watcher?.dispose();
    } catch (e) {
      debugPrint('[DesktopAudioOutput] 停止输出监听失败: $e');
    }
    if (!_outputLost.isClosed) await _outputLost.close();
  }

  // 桌面没有会话实现：以下调用保持 no-op（由 `supported == false` 保证
  // AudioSessionLifecycle 不会主动进入这些路径）。
}

/// 生产工厂：按当前平台创建桌面端口。
PlatformAudioPort createDesktopAudioOutputPort() => DesktopAudioOutputPort();
