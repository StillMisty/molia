import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        VoidCallback,
        defaultTargetPlatform,
        kIsWeb;
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/catalog/catalog_service.dart';
import '../data/library_repository.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/library.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/playback_facade.dart';
import '../domain/ports/state_listenable.dart';
import '../domain/ports/ui_messenger.dart';
import '../managers/image_preload_manager.dart';
import '../models/play_mode.dart';
import '../services/data_saver_service.dart';
import '../services/playback_session_store.dart';
import '../sources/source_manager.dart';
import '../sources/source_track.dart';
import '../utils/notify_throttler.dart';
import 'local_database_provider.dart';

final _logger = Logger();

/// 领域 [StateListenable] → Flutter [ValueListenable] 适配器。
///
/// `lib/domain/**` 禁止 import Flutter，facade 端口只能暴露纯 Dart 接口；
/// UI（`ValueListenableBuilder`）需要 Flutter 形态，故在 provider 边界适配。
/// 同一实例稳定持有，保证 `ValueListenableBuilder` 不因换对象重订阅。
class _StateValueListenable<T> implements ValueListenable<T> {
  _StateValueListenable(this._source);

  final StateListenable<T> _source;

  @override
  T get value => _source.value;

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _source.removeListener(listener);
}

/// 进度通道：真实播放时转发 facade position；恢复态（冷启动未加载）
/// 显示上次保存的进度，直到用户恢复播放后交还底层。
class _PositionChannel implements ValueListenable<Duration> {
  _PositionChannel(this._source) {
    _source.addListener(_relay);
  }

  final ValueListenable<Duration> _source;
  final List<VoidCallback> _listeners = [];
  Duration? _restored;

  @override
  Duration get value => _restored ?? _source.value;

  /// 进入/更新恢复态（null 表示退出，交还底层）。
  void setRestored(Duration? position) {
    _restored = position;
    _notify();
  }

  void _relay() {
    if (_restored != null) return;
    _notify();
  }

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void dispose() => _source.removeListener(_relay);
}

/// UI 播放状态唯一入口：包装 [PlaybackFacade]（阶段 1 起）。
///
/// 对外只暴露领域 [PlaybackSnapshot]（真实播放来自 facade；冷启动恢复态
/// 由会话构造展示快照）与高频 position 通道；不再有 Map 形状的兼容层。
/// 所有播放均走本地音源，不再有远程播放分支。
///
/// 职责边界（docs/architecture.md §2.1）：
/// - 不再 import `main.dart`：错误提示走注入的 [UiMessenger]；
/// - 状态从 facade 快照/进度通道订阅；
/// - 持久化 / 写库 / 桌面小组件 / 封面预加载等副作用保留在本类。
class PlaybackProvider extends ChangeNotifier {
  static const String _lastPlayedImageKey = 'last_played_image_url';
  static const String _lastPlayedTrackNameKey = 'last_played_track_name';
  static const String _lastPlayedArtistsKey = 'last_played_artists';
  static const String _defaultPlayModeKey = 'default_play_mode';

  final PlaybackFacade _facade;
  final UiMessenger _messenger;
  final SourceManager? _sourceManager;

  /// 取链缓存失效入口（播放失败时按 sourceKey 失效，下一次播放重试）。
  final CatalogService? _catalogService;

  /// 资料库仓库（播放开始时写 play_history；失败仅日志）。
  final LibraryRepository? _libraryRepository;

  /// 省流模式（可选注入）：音质标签、封面预加载与桌面小组件封面共用。
  final DataSaverService? _dataSaver;

  /// 播放上下文写入（最近播放）：composition root 注入，不再经
  /// `navigatorKey.currentContext` 反查 provider。
  final LocalDatabaseProvider? _localDatabaseProvider;

  /// 过渡期注入（composition root 持有）：封面预加载需要 BuildContext。
  final GlobalKey<NavigatorState>? _navigatorKey;

  // 通知节流器 - 减少不必要的 UI 重建
  late final CategorizedNotifyThrottler _notifyThrottler;

  /// 高频进度通道（真实播放转发 facade.position；恢复态显示上次进度）。
  late final _PositionChannel _positionChannel;

  // 图片预加载管理器
  final AlbumArtPreloadStrategy _albumArtPreloader = AlbumArtPreloadStrategy();

  // 持久化存储最后播放的歌曲信息（用于离线显示）
  String? _lastPlayedImageUrl;
  String? _lastPlayedTrackName;
  String? _lastPlayedArtists;

