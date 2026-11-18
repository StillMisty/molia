import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'tray_menu_labels.dart';

/// macOS 播放菜单的 Dart 端：把菜单点击翻译成与托盘 / 任务栏相同的动作，
/// 并把当前文案 / 可用性下发给原生（ADR-0036）。
///
/// 原生菜单没有应用本地化表，所以标题与三个菜单项文案都从 Dart 按当前语言
/// 推送；原生只应用变化过的值。菜单命令不带键位，媒体键与应用内快捷键仍是
/// 唯一键位来源。
class PlaybackMenu {
  /// [channel] / [supported] 只给测试注入：Linux / Windows 上 [isSupported]
  /// 为 false，不注入就覆盖不到命令路由与载荷去重。
  PlaybackMenu({MethodChannel? channel, bool? supported})
    : _channel = channel ?? _defaultChannel,
      _supported = supported ?? Platform.isMacOS;

  /// 与 `macos/Runner/AppDelegate.swift` 的通道名成对出现，改一处必须改两处。
  static const MethodChannel _defaultChannel = MethodChannel(
    'top.stillmisty.molia/playback_menu',
  );

  static final Logger _logger = Logger('molia.playback_menu');

  final MethodChannel _channel;
  final bool _supported;

  TrayMenuLabels? _labels;
  bool _hasTrack = false;
  bool _isPlaying = false;
  bool _initialized = false;

  /// 上一次成功下发的载荷：文案 / 状态没变不重复发。
  Map<String, Object>? _lastPayload;

  void Function()? _onTogglePlay;
  void Function()? _onPrevious;
  void Function()? _onNext;

  /// 当前平台是否有原生播放菜单（仅 macOS）。
  bool get isSupported => _supported;

  /// 注册菜单点击回调并下发首份状态（组合根在首帧后调用一次）。
  ///
  /// 初始化之前的 `sync` 只记状态、不发通道；首帧前原生菜单保持禁用，因此
  /// 不会出现「点了没反应」的可用菜单项。
  Future<void> init({
    required TrayMenuLabels labels,
    required bool hasTrack,
    required bool isPlaying,
    required void Function() onTogglePlay,
    required void Function() onPrevious,
    required void Function() onNext,
  }) async {
    if (!_supported || _initialized) return;
    _initialized = true;
    _labels = labels;
    _hasTrack = hasTrack;
    _isPlaying = isPlaying;
    _onTogglePlay = onTogglePlay;
    _onPrevious = onPrevious;
    _onNext = onNext;
    _channel.setMethodCallHandler(_handleCall);
    await _push();
  }

  /// 同步文案与可用性（播放快照 / 语言 / 品牌名变化时由组合根调用）。
  void sync({
    required TrayMenuLabels labels,
    required bool hasTrack,
    required bool isPlaying,
  }) {
    if (!_supported) return;
    _labels = labels;
    _hasTrack = hasTrack;
    _isPlaying = isPlaying;
    unawaited(_push());
  }

  /// 摘掉命令处理函数（退出 / 测试清理用）。
  void dispose() {
    if (!_initialized) return;
    _initialized = false;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _push() async {
    final labels = _labels;
    if (!_initialized || labels == null) return;
    final payload = <String, Object>{
      'menuTitle': labels.menuTitle,
      'playPauseLabel': _isPlaying ? labels.pause : labels.play,
      'previousLabel': labels.previous,
      'nextLabel': labels.next,
      'hasTrack': _hasTrack,
      'isPlaying': _isPlaying,
    };
    final last = _lastPayload;
    if (last != null && mapEquals(last, payload)) return;
    // 先记账再发：同一轮 sync 的多个监听可能连续触发，记账放 await 之后会
    // 让同一份载荷发两遍。
    _lastPayload = payload;
    try {
      await _channel.invokeMethod<void>('update', payload);
    } catch (error) {
      if (identical(_lastPayload, payload)) _lastPayload = null;
      _logger.fine('播放菜单状态同步失败：$error');
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'togglePlayPause':
        _onTogglePlay?.call();
      case 'previousTrack':
        _onPrevious?.call();
      case 'nextTrack':
        _onNext?.call();
      default:
        // 原生先加了新命令 / 非法方法：忽略，不影响播放。
        break;
    }
  }
}
