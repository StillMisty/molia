/// 播放观察者：承担播放快照的「写」与派生动作（副作用扇出的唯一实现）。
///
/// 纯观察者（同 `PlayStatisticsService` 模式）：不触碰播放内核、不 import
/// provider；组合根创建后经 [PlaybackObserver.attach] 订阅 facade 的快照通道，
/// 任何页面与后台切歌都走同一条链路，单测可用假 facade / 假副作用入口
/// 脚本化驱动。
///
/// 承担的副作用（顺序与节流与从 PlaybackProvider 抽出前逐一对应）：
/// - 最后播放信息（SharedPreferences 三键；UI 经 provider getter 读取）；
/// - 播放上下文 / 最近播放（[PlayContextWriter]，组合根注入 drift 写入）；
/// - 桌面小组件（[PlaybackWidgetUpdater]，默认实现仅 Android 生效）；
/// - 封面预取（[ImagePreloadManager]）；
/// - 播放历史（[LibraryStore]）；
/// - 封面补取（artworkResolver → `facade.updateTrackArtwork`）；
/// - 首次真正出声请求通知权限。
///
/// 会话落盘（保存 / 进度 / 清除）不在这里，也没有第二处写者：它连同恢复态
/// 交接一起收在 `PlaybackSessionCoordinator`（恢复态与睡眠定时属 provider /
/// 会话模块的内存状态，同样不在此处）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models/library.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/library_store.dart';
import '../domain/ports/playback_facade.dart';
import '../managers/image_preload_manager.dart';
import 'data_saver_service.dart';
import 'notification_permission.dart';

final _logger = Logger('molia.playback_observer');

/// 播放上下文写入器：组合根注入
/// `LocalDatabaseProvider.insertOrUpdatePlayContext`。
///
/// 用函数类型而不是直接依赖 provider：服务层不反向 import `lib/providers/**`，
/// 单测也不需要拉起真实 drift 数据库。
typedef PlayContextWriter = Future<void> Function({
  required String contextUri,
  required String contextType,
  required String contextName,
  required String? imageUrl,
  required int lastPlayedAt,
});

/// 桌面小组件更新器（Android `top.stillmisty.molia/widget` 通道）。
///
/// 默认实现见 [_updateAndroidWidget]；测试注入记录器断言调用与顺序。
typedef PlaybackWidgetUpdater = Future<void> Function(
    Map<String, Object?> payload);

/// 默认小组件更新：非 Android 是空操作，失败静默（不影响播放主流程）。
Future<void> _updateAndroidWidget(Map<String, Object?> payload) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel('top.stillmisty.molia/widget')
        .invokeMethod<void>('updateWidget', payload);
  } catch (e) {
    // 更新失败静默：桌面小组件不影响播放主流程。
  }
}

/// 播放快照副作用观察者：由组合根创建、挂接，与 provider 同生命周期。
///
/// 对外接口刻意收窄：挂接 / 拆线 + 最后播放信息读取与恢复态展示两条意图；
/// 所有写入细节（去重、过期丢弃）留在实现内部。
class PlaybackObserver {
  PlaybackObserver({
    required PlaybackFacade facade,
    DataSaverService? dataSaver,
    LibraryStore? libraryRepository,
    PlayContextWriter? playContextWriter,
    PlaybackWidgetUpdater? widgetUpdater,
    AlbumArtPreloadStrategy? albumArtPreloader,
    Future<String?> Function(Track track)? artworkResolver,
    GlobalKey<NavigatorState>? navigatorKey,
    Future<void> Function()? requestNotificationPermission,
  })  : _facade = facade,
        _dataSaver = dataSaver,
        _libraryRepository = libraryRepository,
        _playContextWriter = playContextWriter,
        _widgetUpdater = widgetUpdater ?? _updateAndroidWidget,
        _albumArtPreloader = albumArtPreloader ?? AlbumArtPreloadStrategy(),
        _artworkResolver = artworkResolver,
        _navigatorKey = navigatorKey,
        _requestNotificationPermission = requestNotificationPermission ??
            NotificationPermission.ensureRequested {
    _ready = _loadLastPlayedTrackInfo();
  }

  static const String _lastPlayedImageKey = 'last_played_image_url';
  static const String _lastPlayedTrackNameKey = 'last_played_track_name';
  static const String _lastPlayedArtistsKey = 'last_played_artists';

  final PlaybackFacade _facade;
  final DataSaverService? _dataSaver;

  /// 资料库仓库（播放开始时写 play_history；失败仅日志）。
  final LibraryStore? _libraryRepository;

  /// 播放上下文写入（最近播放），组合根注入。
  final PlayContextWriter? _playContextWriter;

  /// 桌面小组件更新入口（Android 通道；测试注入记录器）。
  final PlaybackWidgetUpdater _widgetUpdater;

