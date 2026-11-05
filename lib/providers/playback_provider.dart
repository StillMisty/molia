import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, VoidCallback;
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/playback_facade.dart';
import '../domain/ports/state_listenable.dart';
import '../domain/ports/ui_messenger.dart';
import '../models/play_mode.dart';
import '../playback/playback_error_recovery.dart';
import '../playback/playback_session_coordinator.dart';
import '../services/data_saver_service.dart';
import '../services/playback_observer.dart';
import '../services/playback_volume_store.dart';
import '../services/source_swap/source_swap_settings.dart';
import '../sources/source_manager.dart';
import '../sources/source_track.dart';
import '../utils/notify_throttler.dart';
import 'sleep_timer.dart';

final _logger = Logger('molia.playback_provider');

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

/// UI 播放状态唯一入口：读 [PlaybackSessionCoordinator] 的展示投影、命令转给协调者。
///
/// 对外只暴露领域 [PlaybackSnapshot]（协调者 [PlaybackSessionCoordinator.displaySnapshot]：
/// 真实播放来自 facade，冷启动恢复态由协调者构造覆盖快照）与高频 position 通道。
/// 所有播放均走本地音源。
///
/// 职责边界（docs/architecture.md §2.1）：
/// - 错误提示走注入的 [UiMessenger]（不依赖 `main.dart`）；
/// - UI 状态读协调者展示投影；定时关闭 / 失败恢复订阅 live 投影；
/// - 应用内音量 / 静音是设备本地状态：不进 [PlaybackSnapshot]（快照 `==`
///   契约与低频语义不能动、音量也不是播放事件），变化直接 `notifyListeners`
///   且不新增节流类别；
/// - 只保留命令 / 队列 / 模式与快照投影：命令一律转给
///   [PlaybackSessionCoordinator]（恢复态与 live 的交接、恢复态快照构造与会话
///   落盘都在那里，本类不再持有恢复态分支）；失败恢复策略（同源重试一次 →
///   自动换源）在 [PlaybackErrorRecovery]，本类只转发失败快照；持久化 / 写库 /
///   桌面小组件 / 封面预取与补取 / 历史等副作用由 [PlaybackObserver] 承担
///   （组合根创建并挂接），本类只转发 [suspendPlaybackSession] 与最后播放信息读取。
///
/// 不经过命令面的写入口（都不是会话命令，见各处注释）：装载队列
/// `_facade.playTracks`（新播放上下文，由快照监听落盘）、追加队列
/// `_facade.enqueueTracks`（只编辑队列）、`_facade.setVolume`（设备本地状态）、
/// 无曲目时应用默认模式（只影响下一次播放的初始模式）。
class PlaybackProvider extends ChangeNotifier {
  final PlaybackFacade _facade;
  final SettingsAccess _settings;
  final UiMessenger _messenger;
  final SourceManager? _sourceManager;

  /// 省流模式（可选注入）：音质标签读取（`currentQualityType`）。
  final DataSaverService? _dataSaver;

  /// 播放副作用观察者（组合根创建、注入并挂接）：最后播放信息 / 播放上下文 /
  /// 桌面小组件 / 历史 / 会话落盘 / 封面预取与补取由它承担。
  final PlaybackObserver? _observer;

  /// 播放失败恢复策略（同源重试一次 → 自动换源）：写入只经会话协调者。
  late final PlaybackErrorRecovery _errorRecovery;

  /// 统一退出路径（组合根在 `quitApp` 可用后经 [attachQuitApp] 回填）。
  ///
  /// 定时关闭勾选「同时退出应用」时，到点先暂停再走这里；未装配（测试 /
  /// 无壳宿主）时只暂停。
  Future<void> Function()? _quitApp;

  // 通知节流器 - 减少不必要的 UI 重建
  late final CategorizedNotifyThrottler _notifyThrottler;

  /// 播放会话模块（组合根创建并注入，系统媒体会话 / 同步栈共用同一实例）：
  /// 恢复态 ↔ live 交接、恢复态快照构造、会话落盘唯一写者都在它里面。
  ///
  /// 必须注入、没有回退：provider 自建 store + 协调者会形成第二个写队列，
  /// 与组合根 / 同步栈持有的那个互不知情（`pendingWrite` 也无法跨队列排序）。
  final PlaybackSessionCoordinator _session;

