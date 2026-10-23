import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/play_mode.dart';
import '../services/audio_cache_platform.dart';
import '../services/audio_cache_store.dart';
import '../services/cache_service.dart';
import '../sources/source_track.dart';
import 'audio_cache_source.dart';
import 'audio_focus_guard.dart';
import 'next_track_preloader.dart';
import 'playback_order.dart';
import 'playback_power_policy.dart';
import 'playing_track_cache_writer.dart';
import 'queue_navigation.dart';
import 'queue_projection.dart';
import 'shuffle_order.dart';

/// 位置采样档位：播放链路按前后台 / 桌面歌词选择（纯决策，便于单测）。
enum PositionSamplingMode {
  /// 跟随 `AudioPlayer.positionStream`（约 5Hz）：前台或桌面歌词可能展示。
  highFrequency,

  /// 后台播放：1s Timer 读一次 `_player.position`，值变才通知。
  periodic,

  /// 后台暂停：位置不会变，不建订阅也不建 Timer。
  none,
}

/// 后台位置采样决策。
///
/// 桌面歌词在后台也要逐字 / 切行，因此 [keepHighFrequency] 优先于播放态；
/// 暂停时不采样（避免白醒主 isolate）。
@visibleForTesting
PositionSamplingMode positionSamplingModeFor({
  required bool keepHighFrequency,
  required bool playing,
}) {
  if (keepHighFrequency) return PositionSamplingMode.highFrequency;
  return playing ? PositionSamplingMode.periodic : PositionSamplingMode.none;
}

/// 将音源曲目解析为可播放 URL 的回调（由 SourceManager 提供）。
typedef SourceUrlResolver = Future<String> Function(
  SourceTrack track, {
  String? quality,
});

/// 本地播放服务：音源取链后由 App 直接播放。
///
/// 对外输出 `SourceTrack` 曲目结构，现有 NowPlaying / 队列 / 歌词等界面
/// 无需感知播放后端差异。
class LocalPlaybackService extends ChangeNotifier {
  final SourceUrlResolver _resolver;
  final AudioPlayer _player;

  /// 播放器是否已在退出收尾里释放。
  ///
  /// 退出路径不经过 provider dispose：`shutdownAudioForQuit()` 与 [dispose]
  /// 可能先后到达，靠这个标记保证 `AudioPlayer.dispose()` 只调用一次。
  bool _playerDisposed = false;

  /// 当前偏好音质（composition root 注入；省流模式由注入方压低上限）。
  ///
  /// 播放前用它选出本次实际音质：解析器与音频缓存键共用同一值，
  /// 避免省流下缓存的 128k 文件在 Wi-Fi 上被当作标准音质复用。
  final String Function()? _preferredQuality;

  /// 统一缓存门面（默认全局单例；测试可注入临时目录实现）。
  final CacheService? _cacheService;

  /// 下一首预载器（组合根注入；null = 关闭预载）。
  final NextTrackPreloader? _nextTrackPreloader;

  /// 移动端播放功耗策略（组合根注入共享实例；默认前台实例便于单测）。
  ///
  /// 只影响位置采样节拍——本服务不据它停产任何预取 / 取色（那些由
  /// `PlaybackObserver` 等观察者按各自口径驱动）。
  final PlaybackPowerPolicy _powerPolicy;

  /// 当前曲目后台缓存写入（组合根注入；null = 关闭）。
  ///
  /// 只在播放侧没有写缓存时启用：桌面（media_kit 不能边播边缓存）或运行期
  /// 后端拒绝 `StreamAudioSource` 后退到直接流播的会话。移动端正常路径由
  /// `LockCachingAudioSource` 写同一文件，重复写会互相破坏。
  final PlayingTrackCacheWriter? _cacheWriter;

  /// 已知平台后端不支持 StreamAudioSource（如桌面 media_kit）：
  /// 本会话内不再尝试边播边缓存，直接流播。
  bool _audioCacheUnsupported = false;

  /// 音频中断事件流（audio_session 的 `interruptionEventStream`）。
  ///
  /// 生产路径为 null：服务在 [_configureAudioSession] 里从 `AudioSession.instance`
  /// 取（桌面无插件实现时跳过，保持桌面端现状）；测试注入假流，
  /// 不触碰插件通道即可验证「焦点丢失 → 暂停」接线。
  final Stream<AudioInterruptionEvent>? _interruptionsOverride;

