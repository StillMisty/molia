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
/// - 提交落点只认最近一次预览值，不认滑杆回调的入参（快速单击时那是上一帧的
///   旧位置，见 [commit]）；
/// - 曲目身份变化即清预览：旧进度不残留在新曲目的滑杆上；
/// - 时序常量收在这里，不给宿主配置面——行为必须一致。
///
/// 宿主只提供三样东西：position 通道、曲目身份来源与 seek 命令；预览值经
/// [previewMs] 向外发布。
class SeekPreviewController {
  SeekPreviewController({
    required this._position,
    required this._trackChanges,
    required TrackId? Function() currentTrackId,
    required this._seek,
  })  : _currentTrackId = currentTrackId,
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

  /// 松手提交：落点 = 最近一次 [preview] 记下的值；没有预览则什么都不做。
  ///
  /// 不接收落点入参：滑杆在一次点按里会先经 drag-cancel、再经 tap-up 各调一次
  /// `onChangeEnd`，两次回传的都是它**上一帧**拿到的 value——快速单击
  /// （按下 < 100ms）时中间没有一帧重建，那就是点击前的位置，照它提交等于把
  /// 这次点击吞掉（用户看到的是「单击没反应，得按住」）。预览值才是用户点到 /
  /// 拖到的位置。
  ///
  /// 提交后保留显示，直到 position 追上目标（容差 [settleToleranceMs]）或
  /// 超时兜底 [fallbackTimeout]。
  void commit() {
    final double? pending = _previewMs.value;
    if (pending == null) return;
    final target = pending.round();
    _targetMs = target;
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
