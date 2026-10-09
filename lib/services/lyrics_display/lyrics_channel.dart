import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生歌词通道事件（方法名 + 参数）。
class LyricsChannelEvent {
  final String method;
  final Map<String, dynamic> arguments;

  const LyricsChannelEvent(this.method, this.arguments);
}

/// Android 歌词平台通道唯一封装（Dart ↔ 原生）。
///
/// 桌面悬浮窗与 A2DP 状态共用同一个通道：MethodChannel 同名只能有一个
/// 方法调用处理器，因此原生事件集中在此分发，输出/监测器只订阅 [events]。
class LyricsChannel {
  LyricsChannel({MethodChannel? channel})
      : _channel = channel ?? MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String channelName = 'top.stillmisty.molia/lyrics';

  /// 应用内共享实例（原生事件单点分发）。
  static final LyricsChannel instance = LyricsChannel();

  final MethodChannel _channel;
  final StreamController<LyricsChannelEvent> _events =
      StreamController<LyricsChannelEvent>.broadcast();

  Stream<LyricsChannelEvent> get events => _events.stream;

  /// 歌词输出当前只在 Android 落地（桌面平台等官方多窗口 API 稳定后接）。
  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _onNativeCall(MethodCall call) async {
    final raw = call.arguments;
    _events.add(LyricsChannelEvent(
      call.method,
      raw is Map ? Map<String, dynamic>.from(raw) : const {},
    ));
  }

  Future<bool> desktopSupported() async =>
      await _invokeBool('desktop.isSupported') ?? false;

  Future<bool> canDrawOverlays() async =>
      await _invokeBool('desktop.canDrawOverlays') ?? false;

  Future<void> openOverlayPermission() =>
      _invokeVoid('desktop.openOverlayPermission');

  Future<void> showDesktop(Map<String, Object?> config) =>
      _invokeVoid('desktop.show', config);

  Future<void> updateDesktop(Map<String, Object?> presentation) =>
      _invokeVoid('desktop.update', presentation);

  Future<void> setDesktopConfig(Map<String, Object?> config) =>
      _invokeVoid('desktop.setConfig', config);

  Future<void> hideDesktop() => _invokeVoid('desktop.hide');

  Future<void> resetDesktopPosition() => _invokeVoid('desktop.resetPosition');

  Future<bool> isA2dpConnected() async =>
      await _invokeBool('audioRoute.isA2dpConnected') ?? false;

  Future<bool?> _invokeBool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // 非 Android / 未注册：静默降级。
    } on PlatformException {
      // 原生侧失败（如未授权）由 capability 状态体现，不抛到 UI。
    }
  }

  @visibleForTesting
  void debugEmit(LyricsChannelEvent event) => _events.add(event);
}