  /// 上次播放会话持久化（冷启动恢复封面/标题/进度，点播放重新取链）。
  final PlaybackSessionStore _sessionStore;
  PlaybackSession? _restoredSession;

  /// 恢复态展示快照：`snapshot` getter 的覆盖值（无真实播放时生效）。
  PlaybackSnapshot? _restoredSnapshot;
  Duration _restoredPosition = Duration.zero;
  DateTime _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasPlaying = false;

  /// 已处理过的当前曲目（用于去重持久化 / 写库 / 预加载）。
  String? _processedTrackId;

  /// 已展示过的播放错误（避免同一错误反复弹提示）。
  String? _lastShownError;

  /// 已自动重试过的曲目 key（同一操作只重试一次，避免失败循环）。
  String? _retriedTrackKey;

  /// 默认播放模式（设置页配置；启动时无曲目即应用为初始模式）。
  PlayMode _defaultPlayMode = PlayMode.sequential;

  late final Future<void> _preferencesReady;

  PlaybackProvider({
    required PlaybackFacade facade,
    required UiMessenger messenger,
    SourceManager? sourceManager,
    GlobalKey<NavigatorState>? navigatorKey,
    CatalogService? catalogService,
    LibraryRepository? libraryRepository,
    DataSaverService? dataSaver,
    LocalDatabaseProvider? localDatabaseProvider,
    PlaybackSessionStore? sessionStore,
  })  : _facade = facade,
        _messenger = messenger,
        _sourceManager = sourceManager,
        _navigatorKey = navigatorKey,
        _catalogService = catalogService,
        _libraryRepository = libraryRepository,
        _dataSaver = dataSaver,
        _localDatabaseProvider = localDatabaseProvider,
        _sessionStore = sessionStore ?? PlaybackSessionStore() {
    _notifyThrottler = CategorizedNotifyThrottler(
      notifyCallback: super.notifyListeners,
      categoryIntervals: {
        'track': const Duration(milliseconds: 16), // 曲目切换几乎立即响应
        'queue': const Duration(milliseconds: 300), // 队列更新节流 300ms
      },
      defaultInterval: const Duration(milliseconds: 50),
    );
    _positionChannel =
        _PositionChannel(_StateValueListenable<Duration>(_facade.position));
    _facade.position.addListener(_onPositionTick);
    _facade.snapshot.addListener(_onFacadeSnapshot);
    // 阶段 4：position 走独立 ValueListenable 通道（_positionChannel），
    // 不再转发进 notifyListeners——进度 tick 只重建进度条/歌词行。
    _sourceManager?.addListener(_onSourceManagerChanged);
    _dataSaver?.addListener(_onDataSaverChanged);
    _preferencesReady = () async {
      await _loadLastPlayedTrackInfo();
      await _loadDefaultPlayMode();
      await _loadPlaybackSession();
    }();
    // 构造时同步一次快照（系统媒体会话可能在构造前已恢复曲目）。
    _handlePlaybackSnapshot();
  }

  // -------------------------------------------------------------------------
  // 状态（领域快照：真实播放来自 facade；恢复态由会话构造）
  // -------------------------------------------------------------------------

  /// UI 状态唯一入口：真实播放取 facade 快照；冷启动恢复态取会话快照。
  PlaybackSnapshot get snapshot => _restoredSnapshot ?? _facade.snapshot.value;

  /// 是否有可恢复的上次播放会话（无真实曲目时才生效）。
  bool get hasRestoredSession =>
      _restoredSession?.current != null &&
      _facade.snapshot.value.current == null;


  /// 高频进度通道：订阅它做进度条/歌词行更新，避免整 Provider 重建。
  ValueListenable<Duration> get position => _positionChannel;

  /// 同步读取当前进度（回调/一次性读取路径用；不建立订阅）。
  ///
  /// 真实播放与快照同源；恢复态为上次保存的进度。
  Duration get currentPosition => _positionChannel.value;

  PlayMode get currentMode => snapshot.mode;

  /// 当前曲目的领域 id（sourceKey + 平台 id），收藏/资料库 UI 使用。
  TrackId? get currentTrackId => snapshot.current?.id;

  bool get hasTrack => snapshot.current != null;

