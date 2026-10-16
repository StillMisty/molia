import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../l10n/app_localizations.dart';
import '../managers/artwork_cache.dart';
import '../models/play_mode.dart';
import '../services/language_service.dart';
import '../services/lyrics_display/media_lyric_composer.dart';
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

/// 播放顺序动作的 id：通知动作里循环切换「顺序 / 单曲循环 / 随机」。
///
/// Android 通知上的自定义动作必须带 drawable 图标（audio_service 按字符串
/// `getIdentifier` 取资源，release 的 shrinkResources 靠 `keep.xml` 的
/// `@drawable/audio_service_*` 保留），因此三个模式各配一个矢量图标。
const String playModeActionId = 'lx.playMode';

/// 播放模式 → 通知动作图标（Android drawable 资源名）。
const Map<PlayMode, String> playModeActionIcons = {
  PlayMode.sequential: 'drawable/audio_service_repeat_all',
  PlayMode.singleRepeat: 'drawable/audio_service_repeat_one',
  PlayMode.shuffle: 'drawable/audio_service_shuffle',
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

/// 初始化系统媒体会话（后台播放 + 通知栏/锁屏/耳机键）。
///
/// 平台不支持或初始化失败时返回 null，播放功能降级为应用内播放，
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
  Future<void> Function()? onRestoredSkipToNext,
  Future<void> Function()? onRestoredSkipToPrevious,
}) async {
  if (!isSystemMediaSessionSupported) {
    return null;
  }
  try {
    return await AudioService.init<LocalAudioHandler>(
      builder: () => LocalAudioHandler(
        service,
        artworkBlocked: artworkBlocked,
        onRestoredSkipToNext: onRestoredSkipToNext,
        onRestoredSkipToPrevious: onRestoredSkipToPrevious,
      ),
      // managerOrNull 内部吞掉构造异常并返回 null（回退默认缓存），
      // 不会把「封面缓存不可用」升级成「媒体会话初始化失败」。
      cacheManager: await ArtworkCache.instance.managerOrNull(),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'top.stillmisty.molia.channel.audio',
        androidNotificationChannelName: 'Molia',
        androidNotificationChannelDescription: '本地音源播放控制',
        // 通知 small icon 必须指向真实存在的 drawable：audio_service 默认
        // `mipmap/ic_launcher` 在本项目不存在（改用自适应图标 launcher_icon，
        // 传统 mipmap 已移除），资源 ID=0 会让 NotificationManager 抛
        // 「Invalid notification (no valid small icon)」直接崩溃进程。
        androidNotificationIcon: 'drawable/ic_notification',
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
  LocalAudioHandler(
    this._service, {
    bool Function()? artworkBlocked,
    Future<void> Function()? onRestoredSkipToNext,
    Future<void> Function()? onRestoredSkipToPrevious,
  })  : _artworkBlocked = artworkBlocked ?? (() => false),
        _onRestoredSkipToNext = onRestoredSkipToNext,
        _onRestoredSkipToPrevious = onRestoredSkipToPrevious {
    _service.addListener(_syncFromService);
    // 界面语言切换后通知动作文案（播放顺序）跟随。
    LanguageService.localeNotifier.addListener(_onLocaleChanged);
    _syncFromService(force: true);
  }

  final LocalPlaybackService _service;

  /// 省流模式封面网关：返回 true 时媒体项不带 artUri（不为通知下载封面）。
  final bool Function() _artworkBlocked;

  /// 恢复态（冷启动未起播、服务无曲目）切歌键的回落目标。
  ///
  /// 恢复态通常没有通知本体，但耳机 / 系统媒体键仍可能到达 handler；
  /// 回落给 PlaybackProvider 用保存的会话立即恢复播放，补齐控制链一致性。
  /// 组合根经 `mediaSessionFactory` 在 handler 创建时直接注入。
  final Future<void> Function()? _onRestoredSkipToNext;
  final Future<void> Function()? _onRestoredSkipToPrevious;

  /// 会话落盘入口（组合根在 handler 建好后回填 `provider.flushPlaybackSession`）。
  ///
  /// 通知 / 锁屏 / 耳机键的暂停与停止直接调用 [LocalPlaybackService]，不经过
  /// provider 的命令路径：控制动作返回前显式落盘，而不是等中间快照被间接
  /// 观察到——进程随后被系统回收时，「重开应用恢复上一首 / 队列 / 模式 / 进度」
  /// 才是确定的（见 `playback_stack.dart` 的接线）。
  Future<void> Function()? _persistSession;

  Future<void>? _persistingSession;

  /// 绑定会话落盘（组合根调用；见 [_persistSession]）。
  void attachSessionPersister(Future<void> Function() persistSession) {
    _persistSession = persistSession;
  }

  // 上次广播的状态，用于去重：位置每 400ms 都会变化，但系统媒体会话只需要
  // 在曲目切换 / 播放状态变化 / 明显跳转（seek）时收到 setState。
  String? _lastTrackId;
  bool? _lastPlaying;
  bool? _lastLoading;
  PlayMode? _lastMode;
  Duration _lastPosition = Duration.zero;

  /// 上次广播的封面 URL（音源补图回写队列后需刷新通知/锁屏封面）。
  String? _lastArtworkUrl;

  /// 歌词行元数据覆盖（通知/锁屏 + 蓝牙 profile 的合成结果）。
  LyricMetadataOverride? _lyricMetadataOverride;

  /// 应用歌词覆盖（null = 还原原始元数据）。
  ///
  /// 调用方（歌词显示调度）只在合成结果变化时调用；本方法触发一次带
  /// 去重的广播，通知栏 / 锁屏 / AVRCP 随 MediaItem 一起更新。
  void setLyricMetadataOverride(LyricMetadataOverride? override) {
    if (override == _lyricMetadataOverride) return;
    _lyricMetadataOverride = override;
    _syncFromService(force: true);
  }

  static const Set<MediaAction> _systemActions = {
    MediaAction.seek,
    MediaAction.seekForward,
    MediaAction.seekBackward,
    MediaAction.skipToNext,
    MediaAction.skipToPrevious,
  };

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
    // 暂停即落盘（幂等）：暂停后进程随时可能被系统回收，重开应用要能恢复
    // 上一首 / 队列 / 模式 / 进度（isPlaying=false）。
    await _persistSessionState();
  }

  @override
  Future<void> stop() async {
    // 停止会清空服务队列（快照随后变空、再也取不到会话）：先落盘再停。
    await _persistSessionState();
    await _service.stop();
    _syncFromService(force: true);
  }

  /// 通知动作「播放顺序」：按 App 内同一顺序循环 顺序 → 单曲循环 → 随机。
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name != playModeActionId) return super.customAction(name, extras);
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

  @override
  Future<void> skipToNext() async {
    // 恢复态（无真实曲目）：回落给注入的 provider 回调（保存会话立即恢复播放）。
    if (!_service.hasTrack) {
      await _onRestoredSkipToNext?.call();
      _syncFromService(force: true);
      return;
    }
    await _service.skipToNext();
    _syncFromService(force: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_service.hasTrack) {
      await _onRestoredSkipToPrevious?.call();
      _syncFromService(force: true);
      return;
    }
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

  void _syncFromService({bool force = false}) {
    final track = _service.currentSourceTrack;
    final trackId = track?.id;
    final playing = _service.isPlaying;
    final loading = _service.isLoading;
    final mode = _service.mode;
    final position = _service.position;

    final trackChanged = trackId != _lastTrackId;
    final playingChanged = playing != _lastPlaying;
    final loadingChanged = loading != _lastLoading;
    // 模式变化要重发通知动作：图标/文案反映当前模式（App 内切换同样到达这里）。
    final modeChanged = mode != _lastMode;
    final artworkUrl = track?.coverUrl;
    final artworkChanged = artworkUrl != _lastArtworkUrl;
    final seeked =
        (position - _lastPosition).abs() > const Duration(seconds: 1);
    if (!force &&
        !trackChanged &&
        !playingChanged &&
        !loadingChanged &&
        !modeChanged &&
        !seeked &&
        !artworkChanged) {
      return;
    }
    _lastTrackId = trackId;
    _lastPlaying = playing;
    _lastLoading = loading;
    _lastMode = mode;
    _lastPosition = position;
    _lastArtworkUrl = artworkUrl;

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
        _playModeControl(mode),
        MediaControl.stop,
      ],
      // 紧凑视图（Android 通知收起态 / 锁屏）仍是「上一首 / 播放暂停 / 下一首」。
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

  /// 播放顺序动作：图标与文案反映**当前**模式（点按循环到下一个模式）。
  MediaControl _playModeControl(PlayMode mode) {
    final l10n = _currentLocalizations();
    return MediaControl.custom(
      name: playModeActionId,
      label: switch (mode) {
        PlayMode.sequential => l10n.playModeSequential,
        PlayMode.singleRepeat => l10n.playModeSingleRepeat,
        PlayMode.shuffle => l10n.playModeShuffle,
      },
      androidIcon: playModeActionIcons[mode]!,
    );
  }

  MediaItem _toMediaItem(SourceTrack track, {bool isCurrent = false}) {
    final duration = isCurrent && _service.duration > Duration.zero
        ? _service.duration
        : track.duration;
    final item = mediaItemForTrack(
      track,
      duration: duration,
      artworkBlocked: _artworkBlocked(),
    );
    if (!isCurrent) return item;
    return applyLyricMetadataOverride(item, _lyricMetadataOverride);
  }
}

/// 应用歌词元数据覆盖（纯函数，便于单测）：null 字段保持原值。
@visibleForTesting
MediaItem applyLyricMetadataOverride(
  MediaItem item,
  LyricMetadataOverride? override,
) {
  if (override == null || override.isEmpty) return item;
  return item.copyWith(
    title: override.title ?? item.title,
    artist: override.artist ?? item.artist,
    album: override.album ?? item.album,
    displaySubtitle: override.displaySubtitle ?? item.displaySubtitle,
  );
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