  final AlbumArtPreloadStrategy _albumArtPreloader;

  /// 封面补取解析器（组合根注入）：曲目起播且无封面时调用；
  /// 返回空表示无法补取（省流网关由注入侧实现）。
  final Future<String?> Function(Track track)? _artworkResolver;

  /// 组合根注入（封面预加载需要 BuildContext）。
  final GlobalKey<NavigatorState>? _navigatorKey;

  /// 首次真正出声请求通知权限（测试注入记录器）。
  final Future<void> Function() _requestNotificationPermission;

  late final Future<void> _ready;
  bool _attached = false;

  // 持久化存储最后播放的歌曲信息（用于离线显示）
  String? _lastPlayedImageUrl;
  String? _lastPlayedTrackName;
  String? _lastPlayedArtists;

  /// 已处理过的当前曲目（用于去重持久化 / 写库 / 预加载）。
  String? _processedTrackId;

  /// 本次会话是否已请求过通知权限（首次真正播放时请求）。
  bool _notificationPermissionAsked = false;

  /// 正在补取封面的曲目 key（去重；同曲目只解析一次）。
  String? _artworkResolvingTrackId;

  /// 启动加载完成（最后播放信息已读；provider 的 preferencesReady 等待它）。
  Future<void> get ready => _ready;

  String? get lastPlayedImageUrl => _lastPlayedImageUrl;
  String? get lastPlayedTrackName => _lastPlayedTrackName;
  String? get lastPlayedArtists => _lastPlayedArtists;

  /// 挂接到 facade：订阅快照通道，并立即处理一次当前快照
  /// （接线前系统媒体会话可能已恢复曲目）。重复调用是空操作。
  void attach() {
    if (_attached) return;
    _attached = true;
    _facade.snapshot.addListener(_onSnapshot);
    _onSnapshot();
  }

  /// 拆线（组合根只负责创建；释放与 provider 同生命周期）。
  void dispose() {
    if (!_attached) return;
    _attached = false;
    _facade.snapshot.removeListener(_onSnapshot);
  }

  /// 冷启动恢复态：把恢复曲目信息作为「最后播放」展示（不落盘）。
  ///
  /// 曲目并未真正起播，只在 UI 空态复用该信息；会话模块装载恢复会话时调用。
  void showRestoredTrack(Track track) {
    _lastPlayedTrackName = track.title;
    _lastPlayedArtists = track.artistLabel;
    _lastPlayedImageUrl = track.artwork?.uri.toString();
  }

  /// 曲目切换时：持久化最后播放信息、写入播放上下文（最近播放）、
  /// 更新桌面小组件并触发封面预加载。
  void _onSnapshot() {
    final live = _facade.snapshot.value;
    final track = live.current;
    final trackId = track?.id.uri;
    if (trackId == null) {
      _processedTrackId = null;
    } else if (trackId != _processedTrackId) {
      _processedTrackId = trackId;
      _persistLastPlayedTrackInfo(track!);
      unawaited(_savePlayContextToDatabase(track, live.context));
      unawaited(_updateWidget());
      _triggerImagePreload();
      unawaited(_recordPlayHistory(track));
      if (track.artwork == null) {
        unawaited(_resolveMissingArtwork(track));
      }
    }
    // 首次真正出声时才请求通知权限（用户已经听到歌，权限弹窗有上下文；
    // 媒体通知依赖它才不会在部分 ROM 上被静默丢弃）。
    if (live.isPlaying && !_notificationPermissionAsked) {
      _notificationPermissionAsked = true;
      unawaited(_requestNotificationPermission());
    }
  }

