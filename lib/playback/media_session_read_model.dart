/// 系统媒体会话的读取面：通知 / 锁屏 / 耳机键需要的播放事实。
///
/// **为什么单独成接口**：`LocalAudioHandler` 是平台媒体控件的适配层，不该认识
/// 1178 行的 `LocalPlaybackService`（读七个具体 getter）。生产实现把服务
/// （外加曲库收藏回调）投影成这个窄面，测试用普通值假实现即可，不必再
/// `extends LocalPlaybackService` 拉起整条 just_audio 链路。
///
/// 写路径不在这里：播放控制仍走 `PlaybackCommandPort`；收藏是曲库写入，
/// 由组合根在曲库 provider 建好后回填（[bindFavorite]），handler 只消费结果。
library;

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

import '../models/play_mode.dart';
import '../sources/source_track.dart';
import 'local_playback_service.dart';

/// 系统媒体会话读取面。
abstract interface class MediaSessionReadModel implements Listenable {
  /// 当前真实播放曲目（null = 无曲目 / 恢复态尚未起播）。
  SourceTrack? get currentTrack;

  bool get isPlaying;

  bool get isLoading;

  PlayMode get mode;

  /// 当前播放进度（通知 / 锁屏进度条的锚点）。
  Duration get position;

  /// 当前曲目时长（优先播放器解析值，服务侧已做回退）。
  Duration get duration;

  /// 真实跳转版本号：变化即补发播放态（Android 只认它判断非连续跳转）。
  int get seekRevision;

  /// 曲目是否已收藏（曲库未接线时 false）。
  bool isFavorite(SourceTrack track);

  /// 切换曲目收藏（曲库未接线时 no-op；异常由 handler 吞掉）。
  Future<void> toggleFavorite(SourceTrack track);

  /// 曲库就绪后回填收藏读写（组合根晚绑定，与 handler 创建顺序无关）。
  void bindFavorite({
    required bool Function(SourceTrack track) isFavorite,
    required Future<void> Function(SourceTrack track) toggle,
  });
}

/// 生产实现：把 [LocalPlaybackService] 的读 getter 投影成读取面。
///
/// 播放事实（曲目 / 状态 / 进度 / 模式 / seek 版本）随服务通知转发；收藏
/// 读写是组合根晚绑定的曲库回调（见 `wireNotificationFavorite`）。
class LocalPlaybackMediaSessionReadModel implements MediaSessionReadModel {
  LocalPlaybackMediaSessionReadModel(this._service);

  final LocalPlaybackService _service;

  bool Function(SourceTrack track)? _isFavorite;
  Future<void> Function(SourceTrack track)? _toggleFavorite;

  @override
  SourceTrack? get currentTrack => _service.currentSourceTrack;

  @override
  bool get isPlaying => _service.isPlaying;

  @override
  bool get isLoading => _service.isLoading;

  @override
  PlayMode get mode => _service.mode;

  @override
  Duration get position => _service.position;

  @override
  Duration get duration => _service.duration;

  @override
  int get seekRevision => _service.seekRevision;

  @override
  bool isFavorite(SourceTrack track) => _isFavorite?.call(track) ?? false;

  @override
  Future<void> toggleFavorite(SourceTrack track) async {
    final toggle = _toggleFavorite;
    if (toggle == null) return;
    await toggle(track);
  }

  @override
  void bindFavorite({
    required bool Function(SourceTrack track) isFavorite,
    required Future<void> Function(SourceTrack track) toggle,
  }) {
    _isFavorite = isFavorite;
    _toggleFavorite = toggle;
  }

  // 通知直接转发服务：读取面只做投影，不额外维护一份状态机。
  @override
  void addListener(VoidCallback listener) => _service.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _service.removeListener(listener);
}
