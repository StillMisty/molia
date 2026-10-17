import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_media_session/flutter_media_session.dart';

import '../l10n/app_localizations.dart';
import '../managers/artwork_cache.dart';
import '../models/play_mode.dart';
import '../services/language_service.dart';
import '../services/lyrics_display/media_lyric_composer.dart';
import '../sources/source_track.dart';
import 'local_playback_service.dart';
import 'media_artwork_uri.dart';
import 'media_session_backend.dart';
import 'media_session_backend_factory.dart';

/// 当前平台是否具备系统级媒体会话实现。
///
/// - Android / iOS / macOS / Windows：`flutter_media_session` 原生实现；
/// - Linux：`audio_service_mpris`（D-Bus 不可用时静默降级）。
bool get isSystemMediaSessionSupported {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux =>
      true,
    _ => false,
  };
}

/// 播放顺序动作的 id：系统控件里循环切换「顺序 / 单曲循环 / 随机」。
///
/// Android 通知上的自定义动作按字符串 `getIdentifier` 取 drawable
/// （release 的 shrinkResources 靠 `keep.xml` 的 `@drawable/audio_service_*`
/// 保留），因此三个模式各配一个矢量图标。资源名沿用历史命名，避免动
/// 发布清单；`flutter_media_session` 的 `customIconResource` 只接受裸资源名
/// （不带 `drawable/` 前缀）。
const String playModeActionId = 'lx.playMode';

/// 播放模式 → 通知动作图标（Android drawable 资源名，不带目录前缀）。
const Map<PlayMode, String> playModeActionIcons = {
  PlayMode.sequential: 'audio_service_repeat_all',
  PlayMode.singleRepeat: 'audio_service_repeat_one',
  PlayMode.shuffle: 'audio_service_shuffle',
};

/// 当前界面语言的 l10n（通知动作文案）。
///
/// 与托盘菜单同一解析口径：用户选择优先、否则跟随系统，不支持的 locale
/// 回退首个支持语言（`lookupAppLocalizations` 对不支持的语言会抛错）。
AppLocalizations _currentLocalizations() {
  final effective = LanguageService.localeNotifier.value ??
      WidgetsBinding.instance.platformDispatcher.locale;
  final resolved = LanguageService.supportedLocales.any(
    (supported) => supported.languageCode == effective.languageCode,
  )
      ? effective
      : LanguageService.supportedLocales.first;
  return lookupAppLocalizations(resolved);
}

/// 初始化系统媒体会话（后台播放 + 通知栏/锁屏/耳机键/媒体浮层）。
///
/// 平台不支持或初始化失败时返回 null，播放功能降级为应用内播放，
/// 不阻塞启动。调用点应在 `runApp` 之前（Android / Windows 的媒体会话
/// 需要尽早接管冷启动时的媒体键事件）。
///
/// [artworkBlocked] 为省流模式封面网关：返回 true 时媒体项不带封面。
/// 封面不直接交给平台下载（网易云等 CDN 对默认 UA 返回 403）：先复用
/// [ArtworkCache] 带浏览器 UA + Referer 落到本地文件，再以本地 URI 补发；
/// 未命中本地缓存时先发远程 URL 兜底。
Future<LocalAudioHandler?> initSystemMediaSession(
  LocalPlaybackService service, {
  bool Function()? artworkBlocked,
  Future<void> Function()? onRestoredSkipToNext,
  Future<void> Function()? onRestoredSkipToPrevious,
}) async {
  if (!isSystemMediaSessionSupported) {
    return null;
  }
  try {
    final backend = createSystemMediaSessionBackend();
    if (backend == null) return null;
    final handler = LocalAudioHandler(
      service,
      backend: backend,
      artworkBlocked: artworkBlocked,
      onRestoredSkipToNext: onRestoredSkipToNext,
      onRestoredSkipToPrevious: onRestoredSkipToPrevious,
    );
    await handler.activate();
    return handler;
  } catch (e) {
    debugPrint('[Molia] 系统媒体会话初始化失败，降级为应用内播放: $e');
    return null;
  }
}

/// 默认封面本地化：`ArtworkCache` 命中或下载后返回平台可用的本地地址。
///
/// Windows 的 WinRT `StorageFile` 分支要求裸路径；其余平台用 `file://` URI。
Future<String?> _artworkUriFromCache(String url) async {
  final path = await ArtworkCache.instance.cachedFilePath(url);
  if (path == null) return null;
  return mediaArtworkUriForPath(path);
}