  /// 高频进度通道（真实播放转发 facade.position；恢复态显示上次进度）。
  ///
  /// 恢复态覆盖值由 [_session] 持有，这里只做领域 → Flutter 形态适配，
  /// 同一实例稳定持有。
  late final ValueListenable<Duration> _positionChannel;

  /// 定时关闭（歌曲信息页入口）：只决定「什么时候暂停」，到点暂停经播放命令面
  /// [PlaybackSessionCoordinator.pause] 落地（与通知 / UI 暂停同一阶段路由与
  /// 「返回前已提交」口径）；状态经 [SleepTimerController] 的 ValueListenable 暴露。
  late final SleepTimerController sleepTimer;

  /// 应用内音量持久化（设备本地键，见 [PlaybackVolumeStore]）。
  final PlaybackVolumeStore _volumeStore;

  /// 已展示过的播放错误（避免同一错误反复弹提示）。
  String? _lastShownError;

  /// 默认播放模式（设置页配置；启动时无曲目即应用为初始模式）。
  PlayMode _defaultPlayMode = _playModeOf(kDefaultPlayMode.defaultValue);

  /// 应用内音量（0..1，不含静音状态）；设备本地持久化，不随账号同步。
  double _volume = PlaybackVolumeStore.defaultVolume;

  /// 是否静音：不改 [_volume] 的值，有效音量按 0 下发。
  bool _muted = PlaybackVolumeStore.defaultMuted;

  late final Future<void> _preferencesReady;

