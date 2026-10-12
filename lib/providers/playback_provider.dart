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
import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/failure.dart';
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
import '../services/source_swap/source_swap_settings.dart';
import '../sources/source_manager.dart';
import '../sources/source_track.dart';
import '../utils/notify_throttler.dart';
import 'local_database_provider.dart';

final _logger = Logger();

/// 自动换源解析器：在其它音源严格找回同一首歌（组合根注入）。
///
/// [excludeSourceKeys] 为已尝试来源（provenance，由 provider 维护）。
typedef AutoSourceSwapResolver = Future<Track?> Function(
  Track track, {
  required Set<String> excludeSourceKeys,
});

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

/// UI 播放状态唯一入口：包装 [PlaybackFacade]。
///
/// 对外只暴露领域 [PlaybackSnapshot]（真实播放来自 facade；冷启动恢复态
/// 由会话构造展示快照）与高频 position 通道。
/// 所有播放均走本地音源。
///
/// 职责边界（docs/architecture.md §2.1）：
/// - 错误提示走注入的 [UiMessenger]（不依赖 `main.dart`）；
/// - 状态从 facade 快照/进度通道订阅；
/// - 持久化 / 写库 / 桌面小组件 / 封面预加载等副作用保留在本类。
class PlaybackProvider extends ChangeNotifier {
  static const String _lastPlayedImageKey = 'last_played_image_url';
  static const String _lastPlayedTrackNameKey = 'last_played_track_name';
  static const String _lastPlayedArtistsKey = 'last_played_artists';

  /// 播放会话进度落盘节流：正常播放中最多每秒写一次
  /// （被系统杀进程时最多丢 ~1s 进度；track 切换/暂停/后台强制写）。
  static const Duration _sessionSaveInterval = Duration(seconds: 1);

  final PlaybackFacade _facade;
  final SettingsRegistry _settings;
  final UiMessenger _messenger;
  final SourceManager? _sourceManager;

  /// 取链缓存失效入口（播放失败时按 sourceKey 失效，下一次播放重试）。
  final CatalogService? _catalogService;

  /// 资料库仓库（播放开始时写 play_history；失败仅日志）。
  final LibraryRepository? _libraryRepository;

  /// 省流模式（可选注入）：音质标签、封面预加载与桌面小组件封面共用。
  final DataSaverService? _dataSaver;

  /// 封面补取解析器（组合根注入）：曲目起播且无封面时调用；
  /// 返回空表示无法补取（省流网关由注入侧实现）。
  final Future<String?> Function(Track track)? _artworkResolver;

  /// 播放上下文写入（最近播放）：由 composition root 注入。
  final LocalDatabaseProvider? _localDatabaseProvider;

  /// 自动换源开关（设置 › 播放，默认开）；null = 关闭该能力。
  final SourceSwapSettings? _autoSwapSettings;

  /// 自动换源解析器（组合根注入 `AutoSourceSwapService.findMatch`）。
  final AutoSourceSwapResolver? _autoSwapResolver;

  /// composition root 注入（封面预加载需要 BuildContext）。
  final GlobalKey<NavigatorState>? _navigatorKey;

  // 通知节流器 - 减少不必要的 UI 重建
  late final CategorizedNotifyThrottler _notifyThrottler;

  /// 高频进度通道（真实播放转发 facade.position；恢复态显示上次进度）。
  late final _PositionChannel _positionChannel;

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

  /// 恢复播放进行中（playTracks/seek 未完成）：此时撤下恢复态快照但
  /// 保留进度通道的恢复进度，避免进度条闪回 0。
  bool _resumeRestoring = false;

  /// 恢复装载期间用户主动 seek 的目标：恢复流程末尾以用户目标为准，
  /// 否则用户的拖动/点歌词行会被「跳回保存进度」覆盖。
  Duration? _resumeSeekTarget;
  DateTime _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasPlaying = false;

  /// 已处理过的当前曲目（用于去重持久化 / 写库 / 预加载）。
  String? _processedTrackId;

  /// 已展示过的播放错误（避免同一错误反复弹提示）。
  String? _lastShownError;

  /// 已自动重试过的曲目 key（同一操作只重试一次，避免失败循环）。
  String? _retriedTrackKey;

  /// 自动换源：每个曲目 uri 的**已尝试来源**（含种子源；换源后的候选继承
  /// 并追加自身来源），级联每个来源至多一次、有界；cap 防止长期泄漏。
  final Map<String, Set<String>> _autoSwapTriedSources = {};
  static const int _autoSwapProvenanceCap = 64;