/// 把 [LocalPlaybackService] 的状态映射为系统媒体会话所需的
/// [MediaMetadata] / [PlaybackState]，并把通知栏 / 锁屏 / 耳机键 / 媒体浮层
/// 的控制请求委托回 LocalPlaybackService 的现有方法。
///
/// 这样 UI 侧的 `PlaybackProvider` 仍是唯一状态入口，本地播放公开 API 不变。
///
/// 不继承 `audio_service` 的 `BaseAudioHandler`，而用「控制器 + 可注入
/// [MediaSessionBackend]」组合；类名与全部公开方法保持不变。
class LocalAudioHandler {
  LocalAudioHandler(
    this._service, {
    MediaSessionBackend? backend,
    bool Function()? artworkBlocked,
    Future<String?> Function(String url)? artworkUriResolver,
    Future<void> Function()? onRestoredSkipToNext,
    Future<void> Function()? onRestoredSkipToPrevious,
  })  : _backend = backend ??
            createSystemMediaSessionBackend() ??
            const NoopMediaSessionBackend(),
        _artworkBlocked = artworkBlocked ?? (() => false),
        _artworkUriResolver = artworkUriResolver ?? _artworkUriFromCache,
        _onRestoredSkipToNext = onRestoredSkipToNext,
        _onRestoredSkipToPrevious = onRestoredSkipToPrevious {
    _service.addListener(_syncFromService);
    // 界面语言切换后通知动作文案（播放顺序）跟随。
    LanguageService.localeNotifier.addListener(_onLocaleChanged);
    _syncFromService(force: true);
  }

  final LocalPlaybackService _service;
  final MediaSessionBackend _backend;

  /// 省流模式封面网关：返回 true 时媒体项不带封面。
  final bool Function() _artworkBlocked;

  /// 封面本地化（返回平台可用的本地地址；失败 / 未命中返回 null）。
  final Future<String?> Function(String url) _artworkUriResolver;

  /// 恢复态（冷启动未起播、服务无曲目）切歌键的回落目标。
  ///
  /// 恢复态通常没有通知本体，但耳机 / 系统媒体键仍可能到达 handler；
  /// 回落给 `PlaybackSessionCoordinator`（组合根在工厂里注入），由它按阶段
  /// 决定是从保存的会话恢复播放还是转发真实播放，补齐控制链一致性。
  final Future<void> Function()? _onRestoredSkipToNext;
  final Future<void> Function()? _onRestoredSkipToPrevious;

  /// 会话落盘入口（组合根在 handler 建好后回填
  /// `PlaybackSessionCoordinator.flushSession`）。
  ///
  /// 系统控制动作返回前显式落盘，而不是等中间快照被间接观察到——进程随后
  /// 被系统回收时，「重开应用恢复上一首 / 队列 / 模式 / 进度」才是确定的
  /// （见 `playback_stack.dart` 的接线）。
  Future<void> Function()? _persistSession;

  Future<void>? _persistingSession;

  StreamSubscription<MediaAction>? _actionSubscription;
  bool _activated = false;

  /// 绑定会话落盘（组合根调用；见 [_persistSession]）。
  void attachSessionPersister(Future<void> Function() persistSession) {
    _persistSession = persistSession;
  }

  /// 启动后端并订阅系统控制。
  ///
  /// 由 [initSystemMediaSession] 在 `runApp` 前调用；失败时向上抛，让组合根
  /// 回退为「无媒体会话」（应用内播放继续，仅无系统媒体控制与媒体键）。
  Future<void> activate() async {
    if (!_activated) {
      _activated = true;
      await _backend.activate();
      _actionSubscription ??= _backend.actions.listen(
        _onBackendAction,
        onError: (Object e) => debugPrint('[Molia] 系统媒体动作流错误: $e'),
      );
    }
    _syncFromService(force: true);
  }