  /// 音频焦点守卫（其他应用出声 → [pause]），[_configureAudioSession] 内装配。
  AudioFocusGuard? _focusGuard;

  final List<SourceTrack> _queue = [];
  int _currentIndex = -1;
  SourceTrack? _currentTrack;
  String? _contextName;
  PlayMode _mode = PlayMode.listLoop;

  /// 队列内容版本号：任何队列变更（装载 / 追加 / 原地替换 / 补图 / 清空）
  /// 自增。O(1) 的「队列是否真的变了」判定（位置 tick 不算变更）；
  /// `LocalPlaybackBackend` 用它判断能否复用队列的领域 `Track` 映射。
  int _queueRevision = 0;

  /// 队列内容版本号（每次队列内容变更自增；位置 / 播放态变化不变）。
  ///
  /// 快照重建可能由位置 tick 触发而队列未变，消费方（播放后端）据此
  /// 复用上一份队列映射，避免每次通知都重跑全队列转换。
  int get queueRevision => _queueRevision;

  /// 已播放顺序（最近一首在后，栈顶供 previous 弹出）；存队列下标，
  /// 队列仅在 `playTracks` 时整体替换并同步清空。
  final PlaybackOrder _order = PlaybackOrder();

  /// shuffle 播放顺序：队列下标的随机排列（每轮每首恰好一次，轮末自动重洗）。
  final PlaybackShuffleOrder _shuffleOrder;

  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _lastError;

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _positionSampleTimer;
  Timer? _notifyThrottle;
  bool _notifyPending = false;
  int _playRequestId = 0;

  /// 显式位置跳转版本号：用户 seek 与内部回跳（单曲循环 / 无下一首归零）
  /// 都自增。系统媒体会话据此区分「正常进度推进」与「真实跳转」并补发
  /// 播放态（平台间的进度判定口径见 `LocalAudioHandler`）。
  int _seekRevision = 0;
  int get seekRevision => _seekRevision;

  /// 当前曲目自然播完（自动切歌 / 单曲循环重播之前）的广播事件。
  ///
  /// 定时关闭的「播完当前歌曲」不能靠 `positionStream` 判断曲末：息屏 /
  /// 后台时位置流由 Dart 定时器驱动，可能被节流，而播放器仍会完成当前曲目。
  final StreamController<SourceTrack> _trackCompletions =
      StreamController<SourceTrack>.broadcast(sync: true);

  /// 「当前曲目播完即停止」的一次性标志（定时关闭用）。
  bool _stopAfterCurrentTrack = false;

  LocalPlaybackService({
    required SourceUrlResolver resolver,
    CacheService? cacheService,
    String Function()? preferredQuality,
    math.Random? random,
    NextTrackPreloader? nextTrackPreloader,
    PlayingTrackCacheWriter? audioCacheWriter,
    Stream<AudioInterruptionEvent>? audioInterruptions,
    PlaybackPowerPolicy? powerPolicy,
    // 单测注入假播放器（生产不传，内部创建 just_audio 播放器）。
    @visibleForTesting AudioPlayer? player,
  })  : _resolver = resolver,
        _player = player ?? AudioPlayer(),
        _cacheService = cacheService ?? CacheService.instance,
        _preferredQuality = preferredQuality,
        _nextTrackPreloader = nextTrackPreloader,
        _cacheWriter = audioCacheWriter,
        _interruptionsOverride = audioInterruptions,
        _powerPolicy = powerPolicy ?? PlaybackPowerPolicy(),
        _shuffleOrder = PlaybackShuffleOrder(random: random) {
    _playerStateSubscription = _player.playerStateStream.listen(_onPlayerState);
    // 位置采样按前后台策略选择（前台 / 桌面歌词 = 高频流；后台播放 = 1s
    // 轮询；后台暂停 = 不采样），切换时先取消旧订阅 / Timer。
    _powerPolicy.addListener(_syncPositionSampling);
    _syncPositionSampling();
    // 配置系统音频会话（音乐类型）：iOS 后台播放、Android 音频焦点/duck，
    // 并接入中断事件（其他应用出声 → 暂停）。不阻塞构造；不支持的平台内部跳过。
    unawaited(_configureAudioSession());
  }

