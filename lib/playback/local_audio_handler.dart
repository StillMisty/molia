import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../managers/artwork_cache.dart';
import '../sources/source_track.dart';
import 'local_playback_service.dart';

/// 当前平台是否具备 audio_service 的系统级媒体会话实现。
///
/// - Android / iOS / macOS：插件原生支持；
/// - Linux / Windows：无原生实现（pub get 不会注册插件），调用 init 会抛
///   MissingPluginException，因此必须跳过初始化、保持应用内播放的现有行为；
/// - Web：audio_service 通过 audio_service_web 提供了实现，但音源本地播放
///   在 Web 端不可用（无本地 JS 引擎），初始化系统媒体会话没有意义，同样跳过。
bool get isSystemMediaSessionSupported {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// 初始化系统媒体会话（后台播放 + 通知栏/锁屏/耳机键）。
///
/// 平台不支持或初始化失败时返回 null，播放功能降级为原来的应用内播放，
/// 不阻塞启动。调用点应在 `runApp` 之前（audio_service 要求，保证冷启动
/// 时媒体按钮事件能被处理）。
///
/// [artworkBlocked] 为省流模式封面网关：返回 true 时媒体项不带 `artUri`，
/// 避免 audio_service 为通知/锁屏下载封面（省流时只保留本地缓存封面）。
///
/// 通知封面复用统一封面缓存（`ArtworkCache` 的共享 CacheManager）：
/// 与 App 内是同一份已下载文件、同一套请求头（浏览器 UA + 平台 Referer），
/// 命中时无需重复下载；缓存不可用时回退 audio_service 默认缓存。
Future<LocalAudioHandler?> initSystemMediaSession(
  LocalPlaybackService service, {
  bool Function()? artworkBlocked,
}) async {
  if (!isSystemMediaSessionSupported) {
    return null;
  }
  try {
    return await AudioService.init<LocalAudioHandler>(
      builder: () =>
          LocalAudioHandler(service, artworkBlocked: artworkBlocked),
      // managerOrNull 内部吞掉构造异常并返回 null（回退默认缓存），
      // 不会把「封面缓存不可用」升级成「媒体会话初始化失败」。
      cacheManager: await ArtworkCache.instance.managerOrNull(),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'top.stillmisty.molia.channel.audio',
        androidNotificationChannelName: 'Molia',
        androidNotificationChannelDescription: '本地音源播放控制',
        androidNotificationOngoing: false,
        // 暂停时保持前台服务：Android 12+ 禁止后台重新拉起前台服务，
        // 该设置保证从通知栏/耳机键恢复播放不被系统拦截
        // （代价是暂停期间前台服务常驻，音乐类应用的标准行为）。
        androidStopForegroundOnPause: false,
      ),
    );
  } catch (e) {
    debugPrint('[Molia] audio_service 初始化失败，降级为应用内播放: $e');
    return null;
  }
}

/// 把 [LocalPlaybackService] 的状态映射为系统媒体会话所需的
/// [MediaItem] / [PlaybackState]，并把通知栏 / 锁屏 / 耳机键的控制请求
/// 委托回 LocalPlaybackService 的现有方法。
///
/// 这样 UI 侧的 `PlaybackProvider` 仍是唯一状态入口，本地播放公开 API 不变。
class LocalAudioHandler extends BaseAudioHandler with SeekHandler {
  LocalAudioHandler(this._service, {bool Function()? artworkBlocked})
      : _artworkBlocked = artworkBlocked ?? (() => false) {
    _service.addListener(_syncFromService);
    _syncFromService(force: true);
  }

  final LocalPlaybackService _service;

  /// 省流模式封面网关：返回 true 时媒体项不带 artUri（不为通知下载封面）。
  final bool Function() _artworkBlocked;

  // 上次广播的状态，用于去重：位置每 400ms 都会变化，但系统媒体会话只需要
  // 在曲目切换 / 播放状态变化 / 明显跳转（seek）时收到 setState。
  String? _lastTrackId;
  bool? _lastPlaying;
  bool? _lastLoading;
  Duration _lastPosition = Duration.zero;

  static const Set<MediaAction> _systemActions = {
    MediaAction.seek,
    MediaAction.seekForward,
    MediaAction.seekBackward,
    MediaAction.skipToNext,
    MediaAction.skipToPrevious,
  };