  /// 解除监听（应用内 handler 与进程同生命周期；测试用于避免串场）。
  void dispose() {
    _service.removeListener(_syncFromService);
    LanguageService.localeNotifier.removeListener(_onLocaleChanged);
    final subscription = _actionSubscription;
    _actionSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  // 上次广播的状态，用于去重：位置每 400ms 都会变化，但系统媒体会话只需要
  // 在曲目切换 / 播放状态变化 / 明显跳转（seek）时收到更新。
  String? _lastTrackId;
  bool? _lastPlaying;
  bool? _lastLoading;
  PlayMode? _lastMode;
  Duration _lastPosition = Duration.zero;

  /// 上次广播的曲目时长（播放器解析完成后要补发元数据，否则通知进度条
  /// 会用元数据时长）。
  Duration _lastMediaDuration = Duration.zero;

  /// 上次广播的封面 URL（音源补图回写队列后需刷新通知/锁屏封面）。
  String? _lastArtworkUrl;

  /// 已本地化的封面（源 URL → 平台地址）。
  String? _localArtworkSourceUrl;
  String? _localArtworkUri;

  /// 正在解析的封面 URL（避免同一封面重复下载）。
  final Set<String> _resolvingArtwork = {};

  /// 歌词行元数据覆盖（通知/锁屏 + 蓝牙 profile 的合成结果）。
  LyricMetadataOverride? _lyricMetadataOverride;

  /// 应用歌词覆盖（null = 还原原始元数据）。
  ///
  /// 调用方（歌词显示调度）只在合成结果变化时调用；本方法触发一次带
  /// 去重的广播，通知栏 / 锁屏 / AVRCP 随元数据一起更新。
  void setLyricMetadataOverride(LyricMetadataOverride? override) {
    if (override == _lyricMetadataOverride) return;
    _lyricMetadataOverride = override;
    _syncFromService(force: true);
  }

  Future<void> play() async {
    if (_service.hasTrack && !_service.isPlaying) {
      await _service.toggle();
    }
    _syncFromService(force: true);
  }

  Future<void> pause() async {
    if (_service.isPlaying) {
      await _service.toggle();
    }
    _syncFromService(force: true);
    // 暂停即落盘（幂等）：暂停后进程随时可能被系统回收，重开应用要能恢复
    // 上一首 / 队列 / 模式 / 进度（isPlaying=false）。
    await _persistSessionState();
  }

  Future<void> stop() async {
    // 停止会清空服务队列（快照随后变空、再也取不到会话）：先落盘再停。
    await _persistSessionState();
    await _service.stop();
    _syncFromService(force: true);
  }

  /// 系统动作「播放顺序」：按 App 内同一顺序循环 顺序 → 单曲循环 → 随机。
  ///
  /// 其它自定义动作保持透传（返回 null，不产生副作用）。
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name != playModeActionId) return null;
    await _service.toggleMode();
    _syncFromService(force: true);
    // 模式是会话的一部分：系统控制改模式后同样立即落盘。
    await _persistSessionState();
    return null;
  }

  /// 落盘当前会话（失败不影响控制链：会话由观察者按节流继续维护）。
  ///
  /// 串行化：连续动作（暂停 → 改模式）按顺序落盘，最后写入的是最新状态；
  /// 链上吞掉失败，一次写失败不会让后续落盘被跳过。
  Future<void> _persistSessionState() {
    final persist = _persistSession;
    if (persist == null) return Future<void>.value();
    final next = (_persistingSession ?? Future<void>.value())
        .then((_) => persist())
        .catchError((Object e) {
      debugPrint('[Molia] 系统控制路径落盘播放会话失败: $e');
    });
    _persistingSession = next;
    return next;
  }

  /// 界面语言切换：重建通知动作文案（播放顺序）。
  void _onLocaleChanged() => _syncFromService(force: true);

  Future<void> skipToNext() async {
    // 恢复态（无真实曲目）：回落给注入的会话模块（保存会话立即恢复播放，
    // 或按阶段转发真实播放）。
    if (!_service.hasTrack) {
      await _onRestoredSkipToNext?.call();
      _syncFromService(force: true);
      return;
    }
    await _service.skipToNext();
    _syncFromService(force: true);
  }

  Future<void> skipToPrevious() async {
    if (!_service.hasTrack) {
      await _onRestoredSkipToPrevious?.call();
      _syncFromService(force: true);
      return;
    }
    await _service.skipToPrevious();
    _syncFromService(force: true);
  }

  Future<void> seek(Duration position) async {
    await _service.seek(position);
    _syncFromService(force: true);
    // seek 也是会话的一部分：系统 seek 后进程被回收，重开应从新位置继续。
    await _persistSessionState();
  }

  Future<void> skipToQueueItem(int index) async {
    await _service.playQueueIndex(index);
    _syncFromService(force: true);
  }

  void _onBackendAction(MediaAction action) {
    switch (action.name) {
      case 'play':
        unawaited(_guardControl(play));
      case 'pause':
        unawaited(_guardControl(pause));
      case 'stop':
        unawaited(_guardControl(stop));
      case 'skipToNext':
        unawaited(_guardControl(skipToNext));
      case 'skipToPrevious':
        unawaited(_guardControl(skipToPrevious));
      case 'seekTo':
        final position = action.seekPosition;
        if (position != null) {
          unawaited(_guardControl(() => seek(position)));
        }
      case playModeActionId:
        unawaited(_guardControl(() async {
          await customAction(action.name);
        }));
    }
  }

  /// 系统动作来自平台事件流，异常不能冒泡成未捕获的异步错误。
  Future<void> _guardControl(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('[Molia] 系统媒体控制失败: $e');
    }
  }

  void _syncFromService({bool force = false}) {
    final track = _service.currentSourceTrack;
    final trackId = track?.id;
    final playing = _service.isPlaying;
    final loading = _service.isLoading;
    final mode = _service.mode;
    final position = _service.position;
    final duration = _service.duration;

    final trackChanged = trackId != _lastTrackId;
    final playingChanged = playing != _lastPlaying;
    final loadingChanged = loading != _lastLoading;
    // 模式变化要重发状态与动作：图标/文案反映当前模式（App 内切换同样到达这里）。
    final modeChanged = mode != _lastMode;
    final artworkUrl = track?.coverUrl;
    final artworkChanged = artworkUrl != _lastArtworkUrl;
    // 播放器解析出真实时长后补发一次元数据（通知进度条的时长来源）。
    final durationChanged =
        duration > Duration.zero && duration != _lastMediaDuration;
    final seeked =
        (position - _lastPosition).abs() > const Duration(seconds: 1);
    if (!force &&
        !trackChanged &&
        !playingChanged &&
        !loadingChanged &&
        !modeChanged &&
        !seeked &&
        !artworkChanged &&
        !durationChanged) {
      return;
    }

    final metadataNeedsRebuild =
        force || trackChanged || artworkChanged || durationChanged;
    final stateNeedsRebuild = force ||
        trackChanged ||
        playingChanged ||
        loadingChanged ||
        modeChanged ||
        seeked ||
        durationChanged;
    final actionsNeedRebuild = force || trackChanged || modeChanged;

    _lastTrackId = trackId;
    _lastPlaying = playing;
    _lastLoading = loading;
    _lastMode = mode;
    _lastPosition = position;
    _lastArtworkUrl = artworkUrl;
    if (duration > Duration.zero) _lastMediaDuration = duration;

    if (track == null) {
      if (metadataNeedsRebuild) {
        _send(() => _backend.updateMetadata(const MediaMetadata()));
      }
      if (stateNeedsRebuild) {
        _send(
          () => _backend.updatePlaybackState(
            const PlaybackState(status: PlaybackStatus.idle),
          ),
        );
      }
      if (actionsNeedRebuild) {
        _send(() => _backend.updateAvailableActions(const {}));
      }
      return;
    }

    if (metadataNeedsRebuild) {
      _send(() => _backend.updateMetadata(_metadataFor(track)));
      _maybeResolveArtwork(track);
    }
    if (stateNeedsRebuild) {
      _send(
        () => _backend.updatePlaybackState(
          _playbackStateFor(
            mode,
            playing: playing,
            loading: loading,
            position: position,
          ),
        ),
      );
    }
    if (actionsNeedRebuild) {
      _send(() => _backend.updateAvailableActions(_availableActions(mode)));
    }
  }

  void _send(Future<void> Function() operation) {
    unawaited(
      operation().catchError((Object e) {
        debugPrint('[Molia] 系统媒体会话更新失败: $e');
      }),
    );
  }

  PlaybackState _playbackStateFor(
    PlayMode mode, {
    required bool playing,
    required bool loading,
    required Duration position,
  }) {
    return PlaybackState(
      status: loading
          ? PlaybackStatus.buffering
          : playing
              ? PlaybackStatus.playing
              : PlaybackStatus.paused,
      position: position,
      bufferedPosition: position,
      speed: 1.0,
      repeatMode: switch (mode) {
        PlayMode.sequential => MediaRepeatMode.all,
        PlayMode.singleRepeat => MediaRepeatMode.one,
        PlayMode.shuffle => MediaRepeatMode.all,
      },
      shuffleModeEnabled: mode == PlayMode.shuffle,
    );
  }

  Set<MediaAction> _availableActions(PlayMode mode) => {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.stop,
        MediaAction.seekTo,
        _playModeAction(mode),
      };

  /// 播放顺序动作：图标与文案反映**当前**模式（点按循环到下一个模式）。
  MediaAction _playModeAction(PlayMode mode) {
    final l10n = _currentLocalizations();
    return MediaAction.custom(
      name: playModeActionId,
      customLabel: switch (mode) {
        PlayMode.sequential => l10n.playModeSequential,
        PlayMode.singleRepeat => l10n.playModeSingleRepeat,
        PlayMode.shuffle => l10n.playModeShuffle,
      },
      customIconResource: playModeActionIcons[mode]!,
    );
  }

  MediaMetadata _metadataFor(SourceTrack track) {
    final duration = _service.duration > Duration.zero
        ? _service.duration
        : track.duration;
    final metadata = mediaMetadataForTrack(
      track,
      duration: duration,
      artworkUri: _artworkUriFor(track),
    );
    return applyLyricMetadataOverride(metadata, _lyricMetadataOverride);
  }

  String? _artworkUriFor(SourceTrack track) {
    if (_artworkBlocked()) return null;
    final coverUrl = track.coverUrl;
    final parsed = parseArtUri(coverUrl);
    if (parsed == null) return null;
    if (_localArtworkSourceUrl == coverUrl && _localArtworkUri != null) {
      return _localArtworkUri;
    }
    return parsed.toString();
  }

  /// 元数据先发远程 URL 兜底，异步落到本地文件后补发一次。
  ///
  /// 只有网络封面需要本地化：`data:` / 已是 `file:` 的地址原样使用；
  /// 省流模式直接跳过（媒体元数据不带封面）。
  void _maybeResolveArtwork(SourceTrack track) {
    if (_artworkBlocked()) return;
    final coverUrl = track.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    final parsed = parseArtUri(coverUrl);
    if (parsed == null) return;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return;
    if (_localArtworkSourceUrl == coverUrl && _localArtworkUri != null) return;
    if (!_resolvingArtwork.add(coverUrl)) return;
    unawaited(_resolveArtwork(coverUrl));
  }

  Future<void> _resolveArtwork(String coverUrl) async {
    try {
      final localUri = await _artworkUriResolver(coverUrl);
      if (localUri == null || localUri.isEmpty) return;
      _localArtworkSourceUrl = coverUrl;
      _localArtworkUri = localUri;
      // 解析期间可能已切歌：只刷新仍指向同一封面的当前曲目。
      if (_service.currentSourceTrack?.coverUrl == coverUrl) {
        _syncFromService(force: true);
      }
    } catch (e) {
      debugPrint('[Molia] 系统媒体会话封面本地化失败: $e');
    } finally {
      _resolvingArtwork.remove(coverUrl);
    }
  }
}

