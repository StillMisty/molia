import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';

import 'media_session_backend.dart';

/// Linux 的 MPRIS 后端工厂（由条件导入选择）。
MediaSessionBackend? createMprisMediaSessionBackend() =>
    MprisMediaSessionBackend();

/// Linux 的 MPRIS 后端：只使用 `audio_service_mpris` 注册的 Dart 平台实现
/// （`AudioServicePlatform.instance`），**不引入 `audio_service` 本体**。
///
/// 平台实现是 `audio_service_mpris` 通过 `dartPluginClass` 自动注册的；这里
/// 只调用 `ConfigureRequest` / `SetMediaItemRequest` / `SetStateRequest`，
/// 并把 [AudioHandlerCallbacks] 映射回统一的 [MediaAction] 流。
///
/// D-Bus 不可用（无 session bus / 初始化失败）时吞掉异常并标记
/// [isAvailable] = false：播放链路照常，只是没有系统媒体会话。
class MprisMediaSessionBackend implements MediaSessionBackend {
  MprisMediaSessionBackend({AudioServicePlatform? platform})
      : _platform = platform ?? AudioServicePlatform.instance;

  final AudioServicePlatform _platform;
  final StreamController<MediaAction> _actions =
      StreamController<MediaAction>.broadcast();

  bool _activated = false;
  bool _available = false;

  /// MPRIS 是否真的注册成功（测试 / 诊断用；失败不抛给播放链路）。
  bool get isAvailable => _available;

  @override
  Future<void> activate() async {
    if (_activated) return;
    _activated = true;
    _platform.setHandlerCallbacks(_MprisHandlerCallbacks(this));
    try {
      await _platform.configure(
        ConfigureRequest(
          config: AudioServiceConfigMessage(
            // MPRIS 用 channel id 生成总线名
            // `org.mpris.MediaPlayer2.<id>.instance<pid>`，用独立命名空间
            // 避免与其它实例 / 旧 audio_service 配置撞名。
            androidNotificationChannelId: 'top.stillmisty.molia.media',
            androidNotificationChannelName: 'Molia',
            androidNotificationChannelDescription: '本地音源播放控制',
          ),
        ),
      );
      _available = true;
    } catch (e) {
      _available = false;
      debugPrint('[Molia] MPRIS 初始化失败，系统媒体会话降级: $e');
    }
  }

  @override
  Future<void> deactivate() async {
    // audio_service_mpris 没有暴露反注册 API：保持对象由 D-Bus 客户端持有，
    // 停止状态由 setState 的 `Stopped` 表达。应用退出时随进程释放。
    _available = false;
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    if (!_available) return;
    try {
      await _platform.setMediaItem(
        SetMediaItemRequest(mediaItem: _mediaItemOf(metadata)),
      );
    } catch (e) {
      _degradeOnError('setMediaItem', e);
    }
  }

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {
    if (!_available) return;
    try {
      await _platform.setState(
        SetStateRequest(state: _playbackStateOf(state)),
      );
    } catch (e) {
      _degradeOnError('setState', e);
    }
  }

  @override
  Future<void> updateAvailableActions(Set<MediaAction> actions) async {
    // MPRIS 的 LoopStatus / Shuffle 由 audio_service_mpris 固定（见包 README），
    // 没有自定义动作槽位；播放顺序仍可在应用内 / Android 通知里切换。
  }

  @override
  Stream<MediaAction> get actions => _actions.stream;

  void _degradeOnError(String operation, Object error) {
    _available = false;
    debugPrint('[Molia] MPRIS $operation 失败，系统媒体会话降级: $error');
  }

  void _emit(MediaAction action) {
    if (_actions.isClosed) return;
    _actions.add(action);
  }
}

/// [MediaMetadata] → `MediaItemMessage`。
///
/// MPRIS 的 xesam 元数据只有标题 / 歌手 / 专辑 / 时长 / 封面，没有
/// `displaySubtitle`（歌词副标题覆盖在 Dart 侧已合成进 title/artist）。
MediaItemMessage _mediaItemOf(MediaMetadata metadata) {
  final artworkUri = metadata.artworkUri;
  return MediaItemMessage(
    id: 'molia:${metadata.title ?? ''}',
    title: metadata.title ?? '',
    artist: metadata.artist,
    album: metadata.album,
    duration: metadata.duration,
    artUri: artworkUri == null ? null : Uri.tryParse(artworkUri),
  );
}

/// [PlaybackState] → `PlaybackStateMessage`。
///
/// `audio_service_mpris` 只读取 `playing` 与 `updatePosition`（以及固定
/// LoopStatus/Rate），其余字段保持语义完整的映射，方便后续替换后端。
PlaybackStateMessage _playbackStateOf(PlaybackState state) {
  return PlaybackStateMessage(
    processingState: switch (state.status) {
      PlaybackStatus.idle => AudioProcessingStateMessage.idle,
      PlaybackStatus.buffering => AudioProcessingStateMessage.buffering,
      PlaybackStatus.playing ||
      PlaybackStatus.paused =>
        AudioProcessingStateMessage.ready,
      PlaybackStatus.ended => AudioProcessingStateMessage.completed,
      PlaybackStatus.error => AudioProcessingStateMessage.error,
    },
    playing: state.status == PlaybackStatus.playing,
    systemActions: const {MediaActionMessage.seek},
    updatePosition: state.position,
    bufferedPosition: state.bufferedPosition,
    speed: state.speed,
    repeatMode: switch (state.repeatMode) {
      MediaRepeatMode.none => AudioServiceRepeatModeMessage.none,
      MediaRepeatMode.all => AudioServiceRepeatModeMessage.all,
      MediaRepeatMode.one => AudioServiceRepeatModeMessage.one,
    },
    shuffleMode: state.shuffleModeEnabled
        ? AudioServiceShuffleModeMessage.all
        : AudioServiceShuffleModeMessage.none,
  );
}

