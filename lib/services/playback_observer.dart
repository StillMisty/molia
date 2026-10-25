/// 播放观察者：承担播放快照的「写」与派生动作（副作用扇出的唯一实现）。
///
/// 纯观察者（同 `PlayStatisticsService` 模式）：不触碰播放内核、不 import
/// provider；组合根创建后经 [PlaybackObserver.attach] 订阅 facade 的快照通道，
/// 任何页面与后台切歌都走同一条链路，单测可用假 facade / 假副作用入口
/// 脚本化驱动。
///
/// 承担的副作用（顺序与节流与从 PlaybackProvider 抽出前逐一对应）：
/// - 最后播放信息（SharedPreferences 三键；UI 经 provider getter 读取）；
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
import 'package:flutter/widgets.dart'
    show GlobalKey, NavigatorState, WidgetsBinding;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../domain/ports/library_store.dart';
import '../domain/ports/playback_facade.dart';
import '../managers/image_preload_manager.dart';
import '../playback/playback_power_policy.dart';
import 'covers/cover_resolution.dart';
import 'app_presence.dart';
import 'data_saver_service.dart';
import 'notification_permission.dart';

final _logger = Logger('molia.playback_observer');

/// 桌面小组件更新器（Android `top.stillmisty.molia/widget` 通道）。
///
/// 默认实现见 [_updateAndroidWidget]；测试注入记录器断言调用与顺序。
typedef PlaybackWidgetUpdater = Future<void> Function(
  Map<String, Object?> payload,
);

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
    required this._facade,
    this._dataSaver,
    this._libraryRepository,
    PlaybackWidgetUpdater? widgetUpdater,
    AlbumArtPreloadStrategy? albumArtPreloader,
    this._artworkResolver,
    CoverResolver? coverResolver,
    this._navigatorKey,
    Future<void> Function()? requestNotificationPermission,
    AppPresence? presence,
    PlaybackPowerPolicy? mobilePowerPolicy,
  })  : _widgetUpdater = widgetUpdater ?? _updateAndroidWidget,
        _albumArtPreloader = albumArtPreloader ??
            AlbumArtPreloadStrategy(
              coverUrlResolver: coverResolver == null
                  ? null
                  : (track) => coverResolver.displayOf(track).url,
            ),
        _coverResolver = coverResolver,
        _requestNotificationPermission = requestNotificationPermission ??
            NotificationPermission.ensureRequested,
        _presence = presence ?? AppPresence.instance,
        _powerPolicy = mobilePowerPolicy {
    _ready = _loadLastPlayedTrackInfo();
  }

  static const String _lastPlayedImageKey = 'last_played_image_url';
  static const String _lastPlayedTrackNameKey = 'last_played_track_name';
  static const String _lastPlayedArtistsKey = 'last_played_artists';

  final PlaybackFacade _facade;
  final DataSaverService? _dataSaver;

  /// 资料库仓库（播放开始时写 play_history；失败仅日志）。
  final LibraryStore? _libraryRepository;

  /// 桌面小组件更新入口（Android 通道；测试注入记录器）。
  final PlaybackWidgetUpdater _widgetUpdater;

  final AlbumArtPreloadStrategy _albumArtPreloader;

  /// 封面补取解析器（组合根注入）：曲目起播且无封面时调用；
  /// 返回空表示无法补取（省流网关由注入侧实现）。
  final Future<String?> Function(Track track)? _artworkResolver;

  /// 封面解析器（组合根注入；真实 / 展示两种语义由类型区分）。
  final CoverResolver? _coverResolver;

  /// 组合根注入（封面预加载需要 BuildContext）。
  final GlobalKey<NavigatorState>? _navigatorKey;

  /// 窗口存在态：后台期不预取封面；恢复后补一次（见 [_onPresenceChanged]）。
  final AppPresence _presence;

  /// 移动端前后台 / 歌词输出策略：封面预取只在应用内可见时执行。
  ///
  /// 与 [AppPresence] 是两条独立信号：桌面用窗口存在态，移动端用生命周期；
  /// 两者任一不允许就跳过，恢复时任一先恢复都会补一次（幂等）。
  final PlaybackPowerPolicy? _powerPolicy;

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
    _presence.addListener(_onPresenceChanged);
    _powerPolicy?.addListener(_onPowerPolicyChanged);
    _onSnapshot();
  }

  /// 拆线（组合根只负责创建；释放与 provider 同生命周期）。
  void dispose() {
    if (!_attached) return;
    _attached = false;
    _facade.snapshot.removeListener(_onSnapshot);
    _presence.removeListener(_onPresenceChanged);
    _powerPolicy?.removeListener(_onPowerPolicyChanged);
  }

  /// 回到可见：补一次封面预取。
  ///
  /// 托盘隐藏期间界面处于休眠，唤醒后的页面重建发生在下一帧——
  /// [_triggerImagePreload] 依赖 navigator context，因此必须等这一帧建完；
  /// 提前置位 `visible` 时帧可能还是停的，先 `ensureVisualUpdate` 把帧排上。
  void _onPresenceChanged() => _resumeCoverPreload();

  /// 移动端回到前台：与托盘恢复同一套补取路径。
  void _onPowerPolicyChanged() {
    if (_powerPolicy?.canPreloadCovers != true) return;
    _resumeCoverPreload();
  }

  void _resumeCoverPreload() {
    if (!_attached || _presence.isBackgrounded) return;
    if (_powerPolicy?.canPreloadCovers == false) return;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_attached) return;
      _triggerImagePreload();
    });
  }

  /// 冷启动恢复态：把恢复曲目信息作为「最后播放」展示（不落盘）。
  ///
  /// 曲目并未真正起播，只在 UI 空态复用该信息；会话模块装载恢复会话时调用。
  void showRestoredTrack(Track track) {
    _lastPlayedTrackName = track.title;
    _lastPlayedArtists = track.artistLabel;
    _lastPlayedImageUrl = _displayCoverUrlOf(track);
  }

  /// 曲目切换时：持久化最后播放信息、更新桌面小组件并触发封面预加载。
  void _onSnapshot() {
    final live = _facade.snapshot.value;
    final track = live.current;
    final trackId = track?.id.uri;
    if (trackId == null) {
      _processedTrackId = null;
    } else if (trackId != _processedTrackId) {
      _processedTrackId = trackId;
      _persistLastPlayedTrackInfo(track!);
      unawaited(_updateWidget());
      _triggerImagePreload();
      unawaited(_recordPlayHistory(track));
      if (_coverUrlOf(track) == null) {
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
      await repository.addHistoryEntry(
        PlayHistoryEntry(
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
        ),
      );
    } catch (e) {
      _logger.severe('写入播放历史失败', e);
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
    unawaited(
      _saveLastPlayedTrackInfo(
        // 只持久化原始封面 URL：展示封面可能指向本地自定义 / 默认封面文件，
        // 把 file:// 路径写进 prefs 会在文件被替换 / 清理后留下坏地址。本地
        // 展示由 CustomCoverStore 按曲目键重新解析即可。
        imageUrl: track.artwork?.uri.toString(),
        trackName: track.title,
        artists: artists.isEmpty ? null : artists,
      ),
    );
  }

  /// 触发播放相关图片的智能预加载。
  ///
  /// 使用 ImagePreloadManager 预加载当前曲目、下一首、以及队列中的封面图片。
  /// 省流模式阻止封面网络请求时直接跳过（避免注定失败的下载与日志噪音）；
  /// 窗口在后台（托盘 / 最小化）或移动端不在前台时同样跳过——解码结果没有
  /// 展示面，只白占内存与 CPU，恢复后由 [_resumeCoverPreload] 补一次。
  void _triggerImagePreload() {
    if (_presence.isBackgrounded) return;
    if (_powerPolicy?.canPreloadCovers == false) return;
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

  /// 当前曲目的封面展示需要重算（自定义 / 默认封面变化）。
  ///
  /// 只刷新展示面（最后播放信息 / 桌面小组件 / 预取），不重写历史 / 会话 /
  /// 统计——那些必须保留原始封面 URL。
  void refreshCoverPresentation() {
    final track = _facade.snapshot.value.current;
    if (track == null) return;
    _persistLastPlayedTrackInfo(track);
    unawaited(_updateWidget());
    _triggerImagePreload();
  }

  /// 更新桌面小组件：从 facade 快照构造平台无关 payload，平台细节交给
  /// [PlaybackWidgetUpdater]（默认实现仅 Android 发通道消息）。
  Future<void> _updateWidget() async {
    final live = _facade.snapshot.value;
    final track = live.current;
    final displayUrl = _displayCoverUrlOf(track);
    // 省流只挡网络封面：自定义 / 默认封面是本地文件，照常交给小组件。
    // 远程地址传空串，MusicWidget 对空串跳过 Glide 加载。
    final blockRemoteArtwork = _dataSaver?.blockNetworkArtwork ?? false;
    final albumArtUrl = blockRemoteArtwork && !_isLocalArtworkUrl(displayUrl)
        ? ''
        : displayUrl ?? '';
    await _widgetUpdater({
      'songName': track?.title ?? '未在播放',
      'artistName': track?.primaryArtistName ?? '',
      'albumArtUrl': albumArtUrl,
      'isPlaying': live.isPlaying,
    });
  }

  /// 封面地址是否指向本地文件（省流模式无需拦截）。
  ///
  /// 协议相对地址（`//host/...`）是网络封面，不能按 Unix 裸路径放行。
  static bool _isLocalArtworkUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    if (url.startsWith('//')) return false;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') return true;
    return url.startsWith('/') || _windowsPathPattern.hasMatch(url);
  }

  static final RegExp _windowsPathPattern = RegExp(r'^[a-zA-Z]:[\\/]');

  String? _coverUrlOf(Track? track) {
    final covers = _coverResolver;
    if (covers != null) return covers.realOf(track).url;
    return track?.artwork?.uri.toString();
  }

  String? _displayCoverUrlOf(Track? track) {
    final covers = _coverResolver;
    if (covers != null) return covers.displayOf(track).url;
    return _coverUrlOf(track);
  }
}
