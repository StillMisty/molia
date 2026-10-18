import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'tray_menu_labels.dart';

/// Windows 任务栏缩略图工具栏：`ITaskbarList3::ThumbBarAddButtons` 的 Dart 出口。
///
/// 生命周期与托盘菜单同源：文案 / 状态由组合根在播放、收藏、语言变化时同步
/// （同一份 [TrayMenuLabels] 与同一批动作闭包），点击经通道 [MethodCall]
/// `pressed` 回到这里再落到 provider。
///
/// 为什么按钮要由 Dart 驱动而不是原生自己读播放态：文案要按界面语言解析，
/// 收藏态在曲库层；原生只负责把它画出来（见 `taskbar_thumb_bar.cpp`）。
class TaskbarThumbBar {
  /// [channel] / [supported] 只给测试注入：Linux 测试机上 [isSupported] 为
  /// false，不注入就没法覆盖状态同步与点击分发（与下载通知同一模式）。
  TaskbarThumbBar({MethodChannel? channel, bool? supported})
      : _channel = channel ?? _defaultChannel,
        _supported = supported ?? Platform.isWindows;

  /// 与 `windows/runner/flutter_window.cpp` 的通道名成对出现，改一处必须改两处。
  static const MethodChannel _defaultChannel =
      MethodChannel('top.stillmisty.molia/taskbar');

  static final Logger _logger = Logger('molia.taskbar_thumb_bar');

  final MethodChannel _channel;
  final bool _supported;

  TrayMenuLabels? _labels;
  bool _hasTrack = false;
  bool _isPlaying = false;
  bool _isFavorite = false;
  bool _initialized = false;

  /// 上一次成功下发的载荷：原生每次都会重画按钮，值没变不必再发。
  Map<String, Object>? _lastPayload;

  void Function()? _onTogglePlay;
  void Function()? _onPrevious;
  void Function()? _onNext;
  void Function()? _onToggleFavorite;

  /// 当前平台是否支持任务栏缩略图工具栏（仅 Windows）。
  bool get isSupported => _supported;

  /// 注册点击回调并把按钮挂上（组合根在首帧后调用一次；重复调用无效）。
  ///
  /// 不 `await` 首次状态同步：通道失败（插件缺失 / 原生未注册）只记日志，
  /// 不影响应用其余功能。
  Future<void> init({
    required TrayMenuLabels labels,
    required void Function() onTogglePlay,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function() onToggleFavorite,
  }) async {
    if (!_supported || _initialized) return;
    _initialized = true;
    _labels = labels;
    _onTogglePlay = onTogglePlay;
    _onPrevious = onPrevious;
    _onNext = onNext;
    _onToggleFavorite = onToggleFavorite;
    _channel.setMethodCallHandler(_handleCall);
    await _push();
  }

  /// 更新按钮文案（界面语言切换时由组合根重新注入）。
  void setLabels(TrayMenuLabels labels) {
    if (!_supported) return;
    _labels = labels;
    unawaited(_push());
  }

  /// 播放态 / 有无曲目：无曲目时四个按钮整体置灰（原生侧按此设 THBF_DISABLED）。
  void setPlaybackState({required bool hasTrack, required bool isPlaying}) {
    if (!_supported) return;
    if (_hasTrack == hasTrack && _isPlaying == isPlaying) return;
    _hasTrack = hasTrack;
    _isPlaying = isPlaying;
    unawaited(_push());
  }

  /// 当前曲目的收藏态（收藏按钮在「已收藏 / 未收藏」两个图标间切换）。
  void setFavorite(bool isFavorite) {
    if (!_supported) return;
    if (_isFavorite == isFavorite) return;
    _isFavorite = isFavorite;
    unawaited(_push());
  }

  /// 摘掉点击回调（退出 / 测试清理用）。
  void dispose() {
    if (!_initialized) return;
    _initialized = false;
    _channel.setMethodCallHandler(null);
  }

  /// 把当前状态一次性下发给原生（载荷与上次相同则不发）。
  Future<void> _push() async {
    final labels = _labels;
    if (!_initialized || labels == null) return;
    final payload = <String, Object>{
      'hasTrack': _hasTrack,
      'isPlaying': _isPlaying,
      'isFavorite': _isFavorite,
      'tooltipPrevious': labels.previous,
      'tooltipPlayPause': _isPlaying ? labels.pause : labels.play,
      'tooltipNext': labels.next,
      'tooltipFavorite':
          _isFavorite ? labels.removeFavorite : labels.addFavorite,
    };
    final last = _lastPayload;
    if (last != null && mapEquals(last, payload)) return;
    // 先记账再发：一次 syncTray 里可能连着触发多个 setter，记账放 await 之后
    // 会让后一次同步看不到前一次的结果，同一份载荷发两遍。
    _lastPayload = payload;
    try {
      await _channel.invokeMethod<void>('update', payload);
    } catch (error) {
      // 发送失败：清掉记账，下一次状态变化时重试（原生未注册 / 非 Windows 构建）。
      if (identical(_lastPayload, payload)) _lastPayload = null;
      _logger.fine('任务栏按钮状态同步失败：$error');
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'pressed') return;
    switch (call.arguments) {
      case 'previous':
        _onPrevious?.call();
      case 'playPause':
        _onTogglePlay?.call();
      case 'next':
        _onNext?.call();
      case 'favorite':
        _onToggleFavorite?.call();
      default:
        // 未知按钮（原生加了按钮但 Dart 还没跟上）：忽略。
        break;
    }
  }
}
