/// 播放会话协调者：恢复态（冷启动未起播）与真实播放（live）之间的唯一交接点，
/// 也是 `PlaybackSessionStore` 的唯一写者。
///
/// **为什么需要它**：恢复态原本是 `PlaybackProvider` 里的第二套状态机——每条
/// 命令（播放 / seek / 切歌 / 模式 / 换源）都要在「facade 快照 or 恢复会话」之间
/// 分叉，恢复态展示快照也在 provider 里手工拼装；同一个会话存储由 provider /
/// 观察者 / 系统媒体 handler 三处并写，只靠 `pendingWrite` 排序。收进本模块后：
/// - 三阶段状态机 [phase] 只在这里演进，命令按阶段路由（provider 不再分叉）；
/// - 落盘（payload / cursor / 清除）全部经本模块：**只在具体动作时写**，
///   没有 1Hz / 定时写；`pendingWrite` 串行化随之收进来。动作 = 播放 / 暂停 /
///   seek / 切歌 / 队列模式上下文变化 / 曲末 / 停止 / 换源 / 退后台 / 退出；
///   改变会话的命令返回前等写队列排空（「已提交」语义），系统媒体控制与
///   壳层挂起 / 退出共用同一个写队列；
/// - 「冷启动跳过恢复」的判据（开关关闭 / 无会话 / 已有真实播放）只在这里。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../domain/ports/playback_facade.dart';
import '../domain/ports/playback_session_sync.dart';
import '../domain/ports/state_listenable.dart';
import '../models/play_mode.dart';
import '../services/playback_session_store.dart';
import 'playback_commands.dart';
import 'playback_power_policy.dart';
import 'queue_projection.dart';

// provider 仍只 import 协调者：命令结果与命令面同源，避免再添一个 import。
export 'playback_commands.dart'
    show PlaybackCommandOutcome, PlaybackDomain, PlaybackReplaceScope;

final _logger = Logger('molia.playback_session');

/// 播放会话阶段。
///
/// `idle`（无会话）→ `restored`（有恢复数据，命令作用于它）→ `live`（真实播放
/// 接管，恢复数据丢弃）；停止播放 / 关闭恢复开关回到 `idle`。
enum PlaybackSessionPhase {
  /// 无会话：既没有恢复数据，也没有真实播放。
  idle,

  /// 恢复态：冷启动读到的保存会话；展示它、命令作用于它，不触碰真实播放。
  restored,

  /// 真实播放已接管（facade 有当前曲目）：恢复数据已丢弃。
  live,
}

/// 恢复曲目的展示回调（组合根接观察者的「最后播放」入口）。
///
/// 恢复曲目并未真正起播：只把信息交给展示面，不写历史、不落盘。
typedef RestoredTrackReporter = void Function(Track track);

