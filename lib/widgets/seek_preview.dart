import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/track.dart';

/// 进度拖动预览的宿主共享状态机（播放页 / 桌面底栏 / 其它 seek 宿主）。
///
/// 语义的唯一实现，两份宿主必须一致的部分都在这里：
/// - 拖动中显示本地值，不吃 position 通道的旧值（预览优先）；
/// - 松手提交 seek 后**保留**本地值显示，直到 position 追上目标
///   （容差 [settleToleranceMs]）或超时兜底 [fallbackTimeout]，避免滑杆在
///   position 通道追上之前回跳到旧位置；
/// - 新的拖动 / 新的提交作废上一次的等待落点；
/// - 曲目身份变化即清预览：旧进度不残留在新曲目的滑杆上；
/// - 时序常量收在这里，不给宿主配置面——行为必须一致。
///
/// 宿主只提供三样东西：position 通道、曲目身份来源与 seek 命令；预览值经
/// [previewMs] 向外发布。
class SeekPreviewController {
  SeekPreviewController({
    required ValueListenable<Duration> position,
    required Listenable trackChanges,
    required TrackId? Function() currentTrackId,
    required void Function(int milliseconds) seek,
  })  : _position = position,
        _trackChanges = trackChanges,
        _currentTrackId = currentTrackId,
        _seek = seek,
        _lastTrackId = currentTrackId() {
    _position.addListener(_handlePositionTick);
    _trackChanges.addListener(_handleTrackChanged);
  }

  /// position 追上目标的容差：差值落在容差内即撤下预览。
  static const int settleToleranceMs = 800;

  /// 兜底：position 通道迟迟不追上目标时主动撤下预览。
  static const Duration fallbackTimeout = Duration(milliseconds: 1500);

  final ValueListenable<Duration> _position;
  final Listenable _trackChanges;
  final TrackId? Function() _currentTrackId;
  final void Function(int milliseconds) _seek;

  final ValueNotifier<double?> _previewMs = ValueNotifier<double?>(null);

  int? _targetMs;
  Timer? _fallbackTimer;
  TrackId? _lastTrackId;

  /// 拖动预览值（毫秒）；null = 无预览，渲染方按 position 取值。
  ValueListenable<double?> get previewMs => _previewMs;

  /// 拖动中：记下本地值并作废上一次的等待落点。
  void preview(double valueMs) {
    _targetMs = null;
    _fallbackTimer?.cancel();
    _previewMs.value = valueMs;
  }

  /// 松手提交：保留显示直到 position 追上或 [fallbackTimeout] 兜底。
  void commit(double valueMs) {
    final target = valueMs.round();
    _targetMs = target;
    _previewMs.value = valueMs;
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(fallbackTimeout, () {
      // 期间若发生新拖动 / 新提交，这次等待作废。
      if (_targetMs != target) return;
      _clearPreview();
    });
    _seek(target);
  }

  /// position 通道 tick：只在有等待落点时才处理。
  void _handlePositionTick() {
    final target = _targetMs;
    if (target == null) return;
    if ((_position.value.inMilliseconds - target).abs() <= settleToleranceMs) {
      _clearPreview();
    }
  }

  /// [trackChanges] 是 provider 的通知面，切歌之外的快照变化也会进来，
  /// 因此按身份变化判断而不是无条件清。
  void _handleTrackChanged() {
    final id = _currentTrackId();
    if (id == _lastTrackId) return;
    _lastTrackId = id;
    _clearPreview();
  }

  void _clearPreview() {
    _targetMs = null;
    _fallbackTimer?.cancel();
    _previewMs.value = null;
  }

  void dispose() {
    _position.removeListener(_handlePositionTick);
    _trackChanges.removeListener(_handleTrackChanged);
    _fallbackTimer?.cancel();
    _previewMs.dispose();
  }
}
