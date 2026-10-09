import 'dart:async';

import 'package:flutter/foundation.dart';

import 'lyrics_channel.dart';

/// A2DP（蓝牙音频）连接状态：蓝牙歌词的门控信号。
///
/// 探测函数与变化流可注入（单测不触平台通道）；非 Android 平台恒为 false；
/// 检测失败按「未连接」处理，仅影响蓝牙 output 的生效率。
class AudioRouteMonitor extends ChangeNotifier {
  AudioRouteMonitor({
    LyricsChannel? channel,
    Future<bool> Function()? probe,
    Stream<bool>? changes,
  })  : _channelOverride = channel,
        _probeOverride = probe,
        _changesOverride = changes;

  final LyricsChannel? _channelOverride;
  final Future<bool> Function()? _probeOverride;
  final Stream<bool>? _changesOverride;

  StreamSubscription<bool>? _subscription;
  bool _connected = false;

  bool get connected => _connected;

  Future<void> init() async {
    try {
      if (_probeOverride != null || _changesOverride != null) {
        if (_probeOverride != null) {
          _set(await _probeOverride());
        }
        _subscription = (_changesOverride ?? const Stream<bool>.empty())
            .listen(_set, onError: (Object _) {});
        return;
      }
      if (!LyricsChannel.isSupportedPlatform) return;
      final channel = _channelOverride ?? LyricsChannel.instance;
      _set(await channel.isA2dpConnected());
      _subscription = channel.events
          .where((event) => event.method == 'audioRoute.onA2dpChanged')
          .map((event) => event.arguments['connected'] == true)
          .listen(_set, onError: (Object _) {});
    } catch (_) {
      // 检测不可用：保持 false，不影响其他输出。
    }
  }

  void _set(bool value) {
    if (value == _connected) return;
    _connected = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