/// 应用歌词元数据覆盖（纯函数，便于单测）：null 字段保持原值。
///
/// `flutter_media_session` 的 [MediaMetadata] 没有 `displaySubtitle` 字段；
/// 歌词副标题覆盖（[LyricMetadataOverride.displaySubtitle]）在此忽略——
/// 它只用于 Android 通知的副标题，标题 / 歌手 / 专辑覆盖不受影响。
@visibleForTesting
MediaMetadata applyLyricMetadataOverride(
  MediaMetadata metadata,
  LyricMetadataOverride? override,
) {
  if (override == null || override.isEmpty) return metadata;
  return MediaMetadata(
    title: override.title ?? metadata.title,
    artist: override.artist ?? metadata.artist,
    album: override.album ?? metadata.album,
    artworkUri: metadata.artworkUri,
    duration: metadata.duration,
  );
}

/// 构造系统媒体会话用的 [MediaMetadata]（纯函数，便于单测）。
///
/// [artworkUri] 由调用方决定（远程 URL 兜底或本地文件 URI / Windows 路径）；
/// 省流模式传 null。
@visibleForTesting
MediaMetadata mediaMetadataForTrack(
  SourceTrack track, {
  required Duration? duration,
  required String? artworkUri,
}) {
  return MediaMetadata(
    title: track.title,
    artist: track.artist.isEmpty ? '未知歌手' : track.artist,
    album: track.album.isEmpty ? null : track.album,
    duration: duration,
    artworkUri: artworkUri,
  );
}

/// 解析封面地址为媒体元数据封面 URI。
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
