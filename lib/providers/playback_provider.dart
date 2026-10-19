import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, VoidCallback;
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';

import '../data/catalog/catalog_service.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/failure.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/playback_facade.dart';
import '../domain/ports/state_listenable.dart';
import '../domain/ports/ui_messenger.dart';
import '../models/play_mode.dart';
import '../playback/playback_session_coordinator.dart';
import '../services/data_saver_service.dart';
import '../services/playback_observer.dart';
import '../services/playback_session_store.dart';
import '../services/playback_volume_store.dart';
import '../services/source_swap/source_swap_settings.dart';
import '../sources/source_manager.dart';
import '../sources/source_track.dart';
import '../utils/notify_throttler.dart';
import 'sleep_timer.dart';

final _logger = Logger('molia.playback_provider');

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
  void removeListener(VoidCallback listener) =>
      _source.removeListener(listener);
}

/// UI 播放状态唯一入口：包装 [PlaybackFacade]。
///
/// 对外只暴露领域 [PlaybackSnapshot]（真实播放来自 facade；冷启动恢复态
/// 由 [PlaybackSessionCoordinator] 构造覆盖快照）与高频 position 通道。
/// 所有播放均走本地音源。
///
/// 职责边界（docs/architecture.md §2.1）：
/// - 错误提示走注入的 [UiMessenger]（不依赖 `main.dart`）；
/// - 状态从 facade 快照/进度通道订阅；
/// - 应用内音量 / 静音是设备本地状态：不进 [PlaybackSnapshot]（快照 `==`
///   契约与低频语义不能动、音量也不是播放事件），变化直接 `notifyListeners`
///   且不新增节流类别；
/// - 只保留命令 / 队列 / 模式 / 失败恢复：命令一律转给
///   [PlaybackSessionCoordinator]（恢复态与 live 的交接、恢复态快照构造与会话
///   落盘都在那里，本类不再持有恢复态分支）；持久化 / 写库 / 桌面小组件 /
///   封面预取与补取 / 历史等副作用由 [PlaybackObserver] 承担（组合根创建并
///   挂接），本类只转发 [flushPlaybackSession] 与最后播放信息读取。
class PlaybackProvider extends ChangeNotifier {
  final PlaybackFacade _facade;
  final SettingsAccess _settings;
  final UiMessenger _messenger;
  final SourceManager? _sourceManager;

  /// 取链缓存失效入口（播放失败时按 sourceKey 失效，下一次播放重试）。
  final CatalogService? _catalogService;

  /// 省流模式（可选注入）：音质标签读取（`currentQualityType`）。
  final DataSaverService? _dataSaver;

  /// 播放副作用观察者（组合根创建、注入并挂接）：最后播放信息 / 播放上下文 /
  /// 桌面小组件 / 历史 / 会话落盘 / 封面预取与补取由它承担。
  final PlaybackObserver? _observer;

  /// 自动换源开关（设置 › 播放，默认开）；null = 关闭该能力。
  final SourceSwapSettings? _autoSwapSettings;

  /// 自动换源解析器（组合根注入 `AutoSourceSwapService.findMatch`）。
  final AutoSourceSwapResolver? _autoSwapResolver;

  // 通知节流器 - 减少不必要的 UI 重建
  late final CategorizedNotifyThrottler _notifyThrottler;

  /// 播放会话模块（组合根创建并注入；未注入时按默认存储 / 设置自建）：
  /// 恢复态 ↔ live 交接、恢复态快照构造、会话落盘唯一写者都在它里面。
  late final PlaybackSessionCoordinator _session;

  /// 高频进度通道（真实播放转发 facade.position；恢复态显示上次进度）。
  ///
  /// 恢复态覆盖值由 [_session] 持有，这里只做领域 → Flutter 形态适配，
  /// 同一实例稳定持有。
  late final ValueListenable<Duration> _positionChannel;

  /// 定时关闭（歌曲信息页入口）：只决定「什么时候暂停」，暂停动作走
  /// `facade.pause`；状态经 [SleepTimerController] 的 ValueListenable 暴露。
  late final SleepTimerController sleepTimer;

  /// 应用内音量持久化（设备本地键，见 [PlaybackVolumeStore]）。
  final PlaybackVolumeStore _volumeStore;

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

  /// 默认播放模式（设置页配置；启动时无曲目即应用为初始模式）。
  PlayMode _defaultPlayMode = _playModeOf(kDefaultPlayMode.defaultValue);

  /// 应用内音量（0..1，不含静音状态）；设备本地持久化，不随账号同步。
  double _volume = PlaybackVolumeStore.defaultVolume;