  PlaybackProvider({
    required this._facade,
    required this._messenger,
    required PlaybackSessionCoordinator sessionCoordinator,
    this._sourceManager,
    CatalogService? catalogService,
    this._dataSaver,
    this._observer,
    PlaybackVolumeStore? volumeStore,
    SourceSwapSettings? autoSwapSettings,
    AutoSourceSwapResolver? autoSwapResolver,
    AutoSourceSwapTrackHook? onAutoSourceSwapped,
    required this._settings,
    bool Function()? isForeground,
  }) : _session = sessionCoordinator,
       _volumeStore = volumeStore ?? PlaybackVolumeStore() {
    _errorRecovery = PlaybackErrorRecovery(
      commands: _session,
      readSnapshot: () => _session.liveSnapshot,
      onOutcome: _applyOutcome,
      catalogService: catalogService,
      autoSwapSettings: autoSwapSettings,
      autoSwapResolver: autoSwapResolver,
      onAutoSourceSwapped: onAutoSourceSwapped,
    );
    _settings.bindReload(kDefaultPlayMode, reloadDefaultPlayMode);
    // 启动恢复开关的重载钩子（跨设备同步应用远端值后由组合根触发）：钩子挂在
    // provider 上——协调者只报告「恢复态是否变化」，UI 通知由这里发。
    _settings.bindReload(
      kRestoreSessionEnabled,
      reloadRestoreSessionPreference,
    );
    _notifyThrottler = CategorizedNotifyThrottler(
      notifyCallback: super.notifyListeners,
      categoryIntervals: {
        'track': const Duration(milliseconds: 16), // 曲目切换几乎立即响应
        'queue': const Duration(milliseconds: 300), // 队列更新节流 300ms
      },
      defaultInterval: const Duration(milliseconds: 50),
    );
    _positionChannel = _StateValueListenable<Duration>(_session.position);
    // 定时关闭：判定用真实播放通道（协调者的 live 投影；恢复态的展示快照 /
    // 保存进度不是真实播放进度）。到点暂停走命令面——与通知 / UI 暂停共享
    // 阶段路由与提交语义，直接写 facade 会绕过「返回前已落盘」，熄屏到点后
    // 进程被回收就丢最后进度。
    sleepTimer = SleepTimerController(
      snapshot: _session.liveSnapshotChannel,
      position: _session.livePosition,
      trackCompletions: _facade.trackCompletions,
      setStopAfterCurrentTrack: _facade.setStopAfterCurrentTrack,
      // 定时关闭只关心「暂停已落地」，路由结果对倒计时没有 UI 语义。
      onFire: () async {
        await _session.pause();
      },
      // 勾选「同时退出应用」时，暂停落地后再走统一退出路径（会话提交 /
      // 音频收尾 / 统计落盘由组合根负责）。
      onExit: () async {
        final quit = _quitApp;
        if (quit != null) await quit();
      },
      // 生产默认勾选；仅本次运行，不落盘。
      exitAppByDefault: true,
      // 前台屏幕亮着不持 partial wake lock；退后台 / 息屏再持有。
      isForeground: isForeground,
    );
    // 「播完当前歌曲」的完成处理保持不变：后端按 stopAfterCurrentTrack 在
    // 曲末自己停住（`_pauseAtTrackEnd` 推 playing→paused 快照），会话协调者
    // 的快照监听提交一次（payload / cursor 由 store 决定）——那条路径已经
    // 提交；这里共用 onFire 的 pause 对已在曲末停住的后端是幂等的。
    // 订阅协调者的 live 投影（当前实现即 facade 快照通道）：provider 不再
    // 直接认识 facade 的快照对象，恢复态覆盖由协调者负责。
    _session.liveSnapshotChannel.addListener(_onLiveSnapshot);
    // position 走独立 ValueListenable 通道（_positionChannel）：进度 tick
    // 只重建进度条/歌词行，不触发整 Provider 重建（会话只在动作时落盘，
    // 进度 tick 不写库）。
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

  /// UI 状态唯一入口：读协调者的展示投影（恢复态感知）。
  ///
  /// 真实播放接管后它原样透传 facade；恢复态返回协调者构造的恢复快照。
  /// provider 不再自己判断该用哪一份。
  PlaybackSnapshot get snapshot => _session.displaySnapshot;

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

  /// 当前曲目本次播放选用的音质（LX 音质标识：`flac`/`320k`…，见
  /// `kLxQualityOrder`）。
  ///
  /// live 优先取后端快照的实际选用值（含手动切换）；恢复态 / 尚未取链时
  /// 按偏好音质 × 曲目可用音质（纯函数 [pickQualityFor]）派生。无曲目或
  /// 曲目无可用音质时回退到偏好音质。省流生效（移动数据 + 已开启）时按
  /// 上限取值。UI 展示统一用 `sourceQualityLabel(l10n, type)` 本地化。
  String get currentQualityType {
    final actual = snapshot.quality;
    if (actual != null && actual.isNotEmpty) return actual;
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

  /// 本次播放音质是否由用户手动选择（偏离偏好 × 省流上限的派生值）。
  ///
  /// 手动选择允许越过省流上限，此时歌曲信息页不再显示「省流模式」后缀，
  /// 避免出现「在省流模式下播放无损」的矛盾提示。
  bool get isCurrentQualityOverridden {
    final track = snapshot.current;
    final actual = snapshot.quality;
    if (track == null || actual == null || actual.isEmpty) return false;
    final preferred = _sourceManager?.preferredQuality ?? '320k';
    final effective = _dataSaver?.effectiveQuality(preferred) ?? preferred;
    final supported = track.qualities
        .map((quality) => quality.type)
        .where((type) => type.isNotEmpty);
    return actual != pickQualityFor(supported, effective);
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
  }) => _playTracks(
    [for (final track in tracks) trackFromSourceTrack(track)],
    index,
    contextName: contextName,
    logLabel: 'playSourceTracks',
  );

  /// 播放领域曲目（AI 推歌：解析结果已是领域 [Track]）。
  Future<void> playDomainTracks(
    List<Track> tracks,
    int index, {
    String? contextName,
  }) => _playTracks(
    List.of(tracks),
    index,
    contextName: contextName,
    logLabel: 'playDomainTracks',
  );

  /// 装载新队列的唯一实现：构造请求、跟踪数据路径、发一次通知。
  Future<void> _playTracks(
    List<Track> tracks,
    int index, {
    required String logLabel,
    String? contextName,
  }) async {
    if (tracks.isEmpty) return;
    try {
      // 装载新队列不是会话命令：它建立新的播放上下文（不是对当前会话的
      // 增量修改），恢复态路由与「返回前已提交」都不适用；会话内容由协调者
      // 的快照监听提交一次（payload / cursor 由 store 决定）。
      await DataPathTrace.async(
        'play.queue',
        () => _facade.playTracks(
          PlaybackRequest(
            tracks: tracks,
            startIndex: index,
            context: contextName == null
                ? null
                : PlaybackContext(
                    name: contextName,
                    type: 'lx',
                    uri: 'lx:$contextName',
                  ),
          ),
        ),
        fields: () => {'tracks': tracks.length, 'index': index},
      );
      _notifyCategory('track');
      _notifyCategory('queue');
    } catch (e) {
      _logger.severe('$logLabel: 播放失败', e);
      rethrow;
    }
  }

  /// 追加领域曲目到当前队列末尾（AI 推歌续推）：不打断当前播放。
  Future<void> enqueueDomainTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    try {
      // 恢复态没有真实队列：追加保存的会话并落盘；live 追加只编辑 facade
      // 队列（不换当前曲目），队列变化由快照监听落盘。
      if (_session.hasRestoredSession) {
        await _session.enqueueRestoredTracks(List.of(tracks));
      } else {
        await _facade.enqueueTracks(List.of(tracks));
      }
      _notifyCategory('queue');
    } catch (e) {
      _logger.severe('enqueueDomainTracks: 追加队列失败', e);
      rethrow;
    }
  }