  /// 当前曲目的预期音质标签：偏好音质 × 曲目可用音质（纯函数 [pickQualityFor]）。
  /// 无曲目或曲目无可用音质时回退到偏好音质的展示名。
  /// 省流生效（移动数据 + 已开启）时按用户设定的上限显示。
  String get currentQualityLabel {
    final preferred = _sourceManager?.preferredQuality ?? '320k';
    final effective = _dataSaver?.effectiveQuality(preferred) ?? preferred;
    final track = snapshot.current;
    final supported = track == null
        ? const <String>[]
        : track.qualities
            .map((quality) => quality.type)
            .where((type) => type.isNotEmpty);
    return kxQualityDisplayName(pickQualityFor(supported, effective));
  }

  bool get isPlaying => snapshot.isPlaying;

  bool get isLoading => snapshot.isLoading;

  /// 默认播放模式（设置页配置；启动无曲目时已应用到服务）。
  PlayMode get defaultPlayMode => _defaultPlayMode;

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  // 获取最后播放的歌曲信息（用于离线默认显示）
  String? get lastPlayedImageUrl => _lastPlayedImageUrl;
  String? get lastPlayedTrackName => _lastPlayedTrackName;
  String? get lastPlayedArtists => _lastPlayedArtists;

  // -------------------------------------------------------------------------
  // 播放控制（方法名与旧播放 Provider 保持一致）
  // -------------------------------------------------------------------------

  /// 播放音源曲目（本地播放）。[tracks] 为上下文队列。
  Future<void> playSourceTracks(
    List<SourceTrack> tracks,
    int index, {
    String? contextName,
  }) async {
    if (tracks.isEmpty) return;
    try {
      await _facade.playTracks(PlaybackRequest(
        tracks: [for (final track in tracks) trackFromSourceTrack(track)],
        startIndex: index,
        context: contextName == null
            ? null
            : PlaybackContext(
                name: contextName,
                type: 'lx',
                uri: 'lx:$contextName',
              ),
      ));
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.e('playSourceTracks: 播放失败', error: e);
      rethrow;
    }
  }

  /// 播放本地队列中指定 id 的曲目（队列面板点击）。
  ///
  /// 恢复态下 facade 队列为空：命中会话队列则从该曲目恢复播放。
  Future<void> playLocalQueueItemById(String trackId) async {
    final queue = _facade.snapshot.value.queue;
    final index = queue.indexWhere((track) => track.id.uri == trackId);
    if (index < 0) {
      final session = _restoredSession;
      if (session != null) {
        final restoredIndex =
            session.tracks.indexWhere((track) => track.id.uri == trackId);
        if (restoredIndex >= 0) {
          await resumeRestoredSession(startIndex: restoredIndex);
        }
      }
      return;
    }
    await _facade.playQueueIndex(index);
    _notifyCategory('track');
  }

  /// 停止本地播放并清空状态（同时丢弃恢复会话，避免下次启动又出现）。
  Future<void> stopLocalPlayback() async {
    await _facade.stop();
    _clearRestoredSession();
    unawaited(_sessionStore.clear());
    _notifyCategory('track');
    _notifyCategory('queue');
  }

  Future<void> togglePlayPause() async {
    // 恢复态：点播放 = 用上次队列/下标重新取链，并跳回保存的进度。
    if (_facade.snapshot.value.current == null &&
        _restoredSession?.current != null) {
      await resumeRestoredSession();
      return;
    }
    await _facade.toggle();
    _notifyCategory('track');
  }

  /// 恢复上次播放：以保存的队列/下标重新加载，再 seek 回保存的进度。
  ///
  /// [startIndex] 指定从队列中另一首开始（恢复态点队列条目）：此时不 seek
  /// 回保存进度（那是另一首曲目的进度）。直链不持久化（会过期），这里走
  /// 正常取链路径；失败时保留恢复态可重试。
  Future<void> resumeRestoredSession({int? startIndex}) async {
    final session = _restoredSession;
    if (session == null || session.current == null) return;
    final index = (startIndex ?? session.index)
        .clamp(0, session.tracks.length - 1);
    final seekBack = index == session.index ? _restoredPosition : Duration.zero;
    try {
      await _facade.playTracks(PlaybackRequest(
        tracks: session.tracks,
        startIndex: index,
        context: session.context,
      ));
      if (seekBack > Duration.zero) {
        await _facade.seek(seekBack);
      }
      _clearRestoredSession();
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.e('恢复上次播放失败', error: e);
    }
  }