  /// 播放开始时写入播放历史（元数据 + raw 取链参数；不写直链）。
  ///
  /// 失败仅日志：历史持久化不能影响播放主流程。
  Future<void> _recordPlayHistory(Track track) async {
    final repository = _libraryRepository;
    if (repository == null) return;
    try {
      await repository.addHistoryEntry(PlayHistoryEntry(
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
        title: track.title,
        artist: track.artistLabel,
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        // raw 原样持久化（play_history.raw），供下次播放按需重新取链。
        raw: Map<String, dynamic>.from(track.payload),
        playedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      _logger.severe('写入播放历史失败', e);
    }
  }

  /// 把当前播放上下文写入本地数据库（媒体库「最近播放」使用）。
  Future<void> _savePlayContextToDatabase(
    Track track,
    PlaybackContext? context,
  ) async {
    final name = context?.name;
    if (name == null || name.isEmpty) return;
    final writer = _playContextWriter;
    if (writer == null) return;

    final type = context?.type ?? 'lx';
    final uri = context?.uri ?? 'lx:$name';
    try {
      await writer(
        contextUri: uri,
        contextType: type,
        contextName: name,
        imageUrl: track.artwork?.uri.toString(),
        lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      _logger.severe('保存播放上下文失败', e);
    }
  }

  /// 读取「最后播放」信息（构造时发起；[ready] 暴露给组合根 / provider）。
  Future<void> _loadLastPlayedTrackInfo() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _lastPlayedImageUrl = sp.getString(_lastPlayedImageKey);
      _lastPlayedTrackName = sp.getString(_lastPlayedTrackNameKey);
      _lastPlayedArtists = sp.getString(_lastPlayedArtistsKey);
      _logger.fine('已加载最后播放歌曲信息: $_lastPlayedTrackName - $_lastPlayedArtists');
    } catch (e) {
      _logger.severe('加载最后播放歌曲信息失败', e);
    }
  }

  Future<void> _saveLastPlayedTrackInfo({
    String? imageUrl,
    String? trackName,
    String? artists,
  }) async {
    if (imageUrl == null && trackName == null && artists == null) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (imageUrl != null && imageUrl != _lastPlayedImageUrl) {
        await sp.setString(_lastPlayedImageKey, imageUrl);
        _lastPlayedImageUrl = imageUrl;
      }
      if (trackName != null && trackName != _lastPlayedTrackName) {
        await sp.setString(_lastPlayedTrackNameKey, trackName);
        _lastPlayedTrackName = trackName;
      }
      if (artists != null && artists != _lastPlayedArtists) {
        await sp.setString(_lastPlayedArtistsKey, artists);
        _lastPlayedArtists = artists;
      }
      _logger.fine('已保存最后播放歌曲信息: $trackName - $artists');
    } catch (e) {
      _logger.severe('保存最后播放歌曲信息失败', e);
    }
  }

  void _persistLastPlayedTrackInfo(Track track) {
    final artists = track.artistLabel;
    unawaited(_saveLastPlayedTrackInfo(
      imageUrl: track.artwork?.uri.toString(),
      trackName: track.title,
      artists: artists.isEmpty ? null : artists,
    ));
  }

  /// 触发播放相关图片的智能预加载。
  ///
  /// 使用 ImagePreloadManager 预加载当前曲目、下一首、以及队列中的封面图片。
  /// 省流模式阻止封面网络请求时直接跳过（避免注定失败的下载与日志噪音）。
  void _triggerImagePreload() {
    if (_dataSaver?.blockNetworkArtwork ?? false) return;
    final context = _navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;

    // 异步执行预加载，不阻塞主流程
    final live = _facade.snapshot.value;
    final currentTrack = live.current;
    final nextTrack = live.next;
    // 预加载实际播放顺序（shuffle 为洗牌排列剩余），避免随机模式下白下封面。
    final upcomingTracks = live.upNext;

    Future.microtask(() {
      if (!context.mounted) return;
      _albumArtPreloader.preloadForPlayback(
        context: context,
        currentTrack: currentTrack,
        nextTrack: nextTrack,
        upcomingTracks: upcomingTracks,
      );
    });
  }

  /// 封面补取：曲目无封面时经注入解析器取图并原地回写队列。
  ///
  /// 去重（同一曲目只解析一次）+ 过期守卫（补图回来时已切歌则丢弃）；
  /// 失败仅日志——封面是增强项，不影响播放。
  Future<void> _resolveMissingArtwork(Track track) async {
    final resolver = _artworkResolver;
    if (resolver == null) return;
    final trackId = track.id.uri;
    if (_artworkResolvingTrackId == trackId) return;
    _artworkResolvingTrackId = trackId;
    try {
      final url = await resolver(track);
      if (url == null || url.isEmpty) return;
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      if (_facade.snapshot.value.current?.id.uri != trackId) return;
      await _facade.updateTrackArtwork(trackId, uri);
      unawaited(_updateWidget());
    } catch (e) {
      _logger.warning('封面补取失败: $e');
    } finally {
      if (_artworkResolvingTrackId == trackId) {
        _artworkResolvingTrackId = null;
      }
    }
  }

  /// 更新桌面小组件：从 facade 快照构造平台无关 payload，平台细节交给
  /// [PlaybackWidgetUpdater]（默认实现仅 Android 发通道消息）。
  Future<void> _updateWidget() async {
    final live = _facade.snapshot.value;
    final track = live.current;
    // 省流时传空封面地址：MusicWidget 对空串跳过 Glide 加载。
    final blockArtwork = _dataSaver?.blockNetworkArtwork ?? false;
    await _widgetUpdater({
      'songName': track?.title ?? '未在播放',
      'artistName': track?.primaryArtistName ?? '',
      'albumArtUrl': blockArtwork ? '' : track?.artwork?.uri.toString() ?? '',
      'isPlaying': live.isPlaying,
    });
  }
}