/// 播放会话模块：队列 + 下标 + 进度 + 模式 + 上下文的一次完整生命周期。
///
/// 输入是 facade（真实播放的事实来源与命令出口），输出是 [resolve]（UI 快照）+
/// [position]（进度通道）；持久化对上层透明（[flushSession] 只承诺「写完了」）。
/// 组合根创建它并注入 provider / 系统媒体会话——两边都只经 [PlaybackCommandPort]
/// 写入，phase 路由、恢复态回落与「返回即已提交」只在这里实现一份。
class PlaybackSessionCoordinator
    implements PlaybackSessionSyncPort, PlaybackCommandPort {
  PlaybackSessionCoordinator({
    required this._facade,
    required this._store,
    required this._settings,
    this._onRestoredTrack,
    PlaybackPowerPolicy? powerPolicy,
  }) : _powerPolicy = powerPolicy ?? PlaybackPowerPolicy() {
    _position = _RestoredPositionChannel(_facade.position);
    _facade.snapshot.addListener(_onLiveSnapshot);
    // 曲末完成只在事件到达时写一次：单曲循环 / 列表循环单曲重播没有
    // 「曲目 id 变化」的快照，不能只靠快照监听。
    _trackCompletions = _facade.trackCompletions.listen(_onTrackCompleted);
    _powerPolicy.addListener(_onPowerPolicyChanged);
    _wasForeground = _powerPolicy.isForeground;
    // 构造时同步一次快照：接线前真实播放可能已恢复曲目（如系统媒体会话），
    // 与观察者 attach 的「立即处理一次」同一口径（`_wasPlaying` 初值也由此对齐，
    // 否则启动即播放时第一次暂停会被当成「本就没在播」而少一次强制落盘）。
    _handleLiveSnapshot(_facade.snapshot.value);
  }

  final PlaybackFacade _facade;
  final PlaybackSessionStore _store;
  final SettingsAccess _settings;
  final RestoredTrackReporter? _onRestoredTrack;

  /// 播放功耗策略（组合根注入共享实例；默认前台实例便于单测）。
  final PlaybackPowerPolicy _powerPolicy;

  /// 上一帧是否前台：只在「前台 → 后台」那一刻提交一次。
  bool _wasForeground = true;

  /// 曲末完成订阅（单曲循环 / 单曲队列重播没有曲目 id 变化，必须单独落盘）。
  StreamSubscription<Track>? _trackCompletions;

  /// 进度通道（恢复态覆盖值；见 [_RestoredPositionChannel]）。
  late final _RestoredPositionChannel _position;

  /// 恢复态会话（null = 无恢复数据）。
  PlaybackSession? _restoredSession;

  /// 恢复态展示快照：[_restoredSession] 的唯一构造结果（null = 无恢复态）。
  PlaybackSnapshot? _restoredSnapshot;

  /// 恢复态进度：点播放时 seek 回的目标（也是进度通道的覆盖值）。
  Duration _restoredPosition = Duration.zero;

  /// 恢复播放进行中（playTracks / seek 未完成）：此时撤下恢复态快照但保留
  /// 进度通道的恢复进度，避免进度条闪回 0。
  bool _resumeRestoring = false;

  /// 恢复装载期间用户主动 seek 的目标：恢复流程末尾以用户目标为准，
  /// 否则用户的拖动 / 点歌词行会被「跳回保存进度」覆盖。
  Duration? _resumeSeekTarget;

  /// 启动时是否恢复上次播放（曲目 / 队列 / 进度）；设置页开关，默认开。
  bool _restoreSessionEnabled = kRestoreSessionEnabled.defaultValue;

  /// 最近一次写入的会话内容（命令提交点的去重依据）。
  ///
  /// 命令改完 facade 后统一走 [_commitLiveSession]：若快照监听已经写过同一份
  /// 内容（切歌 / 暂停），这里按内容比较跳过重复写——不再用「写次数是否变化」
  /// 猜监听有没有替我写。`flushSession` 仍无条件写（刷新 `savedAt` 的抢占语义）。
  PlaybackSession? _lastWrittenSession;

  /// 上一帧是否在播放（播放中→暂停/停止时强制保存一次进度）。
  bool _wasPlaying = false;

  /// 已处理过的当前曲目（去重：真实播放接管只发生一次、切歌提交一次）。
  String? _processedTrackId;

  /// 上一帧的队列 / 下标 / 模式 / 上下文：只比较内容变化，loading / isPlaying
  /// 抖动不触发 payload 重写。
  ///
  /// 下标必须单独比较：队列里有重复曲目（同一 TrackId）时，自动切到另一
  /// 槽位不会改变 trackId / 队列，但 cursor 的 index 必须更新，否则冷启动
  /// 会回到旧槽位（next / previous 语义错）。
  List<Track>? _observedQueue;
  int? _observedIndex;
  PlayMode? _observedMode;
  PlaybackContext? _observedContext;

  // ── 出口 ───────────────────────────────────────────────

  /// 快照出口：恢复态返回协调者构造的恢复快照，其余原样透传 [live]。
  ///
  /// 恢复态快照的构造只在本模块发生（播放后端与恢复态不再各拼一份）。
  PlaybackSnapshot resolve(PlaybackSnapshot live) => _restoredSnapshot ?? live;

  /// 高频进度通道：恢复态显示上次保存的进度，点播放后交还底层。
  StateListenable<Duration> get position => _position;

  /// 当前阶段（三阶段状态机，见 [PlaybackSessionPhase]）。
  PlaybackSessionPhase get phase {
    if (hasRestoredSession) return PlaybackSessionPhase.restored;
    if (_facade.snapshot.value.current != null) {
      return PlaybackSessionPhase.live;
    }
    return PlaybackSessionPhase.idle;
  }

  /// 是否有可恢复的上次播放会话（无真实曲目时才生效）。
  bool get hasRestoredSession =>
      _restoredSession?.current != null &&
      _facade.snapshot.value.current == null;

  /// 启动时是否恢复上次播放（设置页开关）。
  bool get restoreSessionEnabled => _restoreSessionEnabled;

  /// 最近一次写请求的完成时机：写请求按调用顺序串行落盘，`clear` 不会被在途
  /// 保存在之后复活；系统控制路径 await 它保证动作返回时会话已在本地。
  Future<void> get pendingWrite => _store.pendingWrite;

  /// 最近一次整份写入的会话（测试观察用）：UI 停止播放后必须为 null，
  /// 系统媒体「停止」则保留（那是可恢复的会话）。
  @visibleForTesting
  PlaybackSession? get lastWrittenSession => _lastWrittenSession;

  // ── 装载（冷启动 / 跨设备同步） ─────────────────────────

  /// 冷启动装载上次播放会话；返回是否进入了恢复态（调用方据此刷新 UI）。
  ///
  /// 「跳过恢复」的判据只在这里：开关关闭、无会话、已有真实播放（如系统媒体
  /// 会话恢复）三种情况都不装载，已有真实播放不会被恢复态覆盖。
  Future<bool> load() async {
    try {
      // 即使用户关闭了恢复开关，也要清掉旧 prefs 会话（不读内容）。
      await _store.cleanupLegacyPreferences();
      _restoreSessionEnabled = await _settings.read(kRestoreSessionEnabled);
      if (!_restoreSessionEnabled) return false;
      final session = await _store.load();
      if (session == null || session.current == null) return false;
      if (_facade.snapshot.value.current != null) return false;
      _restoredSession = session;
      _restoredPosition = session.position;
      _position.setRestored(session.position);
      _onRestoredTrack?.call(session.current!);
      _publishRestoredSnapshot();
      _logger.fine(
          '已恢复上次播放会话: ${session.current!.title} @${session.position.inSeconds}s');
      return true;
    } catch (e) {
      _logger.severe('恢复上次播放会话失败', e);
      return false;
    }
  }

  /// 跨设备同步写入新会话后重载恢复态（真实播放 / 装载中不生效）。
  ///
  /// 返回恢复态是否变化（装载 / 撤下）：远端删除会话时撤下本地恢复态，
  /// 正在播放的设备不受影响（真实播放不会被恢复态覆盖）。
  Future<bool> reloadFromStore() async {
    if (_facade.snapshot.value.current != null || _resumeRestoring) {
      return false;
    }
    final session = await _store.load();
    if (session == null || session.current == null) {
      final hadRestored = _restoredSession != null;
      _dropRestoredSession();
      return hadRestored;
    }
    return load();
  }

  // ── 设置 ───────────────────────────────────────────────

  /// 设置「启动时恢复上次播放」；返回恢复态是否被撤下（调用方据此刷新 UI）。
  ///
  /// 关闭时立即撤下尚未开始播放的恢复态（真实播放不受影响）；会话仍持续
  /// 落盘，重新开启后冷启动可再次恢复。
  Future<bool> setRestoreSessionEnabled(bool value) async {
    var dropped = false;
    if (_restoreSessionEnabled != value) {
      dropped = _applyRestoreSessionEnabled(value);
    }
    try {
      await _settings.write(kRestoreSessionEnabled, value);
    } catch (e) {
      _logger.severe('保存启动恢复开关失败', e);
    }
    return dropped;
  }

  /// 重新读取启动恢复开关（跨设备同步应用远端设置后由 provider 的重载钩子调用）。
  ///
  /// 返回恢复态是否发生变化（开关关闭撤下恢复态 / 开关开启且装载成功）：
  /// 调用方据此刷新 UI——值未变或没进入恢复态时不必通知。
  Future<bool> reloadRestoreSessionPreference() async {
    final enabled = await _settings.read(kRestoreSessionEnabled);
    if (_restoreSessionEnabled == enabled) return false;
    if (enabled) {
      _applyRestoreSessionEnabled(true);
      // 开启：能装载才需要刷新（开关本身不改变现有画面）。
      return load();
    }
    return _applyRestoreSessionEnabled(false);
  }

  /// 开关状态落地：关闭且无真实播放时撤下恢复态；返回是否撤下。
  bool _applyRestoreSessionEnabled(bool enabled) {
    _restoreSessionEnabled = enabled;
    if (enabled) return false;
    if (_facade.snapshot.value.current != null || _restoredSession == null) {
      return false;
    }
    _dropRestoredSession();
    return true;
  }

  // ── 命令（按阶段路由；UI 与系统媒体会话共用） ────────────

  /// 播放：恢复态 = 用保存的队列 / 下标重新取链并跳回保存进度；
  /// live = 暂停时才起播（幂等，不会把系统「播放」键变成暂停）。
  ///
  /// 播放是显式动作：起播后提交一次（刷新 cursor 的 savedAt），恢复态的
  /// 恢复流程自己会在末尾提交恢复进度。
  @override
  Future<PlaybackCommandOutcome> play() async {
    if (phase == PlaybackSessionPhase.restored) return resume();
    final live = _facade.snapshot.value;
    // 无曲目 / 已在播：与旧 handler 的 `hasTrack && !isPlaying` 判定同语义。
    if (live.current == null || live.isPlaying) {
      return PlaybackCommandOutcome.none;
    }
    await _facade.play();
    await _commitLiveSession(force: true);
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 暂停：恢复态没有真实播放（空操作）；live 转发 facade，返回前等会话提交。
  ///
  /// 「暂停 → 重开应用恢复暂停态」依赖进度与暂停时刻的队列：快照监听
  /// （playing → paused）会提交一次；[_commitLiveSession] 按内容去重，
  /// 因此同一动作只会产生一次写请求，且返回写入完成之后。
  @override
  Future<PlaybackCommandOutcome> pause() async {
    if (phase == PlaybackSessionPhase.restored) {
      return PlaybackCommandOutcome.none;
    }
    final live = _facade.snapshot.value;
    if (live.current == null) return PlaybackCommandOutcome.none;
    await _facade.pause();
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 播放 / 暂停切换（UI 按钮语义）：按当前播放态走 [play] / [pause]，
  /// 两端因此共享同一条落盘规则，而不是各自再写一遍。
  @override
  Future<PlaybackCommandOutcome> togglePlayPause() async {
    if (phase == PlaybackSessionPhase.restored) return resume();
    final live = _facade.snapshot.value;
    if (live.current == null) {
      // 无曲目时保留 UI 既有语义：toggle 仍下发（后端空操作），不是错误。
      await _facade.toggle();
      return PlaybackCommandOutcome.none;
    }
    return live.isPlaying ? pause() : play();
  }

  /// 下一首：恢复态 = 从下一下标立即恢复播放（越界 no-op）。
  ///
  /// 恢复态切歌语义上「切歌」包含起播——只移动下标会与队列条目点击不一致。
  @override
  Future<PlaybackCommandOutcome> skipToNext() async {
    if (phase == PlaybackSessionPhase.restored) {
      final session = _restoredSession!;
      final next = session.index + 1;
      if (next >= session.tracks.length) return PlaybackCommandOutcome.none;
      return resume(startIndex: next);
    }
    await _facade.next();
    // 切歌的会话提交由快照监听触发；提交点按内容去重并等它排空。
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 上一首：恢复态 = 从上一下标立即恢复播放（越界 no-op）。
  @override
  Future<PlaybackCommandOutcome> skipToPrevious() async {
    if (phase == PlaybackSessionPhase.restored) {
      final session = _restoredSession!;
      final previous = session.index - 1;
      if (previous < 0) return PlaybackCommandOutcome.none;
      return resume(startIndex: previous);
    }
    await _facade.previous();
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 播放队列中指定下标的曲目（系统媒体队列跳转）；越界返回
  /// [PlaybackCommandOutcome.none]。
  ///
  /// 恢复态下 facade 队列为空：下标指向保存的会话队列，从该曲目恢复播放。
  @override
  Future<PlaybackCommandOutcome> playQueueIndex(int index) async {
    if (phase == PlaybackSessionPhase.restored) {
      final session = _restoredSession!;
      if (index < 0 || index >= session.tracks.length) {
        return PlaybackCommandOutcome.none;
      }
      return resume(startIndex: index);
    }
    final queue = _facade.snapshot.value.queue;
    if (index < 0 || index >= queue.length) {
      return PlaybackCommandOutcome.none;
    }
    await _facade.playQueueIndex(index);
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 切换当前曲目音质：以指定音质重新取链，保持进度与播放态。
  ///
  /// 音质不进入持久化会话（会话只存曲目 / 队列 / 进度 / 模式 / 上下文），
  /// 因此不提交会话；恢复态没有真实播放，返回空操作。
  @override
  Future<PlaybackCommandOutcome> setCurrentQuality(String quality) async {
    if (phase != PlaybackSessionPhase.live) {
      return PlaybackCommandOutcome.none;
    }
    await _facade.setCurrentQuality(quality);
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 自动换源写回：把 live 队列中 [trackUri] 的曲目原地替换为 [newTrack]。
  ///
  /// 只改真实播放：自动换源由真实播放失败触发，恢复态没有真实队列可换，
  /// 改保存的会话只会让 UI 显示一首并未播放的曲目——因此返回
  /// [PlaybackCommandOutcome.none]。未命中（uri 不在队列）同样是 no-op。
  ///
  /// live 返回前必须保证换源结果已写进会话，而不是等下一次动作：
  /// 换源后又指向过期直链，进程此时被杀，重开应用恢复的还是旧来源。提交点
  /// 按内容去重：当前曲目 id 变了时快照监听已写同一份内容，不再补写；同 id
  /// 换元数据 / 非当前槽位则由这里补一次。
  @override
  Future<PlaybackCommandOutcome> replaceQueueTrack(
    String trackUri,
    Track newTrack,
  ) =>
      _replaceTrack(
        trackUri,
        newTrack,
        scope: PlaybackReplaceScope.liveOnly,
      );

  /// 播放队列中指定 id 的曲目（队列面板点击）；未命中返回
  /// [PlaybackCommandOutcome.none]。
  ///
  /// 只负责把 id 解析成下标（live 队列优先，其次恢复态保存的会话队列），
  /// 阶段路由、越界校验与提交都复用 [playQueueIndex]——队列播放只有一条路径。
  Future<PlaybackCommandOutcome> playQueueItemById(String trackId) async {
    // 下标必须与 playQueueIndex 接下来读取的那份队列同源：恢复阶段解析
    // 保存会话，live 阶段解析 facade 队列。否则交接窗口里两份队列顺序不同
    // 时会播到另一首。
    final restored = phase == PlaybackSessionPhase.restored;
    final tracks =
        restored ? _restoredSession!.tracks : _facade.snapshot.value.queue;
    final index = tracks.indexWhere((track) => track.id.uri == trackId);
    if (index < 0) return PlaybackCommandOutcome.none;
    return playQueueIndex(index);
  }

  /// seek：恢复装载期间记下用户目标（恢复流程末尾以它为准），恢复态只更新
  /// 保存的进度（点播放时再落到真实播放器上），live 转发 facade 并强制落盘。
  ///
  /// live 与系统 seek 同一口径：拖动只在落点提交（滑杆 onChangeEnd / 点歌词
  /// 行），不是每一帧写；进程紧接着被杀时重开要落在新位置。返回的 Future 在
  /// 写队列排空后结束。
  @override
  Future<PlaybackCommandOutcome> seekToPosition(Duration position) async {
    if (_resumeRestoring) {
      _resumeSeekTarget = position;
    }
    if (phase == PlaybackSessionPhase.restored) {
      final duration = _restoredSession!.current?.duration;
      final clamped = _clampToDuration(position, duration);
      _restoredPosition = clamped;
      _restoredSession = _restoredSession!.copyWith(position: clamped);
      _position.setRestored(clamped);
      _publishRestoredSnapshot();
      await _store.save(_restoredSession!);
      return PlaybackCommandOutcome.trackOnly;
    }
    await _facade.seek(position);
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 换源：把队列中的 [oldTrack] 原地替换为 [newTrack]（库内 / 手动换源）。
  ///
  /// 与 [replaceQueueTrack] 共用同一个实现，区别只有作用范围：live 队列与
  /// 恢复态保存的会话都跟随。facade 队列命中走真实替换（命中当前曲目会重新
  /// 取链）；恢复态（facade 队列为空）替换保存的会话队列并落盘。未命中不算
  /// 失败：库内换源与队列跟随解耦。返回 [PlaybackCommandOutcome.trackAndQueue]
  /// 表示至少命中一处；返回前等写队列排空（命中才可能产生写入）。
  Future<PlaybackCommandOutcome> replaceTrack(
    Track oldTrack,
    Track newTrack,
  ) =>
      _replaceTrack(
        oldTrack.id.uri,
        newTrack,
        scope: PlaybackReplaceScope.liveAndRestored,
      );

  /// 换源的唯一实现：解析 uri → 改 live / 恢复态 → 提交一次。
  ///
  /// [PlaybackReplaceScope.liveOnly] 只处理真实播放（恢复态 / 无曲目 no-op）；
  /// [PlaybackReplaceScope.liveAndRestored] 两处各自命中才改。提交点只有一个：
  /// live 可保存时按 [_commitLiveSession] 的内容去重提交，否则只有恢复态命中
  /// 时写保存的会话——每个命令最多一次写请求。
  Future<PlaybackCommandOutcome> _replaceTrack(
    String trackUri,
    Track newTrack, {
    required PlaybackReplaceScope scope,
  }) async {
    // 自动换源只跟随真实播放：恢复阶段即使 facade 已经推了队列（还没有
    // current），也不能改它——那会让恢复态 UI 显示一首并未播放的曲目。
    if (scope == PlaybackReplaceScope.liveOnly &&
        phase == PlaybackSessionPhase.restored) {
      return PlaybackCommandOutcome.none;
    }
    final live = _facade.snapshot.value;
    final liveHit = live.queue.any((track) => track.id.uri == trackUri);
    if (scope == PlaybackReplaceScope.liveOnly &&
        (live.current == null || !liveHit)) {
      return PlaybackCommandOutcome.none;
    }
    if (liveHit) {
      await _facade.replaceQueueTrack(trackUri, newTrack);
    }
    // live 替换可能触发真实播放接管并撤下恢复态；改恢复态前重新读取，
    // 与「先 live 再 restored」的既有顺序一致。
    final session = scope == PlaybackReplaceScope.liveAndRestored
        ? _restoredSession
        : null;
    final restoredHit = session != null &&
        session.tracks.any((track) => track.id.uri == trackUri);
    if (!liveHit && !restoredHit) return PlaybackCommandOutcome.none;
    if (restoredHit) {
      _restoredSession = session.copyWith(
        tracks: [
          for (final track in session.tracks)
            track.id.uri == trackUri ? newTrack : track,
        ],
      );
      _publishRestoredSnapshot();
    }
    await _commitReplacement(liveHit: liveHit, restoredHit: restoredHit);
    return PlaybackCommandOutcome.trackAndQueue;
  }

  /// 换源的单一提交点（见 [_replaceTrack]）。
  Future<void> _commitReplacement({
    required bool liveHit,
    required bool restoredHit,
  }) async {
    // live 与恢复态同时命中只可能出现在交接窗口：live 可保存时以 live 为准
    // （恢复态随后会被真实播放接管丢弃）；否则提交恢复态，保证不丢换源结果。
    if (liveHit && _hasSavableSession(_facade.snapshot.value)) {
      await _commitLiveSession();
      return;
    }
    if (restoredHit) {
      await _store.save(_restoredSession!);
    }
    await _store.pendingWrite;
  }

  /// 设置播放模式。
  ///
  /// 恢复态必须同步改写保存的会话（否则模式按钮看起来「点不动」），恢复
  /// 播放时会把该模式带给后端；live 立即提交并等它写完（重开应用恢复的
  /// 是改后的模式）。
  @override
  Future<PlaybackCommandOutcome> setPlayMode(PlayMode mode) async {
    await _facade.setMode(mode);
    final session = _restoredSession;
    if (session != null) {
      _restoredSession = session.copyWith(mode: mode);
      _publishRestoredSnapshot();
      await _store.save(_restoredSession!);
      return PlaybackCommandOutcome.trackOnly;
    }
    await _commitLiveSession();
    return PlaybackCommandOutcome.trackOnly;
  }

  /// 循环到下一个播放模式：以当前展示的模式为基准（恢复态读会话，live 读
  /// facade），系统通知与 App 内按钮因此不会各切各的。
  @override
  Future<PlaybackCommandOutcome> togglePlayMode() {
    final current = resolve(_facade.snapshot.value).mode;
    return setPlayMode(current.next);
  }

  /// 系统媒体「停止」：先提交会话再停，保留下次启动可恢复的会话。
  ///
  /// 必须赶在 `facade.stop()` 清空服务队列之前落盘——停止后快照为空，再也
  /// 拼不出「上一首 / 队列 / 模式 / 进度」。与 [stopPlayback] 的区别是语义
  /// 而不是写入方式：那个是 UI 的「本次会话结束」，会清空持久化。
  @override
  Future<PlaybackCommandOutcome> stop() async {
    await flushSession();
    await _facade.stop();
    await _store.pendingWrite;
    return PlaybackCommandOutcome.trackAndQueue;
  }

  /// 停止播放并清空持久化会话（UI 的「本次会话结束」，避免下次启动又出现）。
  ///
  /// 清除等写队列排空后返回：在途的旧保存不会在清除之后把会话复活。
  Future<void> stopPlayback() async {
    await _facade.stop();
    _dropRestoredSession();
    // 会话已明确结束：不再持有上一份完整队列（Track 含 raw payload）。
    // 不这么做时 `_lastWrittenSession` 会一直挂到下次播放，托盘常驻期间
    // 等于白留一整份队列；命令提交点的去重依据在无会话时也不再需要。
    _lastWrittenSession = null;
    await _store.clear();
  }

  /// 恢复上次播放：以保存的队列 / 下标重新装载，再 seek 回保存的进度。
  ///
  /// [startIndex] 指定从队列中另一首开始（恢复态点队列条目）：此时不 seek
  /// 回保存进度（那是另一首曲目的进度）。直链不持久化（会过期），这里走正常
  /// 取链路径。返回 [PlaybackCommandOutcome.trackAndQueue] 表示已接管（恢复
  /// 数据丢弃，曲目与队列都换成了会话内容）；[PlaybackCommandOutcome.none]
  /// 表示空操作或失败——失败时保留恢复态可重试。
  Future<PlaybackCommandOutcome> resume({int? startIndex}) async {
    final session = _restoredSession;
    // 已有恢复流程在跑：忽略重复触发（装载中后端会推送曲目，后续操作走
    // 真实播放路径，不会再次进入本方法）。
    if (session == null || session.current == null || _resumeRestoring) {
      return PlaybackCommandOutcome.none;
    }
    final index =
        (startIndex ?? session.index).clamp(0, session.tracks.length - 1);
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
      _dropRestoredSession();
      // 立刻把恢复进度写回会话：装载时的强制保存记的是 0，
      // 若此时被杀进程，下次冷启动会从 0 开始。
      await _commitLiveSession();
      return PlaybackCommandOutcome.trackAndQueue;
    } catch (e) {
      _logger.severe('恢复上次播放失败', e);
      // 已被真实播放接管（恢复快照已撤下）：交还进度通道，
      // 避免一直停在旧的恢复进度。
      if (_restoredSession == null) {
        _dropRestoredSession();
      }
      return PlaybackCommandOutcome.none;
    } finally {
      _resumeRestoring = false;
      _resumeSeekTarget = null;
    }
  }

  // ── 落盘（PlaybackSessionStore 的唯一写者） ──────────────

  // 跨设备同步端口：远端应用 / 删除也必须经过本模块持有的 store，
  // 与本地 save / clear 共用同一个 pendingWrite 队列（顺序即调用顺序）。
  // 若同步栈另建 store，两个队列会同时写同一组 prefs 键，远端应用可能插进
  // 「本地保存 → 清除」之间。

  @override
  Future<Map<String, dynamic>?> loadRaw() => _store.loadRaw();

  @override
  Future<void> applyRemote(Map<String, dynamic> raw) => _store.saveRaw(raw);

  @override
  Future<void> clearRemote() => _store.clear();

  /// 强制提交当前会话（进入后台 / 桌面隐藏 / 退出 / 系统媒体控制调用）。
  ///
  /// 返回的 Future 在写请求落盘后结束：系统控制动作 await 它，保证控制动作
  /// 返回时会话已在本地——进程随后被系统回收，重开应用仍能恢复上一首 / 队列 /
  /// 模式 / 进度。这是动作入口，不引入任何定时器。
  Future<void> flushSession() async {
    final live = _facade.snapshot.value;
    if (_hasSavableSession(live)) _writeSession(live);
    await _store.pendingWrite;
  }

  /// 前后台切换：进入后台提交一次（息屏 / 切走前把最后进度写回）。
  ///
  /// 与壳层 paused / 桌面隐藏 / 退出共用 [flushSession] 这个提交入口；
  /// 生命周期回调不能 await，用 `unawaited` 触发（写队列仍按顺序串行）。
  void _onPowerPolicyChanged() {
    final foreground = _powerPolicy.isForeground;
    final enteredBackground = _wasForeground && !foreground;
    _wasForeground = foreground;
    if (enteredBackground) unawaited(flushSession());
  }

  /// 曲末完成：单曲循环 / 单曲队列重播没有曲目 id 变化，快照监听不会触发；
  /// 在完成事件到达时提交一次进度（自动切歌随后还会按新曲目再写游标）。
  void _onTrackCompleted(Track track) {
    final live = _facade.snapshot.value;
    if (live.current?.id != track.id) return;
    _maybeSaveSession();
  }

  /// 真实播放快照变化：真实播放接管时撤下恢复数据，内容变化时提交。
  ///
  /// 只比较会落盘的字段（曲目 / 队列内容 / 下标 / 模式 / 上下文 / 播放态
  /// 转暂停），loading / isPlaying 抖动不写 payload。下标覆盖「同曲目不同
  /// 队列槽位」（重复曲目）的自动切换。
  void _onLiveSnapshot() => _handleLiveSnapshot(_facade.snapshot.value);

  void _handleLiveSnapshot(PlaybackSnapshot live) {
    final trackId = live.current?.id.uri;
    final trackChanged = trackId != _processedTrackId;
    if (trackId == null) {
      _processedTrackId = null;
    } else if (trackChanged) {
      _processedTrackId = trackId;
      // 真实播放接管：撤下冷启动恢复态。恢复播放的 seek 尚未落地时，
      // 继续沿用恢复进度显示（见 [_resumeRestoring]），避免进度条闪回 0。
      _dropRestoredSession(keepPosition: _resumeRestoring);
    }

    final queueChanged = !_sameTrackList(live.queue, _observedQueue);
    final indexChanged = live.currentIndex != _observedIndex;
    final modeChanged = live.mode != _observedMode;
    final contextChanged = live.context != _observedContext;
    _observedQueue = live.queue;
    _observedIndex = live.currentIndex;
    _observedMode = live.mode;
    _observedContext = live.context;

    // 曲目 / 队列 / 下标 / 模式 / 上下文变化，或播放中→暂停/停止：提交一次。
    if (trackChanged ||
        queueChanged ||
        indexChanged ||
        modeChanged ||
        contextChanged) {
      _maybeSaveSession();
    } else if (_wasPlaying && !live.isPlaying) {
      _maybeSaveSession();
    }
    _wasPlaying = live.isPlaying;
  }

  /// 仅需「队列 / 下标 / 进度」可写的判定（无曲目 / 空队列 / 非法下标跳过）。
  bool _hasSavableSession(PlaybackSnapshot live) =>
      live.current != null && live.queue.isNotEmpty && live.currentIndex >= 0;

  /// 保存当前快照对应的会话（store 决定写 payload 还是只写 cursor）。
  void _maybeSaveSession() {
    final live = _facade.snapshot.value;
    if (!_hasSavableSession(live)) return;
    _writeSession(live);
  }

  /// 提交落盘：`savedAt` 由 store 按本次动作刷新并触发 `onSaved`。
  void _writeSession(PlaybackSnapshot live) {
    final session = _sessionOf(live);
    _lastWrittenSession = session;
    unawaited(_store.save(session));
  }

  /// 命令的唯一会话提交点：facade 已改完后调用一次。
  ///
  /// 快照监听可能已经替同一份内容写过会话（切歌 / 暂停），这里按内容比较
  /// 跳过重复写；[force] 用于显式动作（播放）刷新 cursor 时间。末尾等写队列
  /// 排空，保证命令返回时会话已在本地（ADR-0010 的「返回即已提交」）。
  Future<void> _commitLiveSession({bool force = false}) async {
    final live = _facade.snapshot.value;
    if (_hasSavableSession(live)) {
      final session = _sessionOf(live);
      final last = _lastWrittenSession;
      if (force || last == null || !_sameSession(last, session)) {
        _writeSession(live);
      }
    }
    await _store.pendingWrite;
  }

  /// 当前 live 快照对应的持久化会话形状（与 [_writeSession] 同源）。
  PlaybackSession _sessionOf(PlaybackSnapshot live) => PlaybackSession(
        tracks: live.queue,
        index: live.currentIndex,
        position: _facade.position.value,
        mode: live.mode,
        context: live.context,
      );

  // ── 恢复态内部 ─────────────────────────────────────────

  /// 用会话构造恢复态展示快照：当前 / 队列 / 下标 / 模式齐备，isPlaying=false。
  ///
  /// 队列投影与真实播放共用 `projectQueue`；恢复态没有播放顺序栈、也没有
  /// 持久化洗牌排列，因此显式传空 [QueueOrder]——shuffle 的 next 为 null、
  /// upNext 为空（不拿队列下标冒充洗牌顺序），previous / previousOfPrevious
  /// 按队列前一位依次回退。
  void _publishRestoredSnapshot() {
    final session = _restoredSession;
    final current = session?.current;
    if (session == null || current == null) {
      _restoredSnapshot = null;
      return;
    }
    final projection = projectQueue(
      session.tracks,
      currentIndex: session.index,
      mode: session.mode,
      idOf: (track) => track.id,
    );
    _restoredSnapshot = PlaybackSnapshot(
      current: current,
      queue: List.unmodifiable(session.tracks),
      currentIndex: session.index,
      next: projection.next,
      previous: projection.previous,
      previousOfPrevious: projection.previousOfPrevious,
      upNext: projection.upNext,
      isPlaying: false,
      isLoading: false,
      duration: current.duration ?? Duration.zero,
      mode: session.mode,
      context: session.context,
    );
  }

  /// 撤下恢复数据：真实播放接管 / 停止播放 / 关闭恢复开关时调用。
  ///
  /// [keepPosition] 为 true 时保留进度通道的恢复进度（恢复播放的 seek 尚未
  /// 落地），由调用方在 seek 完成后再次调用本方法交还进度通道。
  void _dropRestoredSession({bool keepPosition = false}) {
    _restoredSession = null;
    _restoredSnapshot = null;
    if (keepPosition) return;
    _restoredPosition = Duration.zero;
    _position.setRestored(null);
  }

  /// 拆线（组合根只负责创建；释放与 provider 同生命周期）。
  void dispose() {
    _powerPolicy.removeListener(_onPowerPolicyChanged);
    _facade.snapshot.removeListener(_onLiveSnapshot);
    unawaited(_trackCompletions?.cancel());
    _trackCompletions = null;
    _position.dispose();
  }
}

/// 两份会话内容是否相同（命令提交点的去重依据）。
///
/// 只比较真正会落盘的字段：队列内容（Track 深相等）、下标、进度、模式、上下文。
/// 队列列表实例优先用 `identical` 快路径（后端按 `queueRevision` 复用同一份
/// 不可变 List，位置 tick / 播放态变化不会重建它）。
bool _sameSession(PlaybackSession a, PlaybackSession b) {
  if (identical(a, b)) return true;
  if (a.index != b.index ||
      a.position != b.position ||
      a.mode != b.mode ||
      a.context != b.context) {
    return false;
  }
  return _sameTrackList(a.tracks, b.tracks);
}

/// 两份队列内容是否相同（`identical` 快路径 + 逐曲相等）。
bool _sameTrackList(List<Track>? a, List<Track>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 恢复态里的 progress 夹取：有曲目时长时 clamp 到 [0, duration]，否则只兜负值。
Duration _clampToDuration(Duration position, Duration? duration) {
  final durationMs = duration?.inMilliseconds ?? 0;
  final positionMs = position.inMilliseconds;
  if (durationMs > 0) {
    return Duration(milliseconds: positionMs.clamp(0, durationMs));
  }
  return Duration(milliseconds: positionMs < 0 ? 0 : positionMs);
}

/// 进度通道：真实播放时转发 facade position；恢复态（冷启动未加载）
/// 显示上次保存的进度，直到用户恢复播放后交还底层。
class _RestoredPositionChannel implements StateListenable<Duration> {
  _RestoredPositionChannel(this._source) {
    _source.addListener(_relay);
  }

  final StateListenable<Duration> _source;
  final List<void Function()> _listeners = [];
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
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void dispose() => _source.removeListener(_relay);
}