  Future<void> seekToPosition(int positionMs) async {
    // 恢复态：只更新保存的进度（点播放时再落到真实播放器上）。
    if (_facade.snapshot.value.current == null && _restoredSession != null) {
      final durationMs =
          _restoredSession!.current?.duration?.inMilliseconds ?? 0;
      final clamped = durationMs > 0
          ? positionMs.clamp(0, durationMs)
          : (positionMs < 0 ? 0 : positionMs);
      _restoredPosition = Duration(milliseconds: clamped);
      _restoredSession =
          _restoredSession!.copyWith(position: _restoredPosition);
      _positionChannel.setRestored(_restoredPosition);
      _publishRestoredSnapshot();
      unawaited(_sessionStore.save(_restoredSession!));
      _notifyCategory('track');
      return;
    }
    await _facade.seek(Duration(milliseconds: positionMs));
    _notifyCategory('track');
  }

  Future<void> skipToNext() async {
    if (_facade.snapshot.value.current == null &&
        _restoredSession?.current != null) {
      _moveRestoredIndex(1);
      return;
    }
    await _facade.next();
    _notifyCategory('track');
  }

  Future<void> skipToPrevious() async {
    if (_facade.snapshot.value.current == null &&
        _restoredSession?.current != null) {
      _moveRestoredIndex(-1);
      return;
    }
    await _facade.previous();
    _notifyCategory('track');
  }

  /// 恢复态切歌：只在保存的队列内移动下标（点播放时从新下标开始）。
  void _moveRestoredIndex(int delta) {
    final session = _restoredSession;
    if (session == null) return;
    final next = session.index + delta;
    if (next < 0 || next >= session.tracks.length) return;
    _restoredSession = session.copyWith(index: next, position: Duration.zero);
    _restoredPosition = Duration.zero;
    _positionChannel.setRestored(Duration.zero);
    _publishRestoredSnapshot();
    unawaited(_sessionStore.save(_restoredSession!));
    _notifyCategory('track');
    _notifyCategory('queue');
  }

  // 设置播放模式
  Future<void> setPlayMode(PlayMode mode) async {
    await _facade.setMode(mode);
    _notifyCategory('track');
  }

  // 循环切换播放模式
  Future<void> togglePlayMode() async {
    final next =
        PlayMode.values[(currentMode.index + 1) % PlayMode.values.length];
    await setPlayMode(next);
  }