  /// 是否静音：不改 [_volume] 的值，有效音量按 0 下发。
  bool _muted = PlaybackVolumeStore.defaultMuted;

  late final Future<void> _preferencesReady;

  PlaybackProvider({
    required PlaybackFacade facade,
    required UiMessenger messenger,
    SourceManager? sourceManager,
    CatalogService? catalogService,
    DataSaverService? dataSaver,
    PlaybackObserver? observer,
    PlaybackSessionCoordinator? sessionCoordinator,
    PlaybackVolumeStore? volumeStore,
    SourceSwapSettings? autoSwapSettings,
    AutoSourceSwapResolver? autoSwapResolver,
    required SettingsAccess settings,
  })  : _facade = facade,
        _messenger = messenger,
        _sourceManager = sourceManager,
        _catalogService = catalogService,
        _dataSaver = dataSaver,
        _observer = observer,
        _autoSwapSettings = autoSwapSettings,
        _autoSwapResolver = autoSwapResolver,
        _settings = settings,
        _volumeStore = volumeStore ?? PlaybackVolumeStore() {
    // 会话模块：组合根注入（与系统媒体会话 / 同步栈共用同一实例）；
    // 未注入时自建（测试直建 provider 的路径），恢复曲目展示经观察者接线。
    _session = sessionCoordinator ??
        PlaybackSessionCoordinator(
          facade: facade,
          store: PlaybackSessionStore(),
          settings: _settings,
          onRestoredTrack: _observer?.showRestoredTrack,
        );
    _settings.bindReload(kDefaultPlayMode, reloadDefaultPlayMode);
    // 启动恢复开关的重载钩子（跨设备同步应用远端值后由组合根触发）：钩子挂在
    // provider 上——协调者只报告「恢复态是否变化」，UI 通知由这里发。
    _settings.bindReload(
        kRestoreSessionEnabled, reloadRestoreSessionPreference);
    _notifyThrottler = CategorizedNotifyThrottler(
      notifyCallback: super.notifyListeners,
      categoryIntervals: {
        'track': const Duration(milliseconds: 16), // 曲目切换几乎立即响应
        'queue': const Duration(milliseconds: 300), // 队列更新节流 300ms
      },
      defaultInterval: const Duration(milliseconds: 50),
    );
    _positionChannel = _StateValueListenable<Duration>(_session.position);
    // 定时关闭：判定用 facade 原始通道（恢复态覆盖值不是真实播放进度）。
    sleepTimer = SleepTimerController(
      snapshot: _facade.snapshot,
      position: _facade.position,
      onFire: () => _facade.pause(),
    );
    _facade.snapshot.addListener(_onFacadeSnapshot);
    // position 走独立 ValueListenable 通道（_positionChannel）：进度 tick
    // 只重建进度条/歌词行，不触发整 Provider 重建（节流落盘在会话模块里）。
    _sourceManager?.addListener(_onSourceManagerChanged);
    _dataSaver?.addListener(_onDataSaverChanged);
    _preferencesReady = () async {
      if (_observer != null) await _observer.ready;
      await _loadDefaultPlayMode();
      await _loadPlaybackSession();
      await _loadVolume();
    }();
    // 构造时同步一次快照（系统媒体会话可能在构造前已恢复曲目）。
    _handlePlaybackSnapshot();
  }

  /// UI 状态唯一入口：真实播放取 facade 快照；冷启动恢复态取会话快照。
  PlaybackSnapshot get snapshot => _session.resolve(_facade.snapshot.value);

  /// 是否有可恢复的上次播放会话（无真实曲目时才生效）。
  bool get hasRestoredSession => _session.hasRestoredSession;

  /// 高频进度通道：订阅它做进度条/歌词行更新，避免整 Provider 重建。
  ValueListenable<Duration> get position => _positionChannel;

  /// 同步读取当前进度（回调/一次性读取路径用；不建立订阅）。
  ///
  /// 真实播放与快照同源；恢复态为上次保存的进度。
  Duration get currentPosition => _session.position.value;

  PlayMode get currentMode => snapshot.mode;

  /// 当前曲目的领域 id（sourceKey + 平台 id），收藏/资料库 UI 使用。
  TrackId? get currentTrackId => snapshot.current?.id;

  bool get hasTrack => snapshot.current != null;