  /// 换源：把队列中 [oldTrack] 原地替换为 [newTrack]，返回是否命中。
  ///
  /// 真实队列与冷启动恢复态会话都由协调者按范围改写并落盘；这里只按命令
  /// 结果的变化域通知 UI，与其它播放命令同一条 `_applyOutcome` 路径。
  /// 未命中不算失败：库内换源与队列跟随解耦（曲目可能不在当前队列）。
  Future<bool> replaceQueueTrack(Track oldTrack, Track newTrack) async {
    final outcome = await _session.replaceTrack(oldTrack, newTrack);
    _applyOutcome(outcome);
    return outcome.hasChanges;
  }

  /// 移动队列中的一项：live / 恢复态都由协调者路由，UI 只按变化域通知。
  Future<void> moveQueueIndex(int from, int to) async {
    _applyOutcome(await _session.moveQueueIndex(from, to));
  }

  /// 移除队列中的一项：live / 恢复态都由协调者路由。
  Future<void> removeQueueIndex(int index) async {
    _applyOutcome(await _session.removeQueueIndex(index));
  }

  /// 播放本地队列中指定 id 的曲目（AI 推歌按记住的曲目 id 定位）。
  ///
  /// 恢复态下 facade 队列为空：命中会话队列则从该曲目恢复播放。
  /// 队列允许重复曲目，这里只取第一个命中项；队列面板点击必须走
  /// [playQueueIndex] 传真实下标，否则第二项会被解析成第一项。
  Future<void> playLocalQueueItemById(String trackId) async {
    _applyOutcome(await _session.playQueueItemById(trackId));
  }

  /// 播放队列中指定下标的曲目（队列面板点击）。
  ///
  /// 用真实队列下标定位：随机排列 / 列表循环回绕时面板行号与队列下标不同，
  /// 重复曲目也不能按 id 反查（会串到第一项）。
  Future<void> playQueueIndex(int index) async {
    _applyOutcome(await _session.playQueueIndex(index));
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
    _applyOutcome(await _session.togglePlayPause());
  }

  /// 恢复上次播放：以保存的队列/下标重新加载，再 seek 回保存的进度。
  ///
  /// [startIndex] 指定从队列中另一首开始（恢复态点队列条目）。直链不持久化
  /// （会过期），这里走正常取链路径；失败时保留恢复态可重试。
  Future<void> resumeRestoredSession({int? startIndex}) async {
    _applyOutcome(await _session.resume(startIndex: startIndex));
  }

  Future<void> seekToPosition(int positionMs) async {
    // 恢复装载期间的 seek / 恢复态只更新保存进度 / live 转发都由协调者路由。
    _applyOutcome(
      await _session.seekToPosition(Duration(milliseconds: positionMs)),
    );
  }

  /// 切换当前曲目本次播放的音质（歌曲信息页）。
  ///
  /// 只接受曲目可用列表里的档位；恢复态（尚未真实播放）不生效。音质选择
  /// 不写入会话，切歌 / 重启后回到默认音质。
  Future<void> setCurrentQuality(String quality) async {
    final track = snapshot.current;
    if (track == null || quality.isEmpty) return;
    if (!track.qualities.any((option) => option.type == quality)) return;
    if (hasRestoredSession) return;
    // 音质切换是一次新的取链操作：允许失败恢复重新走一次同源重试。
    _errorRecovery.resetRetryGuard();
    try {
      _applyOutcome(await _session.setCurrentQuality(quality));
    } catch (e) {
      _logger.severe('切换音质失败', e);
    }
  }

  Future<void> skipToNext() async {
    _applyOutcome(await _session.skipToNext());
  }

  Future<void> skipToPrevious() async {
    _applyOutcome(await _session.skipToPrevious());
  }

