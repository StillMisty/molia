import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';

import '../app/bootstrap/startup_trace.dart';
import '../managers/artwork_cache.dart';
import '../models/play_mode.dart';
import '../services/lyrics_display/media_lyric_composer.dart';
import '../sources/source_track.dart';
import 'local_playback_service.dart';
import 'media_artwork_uri.dart';
import 'media_session_backend.dart';
import 'media_session_backend_factory.dart';
import 'media_session_copy.dart';
import 'media_session_copy_source.dart';
import 'media_session_read_model.dart';
import 'playback_commands.dart';

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

/// 播放顺序动作的 id：系统控件里循环切换「列表循环 / 顺序播放 / 单曲循环 /
/// 随机播放」。
///
/// Android 通知上的自定义动作按字符串 `getIdentifier` 取 drawable
/// （release 的 shrinkResources 靠 `keep.xml` 的 `@drawable/audio_service_*`
/// 保留），因此四个模式各配一个矢量图标。资源名沿用历史命名，避免动
/// 发布清单；`flutter_media_session` 的 `customIconResource` 只接受裸资源名
/// （不带 `drawable/` 前缀）。
const String playModeActionId = 'lx.playMode';

/// 播放模式 → 通知动作图标（Android drawable 资源名，不带目录前缀）。
const Map<PlayMode, String> playModeActionIcons = {
  PlayMode.listLoop: 'audio_service_repeat_all',
  PlayMode.sequential: 'audio_service_sequential',
  PlayMode.singleRepeat: 'audio_service_repeat_one',
  PlayMode.shuffle: 'audio_service_shuffle',
};

/// 收藏动作的 id：系统控件里切换当前曲目的收藏态。
///
/// 与播放顺序同一套机制（Android 通知自定义动作按资源名字符串取图标，release
/// 的 shrinkResources 靠 `keep.xml` 保留资源）。
const String favoriteActionId = 'lx.favorite';

/// 收藏态 → 通知动作图标（Android drawable 资源名，不带目录前缀）。
const Map<bool, String> favoriteActionIcons = {
  false: 'ic_notification_favorite',
  true: 'ic_notification_favorite_filled',
};