/// 平台回调 → [MediaAction] 流；只覆盖 MPRIS 实际会发生的控制。
class _MprisHandlerCallbacks extends _NoopAudioHandlerCallbacks {
  _MprisHandlerCallbacks(this._backend);

  final MprisMediaSessionBackend _backend;

  @override
  Future<void> play(PlayRequest request) async {
    _backend._emit(MediaAction.play);
  }

  @override
  Future<void> pause(PauseRequest request) async {
    _backend._emit(MediaAction.pause);
  }

  @override
  Future<void> stop(StopRequest request) async {
    _backend._emit(MediaAction.stop);
  }

  @override
  Future<void> skipToNext(SkipToNextRequest request) async {
    _backend._emit(MediaAction.skipToNext);
  }

  @override
  Future<void> skipToPrevious(SkipToPreviousRequest request) async {
    _backend._emit(MediaAction.skipToPrevious);
  }

  @override
  Future<void> seek(SeekRequest request) async {
    _backend._emit(
      MediaAction('seekTo', seekPosition: request.position),
    );
  }
}

/// `AudioHandlerCallbacks` 的空实现：MPRIS 只会触发其中少数几个，
/// 其余方法保留 no-op，避免为平台接口的完整面写一堆噪音。
class _NoopAudioHandlerCallbacks implements AudioHandlerCallbacks {
  const _NoopAudioHandlerCallbacks();

  @override
  Future<void> prepare(PrepareRequest request) async {}

  @override
  Future<void> prepareFromMediaId(PrepareFromMediaIdRequest request) async {}

  @override
  Future<void> prepareFromSearch(PrepareFromSearchRequest request) async {}

  @override
  Future<void> prepareFromUri(PrepareFromUriRequest request) async {}

  @override
  Future<void> play(PlayRequest request) async {}

  @override
  Future<void> playFromMediaId(PlayFromMediaIdRequest request) async {}

  @override
  Future<void> playFromSearch(PlayFromSearchRequest request) async {}

  @override
  Future<void> playFromUri(PlayFromUriRequest request) async {}

  @override
  Future<void> playMediaItem(PlayMediaItemRequest request) async {}

  @override
  Future<void> pause(PauseRequest request) async {}

  @override
  Future<void> click(ClickRequest request) async {}

  @override
  Future<void> stop(StopRequest request) async {}

  @override
  Future<void> addQueueItem(AddQueueItemRequest request) async {}

  @override
  Future<void> insertQueueItem(InsertQueueItemRequest request) async {}

  @override
  Future<void> removeQueueItem(RemoveQueueItemRequest request) async {}

  @override
  Future<void> removeQueueItemAt(RemoveQueueItemAtRequest request) async {}

  @override
  Future<void> skipToNext(SkipToNextRequest request) async {}

  @override
  Future<void> skipToPrevious(SkipToPreviousRequest request) async {}

  @override
  Future<void> fastForward(FastForwardRequest request) async {}

  @override
  Future<void> rewind(RewindRequest request) async {}

  @override
  Future<void> skipToQueueItem(SkipToQueueItemRequest request) async {}

  @override
  Future<void> seek(SeekRequest request) async {}

  @override
  Future<void> setRating(SetRatingRequest request) async {}

  @override
  Future<void> setCaptioningEnabled(SetCaptioningEnabledRequest request) async {
  }

  @override
  Future<void> setRepeatMode(SetRepeatModeRequest request) async {}

  @override
  Future<void> setShuffleMode(SetShuffleModeRequest request) async {}

  @override
  Future<void> seekBackward(SeekBackwardRequest request) async {}

  @override
  Future<void> seekForward(SeekForwardRequest request) async {}

  @override
  Future<void> setSpeed(SetSpeedRequest request) async {}

  @override
  Future<dynamic> customAction(CustomActionRequest request) async => null;

  @override
  Future<void> onTaskRemoved(OnTaskRemovedRequest request) async {}

  @override
  Future<void> onNotificationDeleted(OnNotificationDeletedRequest request) async {
  }

  @override
  Future<void> onNotificationClicked(
    OnNotificationClickedRequest request,
  ) async {}

  @override
  Future<GetChildrenResponse> getChildren(GetChildrenRequest request) async =>
      const GetChildrenResponse(children: []);

  @override
  Future<GetMediaItemResponse> getMediaItem(GetMediaItemRequest request) async =>
      const GetMediaItemResponse(mediaItem: null);

  @override
  Future<SearchResponse> search(SearchRequest request) async =>
      const SearchResponse(mediaItems: []);

  @override
  Future<void> androidSetRemoteVolume(
    AndroidSetRemoteVolumeRequest request,
  ) async {}

  @override
  Future<void> androidAdjustRemoteVolume(
    AndroidAdjustRemoteVolumeRequest request,
  ) async {}
}