  /// 当前曲目的预期音质值（LX 音质标识：`flac`/`320k`…，见 `kLxQualityOrder`）。
  ///
  /// 偏好音质 × 曲目可用音质（纯函数 [pickQualityFor]）；无曲目或曲目无
  /// 可用音质时回退到偏好音质。省流生效（移动数据 + 已开启）时按上限取值。
  /// UI 展示统一用 `sourceQualityLabel(l10n, type)` 本地化（歌曲信息页）。
  String get currentQualityType {
    final preferred = _sourceManager?.preferredQuality ?? '320k';
    final effective = _dataSaver?.effectiveQuality(preferred) ?? preferred;
    final track = snapshot.current;
    final supported = track == null
        ? const <String>[]
        : track.qualities
            .map((quality) => quality.type)
            .where((type) => type.isNotEmpty);
    return pickQualityFor(supported, effective);
  }

  bool get isPlaying => snapshot.isPlaying;

  bool get isLoading => snapshot.isLoading;

  /// 默认播放模式（设置页配置；启动无曲目时已应用到服务）。
  PlayMode get defaultPlayMode => _defaultPlayMode;

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  /// 最后播放曲目信息（离线空态展示）：状态与持久化在 [PlaybackObserver]。
  String? get lastPlayedImageUrl => _observer?.lastPlayedImageUrl;
  String? get lastPlayedTrackName => _observer?.lastPlayedTrackName;
  String? get lastPlayedArtists => _observer?.lastPlayedArtists;

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
      _logger.severe('playSourceTracks: 播放失败', e);
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
      _logger.severe('playDomainTracks: 播放失败', e);
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
      _logger.severe('enqueueDomainTracks: 追加队列失败', e);
      rethrow;
    }
  }

  /// 换源：把队列中 [oldTrack] 原地替换为 [newTrack]，返回是否命中。
  ///
  /// 真实队列经 facade 替换；冷启动恢复态替换保存的会话队列并落盘。
  /// 未命中不算失败：库内换源与队列跟随解耦（曲目可能不在当前队列）。
  Future<bool> replaceQueueTrack(Track oldTrack, Track newTrack) async {
    final hit = await _session.replaceTrack(oldTrack, newTrack);
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
    _notifyRouted(await _session.playQueueItemById(trackId));
  }

  /// 停止本地播放并清空状态（同时丢弃恢复会话，避免下次启动又出现）。
  Future<void> stopLocalPlayback() async {
    await _session.stopPlayback();
    // 主动停止 = 本次会话结束：定时关闭一并撤销（不留下无播放可暂停的定时）。
    sleepTimer.cancel();
    _notifyCategory('track');
    _notifyCategory('queue');
  }

  Future<void> togglePlayPause() async {
    // 恢复态：点播放 = 用上次队列/下标重新取链，并跳回保存的进度（协调者路由）。
    _notifyRouted(await _session.togglePlayPause());
  }

  /// 恢复上次播放：以保存的队列/下标重新加载，再 seek 回保存的进度。
  ///
  /// [startIndex] 指定从队列中另一首开始（恢复态点队列条目）。直链不持久化
  /// （会过期），这里走正常取链路径；失败时保留恢复态可重试。
  Future<void> resumeRestoredSession({int? startIndex}) async {
    _notifyRouted(await _session.resume(startIndex: startIndex));
  }

  Future<void> seekToPosition(int positionMs) async {
    // 恢复装载期间的 seek / 恢复态只更新保存进度 / live 转发都由协调者路由。
    await _session.seekToPosition(Duration(milliseconds: positionMs));
    _notifyCategory('track');
  }

  Future<void> skipToNext() async {
    _notifyRouted(await _session.skipToNext());
  }

  Future<void> skipToPrevious() async {
    _notifyRouted(await _session.skipToPrevious());
  }

  Future<void> setPlayMode(PlayMode mode) async {
    await _session.setPlayMode(mode);
    _notifyCategory('track');
  }

  /// 按命令路由结果通知 UI：恢复态曲目与队列都可能变（两条通道），
  /// live 只有曲目 / 播放态变化，空操作不必通知。
  void _notifyRouted(PlaybackCommandRoute route) {
    if (route == PlaybackCommandRoute.none) return;
    _notifyCategory('track');
    if (route == PlaybackCommandRoute.restored) {
      _notifyCategory('queue');
    }
  }

  Future<void> togglePlayMode() async {
    final next =
        PlayMode.values[(currentMode.index + 1) % PlayMode.values.length];
    await setPlayMode(next);
  }

  /// 应用内音量（0..1，不含静音；静音由 [muted] 表达）。
  double get volume => _volume;

  /// 是否静音（不改 [volume] 的值）。
  bool get muted => _muted;

  /// 设置音量：clamp → 应用到播放后端（静音时只更新值、不解除静音）→
  /// 通知；落盘防抖（滑杆拖动每帧都会走到这里）。
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped == _volume) return;
    _volume = clamped;
    await _applyEffectiveVolume();
    _scheduleVolumePersist();
    notifyListeners();
  }

  /// 静音开关：切换后把有效音量（静音 = 0）应用到后端 → 持久化 → 通知。
  ///
  /// 离散动作，立即落盘（并取消在途的防抖写入，避免旧值后到）。
  Future<void> toggleMute() async {
    _muted = !_muted;
    await _applyEffectiveVolume();
    _volumePersistTimer?.cancel();
    _volumePersistTimer = null;
    await _persistVolumeState();
    notifyListeners();
  }

  /// 相对调整音量（键盘快捷键 ±5%）：clamp 0..1；**静音态下调整即解除静音**
  /// ——用户按音量键就是期望听见声音，只改值不解除会让按键看起来失灵。
  ///
  /// 与 [setVolume] 的差别：setVolume 是滑杆绝对赋值、静音期间只改值不解除；
  /// 两者落盘共用同一条防抖路径（连按音量键不逐次写盘）。
  Future<void> adjustVolume(double delta) async {
    final clamped = (_volume + delta).clamp(0.0, 1.0);
    // 无变化且未静音：不动后端、不通知（到达边界后继续按是纯空转）。
    if (clamped == _volume && !_muted) return;
    _volume = clamped;
    _muted = false;
    await _applyEffectiveVolume();
    _scheduleVolumePersist();
    notifyListeners();
  }

  /// 音量落盘防抖：拖动滑杆时每帧都调 [setVolume]，逐帧写 SharedPreferences
  /// 没有意义（也拖慢拖动）；停手后再写。进程在防抖窗口内被杀最多丢一次
  /// 未落定的拖动值（与其它防抖写入同一取舍）。
  void _scheduleVolumePersist() {
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(_volumePersistDebounce, () {
      _volumePersistTimer = null;
      unawaited(_persistVolumeState());
    });
  }

  /// 音量落盘防抖窗口（见 [_scheduleVolumePersist]）。
  static const Duration _volumePersistDebounce = Duration(milliseconds: 400);

  Timer? _volumePersistTimer;

  /// 有效音量：静音用 0 下发（跨平台最稳，不依赖后端的静音语义）。
  double get _effectiveVolume => _muted ? 0.0 : _volume;

  /// 把有效音量下发给后端；失败只记日志（本地状态与持久化照常）。
  Future<void> _applyEffectiveVolume() async {
    try {
      await _facade.setVolume(_effectiveVolume);
    } catch (e) {
      _logger.warning('应用音量失败', e);
    }
  }

  Future<void> _persistVolumeState() =>
      _volumeStore.save(volume: _volume, muted: _muted);

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
      _logger.severe('保存默认播放模式失败', e);
    }
  }

  /// 默认播放模式：键默认值是唯一来源，模块只把字符串映射成枚举。
  static PlayMode _playModeOf(String name) => PlayMode.values.firstWhere(
        (value) => value.name == name,
        orElse: () => PlayMode.values.firstWhere(
          (value) => value.name == kDefaultPlayMode.defaultValue,
        ),
      );

  /// 启动加载默认播放模式；无曲目时应用到 facade（有曲目时不打断当前会话）。
  Future<void> _loadDefaultPlayMode() async {
    try {
      final name = await _settings.read(kDefaultPlayMode);
      final mode = _playModeOf(name);
      _defaultPlayMode = mode;
      final snapshot = _facade.snapshot.value;
      if (snapshot.current == null && snapshot.mode != mode) {
        await _facade.setMode(mode);
      }
      _notifyCategory('default');
    } catch (e) {
      _logger.severe('加载默认播放模式失败', e);
    }
  }

  /// 重新读取默认播放模式（跨设备同步应用远端设置后由组合根调用）。
  Future<void> reloadDefaultPlayMode() => _loadDefaultPlayMode();

  /// 启动加载设备本地音量：读取失败回默认（1.0 / 未静音）。
  ///
  /// 加载完成后把有效音量下发一次：后端构造默认 1.0，恢复的静音态
  /// 需要压到 0，恢复的低音量也要立刻生效。不通知 UI——启动链在
  /// runApp 前 await [preferencesReady]，首帧构建时直接读到新值。
  Future<void> _loadVolume() async {
    final saved = await _volumeStore.load();
    _volume = saved.volume;
    _muted = saved.muted;
    await _applyEffectiveVolume();
  }

  /// 启动时恢复上次播放（设置页开关，默认开）。
  bool get restoreSessionEnabled => _session.restoreSessionEnabled;

  /// 设置「启动时恢复上次播放」。
  ///
  /// 关闭时立即撤下尚未开始播放的恢复态（真实播放不受影响）；会话仍
  /// 持续落盘，重新开启后冷启动可再次恢复。
  Future<void> setRestoreSessionEnabled(bool value) async {
    if (await _session.setRestoreSessionEnabled(value)) {
      _notifyCategory('track');
      _notifyCategory('queue');
    }
  }

  /// 重新读取启动恢复开关（跨设备同步应用远端设置后由组合根的重载钩子调用）。
  ///
  /// 恢复态发生撤下 / 装载时通知 UI（远端改开关与本地改同一口径）。
  Future<void> reloadRestoreSessionPreference() async {
    if (await _session.reloadRestoreSessionPreference()) {
      _notifyCategory('track');
      _notifyCategory('queue');
    }
  }

  /// facade 低频快照变化：处理失败并通知 UI（曲目/队列）；副作用扇出在
  /// [PlaybackObserver] 的同源监听里，恢复态交接在 [PlaybackSessionCoordinator]。
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

  /// 曲目切换时：失败提示与恢复见 [_maybeShowPlaybackError]
  /// / [_maybeRecoverFromPlaybackError]。写入类副作用（最后播放 / 播放上下文 /
  /// 小组件 / 历史 / 会话落盘 / 预取 / 补封面）在 [PlaybackObserver]，恢复态
  /// 撤下与 live 交接在会话协调者。
  void _handlePlaybackSnapshot() {
    _maybeShowPlaybackError();
    _maybeRecoverFromPlaybackError();
  }

  /// 强制把当前播放会话写入本地（进入后台 / 生命周期 paused / 系统控制暂停时调用）。
  ///
  /// 返回的 Future 在会话落盘后结束：系统媒体控制（通知暂停 / 停止 / 切播放
  /// 顺序）await 它，保证控制动作返回时会话已在本地——进程随后被系统回收，
  /// 重开应用仍能恢复上一首 / 队列 / 模式 / 进度。
  Future<void> flushPlaybackSession() => _session.flushSession();

  /// 冷启动加载上次播放会话：无真实曲目时进入恢复态。
  ///
  /// 开关关闭（设置 › 播放 › 启动时恢复上次播放）或已有真实播放
  /// （如系统媒体会话恢复）时不装载；同步应用远端会话同样受开关约束。
  /// 判据与装载细节都在协调者（本方法只负责加载后的 UI 通知）。
  Future<void> _loadPlaybackSession() async {
    if (await _session.load()) {
      _notifyCategory('track');
      _notifyCategory('queue');
    }
  }

  /// 跨设备同步写入新会话后重新加载恢复态（仅在没有真实播放/装载时生效）。
  ///
  /// 远端删除会话时同步撤下本地恢复态；正在播放的设备不受影响
  /// （真实播放不会被恢复态覆盖）。
  Future<void> reloadRestoredSessionFromStore() async {
    if (await _session.reloadFromStore()) {
      _notifyCategory('track');
      _notifyCategory('queue');
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
          _logger.severe('播放失败自动重试失败', e);
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
      _logger.warning('自动换源失败: $e');
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

  /// 分类通知 - 根据更新类型使用不同的节流策略
  void _notifyCategory(String category) {
    _notifyThrottler.notify(category);
  }

  @override
  void dispose() {
    _facade.snapshot.removeListener(_onFacadeSnapshot);
    sleepTimer.dispose();
    _sourceManager?.removeListener(_onSourceManagerChanged);
    _dataSaver?.removeListener(_onDataSaverChanged);
    // 在途的音量防抖写入：取消定时器并尽力落一次，避免丢最后一次拖动值。
    if (_volumePersistTimer != null) {
      _volumePersistTimer!.cancel();
      _volumePersistTimer = null;
      unawaited(_persistVolumeState());
    }
    // 会话协调者与观察者由组合根创建、与 provider 同生命周期：这里一并拆线
    // （组合根不单独释放）。
    _session.dispose();
    _observer?.dispose();
    // 注意：facade / backend / LocalPlaybackService 由组合根创建并注入
    // （系统媒体会话复用同一实例），此处不能 dispose，只解除监听。
    _notifyThrottler.dispose();
    super.dispose();
  }
}