  /// 设置默认播放模式：持久化；当前无曲目时立即应用到服务，作为
  /// 下一次播放的初始模式（不打断正在播放的会话）。
  Future<void> setDefaultPlayMode(PlayMode mode) async {
    if (_defaultPlayMode != mode) {
      _defaultPlayMode = mode;
      _notifyCategory('default');
    }
    final snapshot = _facade.snapshot.value;
    if (snapshot.current == null && snapshot.mode != mode) {
      await _facade.setMode(mode);
      _notifyCategory('track');
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_defaultPlayModeKey, mode.name);
    } catch (e) {
      _logger.e('保存默认播放模式失败', error: e);
    }
  }

  /// 启动加载默认播放模式；无曲目时应用到 facade（有曲目时不打断当前会话）。
  Future<void> _loadDefaultPlayMode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final name = sp.getString(_defaultPlayModeKey);
      if (name == null) return;
      final mode = PlayMode.values.firstWhere(
        (value) => value.name == name,
        orElse: () => PlayMode.sequential,
      );
      _defaultPlayMode = mode;
      final snapshot = _facade.snapshot.value;
      if (snapshot.current == null && snapshot.mode != mode) {
        await _facade.setMode(mode);
      }
      _notifyCategory('default');
    } catch (e) {
      _logger.e('加载默认播放模式失败', error: e);
    }
  }

  // -------------------------------------------------------------------------
  // 状态变更处理
  // -------------------------------------------------------------------------

  /// facade 低频快照变化：持久化并通知 UI（曲目/队列）。
  void _onFacadeSnapshot() {
    _handlePlaybackSnapshot();
    _notifyCategory('track');
    _notifyCategory('queue');
  }

  void _onSourceManagerChanged() {
    _notifyCategory('default');
  }

  /// 省流模式状态变化（开关/网络切换）：音质标签等 UI 需刷新。
  void _onDataSaverChanged() {
    _notifyCategory('default');
  }

  /// 曲目切换时：持久化最后播放信息、写入播放上下文（最近播放）、
  /// 更新桌面小组件并触发封面预加载；同时维护「上次播放会话」。
  void _handlePlaybackSnapshot() {
    final live = _facade.snapshot.value;
    final track = live.current;
    final trackId = track?.id.uri;
    if (trackId == null) {
      _processedTrackId = null;
    } else if (trackId != _processedTrackId) {
      _processedTrackId = trackId;
      // 真实播放接管：撤下冷启动恢复态。
      _clearRestoredSession();
      _persistLastPlayedTrackInfo(track!);
      unawaited(_savePlayContextToDatabase(track, live.context));
      unawaited(updateWidget());
      _triggerImagePreload();
      unawaited(_recordPlayHistory(track));
      _maybeSavePlaybackSession(force: true);
    }
    // 播放中→暂停/停止：强制保存一次进度（避免节流窗口内丢进度）。
    if (_wasPlaying && !live.isPlaying) {
      _maybeSavePlaybackSession(force: true);
    }
    _wasPlaying = live.isPlaying;
    _maybeShowPlaybackError();
    _maybeRecoverFromPlaybackError();
  }

  // -------------------------------------------------------------------------
  // 上次播放会话（冷启动恢复）
  // -------------------------------------------------------------------------

  /// 高频进度 tick：节流保存会话进度。
  void _onPositionTick() {
    _maybeSavePlaybackSession();
  }

  /// 保存当前播放会话（节流；track 切换/暂停时强制）。
  void _maybeSavePlaybackSession({bool force = false}) {
    final snapshot = _facade.snapshot.value;
    final current = snapshot.current;
    if (current == null || snapshot.queue.isEmpty || snapshot.currentIndex < 0) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastSessionSave) < const Duration(seconds: 5)) {
      return;
    }
    _lastSessionSave = now;
    unawaited(_sessionStore.save(PlaybackSession(
      tracks: snapshot.queue,
      index: snapshot.currentIndex,
      position: _facade.position.value,
      mode: snapshot.mode,
      context: snapshot.context,
    )));
  }

  /// 冷启动加载上次播放会话：无真实曲目时进入恢复态。
  Future<void> _loadPlaybackSession() async {
    try {
      final session = await _sessionStore.load();
      if (session == null || session.current == null) return;
      // 已有真实播放（如系统媒体会话恢复）时不覆盖。
      if (_facade.snapshot.value.current != null) return;
      _restoredSession = session;
      _restoredPosition = session.position;
      _positionChannel.setRestored(session.position);
      final current = session.current!;
      _lastPlayedTrackName = current.title;
      _lastPlayedArtists =
          current.artists.map((artist) => artist.name).join(', ');
      _lastPlayedImageUrl = current.artwork?.uri.toString();
      _publishRestoredSnapshot();
      _logger.d(
          '已恢复上次播放会话: ${current.title} @${session.position.inSeconds}s');
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.e('恢复上次播放会话失败', error: e);
    }
  }

  /// 用会话构造恢复态展示快照：当前/队列/下标/模式齐备，isPlaying=false；
  /// 历史用会话队列前缀近似（与旧「index-1 上一首封面」语义一致）。
  void _publishRestoredSnapshot() {
    final session = _restoredSession;
    final current = session?.current;
    if (session == null || current == null) {
      _restoredSnapshot = null;
      return;
    }
    _restoredSnapshot = PlaybackSnapshot(
      current: current,
      queue: List.unmodifiable(session.tracks),
      currentIndex: session.index,
      next: session.index + 1 < session.tracks.length
          ? session.tracks[session.index + 1]
          : null,
      upcoming: List.unmodifiable(session.tracks.sublist(session.index + 1)),
      history: List.unmodifiable(session.tracks.sublist(0, session.index)),
      isPlaying: false,
      isLoading: false,
      duration: current.duration ?? Duration.zero,
      mode: session.mode,
      context: session.context,
    );
  }

  /// 撤下恢复态：真实播放接管或停止播放时调用。
  void _clearRestoredSession() {
    _restoredSession = null;
    _restoredSnapshot = null;
    _restoredPosition = Duration.zero;
    _positionChannel.setRestored(null);
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
        artist: track.artists.map((artist) => artist.name).join(', '),
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        // raw 原样持久化（play_history.raw），供下次播放按需重新取链。
        raw: Map<String, dynamic>.from(track.payload),
        playedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      _logger.e('写入播放历史失败', error: e);
    }
  }

  /// 播放失败恢复：按 sourceKey 失效取链缓存，并自动重试一次。
  ///
  /// 同一曲目 key 只重试一次（`_retriedTrackKey` 守卫），失败不缓存，
  /// 下一次播放自然会重新取链，不会形成失败循环。
  void _maybeRecoverFromPlaybackError() {
    final state = _facade.snapshot.value;
    final failure = state.error;
    final track = state.current;
    if (failure == null || track == null) return;
    if (state.currentIndex < 0) return;

    // 失败即失效该音源取链缓存（失败本身不入缓存，下次播放重新取链）。
    _catalogService?.invalidateResolvePrefix(track.id.sourceKey);

    final key = track.id.uri;
    if (_retriedTrackKey == key) return;
    _retriedTrackKey = key;

    final index = state.currentIndex;
    unawaited(Future<void>.microtask(() async {
      try {
        await _facade.playQueueIndex(index);
      } catch (e) {
        _logger.e('播放失败自动重试失败', error: e);
      }
    }));
  }

  void _maybeShowPlaybackError() {
    final failure = _facade.snapshot.value.error;
    if (failure == null || failure.message == _lastShownError) return;
    _lastShownError = failure.message;
    _messenger.showFailure(failure);
  }

  /// 把当前播放上下文写入本地数据库（媒体库「最近播放」使用）。
  Future<void> _savePlayContextToDatabase(
    Track track,
    PlaybackContext? context,
  ) async {
    final name = context?.name;
    if (name == null || name.isEmpty) return;
    final localDbProvider = _localDatabaseProvider;
    if (localDbProvider == null) return;

    final type = context?.type ?? 'lx';
    final uri = context?.uri ?? 'lx:$name';
    try {
      await localDbProvider.insertOrUpdatePlayContext(
        contextUri: uri,
        contextType: type,
        contextName: name,
        imageUrl: track.artwork?.uri.toString(),
        lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      _logger.e('保存播放上下文失败', error: e);
    }
  }

  // -------------------------------------------------------------------------
  // 最后播放信息持久化（离线默认展示）
  // -------------------------------------------------------------------------

  Future<void> _loadLastPlayedTrackInfo() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _lastPlayedImageUrl = sp.getString(_lastPlayedImageKey);
      _lastPlayedTrackName = sp.getString(_lastPlayedTrackNameKey);
      _lastPlayedArtists = sp.getString(_lastPlayedArtistsKey);
      _logger.d('已加载最后播放歌曲信息: $_lastPlayedTrackName - $_lastPlayedArtists');
    } catch (e) {
      _logger.e('加载最后播放歌曲信息失败', error: e);
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
      _logger.d('已保存最后播放歌曲信息: $trackName - $artists');
    } catch (e) {
      _logger.e('保存最后播放歌曲信息失败', error: e);
    }
  }

  void _persistLastPlayedTrackInfo(Track track) {
    final artists = track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    unawaited(_saveLastPlayedTrackInfo(
      imageUrl: track.artwork?.uri.toString(),
      trackName: track.title,
      artists: artists.isEmpty ? null : artists,
    ));
  }

  // -------------------------------------------------------------------------
  // 图片预加载 / 桌面小组件
  // -------------------------------------------------------------------------

  /// 触发播放相关图片的智能预加载
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
    final upcomingTracks = live.upcoming;

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

  Future<void> updateWidget() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      const platform = MethodChannel('top.stillmisty.molia/widget');
      try {
        // 省流时传空封面地址：MusicWidget 对空串跳过 Glide 加载。
        final blockArtwork = _dataSaver?.blockNetworkArtwork ?? false;
        final track = snapshot.current;
        await platform.invokeMethod('updateWidget', {
          'songName': track?.title ?? '未在播放',
          'artistName': track == null || track.artists.isEmpty
              ? ''
              : track.artists.first.name,
          'albumArtUrl': blockArtwork
              ? ''
              : track?.artwork?.uri.toString() ?? '',
          'isPlaying': snapshot.isPlaying,
        });
      } catch (e) {
        // debugPrint('更新 widget 失败: $e');
      }
    }
  }

  /// 分类通知 - 根据更新类型使用不同的节流策略
  void _notifyCategory(String category) {
    _notifyThrottler.notify(category);
  }

  @override
  void dispose() {
    _facade.snapshot.removeListener(_onFacadeSnapshot);
    _facade.position.removeListener(_onPositionTick);
    _positionChannel.dispose();
    _sourceManager?.removeListener(_onSourceManagerChanged);
    _dataSaver?.removeListener(_onDataSaverChanged);
    // 注意：facade / backend / LocalPlaybackService 由 main 创建并注入
    // （audio_service 复用），此处不能 dispose，只解除监听。
    _notifyThrottler.dispose();
    super.dispose();
  }
}
