import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/snapshot_source.dart';
import 'lyrics_channel.dart';

/// A2DP（蓝牙音频）连接状态：蓝牙歌词的门控信号。
///
/// 探测函数与变化流可注入（单测不触平台通道）；非 Android 平台恒为 false；
/// 检测失败按「未连接」处理，仅影响蓝牙 output 的生效率。
///
/// 快照是单个布尔值（[state]），订阅面是 [changes]；不再继承 `ChangeNotifier`。
class AudioRouteMonitor implements SnapshotSource<bool> {
  AudioRouteMonitor({
    LyricsChannel? channel,
    Future<bool> Function()? probe,
    Stream<bool>? changes,
  }) : _channelOverride = channel,
       _probeOverride = probe,
       _changesOverride = changes;

  final LyricsChannel? _channelOverride;
  final Future<bool> Function()? _probeOverride;
  final Stream<bool>? _changesOverride;
  final SnapshotSignal _signal = SnapshotSignal();

  StreamSubscription<bool>? _subscription;
  bool _connected = false;

  @override
  bool get state => _connected;

  @override
  Listenable get changes => _signal;

  Future<void> init() async {
    try {
      if (_probeOverride != null || _changesOverride != null) {
        if (_probeOverride != null) {
          _set(await _probeOverride());
        }
        _subscription = (_changesOverride ?? const Stream<bool>.empty()).listen(
          _set,
          onError: (Object _) {},
        );
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
    _signal.notify();
  }

  void dispose() {
    _subscription?.cancel();
  }
}