/// 初始化系统媒体会话（后台播放 + 通知栏/锁屏/耳机键/媒体浮层）。
///
/// 平台不支持或初始化失败时返回 null，播放功能降级为应用内播放，
/// 不阻塞启动。调用点应在 `runApp` 之前（Android / Windows 的媒体会话
/// 需要尽早接管冷启动时的媒体键事件）。
///
/// [commands] 是播放写入口（组合根注入 `PlaybackSessionCoordinator`）：
/// handler 只把系统动作翻译成命令，恢复态路由与落盘时机都由命令面负责。
/// [copy] 是界面文案来源（默认跟随全局语言）；handler 不读全局 locale。
/// [artworkBlocked] 为省流模式封面网关：返回 true 时媒体项不带封面。
/// 封面不直接交给平台下载（网易云等 CDN 对默认 UA 返回 403）：先复用
/// [ArtworkCache] 带浏览器 UA + Referer 落到本地文件，再以本地 URI 补发；
/// 未命中本地缓存时先发远程 URL 兜底。
Future<LocalAudioHandler?> initSystemMediaSession(
  LocalPlaybackService service, {
  required PlaybackCommandPort commands,
  ValueListenable<MediaSessionCopy>? copy,
  bool Function()? artworkBlocked,
  String? Function(SourceTrack track)? coverUrlResolver,
}) async {
  if (!isSystemMediaSessionSupported) {
    return null;
  }
  try {
    final backend = createSystemMediaSessionBackend();
    if (backend == null) return null;
    final buildWatch = Stopwatch()..start();
    final handler = LocalAudioHandler(
      LocalPlaybackMediaSessionReadModel(service),
      commands: commands,
      copy: copy ?? LocalizedMediaSessionCopy(),
      backend: backend,
      artworkBlocked: artworkBlocked,
      coverUrlResolver: coverUrlResolver,
    );
    markStartupStep('sub.mediaSession.build', buildWatch);
    final activateWatch = Stopwatch()..start();
    await handler.activate();
    markStartupStep('sub.mediaSession.activate（handler）', activateWatch);
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

/// 把媒体会话读取面（[MediaSessionReadModel]）的状态映射为系统媒体会话所需
/// 的 [MediaMetadata] / [PlaybackState]，并把通知栏 / 锁屏 / 耳机键 / 媒体浮层
/// 的控制请求翻译成 [PlaybackCommandPort] 命令。
///
/// 类名与媒体控制方法名保持不变（ADR-0010）；读取只依赖窄接口（生产实现投影
/// `LocalPlaybackService`，测试注入普通值假实现），写入一律经命令面（恢复态
/// 与 live 的分叉、落盘时机都在 `PlaybackSessionCoordinator`，handler 不再
/// 自己判断 phase 或落盘）。界面文案经 [MediaSessionCopy] 注入，handler 不读
/// 全局 locale，也不硬编码歌手回退文案。
///
/// 不继承 `audio_service` 的 `BaseAudioHandler`，而用「控制器 + 可注入
/// [MediaSessionBackend]」组合。
class LocalAudioHandler {
  LocalAudioHandler(
    this._readModel, {
    required PlaybackCommandPort commands,
    required ValueListenable<MediaSessionCopy> copy,
    MediaSessionBackend? backend,
    bool Function()? artworkBlocked,
    String? Function(SourceTrack track)? coverUrlResolver,
    Future<String?> Function(String url)? artworkUriResolver,
    bool? periodicPositionStateUpdates,
  })  : _commands = commands,
        _copy = copy,
        _backend = backend ??
            createSystemMediaSessionBackend() ??
            const NoopMediaSessionBackend(),
        _artworkBlocked = artworkBlocked ?? (() => false),
        _coverUrlResolver = coverUrlResolver,
        _artworkUriResolver = artworkUriResolver ?? _artworkUriFromCache,
        _periodicPositionStateUpdates = periodicPositionStateUpdates ??
            defaultTargetPlatform != TargetPlatform.android {
    _readModel.addListener(_syncFromService);
    // 界面语言切换后通知动作文案（播放顺序 / 收藏）跟随：来源重算文案后
    // 通知 handler 重发动作，handler 自己不解析 locale。
    _copy.addListener(_onCopyChanged);
    _syncFromService(force: true);
  }

  /// 系统媒体会话读取面（生产：`LocalPlaybackMediaSessionReadModel`）。
  final MediaSessionReadModel _readModel;

  /// 播放写入口（组合根注入 `PlaybackSessionCoordinator`）。
  final PlaybackCommandPort _commands;

  /// 当前界面文案（组合根注入；语言切换时由来源 notifier 通知）。
  final ValueListenable<MediaSessionCopy> _copy;

  final MediaSessionBackend _backend;

  /// 省流模式封面网关：返回 true 时媒体项不带封面。
  final bool Function() _artworkBlocked;

  /// 封面 URL 解析（自定义 → 原始 → 默认占位；组合根注入）。
  final String? Function(SourceTrack track)? _coverUrlResolver;

  /// 封面本地化（返回平台可用的本地地址；失败 / 未命中返回 null）。
  final Future<String?> Function(String url) _artworkUriResolver;

  /// 正常进度推进时是否周期补发播放态（Android 关闭，其余平台开启）。
  ///
  /// Android 的 `flutter_media_session` 按 `lastPositionMs + elapsed × speed`
  /// 自行插值，每秒一次 state 更新只是多余 IPC；Linux MPRIS 的 `GetPosition`
  /// 不插值，需要周期更新。可注入：常规用例可显式注入，平台默认值另有用例覆盖。
  final bool _periodicPositionStateUpdates;

  StreamSubscription<MediaAction>? _actionSubscription;
  bool _activated = false;

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
    _readModel.removeListener(_syncFromService);
    _copy.removeListener(_onCopyChanged);
    final subscription = _actionSubscription;
    _actionSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  // 上次广播的状态，用于去重：位置每 400ms 都会变化，但系统媒体会话只需要
  // 在曲目切换 / 播放状态变化 / 真实跳转（seek）时收到更新。
  String? _lastTrackId;
  bool? _lastPlaying;
  bool? _lastLoading;
  PlayMode? _lastMode;
  Duration _lastPosition = Duration.zero;

  /// 上次广播时的服务 seek 版本号（Android 只认它判断真实跳转）。
  int _lastSeekRevision = 0;

  /// 上次广播的曲目时长（播放器解析完成后要补发元数据，否则通知进度条
  /// 会用元数据时长）。
  Duration _lastMediaDuration = Duration.zero;

  /// 上次广播的封面 URL（音源补图回写队列后需刷新通知/锁屏封面）。
  String? _lastArtworkUrl;

  /// 当前曲目的收藏态（决定通知里收藏动作的图标与文案）。
  ///
  /// 读取面在曲库 `LibraryProvider` 建好后回填（见 [attachFavoriteActions]；
  /// 与媒体会话本身一样的晚绑定），handler 只消费结果，不直接持有曲库。
  bool _favorite = false;

  /// 上次广播的收藏态：曲库里的收藏变化要重发动作（空心 ↔ 实心）。
  bool? _lastFavorite;

  /// 已本地化的封面（源 URL → 平台地址）。
  String? _localArtworkSourceUrl;
  String? _localArtworkUri;

  /// 正在解析的封面 URL（避免同一封面重复下载）。
  final Set<String> _resolvingArtwork = {};

  /// 歌词行元数据覆盖（通知/锁屏 + 蓝牙 profile 的合成结果）。
  LyricMetadataOverride? _lyricMetadataOverride;

  /// 应用歌词覆盖（null = 还原原始元数据）。
  ///
  /// 调用方（歌词显示调度）只在合成结果变化时调用；通知歌词换行不是
  /// 播放 / 队列事件，只补发元数据——不重建播放态与可用动作，避免每次
  /// 换行都把三件套全部推一遍平台通道。没有曲目时跳过。
  void setLyricMetadataOverride(LyricMetadataOverride? override) {
    if (override == _lyricMetadataOverride) return;
    _lyricMetadataOverride = override;
    _sendMetadataOnly();
  }

  /// 自定义 / 默认封面变化后刷新当前曲目的系统媒体元数据。
  ///
  /// 只补发元数据；播放态与动作不受影响（封面 URI 不是播放事件）。
  void refreshArtwork() {
    _localArtworkSourceUrl = null;
    _localArtworkUri = null;
    _syncFromService(force: true);
  }

  /// 只补发当前曲目的元数据（歌词覆盖 / 封面本地化完成）。
  ///
  /// 这两类变化都不影响播放态与动作；位置 / 播放态去重字段也保持不动，
  /// 让下一次真实事件仍按原口径判定。
  void _sendMetadataOnly() {
    final track = _readModel.currentTrack;
    if (track == null) return;
    _send(() => _backend.updateMetadata(_metadataFor(track)));
  }

  /// 绑定「收藏」能力（组合根调用；见 [favoriteActionId]）。
  ///
  /// 与媒体会话状态同步一样的晚绑定原因：handler 在播放栈里创建，
  /// 而曲库 provider 之后才建好。收藏读写回填到读取面，通知动作只消费结果
  /// （图标空心 / 实心）。
  void attachFavoriteActions({
    required bool Function(SourceTrack track) isFavorite,
    required Future<void> Function(SourceTrack track) toggle,
  }) {
    _readModel.bindFavorite(isFavorite: isFavorite, toggle: toggle);
    refreshFavoriteState();
  }

  /// 曲库侧收藏态可能变了（组合根监听 `LibraryProvider` 后调用）。
  ///
  /// 现查当前曲目的收藏态，值变了才重发动作（图标空心 ↔ 实心）；没有曲目时
  /// 沿用已有值，不产生额外广播。
  void refreshFavoriteState() {
    final track = _readModel.currentTrack;
    final favorite = track == null ? _favorite : _readModel.isFavorite(track);
    if (favorite == _favorite) return;
    _favorite = favorite;
    _syncFromService();
  }

  Future<void> play() async {
    await _commands.play();
    _syncFromService(force: true);
  }

  Future<void> pause() async {
    await _commands.pause();
    _syncFromService(force: true);
  }

  Future<void> stop() async {
    // 命令面先落盘再停（停止会清空服务队列，之后再也拼不出会话）。
    await _commands.stop();
    _syncFromService(force: true);
  }

  /// 系统自定义动作：播放顺序（循环切换）与收藏（切换当前曲目）。
  ///
  /// 其它自定义动作保持透传（返回 null，不产生副作用）。
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == favoriteActionId) {
      await _toggleFavoriteTrack();
      return null;
    }
    if (name != playModeActionId) return null;
    // 模式是会话的一部分：命令面在返回前完成落盘；恢复态按保存会话的模式
    // 循环，不会拿服务里的启动默认模式冒充当前模式。
    await _commands.togglePlayMode();
    _syncFromService(force: true);
    return null;
  }

  /// 收藏动作：走读取面回填的曲库写入回调（唯一写路径），完成后立即刷新图标。
  ///
  /// 曲库通知本身也会触发一次刷新（组合根监听）；这里补一次是为了不依赖接线
  /// 顺序，也让「点通知 → 图标变实心」在同一次动作里完成。未接线时读取面的
  /// `toggleFavorite` 是 no-op，不会产生广播。
  Future<void> _toggleFavoriteTrack() async {
    final track = _readModel.currentTrack;
    if (track == null) return;
    try {
      await _readModel.toggleFavorite(track);
    } catch (e) {
      // 通知动作没有提示位：写失败只记日志，图标保持原状态，不能把异常
      // 抛回平台通道（会变成未处理异步错误）。
      debugPrint('[AudioHandler] 切换收藏失败: $e');
      return;
    }
    refreshFavoriteState();
  }

  /// 界面语言切换：文案来源重算后重建通知动作文案（收藏 / 播放顺序）。
  void _onCopyChanged() => _syncFromService(force: true);

  Future<void> skipToNext() async {
    // 恢复态回落（服务无真实曲目）也由命令面按阶段处理，handler 不再分叉。
    await _commands.skipToNext();
    _syncFromService(force: true);
  }

  Future<void> skipToPrevious() async {
    await _commands.skipToPrevious();
    _syncFromService(force: true);
  }

  Future<void> seek(Duration position) async {
    await _commands.seekToPosition(position);
    _syncFromService(force: true);
  }

  Future<void> skipToQueueItem(int index) async {
    await _commands.playQueueIndex(index);
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
      case favoriteActionId:
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
    final track = _readModel.currentTrack;
    final trackId = track?.id;
    final playing = _readModel.isPlaying;
    final loading = _readModel.isLoading;
    final mode = _readModel.mode;
    final position = _readModel.position;
    final duration = _readModel.duration;
    final seekRevision = _readModel.seekRevision;

    final trackChanged = trackId != _lastTrackId;
    final playingChanged = playing != _lastPlaying;
    final loadingChanged = loading != _lastLoading;
    // 模式变化要重发状态与动作：图标/文案反映当前模式（App 内切换同样到达这里）。
    final modeChanged = mode != _lastMode;
    // 收藏态只影响动作（空心 / 实心图标），不进元数据 / 播放状态重建。
    final favorite = track == null ? _favorite : _readModel.isFavorite(track);
    final favoriteChanged = favorite != _lastFavorite;
    final artworkUrl = _coverUrlOf(track);
    final artworkChanged = artworkUrl != _lastArtworkUrl;
    // 播放器解析出真实时长后补发一次元数据（通知进度条的时长来源）。
    final durationChanged =
        duration > Duration.zero && duration != _lastMediaDuration;
    final seeked = seekRevision != _lastSeekRevision ||
        (_periodicPositionStateUpdates &&
            (position - _lastPosition).abs() > const Duration(seconds: 1));
    if (!force &&
        !trackChanged &&
        !playingChanged &&
        !loadingChanged &&
        !modeChanged &&
        !favoriteChanged &&
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
    final actionsNeedRebuild =
        force || trackChanged || modeChanged || favoriteChanged;

    _lastTrackId = trackId;
    _lastPlaying = playing;
    _lastLoading = loading;
    _lastMode = mode;
    _lastPosition = position;
    _lastSeekRevision = seekRevision;
    _lastArtworkUrl = artworkUrl;
    _favorite = favorite;
    _lastFavorite = favorite;
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
        PlayMode.listLoop => MediaRepeatMode.all,
        PlayMode.sequential => MediaRepeatMode.none,
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
        // 收藏在前、播放顺序在后：这是自定义动作之间的相对顺序；标准三键与
        // 自定义动作的最终位置由系统媒体控件决定（见 ADR-0010）。
        _favoriteAction(),
        _playModeAction(mode),
      };

  /// 收藏动作：图标与文案反映**当前**收藏态（点按切换）。
  MediaAction _favoriteAction() {
    return MediaAction.custom(
      name: favoriteActionId,
      customLabel: _copy.value.favoriteLabel(favorite: _favorite),
      customIconResource: favoriteActionIcons[_favorite]!,
    );
  }

  /// 播放顺序动作：图标与文案反映**当前**模式（点按循环到下一个模式）。
  MediaAction _playModeAction(PlayMode mode) {
    return MediaAction.custom(
      name: playModeActionId,
      customLabel: _copy.value.playModeLabel(mode),
      customIconResource: playModeActionIcons[mode]!,
    );
  }

  MediaMetadata _metadataFor(SourceTrack track) {
    final duration = _readModel.duration > Duration.zero
        ? _readModel.duration
        : track.duration;
    final metadata = mediaMetadataForTrack(
      track,
      duration: duration,
      artworkUri: _artworkUriFor(track),
      unknownArtist: _copy.value.unknownArtist,
    );
    return applyLyricMetadataOverride(metadata, _lyricMetadataOverride);
  }

  String? _artworkUriFor(SourceTrack track) {
    if (_artworkBlocked()) return null;
    final coverUrl = _coverUrlOf(track);
    if (coverUrl == null || coverUrl.isEmpty) return null;
    // 本地文件（自定义封面 / 下载封面）：Windows 的 WinRT 实现只认裸路径。
    final localUri = _localFileUriFor(coverUrl);
    if (localUri != null) return localUri;
    final parsed = parseArtUri(coverUrl);
    if (parsed == null) return null;
    if (_localArtworkSourceUrl == coverUrl && _localArtworkUri != null) {
      return _localArtworkUri;
    }
    return parsed.toString();
  }

  /// 本地封面地址 → 平台可用地址（file URI / Windows 裸路径）；非本地返回 null。
  String? _localFileUriFor(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.scheme == 'file') {
      return mediaArtworkUriForPath(parsed.toFilePath()) ?? parsed.toString();
    }
    // 裸路径（Windows `C:\...` 或 Unix `/...`）：Uri.parse 要么给单字母
    // scheme，要么没有 scheme，都不能直接交给系统媒体会话。
    final windowsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(url);
    if (windowsPath || url.startsWith('/')) {
      return mediaArtworkUriForPath(url);
    }
    return null;
  }

  /// 元数据先发远程 URL 兜底，异步落到本地文件后补发一次。
  ///
  /// 只有网络封面需要本地化：`data:` / 已是 `file:` 的地址原样使用；
  /// 省流模式直接跳过（媒体元数据不带封面）。
  void _maybeResolveArtwork(SourceTrack track) {
    if (_artworkBlocked()) return;
    final coverUrl = _coverUrlOf(track);
    if (coverUrl == null || coverUrl.isEmpty) return;
    final parsed = parseArtUri(coverUrl);
    if (parsed == null) return;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return;
    if (_localArtworkSourceUrl == coverUrl && _localArtworkUri != null) return;
    if (!_resolvingArtwork.add(coverUrl)) return;
    unawaited(_resolveArtwork(coverUrl));
  }

  String? _coverUrlOf(SourceTrack? track) {
    if (track == null) return null;
    return _coverUrlResolver?.call(track) ?? track.coverUrl;
  }

  Future<void> _resolveArtwork(String coverUrl) async {
    try {
      final localUri = await _artworkUriResolver(coverUrl);
      if (localUri == null || localUri.isEmpty) return;
      _localArtworkSourceUrl = coverUrl;
      _localArtworkUri = localUri;
      // 解析期间可能已切歌：只刷新仍指向同一封面的当前曲目。
      // 封面 URI 只是元数据，不重建播放态 / 动作（避免多一次无谓 IPC）。
      if (_coverUrlOf(_readModel.currentTrack) == coverUrl) {
        _sendMetadataOnly();
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
/// 省流模式传 null。[unknownArtist] 是注入的 l10n 回退文案（不硬编码中文）。
@visibleForTesting
MediaMetadata mediaMetadataForTrack(
  SourceTrack track, {
  required Duration? duration,
  required String? artworkUri,
  required String unknownArtist,
}) {
  return MediaMetadata(
    title: track.title,
    artist: track.artist.isEmpty ? unknownArtist : track.artist,
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