  Future<void> setPlayMode(PlayMode mode) async {
    _applyOutcome(await _session.setPlayMode(mode));
  }

  /// 按命令结果通知 UI：只失效真正变化的领域（协调者返回的 change set），
  /// 空操作不必通知。provider 不再解读「命令由恢复态还是 live 处理」。
  void _applyOutcome(PlaybackCommandOutcome outcome) {
    if (outcome.changed.contains(PlaybackDomain.track)) {
      _notifyCategory('track');
    }
    if (outcome.changed.contains(PlaybackDomain.queue)) {
      _notifyCategory('queue');
    }
  }

  /// 循环播放模式：交给协调者的阶段感知实现（恢复态读保存会话，live 读
  /// facade），UI 不再自己从快照推导下一模式。
  Future<void> togglePlayMode() async {
    _applyOutcome(await _session.togglePlayMode());
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
  ///
  /// 音量是设备本地状态（不进会话快照），不是会话命令：不需要阶段路由，
  /// 也不该为此触发会话落盘。
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
  ///
  /// 与 [_loadDefaultPlayMode] 同理：默认模式不是会话命令。
  Future<void> setDefaultPlayMode(PlayMode mode) async {
    if (_defaultPlayMode != mode) {
      _defaultPlayMode = mode;
      _notifyCategory('default');
    }
    // 只依据真实播放判断「是否已有当前曲目」：恢复态保存的曲目并未起播，
    // 不能因为它压掉默认模式的落地（否则下次真正播放仍是旧默认模式）。
    final snapshot = _session.liveSnapshot;
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
  ///
  /// 默认模式是「下一次播放的初始模式」而非当前会话内容：不是会话命令，
  /// 恢复态 / live 的路由不适用（恢复流程自己会先落地会话里的模式）。
  Future<void> _loadDefaultPlayMode() async {
    try {
      final name = await _settings.read(kDefaultPlayMode);
      final mode = _playModeOf(name);
      _defaultPlayMode = mode;
      // 与 setDefaultPlayMode 同口径：恢复态保存的曲目不算真实播放。
      final snapshot = _session.liveSnapshot;
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

  /// 真实播放快照变化：处理失败并通知 UI（曲目/队列）；副作用扇出在
  /// [PlaybackObserver] 的同源监听里，恢复态交接在 [PlaybackSessionCoordinator]。
  void _onLiveSnapshot() {
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

  /// 曲目切换时：失败提示在 [_maybeShowPlaybackError]，同源重试 / 自动换源
  /// 策略在 [PlaybackErrorRecovery]。写入类副作用（最后播放 / 播放上下文 /
  /// 小组件 / 历史 / 会话落盘 / 预取 / 补封面）在 [PlaybackObserver]，恢复态
  /// 撤下与 live 交接在会话协调者。
  void _handlePlaybackSnapshot() {
    // 错误恢复只处理真实播放的失败：恢复快照里的 error 不是本次播放产生的。
    final snapshot = _session.liveSnapshot;
    _maybeShowPlaybackError(snapshot);
    _errorRecovery.onPlaybackError(snapshot);
  }

  /// 挂起 / 退出前提交当前播放会话：应用壳 paused 与桌面退出共用这一个入口。
  ///
  /// 返回的 Future 在会话落盘后结束（协调者 `flushSession` → store 的
  /// `pendingWrite`）：退出路径必须 await 它再销毁窗口；生命周期回调无法
  /// await，用 `unawaited` 触发同一个提交。系统媒体控制（通知暂停 / 停止 /
  /// 切播放顺序）走同一个协调者的命令面，与这里汇入同一条写队列。
  Future<void> suspendPlaybackSession() => _session.flushSession();

  /// 装配统一退出路径（组合根在 `quitApp` 可用后回填）。
  ///
  /// 定时关闭勾选「同时退出应用」时，到点先暂停再调用它；未装配
  /// （测试 / 无壳宿主）时只暂停。退出前的会话提交 / 音频收尾 / 统计落盘
  /// 由组合根的同一条退出路径负责。
  void attachQuitApp(Future<void> Function() quitApp) {
    _quitApp = quitApp;
  }

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

  void _maybeShowPlaybackError(PlaybackSnapshot snapshot) {
    final failure = snapshot.error;
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
    _session.liveSnapshotChannel.removeListener(_onLiveSnapshot);
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
