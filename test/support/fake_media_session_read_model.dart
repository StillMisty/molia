/// 系统媒体会话读取面的普通值假实现（不依赖 `LocalPlaybackService`）。
///
/// handler 测试只关心「读到什么」：直接改字段 + `emit*` 通知，不触碰
/// just_audio 平台通道，也不需要为每个用例覆写七个 getter。
library;

import 'package:flutter/foundation.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/media_session_read_model.dart';
import 'package:molia/sources/source_track.dart';

class FakeMediaSessionReadModel extends ChangeNotifier
    implements MediaSessionReadModel {
  @override
  SourceTrack? currentTrack;

  @override
  bool isPlaying = false;

  @override
  bool isLoading = false;

  @override
  PlayMode mode = PlayMode.sequential;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  int seekRevision = 0;

  /// 未绑定曲库时的默认收藏态（绑定后以 [isFavoriteOverride] 为准）。
  bool favorite = false;

  bool Function(SourceTrack track)? isFavoriteOverride;
  Future<void> Function(SourceTrack track)? toggleOverride;

  /// 是否已回填曲库回调：未接线时 `toggleFavorite` 与真实读取面一样是 no-op。
  bool _bound = false;

  /// 切换收藏的调用台账（通知动作测试用）。
  final List<SourceTrack> toggled = [];

  @override
  bool isFavorite(SourceTrack track) {
    if (!_bound) return favorite;
    return isFavoriteOverride?.call(track) ?? favorite;
  }

  @override
  Future<void> toggleFavorite(SourceTrack track) async {
    if (!_bound) return;
    toggled.add(track);
    final toggle = toggleOverride;
    if (toggle != null) {
      await toggle(track);
      return;
    }
    favorite = !favorite;
  }

  @override
  void bindFavorite({
    required bool Function(SourceTrack track) isFavorite,
    required Future<void> Function(SourceTrack track) toggle,
  }) {
    _bound = true;
    isFavoriteOverride = isFavorite;
    toggleOverride = toggle;
  }

  /// 模拟播放推进（位置 tick）。
  void emitPosition(Duration value) {
    position = value;
    notifyListeners();
  }

  /// 模拟真实位置跳转（用户 seek / 内部回跳）：版本号自增。
  void emitSeek(Duration value) {
    position = value;
    seekRevision++;
    notifyListeners();
  }

  /// 模拟播放 / 缓冲状态变化。
  void emitPlaying({bool? playing, bool? loading}) {
    if (playing != null) isPlaying = playing;
    if (loading != null) isLoading = loading;
    notifyListeners();
  }

  /// 模拟播放器解析出真实时长。
  void emitDuration(Duration value) {
    duration = value;
    notifyListeners();
  }

  /// 模拟 App 内切换播放模式。
  void emitMode(PlayMode value) {
    mode = value;
    notifyListeners();
  }

  /// 模拟曲目 / 封面变化。
  void emitTrack(SourceTrack? track) {
    currentTrack = track;
    notifyListeners();
  }
}