  /// 正在自动换源的曲目 uri（防并发重复触发）。
  final Set<String> _autoSwapping = {};

  /// 正在补取封面的曲目 key（去重；同曲目只解析一次）。
  String? _artworkResolvingTrackId;

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
    Future<String?> Function(Track track)? artworkResolver,
    SourceSwapSettings? autoSwapSettings,
    AutoSourceSwapResolver? autoSwapResolver,
    SettingsRegistry? settings,
  })  : _facade = facade,
        _messenger = messenger,
        _sourceManager = sourceManager,
        _navigatorKey = navigatorKey,
        _catalogService = catalogService,
        _libraryRepository = libraryRepository,
        _dataSaver = dataSaver,
        _localDatabaseProvider = localDatabaseProvider,
        _artworkResolver = artworkResolver,
        _autoSwapSettings = autoSwapSettings,
        _autoSwapResolver = autoSwapResolver,
        _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys),
        _sessionStore = sessionStore ?? PlaybackSessionStore() {
    _settings.bindReload(kDefaultPlayMode, reloadDefaultPlayMode);
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
    // position 走独立 ValueListenable 通道（_positionChannel）：进度 tick
    // 只重建进度条/歌词行，不触发整 Provider 重建。
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

  String? get lastPlayedImageUrl => _lastPlayedImageUrl;
  String? get lastPlayedTrackName => _lastPlayedTrackName;
  String? get lastPlayedArtists => _lastPlayedArtists;

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

  /// 播放领域曲目（AI 推歌：解析结果已是领域 [Track]）。
  Future<void> playDomainTracks(
    List<Track> tracks,
    int index, {
    String? contextName,
  }) async {
    if (tracks.isEmpty) return;
    try {
      await _facade.playTracks(PlaybackRequest(
        tracks: List.of(tracks),
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
      _logger.e('playDomainTracks: 播放失败', error: e);
      rethrow;
    }
  }

  /// 追加领域曲目到当前队列末尾（AI 推歌续推）：不打断当前播放。
  Future<void> enqueueDomainTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await _facade.enqueueTracks(List.of(tracks));
      _notifyCategory('queue');
    } catch (e) {
      _logger.e('enqueueDomainTracks: 追加队列失败', error: e);
      rethrow;
    }
  }

  /// 换源：把队列中 [oldTrack] 原地替换为 [newTrack]，返回是否命中。
  ///
  /// 真实队列经 facade 替换（按 id 全量命中；命中当前曲目会重新取链
  /// 从头播放）；冷启动恢复态（facade 队列为空）替换保存的会话队列并落盘。
  /// 未命中不算失败：库内换源与队列跟随解耦（曲目可能不在当前队列）。
  Future<bool> replaceQueueTrack(Track oldTrack, Track newTrack) async {
    final uri = oldTrack.id.uri;
    var hit = false;
    if (_facade.snapshot.value.queue.any((track) => track.id.uri == uri)) {
      await _facade.replaceQueueTrack(uri, newTrack);
      hit = true;
    }
    final session = _restoredSession;
    if (session != null &&
        session.tracks.any((track) => track.id.uri == uri)) {
      _restoredSession = session.copyWith(
        tracks: [
          for (final track in session.tracks)
            track.id.uri == uri ? newTrack : track,
        ],
      );
      _publishRestoredSnapshot();
      unawaited(_sessionStore.save(_restoredSession!));
      hit = true;
    }
    if (hit) {
      _notifyCategory('track');
      _notifyCategory('queue');
    }
    return hit;
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
    // 已有恢复流程在跑：忽略重复触发（装载中后端会推送曲目，后续操作走
    // 真实播放路径，不会再次进入本方法）。
    if (session == null || session.current == null || _resumeRestoring) return;
    final index = (startIndex ?? session.index)
        .clamp(0, session.tracks.length - 1);
    final seekBack = index == session.index ? _restoredPosition : Duration.zero;
    // 装载期间保持显示恢复进度：后端装载会把进度通道对齐到 0，
    // 若立刻交还底层，进度条会先闪回首部再跳到恢复进度。
    _resumeRestoring = true;
    try {
      // 会话模式先落地：shuffle 需要在装载队列前生效（决定洗牌顺序）；
      // 也保证实际播放模式与恢复态 UI 显示的一致。
      await _facade.setMode(session.mode);
      await _facade.playTracks(PlaybackRequest(
        tracks: session.tracks,
        startIndex: index,
        context: session.context,
      ));
      // 装载期间用户主动 seek（拖进度条/点歌词行）优先于保存进度。
      final targetSeek = _resumeSeekTarget ?? seekBack;
      if (targetSeek > Duration.zero) {
        await _facade.seek(targetSeek);
      }
      _clearRestoredSession();
      // 立刻把恢复进度写回会话：装载时的强制保存记的是 0，
      // 若在节流窗口内被杀进程，下次冷启动会从 0 开始。
      _maybeSavePlaybackSession(force: true);
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.e('恢复上次播放失败', error: e);
      // 已被真实播放接管（恢复快照已撤下）：交还进度通道，
      // 避免一直停在旧的恢复进度。
      if (_restoredSession == null) {
        _clearRestoredSession();
      }
    } finally {
      _resumeRestoring = false;
      _resumeSeekTarget = null;
    }
  }

  Future<void> seekToPosition(int positionMs) async {
    // 恢复装载期间的 seek：记下用户目标，恢复流程末尾以它为准
    // （否则用户的拖动/点歌词行会被恢复流程的「跳回保存进度」覆盖）。
    if (_resumeRestoring) {
      _resumeSeekTarget = Duration(milliseconds: positionMs);
    }
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

  // 恢复态（冷启动未真正播放）下 UI 读的是恢复快照，必须同步更新恢复会话
  // 并持久化，否则模式按钮看起来「点不动」；恢复播放时会把该模式带给后端。
  Future<void> setPlayMode(PlayMode mode) async {
    await _facade.setMode(mode);
    final session = _restoredSession;
    if (session != null) {
      _restoredSession = session.copyWith(mode: mode);
      _publishRestoredSnapshot();
      unawaited(_sessionStore.save(_restoredSession!));
    }
    _notifyCategory('track');
  }

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
      await _settings.write(kDefaultPlayMode, mode.name);
    } catch (e) {
      _logger.e('保存默认播放模式失败', error: e);
    }
  }

  /// 启动加载默认播放模式；无曲目时应用到 facade（有曲目时不打断当前会话）。
  Future<void> _loadDefaultPlayMode() async {
    try {
      final name = await _settings.read(kDefaultPlayMode);
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

  /// 重新读取默认播放模式（跨设备同步应用远端设置后由组合根调用）。
  Future<void> reloadDefaultPlayMode() => _loadDefaultPlayMode();

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
      // 真实播放接管：撤下冷启动恢复态。恢复播放的 seek 尚未落地时，
      // 继续沿用恢复进度显示（见 _resumeRestoring），避免进度条闪回 0。
      _clearRestoredSession(keepPosition: _resumeRestoring);
      _persistLastPlayedTrackInfo(track!);
      unawaited(_savePlayContextToDatabase(track, live.context));
      unawaited(updateWidget());
      _triggerImagePreload();
      unawaited(_recordPlayHistory(track));
      if (track.artwork == null) {
        unawaited(_resolveMissingArtwork(track));
      }
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

  /// 立即把当前播放会话写入本地（进入后台/生命周期 paused 时调用）。
  ///
  /// 会话进度平时按 [_sessionSaveInterval] 节流保存；暂停/后台时强制落盘，
  /// 被系统杀进程时最多丢约 1s 进度。
  void flushPlaybackSession() => _maybeSavePlaybackSession(force: true);

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
    if (!force && now.difference(_lastSessionSave) < _sessionSaveInterval) {
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

  /// 跨设备同步写入新会话后重新加载恢复态（仅在没有真实播放/装载时生效）。
  ///
  /// 远端删除会话时同步撤下本地恢复态；正在播放的设备不受影响
  /// （真实播放不会被恢复态覆盖）。
  Future<void> reloadRestoredSessionFromStore() async {
    if (_facade.snapshot.value.current != null || _resumeRestoring) return;
    final session = await _sessionStore.load();
    if (session == null || session.current == null) {
      final hadRestored = _restoredSession != null;
      _clearRestoredSession();
      if (hadRestored) {
        _notifyCategory('track');
        _notifyCategory('queue');
      }
      return;
    }
    await _loadPlaybackSession();
  }

  /// 用会话构造恢复态展示快照：当前/队列/下标/模式齐备，isPlaying=false；
  /// 历史用会话队列前缀近似。
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
      // 恢复态没有洗牌顺序可还原：upNext 按队列顺序近似（与 upcoming 同源）。
      upNext: List.unmodifiable(session.tracks.sublist(session.index + 1)),
      history: List.unmodifiable(session.tracks.sublist(0, session.index)),
      isPlaying: false,
      isLoading: false,
      duration: current.duration ?? Duration.zero,
      mode: session.mode,
      context: session.context,
    );
  }

  /// 撤下恢复态：真实播放接管或停止播放时调用。
  ///
  /// [keepPosition] 为 true 时保留进度通道的恢复进度（恢复播放的 seek
  /// 尚未落地），调用方负责在 seek 完成后再次调用本方法交还进度通道。
  void _clearRestoredSession({bool keepPosition = false}) {
    _restoredSession = null;
    _restoredSnapshot = null;
    if (keepPosition) return;
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

  /// 播放失败恢复：按 sourceKey 失效取链缓存，自动重试一次；
  /// 重试仍失败（或重试成功后再次失败）→ 尝试自动换源。
  ///
  /// 同一曲目 key 只做一次同源重试（`_retriedTrackKey` 守卫），失败不缓存，
  /// 下一次播放自然会重新取链，不会形成失败循环。自动换源的级联有界见
  /// [_tryAutoSourceSwap]。
  void _maybeRecoverFromPlaybackError() {
    final state = _facade.snapshot.value;
    final failure = state.error;
    final track = state.current;
    if (failure == null || track == null) return;
    if (state.currentIndex < 0) return;

    // 失败即失效该音源取链缓存（失败本身不入缓存，下次播放重新取链）。
    _catalogService?.invalidateResolvePrefix(track.id.sourceKey);

    final key = track.id.uri;
    if (_retriedTrackKey != key) {
      _retriedTrackKey = key;
      final index = state.currentIndex;
      unawaited(Future<void>.microtask(() async {
        try {
          await _facade.playQueueIndex(index);
        } catch (e) {
          _logger.e('播放失败自动重试失败', error: e);
        }
        // 重试仍失败（错误快照可能值未变、不会再触发本方法）→ 自动换源。
        _maybeAutoSwapAfterRetry(track);
      }));
      return;
    }

    // 同源重试已发生过（重试成功后中途再失败等）：直接尝试自动换源。
    unawaited(_tryAutoSourceSwap(track, failure));
  }

  /// 同源重试完成后的判定：错误仍在且仍是同一首 → 尝试自动换源。
  void _maybeAutoSwapAfterRetry(Track track) {
    final state = _facade.snapshot.value;
    if (state.error == null) return;
    if (state.current?.id.uri != track.id.uri) return;
    unawaited(_tryAutoSourceSwap(track, state.error!));
  }

  /// 自动换源：跨音源严格找回同一首并原地替换队列曲目（静默，对齐 LX）。
  ///
  /// 守卫：
  /// - 开关关闭 / 未注入解析器 / 本地文件 / cancelled·unsupported 失败 → 跳过；
  /// - provenance（[_autoSwapTriedSources]）记录已尝试来源，候选继承后追加
  ///   自身来源：级联每个来源至多一次、必然收敛；
  /// - [_autoSwapping] 防并发重复；换源前复查当前曲目仍是失败的那首。
  Future<void> _tryAutoSourceSwap(Track track, SourceFailure failure) async {
    final settings = _autoSwapSettings;
    final resolver = _autoSwapResolver;
    if (settings == null || resolver == null || !settings.autoEnabled) return;
    if (track.origin == TrackOrigin.localFile) return;
    if (failure.kind == FailureKind.cancelled ||
        failure.kind == FailureKind.unsupported) {
      return;
    }
    final uri = track.id.uri;
    if (!_autoSwapping.add(uri)) return;
    try {
      final tried = _autoSwapTriedSources[uri] ?? <String>{};
      tried.add(track.id.sourceKey);
      final match = await resolver(track, excludeSourceKeys: tried);
      if (match == null || match.id.uri == uri) return;
      // 搜索期间可能已切歌/被手动换源：只替换仍是这首的当前曲目。
      if (_facade.snapshot.value.current?.id.uri != uri) return;
      _rememberAutoSwapProvenance(
        match.id.uri,
        {...tried, match.id.sourceKey},
      );
      await _facade.replaceQueueTrack(uri, match);
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.w('自动换源失败: $e');
    } finally {
      _autoSwapping.remove(uri);
    }
  }

  void _rememberAutoSwapProvenance(String uri, Set<String> tried) {
    if (_autoSwapTriedSources.length >= _autoSwapProvenanceCap) {
      _autoSwapTriedSources.remove(_autoSwapTriedSources.keys.first);
    }
    _autoSwapTriedSources[uri] = tried;
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
      unawaited(updateWidget());
    } catch (e) {
      _logger.w('封面补取失败: $e');
    } finally {
      if (_artworkResolvingTrackId == trackId) {
        _artworkResolvingTrackId = null;
      }
    }
  }

  Future<void> updateWidget() async {    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
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
        // 更新失败静默：桌面小组件不影响播放主流程。
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