  /// 当前位置采样档位（测试观察用；生产只经 [_syncPositionSampling] 演进）。
  @visibleForTesting
  PositionSamplingMode get positionSamplingMode => positionSamplingModeFor(
        keepHighFrequency: _powerPolicy.keepHighFrequencyPosition,
        playing: _player.playing,
      );

  /// 位置流订阅是否活跃（测试观察用）。
  @visibleForTesting
  bool get positionStreamActive => _positionSubscription != null;

  /// 后台 1s 采样 Timer 是否活跃（测试观察用）。
  @visibleForTesting
  bool get positionSampleTimerActive => _positionSampleTimer != null;

  /// 按功耗策略 / 播放态选择位置采样方式。
  ///
  /// 前后台与播放态都可能独立变化（息屏、暂停、桌面歌词开关），每次全量
  /// 重选并取消不需要的通道——不能出现「positionStream 与 Timer 同时采样」。
  void _syncPositionSampling() {
    switch (positionSamplingModeFor(
      keepHighFrequency: _powerPolicy.keepHighFrequencyPosition,
      playing: _player.playing,
    )) {
      case PositionSamplingMode.highFrequency:
        _stopPositionSampleTimer();
        _positionSubscription ??=
            _player.positionStream.listen(_onPlayerPosition);
      case PositionSamplingMode.periodic:
        _cancelPositionSubscription();
        _positionSampleTimer ??= Timer.periodic(
          const Duration(seconds: 1),
          (_) => _pollPlayerPosition(),
        );
      case PositionSamplingMode.none:
        _cancelPositionSubscription();
        _stopPositionSampleTimer();
    }
  }

  void _cancelPositionSubscription() {
    final subscription = _positionSubscription;
    if (subscription == null) return;
    _positionSubscription = null;
    unawaited(subscription.cancel());
  }

  void _stopPositionSampleTimer() {
    _positionSampleTimer?.cancel();
    _positionSampleTimer = null;
  }

  void _onPlayerPosition(Duration position) {
    _position = position;
    _scheduleNotify();
  }

  /// 后台 1s 轮询：值没变不发通知（暂停 / 缓冲时避免空转唤醒 UI）。
  void _pollPlayerPosition() {
    final position = _player.position;
    if (position == _position) return;
    _position = position;
    _scheduleNotify();
  }

  /// 音乐会话配置：在 [AudioSessionConfiguration.music] 上声明
  /// 「被 duck 请求打断时按暂停处理」。
  ///
  /// 为什么不用默认的 `music()`（`androidWillPauseWhenDucked` 缺省 false）：
  /// just_audio 对 `usage=media` 的 duck 事件没有任何处理（只有 `usage=game`
  /// 压半音量），保持缺省会让导航提示 / 语音消息与音乐「叠着播」；声明后系统
  /// 把其他应用的 may-duck 请求升级为 transient 满音量，本应用收到
  /// LOSS_TRANSIENT → 暂停，焦点归还时由 just_audio 的中断续播记账接上。
  static final AudioSessionConfiguration _sessionConfiguration =
      const AudioSessionConfiguration.music()
          .copyWith(androidWillPauseWhenDucked: true);