  // 系统控制入口（通知栏 / 锁屏 / 耳机键）：委托给 LocalPlaybackService

  @override
  Future<void> play() async {
    if (_service.hasTrack && !_service.isPlaying) {
      await _service.toggle();
    }
    _syncFromService(force: true);
  }

  @override
  Future<void> pause() async {
    if (_service.isPlaying) {
      await _service.toggle();
    }
    _syncFromService(force: true);
  }

  @override
  Future<void> stop() async {
    await _service.stop();
    _syncFromService(force: true);
  }

  @override
  Future<void> skipToNext() async {
    await _service.skipToNext();
    _syncFromService(force: true);
  }

  @override
  Future<void> skipToPrevious() async {
    await _service.skipToPrevious();
    _syncFromService(force: true);
  }

  @override
  Future<void> seek(Duration position) async {
    await _service.seek(position);
    _syncFromService(force: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _service.playQueueIndex(index);
    _syncFromService(force: true);
  }

  // 状态映射

  void _syncFromService({bool force = false}) {
    final track = _service.currentSourceTrack;
    final trackId = track?.id;
    final playing = _service.isPlaying;
    final loading = _service.isLoading;
    final position = _service.position;

    final trackChanged = trackId != _lastTrackId;
    final playingChanged = playing != _lastPlaying;
    final loadingChanged = loading != _lastLoading;
    final seeked =
        (position - _lastPosition).abs() > const Duration(seconds: 1);
    if (!force &&
        !trackChanged &&
        !playingChanged &&
        !loadingChanged &&
        !seeked) {
      return;
    }
    _lastTrackId = trackId;
    _lastPlaying = playing;
    _lastLoading = loading;
    _lastPosition = position;

    if (track == null) {
      mediaItem.add(null);
      queue.add(const []);
      playbackState.add(PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
        controls: const [],
        systemActions: const {},
      ));
      return;
    }

    queue.add([
      for (final item in _service.queueTracks) _toMediaItem(item),
    ]);
    mediaItem.add(_toMediaItem(track, isCurrent: true));
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: _systemActions,
      androidCompactActionIndices: const [0, 1, 2],
      processingState:
          loading ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      bufferedPosition: position,
      speed: 1.0,
      queueIndex: _service.currentIndex >= 0 &&
              _service.currentIndex < _service.queueTracks.length
          ? _service.currentIndex
          : null,
    ));
  }

  MediaItem _toMediaItem(SourceTrack track, {bool isCurrent = false}) {
    final duration = isCurrent && _service.duration > Duration.zero
        ? _service.duration
        : track.duration;
    return mediaItemForTrack(
      track,
      duration: duration,
      artworkBlocked: _artworkBlocked(),
    );
  }
}

/// 构造系统媒体会话用的 [MediaItem]（纯函数，便于单测）。
///
/// - [artworkBlocked] 为省流模式网关：true 时通知不带封面，避免
///   audio_service 为通知下载封面；
/// - 通知封面由 audio_service 在 Dart 侧下载（默认 UA 为 `Dart/x`），
///   网易云等 CDN 会直接 403 —— 与 App 内封面同一问题，因此统一带上
///   [ArtworkCache.headersFor]（浏览器 UA + 平台 Referer）。
@visibleForTesting
MediaItem mediaItemForTrack(
  SourceTrack track, {
  required Duration? duration,
  required bool artworkBlocked,
}) {
  final artUri = artworkBlocked ? null : parseArtUri(track.coverUrl);
  return MediaItem(
    id: 'lx:${track.id}',
    title: track.title,
    artist: track.artist.isEmpty ? '未知歌手' : track.artist,
    album: track.album.isEmpty ? null : track.album,
    duration: duration,
    artUri: artUri,
    artHeaders:
        artUri == null ? null : ArtworkCache.headersFor(artUri.toString()),
    extras: const {'source': 'lx'},
  );
}

/// 解析封面地址为 [MediaItem.artUri]。
///
/// 空串 / 无 scheme 返回 null；`//host/path` 这类协议相对地址按 https 补全。
@visibleForTesting
Uri? parseArtUri(String? url) {
  if (url == null || url.isEmpty) return null;
  final normalized = url.startsWith('//') ? 'https:$url' : url;
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasScheme) return null;
  return uri;
}