  /// 配置 audio_session（仅移动端/桌面原生支持平台）+ 装配音频焦点守卫。
  ///
  /// Linux/Windows 没有 audio_session 插件实现，调用会抛 MissingPluginException，
  /// 因此按平台跳过，保持桌面端现有行为（没有焦点事件，不因其他应用出声暂停）。
  Future<void> _configureAudioSession() async {
    final injected = _interruptionsOverride;
    if (injected != null) {
      _attachFocusGuard(injected);
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    try {
      final session = await AudioSession.instance;
      await session.configure(_sessionConfiguration);
      _attachFocusGuard(session.interruptionEventStream);
    } catch (e) {
      debugPrint('[LocalPlayback] 音频会话配置失败: $e');
    }
  }

  /// 装配音频焦点守卫：其他应用夺走焦点时暂停（语义见 [AudioFocusGuard]）。
  void _attachFocusGuard(Stream<AudioInterruptionEvent> interruptions) {
    (_focusGuard ??= AudioFocusGuard(onFocusLoss: pause)).attach(interruptions);
  }

  bool get hasTrack => _currentTrack != null;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  PlayMode get mode => _mode;
  String? get lastError => _lastError;
  SourceTrack? get currentSourceTrack => _currentTrack;

  /// 当前曲目自然播完的事件（自动切歌 / 单曲循环重播之前发出）。
  Stream<SourceTrack> get trackCompletions => _trackCompletions.stream;

  /// 武装 / 撤销「当前曲目播完即停止」；曲目完成时自动清除。
  void setStopAfterCurrentTrack(bool enabled) {
    _stopAfterCurrentTrack = enabled;
  }

  /// 当前是否已武装停止标志（测试 / 断点观察用）。
  @visibleForTesting
  bool get stopAfterCurrentTrack => _stopAfterCurrentTrack;

  /// 最近一次 `playTracks` 传入的上下文名（系统媒体会话/快照映射用）。
  String? get contextName => _contextName;

  /// 队列投影：快照的 next / previous / upNext 唯一推导（纯函数在
  /// `queue_projection.dart`；恢复态共用同一实现）。
  ///
  /// shuffle 排列只在长度 > 1 时需要——单曲队列的「下一首」就是自己，
  /// 与既有语义一致；排列缺失时按当前曲目置首补齐（正常路径在
  /// playTracks / setMode 已重置）。
  QueueProjection<SourceTrack> get queueProjection {
    if (_queue.isEmpty || _currentIndex < 0 || _currentIndex >= _queue.length) {
      return const QueueProjection<SourceTrack>();
    }
    if (_mode == PlayMode.shuffle && _queue.length > 1) {
      _ensureShuffleOrder();
    }
    return projectQueue(
      _queue,
      currentIndex: _currentIndex,
      mode: _mode,
      order: QueueOrder(
        shuffleIndices:
            _mode == PlayMode.shuffle ? _shuffleOrder.indices : null,
        previousIndex: _order.peekPrevious(),
      ),
      idOf: (track) => track.id,
    );
  }

  /// 按当前模式解析出的下一首（界面预览；shuffle 为排列中的下一首，
  /// 本轮末尾为空——自动播完/手动切歌时才重洗新一轮）。
  SourceTrack? get nextSourceTrack => queueProjection.next;

  /// 可展示的上一首：播放顺序最近一首（非破坏性 peek）→ 队列前一位
  /// （列表循环队首回绕到队尾）；无 / 与当前曲目同 id 为 null
  /// （队首的「重播当前」不当作上一首）。
  SourceTrack? get previousSourceTrack => queueProjection.previous;

  /// 实际播放顺序中当前曲目之后的曲目（队列页「接下来」展示用）：
  /// 列表循环 = 队列下一位起，队尾后补上队首到当前之前的曲目；
  /// 顺序播放 = 队列下一位起；shuffle = 本轮洗牌排列的剩余。
  List<SourceTrack> get upNextTracks => queueProjection.upNext;

  /// 当前播放进度（用于系统媒体会话状态映射）。
  Duration get position => _position;

  /// 当前曲目时长（优先使用播放器解析出的时长）。
  Duration get duration => _duration;

  /// 当前队列与下标（用于系统媒体会话的队列展示与跳转）。
  List<SourceTrack> get queueTracks => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  /// 原地更新队列中某曲目的封面（音源补图）。
  ///
  /// 替换队列元素（新对象触发领域映射重建）并同步当前曲目引用；
  /// 低频快照通知，封面换图淡化由封面堆叠组件消费。
  void updateTrackArtwork(String trackId, String? coverUrl) {
    final index = _queue.indexWhere((track) => track.id == trackId);
    if (index < 0) return;
    final old = _queue[index];
    final next = (coverUrl == null || coverUrl.isEmpty) ? null : coverUrl;
    if (old.coverUrl == next) return;
    _queue[index] = old.copyWith(coverUrl: next);
    _queueRevision++;
    if (_currentIndex == index) {
      _currentTrack = _queue[index];
    }
    notifyListeners();
  }

  /// 换源：原地替换队列中 [trackId] 的曲目。
  ///
  /// 命中当前播放曲目时重新取链**从头播放**（新源音频时长/偏移不可假设，
  /// 与 LX 换源后跳转到新曲目的语义一致）；其余命中项只替换数据，
  /// 播放到它时自然走新源。命中则触发一次低频快照通知。
  Future<void> replaceQueueTrack(String trackId, SourceTrack track) async {
    var hit = false;
    var currentHit = false;
    for (var index = 0; index < _queue.length; index++) {
      if (_queue[index].id != trackId) continue;
      hit = true;
      _queue[index] = track;
      if (index == _currentIndex) currentHit = true;
    }
    if (!hit) return;
    _queueRevision++;
    if (currentHit) {
      // _playIndex 内部同步 _currentTrack / 加载态 / 进度清零与重新取链。
      await _playIndex(_currentIndex);
    } else {
      notifyListeners();
    }
  }

  Future<void> playTracks(
    List<SourceTrack> tracks,
    int index, {
    String? contextName,
  }) async {
    if (tracks.isEmpty) return;
    _queue
      ..clear()
      ..addAll(tracks);
    _queueRevision++;
    // 新队列 = 新会话：播放顺序从头开始；shuffle 以起播曲目置首重洗。
    _order.clear();
    final safeIndex = index.clamp(0, tracks.length - 1);
    if (_mode == PlayMode.shuffle) {
      _shuffleOrder.reset(_queue.length, startIndex: safeIndex);
    } else {
      _shuffleOrder.clear();
    }
    _contextName = contextName;
    await _playIndex(safeIndex, recordHistory: false);
  }

  /// 追加曲目到队列末尾（AI 推歌续推等）：不打断当前播放。
  ///
  /// 顺序模式立即追加到队尾；shuffle 模式下把新下标扩展到洗牌排列尾部
  /// （当前轮先放完老歌，轮末重洗覆盖全队列）；空队列时仅入队
  /// （不自动开播，调用方随后用 [playTracks] 起播）。
  Future<void> enqueueTracks(List<SourceTrack> tracks) async {
    if (tracks.isEmpty) return;
    final oldLength = _queue.length;
    _queue.addAll(tracks);
    _queueRevision++;
    if (_mode == PlayMode.shuffle) {
      _shuffleOrder.extend(oldLength, _queue.length);
    }
    notifyListeners();
  }

  Future<void> playTrackId(String trackId) async {
    final index = _queue.indexWhere((t) => t.id == trackId);
    if (index < 0) return;
    await _playIndex(index);
  }

  /// 播放队列中指定下标（系统媒体会话的 queue 跳转用，允许队列有重复曲目）。
  Future<void> playQueueIndex(int index) async {
    await _playIndex(index);
  }

  Future<void> _playIndex(int index, {bool recordHistory = true}) async {
    if (index < 0 || index >= _queue.length) return;
    // 预取与边播边缓存不能双写同一缓存文件：起播前取消未完成的预取。
    _nextTrackPreloader?.cancelPending();
    // 上一首的后台缓存写入（桌面）同理：切歌即停，避免与新曲目抢带宽。
    _cacheWriter?.cancel();
    // 切到不同曲目时把「离开的当前曲目」压入播放顺序；显式回退不重复压栈。
    if (recordHistory && _currentTrack != null && _currentIndex != index) {
      _order.record(_currentIndex);
    }
    final requestId = ++_playRequestId;
    final track = _queue[index];

    _currentIndex = index;
    _currentTrack = track;
    _isLoading = true;
    _lastError = null;
    _position = Duration.zero;
    _duration = track.duration ?? Duration.zero;
    notifyListeners();

    try {
      final preferred = _preferredQuality?.call();
      final quality = preferred == null ? null : track.pickQuality(preferred);
      final url = await _resolver(track, quality: quality);
      if (requestId != _playRequestId) return;

      await _setAudioSourceWithCache(Uri.parse(url), track, quality: quality);
      if (requestId != _playRequestId) return;

      // 播放侧没有写缓存（平台不支持边播边缓存 / 后端拒绝后退到直接流播）：
      // 由后台字节下载补上缓存——重播经 `localUriFor` 命中 file://。
      if (!_platformSupportsAudioCaching || _audioCacheUnsupported) {
        final writer = _cacheWriter;
        if (writer != null) {
          unawaited(writer.start(track, url: url, quality: quality));
        }
      }

      _duration = _player.duration ?? track.duration ?? Duration.zero;
      // 播放启动后立即返回：just_audio 的 play() Future 在「播完/暂停」才
      // 完成，挂在这里会拖住调用方（自动切歌完成处理器）并吞掉后续
      // completed 事件；启动失败单独捕获进 lastError。
      unawaited(_player.play().catchError((Object e) {
        if (requestId == _playRequestId) {
          _lastError = e.toString();
          _isPlaying = false;
          notifyListeners();
        }
      }));
      // 当前曲目已起播：后台预载下一首（直链 + 音频缓存；歌词/封面由
      // 各自链路从播放快照统一触发）。此刻不会与当前取链抢 LX 引擎。
      unawaited(_nextTrackPreloader?.preload(nextSourceTrack));
    } catch (e) {
      if (requestId != _playRequestId) return;
      _lastError = e.toString();
      _isPlaying = false;
      debugPrint('[LocalPlayback] 播放失败: $e');
    } finally {
      if (requestId == _playRequestId) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 设置音频源：优先边播边缓存（策略开启时），失败回退直接流播。
  ///
  /// 缓存不能影响播放可用性：平台不支持、目录解析失败、网络异常都会
  /// 回退到 `AudioSource.uri`，仅记录日志。
  Future<void> _setAudioSourceWithCache(
    Uri uri,
    SourceTrack track, {
    String? quality,
  }) async {
    final cache = _cacheService;
    final cacheable = _platformSupportsAudioCaching &&
        !_audioCacheUnsupported &&
        cache != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        !uri.path.toLowerCase().endsWith('.m3u8');

    if (cacheable) {
      try {
        if (await cache.audioEnabled()) {
          final directory = await cache.audioCacheDirPath();
          if (directory != null) {
            final fileName = AudioCacheStore.keyForSource(
              track,
              quality: quality ?? '',
            );
            final source = createCachingAudioSource(
              uri,
              audioCacheFilePath(directory, fileName),
            );
            if (source != null) {
              try {
                await _player
                    .setAudioSource(source)
                    .timeout(const Duration(seconds: 30));
                // 写入开始后执行一次 LRU 淘汰（策略上限）。
                unawaited(cache.enforceAudioLimit());
                return;
              } on UnsupportedError catch (e) {
                // 防御性兜底：平台后端不支持 StreamAudioSource 时本会话停用。
                _audioCacheUnsupported = true;
                debugPrint('[LocalPlayback] 平台不支持音频缓存，改用直接流播: $e');
              } catch (e) {
                debugPrint('[LocalPlayback] 音频缓存源失败，回退直接流播: $e');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[LocalPlayback] 音频缓存初始化失败，回退直接流播: $e');
      }
    }

    await _player
        .setAudioSource(AudioSource.uri(uri))
        .timeout(const Duration(seconds: 30));
  }

  /// 是否尝试边播边缓存：仅 Android / iOS / macOS（见 [platformSupportsAudioCaching]）。
  bool get _platformSupportsAudioCaching => platformSupportsAudioCaching();

  /// 暂停播放（音频焦点被其他应用夺走等外部触发）。
  ///
  /// 与 [toggle] 的暂停分支同语义：无曲目 / 已暂停时无操作（幂等——中断事件
  /// 可能连续到达，重复调用不叠加副作用）。
  Future<void> pause() async {
    if (_currentTrack == null) return;
    if (_player.playing) {
      await _player.pause();
    }
  }

  Future<void> toggle() async {
    if (_currentTrack == null) return;
    if (_player.playing) {
      await pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _seekPlayer(Duration.zero);
      }
      unawaited(_player.play().catchError((Object e) {
        _lastError = e.toString();
        _isPlaying = false;
        notifyListeners();
      }));
    }
  }

  Future<void> seek(Duration position) async {
    if (_currentTrack == null) return;
    await _seekPlayer(position);
  }

  /// 真实位置跳转的唯一入口：跳转后版本号自增并立即对齐进度，媒体会话
  /// 据此补发 state。
  ///
  /// 内部回跳（单曲循环 / 队列只有一首的重播 / 无下一首归零）也走这里：
  /// 它们同样是位置不连续；只靠后台 1s 轮询会让通知按旧锚点插值一整首。
  Future<void> _seekPlayer(Duration position) async {
    await _player.seek(position);
    _seekRevision++;
    _position = position;
    _scheduleNotify();
  }

  /// 应用内音量（0..1；直接读播放器，构造默认 1.0）。
  double get volume => _player.volume;

  /// 设置应用内音量：clamp 0..1 后直达 [AudioPlayer]（桌面 media_kit 后端
  /// 与移动端共用同一播放器，无需分支）；失败向上抛，由调用方兜底。
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  Future<void> skipToNext() async {
    // 手动切歌与界面预览同源：shuffle 走洗牌排列的下一首（本轮末尾自动
    // 重洗新一轮）；单曲循环下手动切歌走队列下一位（只有自动播完才重播）。
    final index = _commitNextIndex(auto: false);
    if (index < 0) {
      await _player.pause();
      await _seekPlayer(Duration.zero);
      return;
    }
    await _playIndex(index);
  }

  Future<void> skipToPrevious() async {
    if (_currentTrack == null || _queue.isEmpty) return;
    // 永远切上一首：滑动/按钮/耳机键同一语义，不做「>3 秒重播本曲」。
    // 有播放顺序（含 shuffle）消费最近一首；否则回退到队列前一位
    // （列表循环队首回绕到队尾）。
    final previous = _order.popPrevious() ??
        previousQueueIndex(
          _currentIndex,
          _queue.length,
          wrap: _mode == PlayMode.listLoop,
        ) ??
        0;
    await _playIndex(previous, recordHistory: false);
  }

  Future<void> setMode(PlayMode mode) async {
    final changed = _mode != mode;
    _mode = mode;
    if (changed) {
      if (mode == PlayMode.shuffle && _queue.isNotEmpty) {
        // 以当前曲目置首重洗：切到随机模式不会立刻跳走正在播放的曲目。
        _shuffleOrder.reset(
          _queue.length,
          startIndex: _currentIndex >= 0 ? _currentIndex : 0,
        );
      } else if (mode != PlayMode.shuffle) {
        _shuffleOrder.clear();
      }
    }
    notifyListeners();
  }

  Future<void> toggleMode() async {
    await setMode(_mode.next);
  }

  /// 停止本地播放并清空状态。
  Future<void> stop({bool clear = true}) async {
    _playRequestId++;
    _stopAfterCurrentTrack = false;
    _nextTrackPreloader?.cancelPending();
    _cacheWriter?.cancel();
    try {
      await _player.stop();
    } catch (_) {}
    _isPlaying = false;
    if (clear) {
      _queue.clear();
      _queueRevision++;
      _currentIndex = -1;
      _currentTrack = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _contextName = null;
      _order.clear();
      _shuffleOrder.clear();
    }
    notifyListeners();
  }

  /// 执行用的下一首下标（自动播完 / 手动切歌共用）：shuffle 走排列，
  /// 轮末重洗；线性模式由 [nextQueueIndex] 决定是否在队尾回绕。
  ///
  /// 与快照的 peek（[queueProjection]）刻意分开：peek 不重洗、轮末返回
  /// null，commit 才推进轮次。
  int _commitNextIndex({required bool auto}) {
    if (_queue.isEmpty) return -1;
    if (_mode == PlayMode.singleRepeat && auto) {
      return _currentIndex;
    }
    if (_mode == PlayMode.shuffle) {
      if (_queue.length == 1) return _currentIndex;
      _ensureShuffleOrder();
      return _shuffleOrder.next(_currentIndex);
    }
    return nextQueueIndex(
          _currentIndex,
          _queue.length,
          wrap: _mode == PlayMode.listLoop,
        ) ??
        -1;
  }

  /// shuffle 排列缺失时按当前曲目置首补齐（正常路径在 playTracks/setMode
  /// 已重置；这里兜底，避免读到空排列）。
  void _ensureShuffleOrder() {
    if (_queue.isEmpty || _shuffleOrder.isEmpty) {
      _shuffleOrder.reset(
        _queue.length,
        startIndex: _currentIndex >= 0 ? _currentIndex : 0,
      );
    }
  }

  void _onPlayerState(PlayerState state) {
    _isPlaying =
        state.playing && state.processingState != ProcessingState.completed;
    // 播放态变化可能改变采样档位（后台暂停 → 停采样；后台续播 → 1s Timer；
    // 前台始终高频流，这里是无操作）。
    _syncPositionSampling();
    if (state.processingState == ProcessingState.completed) {
      _handleTrackCompleted();
    }
    notifyListeners();
  }

  bool _handlingCompletion = false;

  Future<void> _handleTrackCompleted() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      // 先捕获并清除一次性标志：完成事件的监听器可能同步调用
      // setStopAfterCurrentTrack(false)，不能让这次回调影响本次判定。
      final stopAfterCurrent = _stopAfterCurrentTrack;
      _stopAfterCurrentTrack = false;
      final completed = _currentTrack;
      if (completed != null && !_trackCompletions.isClosed) {
        _trackCompletions.add(completed);
      }
      if (stopAfterCurrent) {
        // 曲末停在当前曲目，不自动切歌；位置流可能停在半途，这里对齐到
        // 曲末，通知栏 / 播放页不会显示一个半截进度。
        if (_duration > Duration.zero) _position = _duration;
        try {
          await _player.pause();
        } catch (e) {
          debugPrint('[LocalPlayback] 播完当前曲目后暂停失败: $e');
        }
        _isPlaying = false;
        notifyListeners();
        return;
      }
      if (_mode == PlayMode.singleRepeat) {
        await _seekPlayer(Duration.zero);
        _resumeCurrentTrack();
      } else {
        final index = _commitNextIndex(auto: true);
        if (index < 0) {
          _isPlaying = false;
          notifyListeners();
        } else if (index == _currentIndex) {
          // 列表循环 / 随机只有一首歌：下一首就是自己，按重播处理。
          await _seekPlayer(Duration.zero);
          _resumeCurrentTrack();
        } else {
          await _playIndex(index);
        }
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  /// 续播当前曲目（单曲循环重播）：与 `_playIndex` 一致，不等待整曲播完。
  void _resumeCurrentTrack() {
    unawaited(_player.play().catchError((Object e) {
      _lastError = e.toString();
      _isPlaying = false;
      notifyListeners();
    }));
  }

  void _scheduleNotify() {
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyThrottle?.cancel();
    _notifyThrottle = Timer(const Duration(milliseconds: 400), () {
      _notifyPending = false;
      notifyListeners();
    });
  }

  /// 退出前的音频收尾：先暂停让设备停止出数据，再释放播放器
  /// （media_kit 的 `dispose()` 内部会先 stop，关闭音频输出）。
  ///
  /// 为什么需要：进程直接退出时 libmpv / WASAPI 仍在出数据，Windows 上听感是
  /// 「突然断掉 / 爆一声」；强杀不经过收尾反而听不出来。100ms 是留给已排队的
  /// 设备缓冲排空的时间，不参与任何 UI 交互。
  ///
  /// 幂等；失败只记日志：退出流程不能卡在音频设备上（调用方另有超时兜底）。
  Future<void> shutdownAudioForQuit() async {
    if (_playerDisposed) return;
    _playerDisposed = true;
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[LocalPlayback] 退出前暂停失败: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      await _player.dispose();
    } catch (e) {
      debugPrint('[LocalPlayback] 退出前释放播放器失败: $e');
    }
  }

  @override
  void dispose() {
    _playRequestId++;
    _stopAfterCurrentTrack = false;
    _powerPolicy.removeListener(_syncPositionSampling);
    _stopPositionSampleTimer();
    _notifyThrottle?.cancel();
    _playerStateSubscription?.cancel();
    _cancelPositionSubscription();
    _cacheWriter?.cancel();
    unawaited(_trackCompletions.close());
    final guard = _focusGuard;
    if (guard != null) unawaited(guard.detach());
    if (!_playerDisposed) {
      _playerDisposed = true;
      _player.dispose();
    }
    super.dispose();
  }
}
