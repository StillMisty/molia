import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../app/perf/playback_start_trace.dart';
import '../domain/ports/music_source.dart' show PlayableStream;
import '../models/play_mode.dart';
import '../services/audio_cache_platform.dart';
import '../services/audio_cache_store.dart';
import '../services/cache_service.dart';
import '../sources/source_track.dart';
import 'audio_cache_source.dart';
import 'audio_focus_guard.dart';
import 'audio_focus_policy.dart';
import 'audio_output_policy.dart';
import 'fade_envelope.dart';
import 'next_track_preloader.dart';
import 'playback_order.dart';
import 'playback_power_policy.dart';
import 'playing_track_cache_writer.dart';
import 'queue_edit_policy.dart';
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

/// 未注入设置时的默认策略：与其他应用同时播放（新默认行为）。
class _AlwaysPlayWithOtherApps implements ValueListenable<bool> {
  const _AlwaysPlayWithOtherApps();

  @override
  bool get value => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

const ValueListenable<bool> _alwaysPlayWithOtherApps =
    _AlwaysPlayWithOtherApps();

/// 将音源曲目解析为可播放流的回调（由播放组合根提供）。
///
/// 返回 [PlayableStream] 而不是 URL：B 站等平台的直链需要 `Referer` / `UA`，
/// 请求头要透传到播放器、边播边缓存与后台缓存写入。
typedef SourceStreamResolver = Future<PlayableStream> Function(
  SourceTrack track, {
  String? quality,
});

/// 本地播放服务：音源取链后由 App 直接播放。
///
/// 对外输出 `SourceTrack` 曲目结构，现有 NowPlaying / 队列 / 歌词等界面
/// 无需感知播放后端差异。
class LocalPlaybackService extends ChangeNotifier {
  final SourceStreamResolver _resolver;

  /// just_audio 播放器。队列替换 / 显式停止时可换新实例，回收旧实例里
  /// 按 source 累积的注册表（`_audioSources` / 代理 handler 只在 dispose
  /// 时清空，见 just_audio 0.10.x）。
  AudioPlayer _player;

  /// 生产环境创建新播放器的入口；测试注入固定 [player] 时为 null，不回收。
  final AudioPlayer Function()? _playerFactory;

  /// 当前播放器已创建过多少个 audio source（近似 just_audio 注册表大小）。
  int _sourceRegistrations = 0;

  /// 播放器回收进行中的 Future：双击换队列 / 换队列同时 stop 时只回收一次。
  Future<void>? _playerRecycleFuture;

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
  /// 本服务只用它决定位置采样节拍；下一首字节预取由 `NextTrackPreloader`
  /// 消费同一实例，封面预取 / 取色由 `PlaybackObserver` / `ArtworkThemeSync`
  /// 各自按同一策略判定。
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

  /// 耳机拔出事件流（audio_session 的 `becomingNoisyEventStream`）。
  ///
  /// 同样只给测试注入；生产从会话取。just_audio 的内建中断处理被关闭后，
  /// 这个原本由它负责的「拔耳机即暂停」必须在服务里补上。
  final Stream<void>? _becomingNoisyOverride;

  /// 输出设备增删事件流（audio_session 的 `devicesChangedEventStream`）。
  ///
  /// 为什么需要它：audio_session 的 noisy receiver 只在持有音频焦点时注册，
  /// 永久失焦（开了「与其他应用同时播放」后很常见）会被插件反注册，此后
  /// 拔线 / 蓝牙断链收不到 `becomingNoisyEventStream`。设备回调不依赖焦点，
  /// 作为「换输出路由必须暂停」的兜底；测试注入假流，生产从会话取。
  final Stream<AudioDevicesChangedEvent>? _audioDevicesOverride;

  /// 「与其他应用同时播放」偏好（设置 › 播放，默认开）。
  ///
  /// 事件到达时读当前值，开关切换即时生效；同时作为会话配置的变更信号
  /// （iOS / macOS 需要切换 `mixWithOthers`）。
  final ValueListenable<bool> _playWithOtherApps;

  /// 音频焦点守卫（其他应用出声 → [pause]），[_configureAudioSession] 内装配。
  AudioFocusGuard? _focusGuard;

  StreamSubscription<void>? _becomingNoisySubscription;
  StreamSubscription<AudioDevicesChangedEvent>? _audioDevicesSubscription;

  final List<SourceTrack> _queue = [];
  int _currentIndex = -1;
  SourceTrack? _currentTrack;
  String? _contextName;
  PlayMode _mode = PlayMode.listLoop;

  /// 用户音量（0..1）的**服务内副本**，只用于淡变乘法。
  ///
  /// 用户音量的所有者仍是 provider（持久化 / 静音 / UI 都读它）；这里不
  /// 持久化、不暴露第二套音量 API，[volume] 也只回报这个基值。
  double _baseVolume = 1.0;

  /// 当前包络倍数（0..1）；播放器实际音量 = 基值 × 包络。
  double _envelope = 1.0;

  /// 用户暂停 / 播放淡变时长；[Duration.zero] = 关闭。
  Duration _fadeDuration;

  /// 上一次真正写给播放器的音量：避免轨切换时重复写同一个值。
  double _lastWrittenVolume = 1.0;

  /// 串行化平台音量写入；中间步骤在途时允许跳过，最终值一定排队写出。
  Future<void> _volumeWriteTail = Future<void>.value();
  int _volumeWritesInFlight = 0;

  Timer? _fadeTimer;
  Completer<bool>? _fadeCompleter;

  /// 睡眠定时专用淡出进行中：用户暂停 / 取消时要能单独撤销它。
  bool _sleepFadeActive = false;

  /// 暂停淡出进行中：此刻 `_isPlaying` 仍为 true，但用户最新意图是暂停。
  /// 快速点「播放」要能反向淡入，而不是再暂停一次。
  bool _pauseIntentPending = false;

  /// 智能随机开关与最近听过证据（组合根注入只读快照；null = 均匀洗牌）。
  bool _smartShuffleEnabled;
  final Future<Set<String>> Function()? _recentTrackIds;
  Set<String> _cachedRecentTrackIds = const {};

  /// 当前曲目本次播放选用的音质（解析请求值；null = 尚未取链）。
  String? _currentQuality;

  /// 用户手动选择的音质：按曲目 id 记住，自动重试仍用同一档位；
  /// 切歌后自然回到偏好音质（不写入会话）。
  String? _qualityOverride;
  String? _qualityOverrideTrackId;

  /// 切换音质期间抑制播放器位置回写：新源 `setAudioSource` 会先报 0，
  /// 不能让它把进度闪回 0 或让会话落盘成 0。
  bool _suppressPositionUpdates = false;

  /// 队列内容版本号：任何队列变更（装载 / 追加 / 原地替换 / 补图 / 清空）
  /// 自增。O(1) 的「队列是否真的变了」判定（位置 tick 不算变更）；
  /// `PlaybackEngine` 用它判断能否复用队列的领域 `Track` 映射。
  int _queueRevision = 0;

  /// 队列内容版本号（每次队列内容变更自增；位置 / 播放态变化不变）。
  ///
  /// 快照重建可能由位置 tick 触发而队列未变，消费方（播放后端）据此
  /// 复用上一份队列映射，避免每次通知都重跑全队列转换。
  int get queueRevision => _queueRevision;

  /// 播放顺序栈的内容版本：快照投影缓存键的一部分。
  ///
  /// 位置 tick 不会改它；只有真实切歌 / 回退 / 队列重映射才变。
  int get playbackOrderRevision => _order.revision;

  /// 洗牌排列的内容版本：快照投影缓存键的一部分（轮末重洗也会自增）。
  int get shuffleOrderRevision => _shuffleOrder.revision;

  /// 当前这一轮是否按「少放最近听过的」权重生成（测试 / 诊断用）。
  bool get shuffleRoundWeighted => _shuffleOrder.isWeightedRound;

  /// 已播放顺序（最近一首在后，栈顶供 previous 弹出）；存队列下标，
  /// 队列仅在 `playTracks` 时整体替换并同步清空。
  final PlaybackOrder _order = PlaybackOrder();

  /// shuffle 播放顺序：队列下标的随机排列（每轮每首恰好一次，轮末自动重洗）。
  final PlaybackShuffleOrder _shuffleOrder;

  bool _isPlaying = false;
  bool _isLoading = false;

  /// 旧源已停、新源尚未落位（手动切歌卸载后的空窗）。
  ///
  /// just_audio 的 [AudioPlayer.stop] 会保留当前 audio source：这个窗口里
  /// 直接 `play()` 会把停掉的旧曲目重新拉起来（界面却已经显示新曲目）。
  /// 装载中忽略播放键；装载失败后按当前曲目重新取链。
  bool _sourceUnloaded = false;

  /// 上一次播放器处理状态：完成处理只在「进入 completed」时触发一次。
  ///
  /// 播完后 playing 仍可能为 true，暂停 / seek 会再次上报 completed；按
  /// 状态跳变去重，避免重复发完成事件（定时关闭 / 自动切歌被触发两次）。
  ProcessingState _lastProcessingState = ProcessingState.idle;

  /// 上一次可用于「曲末兜底」的位置采样（仅桌面 media_kit）。
  ///
  /// Windows/Linux 的 media_kit 自然播完时可能不上报 completed：mpv 停在
  /// EOF、processingState 仍是 ready、just_audio 的 playing 也还是 true，
  /// 位置被插值钳在时长上。位置流每 ~200ms 采样一次，连续两次都停在同一个
  /// 末位即视为播完（见已知坑 78）；正常播放位置一直前进，不会命中。
  Duration? _lastEndPositionSample;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _lastError;

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<PlayerException>? _errorSubscription;
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

  static AudioPlayer _newAudioPlayer() =>
      AudioPlayer(handleInterruptions: false);

  LocalPlaybackService({
    required this._resolver,
    CacheService? cacheService,
    this._preferredQuality,
    math.Random? random,
    this._nextTrackPreloader,
    PlayingTrackCacheWriter? audioCacheWriter,
    Stream<AudioInterruptionEvent>? audioInterruptions,
    Stream<void>? audioBecomingNoisy,
    Stream<AudioDevicesChangedEvent>? audioDevicesChanged,
    ValueListenable<bool>? playWithOtherApps,
    PlaybackPowerPolicy? powerPolicy,
    // 组合根注入的「最近听过」只读证据；只有播放层拿到的 Set，没有统计 /
    // 历史服务。缺省（测试 / 无证据）走均匀洗牌。
    Future<Set<String>> Function()? recentTrackIds,
    // 与设置默认值同源：偏好加载前播放已经是正确手感。
    Duration fadeDuration = const Duration(milliseconds: 200),
    bool smartShuffleEnabled = true,
    // 单测注入假播放器（生产不传，内部创建 just_audio 播放器）。
    @visibleForTesting AudioPlayer? player,
    // 单测注入「换队列时创建新播放器」的工厂；生产缺省为真实播放器。
    AudioPlayer Function()? playerFactory,
  }) : _player = player ?? (playerFactory ?? _newAudioPlayer)(),
       _playerFactory = player == null
           ? (playerFactory ?? _newAudioPlayer)
           : null,
       _cacheService = cacheService ?? CacheService.instance,
       _cacheWriter = audioCacheWriter,
       _interruptionsOverride = audioInterruptions,
       _becomingNoisyOverride = audioBecomingNoisy,
       _audioDevicesOverride = audioDevicesChanged,
       _playWithOtherApps = playWithOtherApps ?? _alwaysPlayWithOtherApps,
       _powerPolicy = powerPolicy ?? PlaybackPowerPolicy(),
       // ignore: prefer_initializing_formals
       _recentTrackIds = recentTrackIds,
       // ignore: prefer_initializing_formals
       _fadeDuration = fadeDuration,
       // ignore: prefer_initializing_formals
       _smartShuffleEnabled = smartShuffleEnabled,
       _shuffleOrder = PlaybackShuffleOrder(random: random) {
    _playerStateSubscription = _player.playerStateStream.listen(_onPlayerState);
    _playWithOtherApps.addListener(_onPlayWithOtherAppsChanged);
    // 曲末解码错误也要收：源文件最后一帧损坏时不会走 completed，见
    // [_onPlayerError] / 已知坑 78。
    _errorSubscription = _player.errorStream.listen(_onPlayerError);
    // 位置采样按前后台策略选择（前台 / 桌面歌词 = 高频流；后台播放 = 1s
    // 轮询；后台暂停 = 不采样），切换时先取消旧订阅 / Timer。
    _powerPolicy.addListener(_syncPositionSampling);
    _syncPositionSampling();
    // 配置系统音频会话（音乐类型）：iOS 后台播放、Android 音频焦点/duck，
    // 并按「与其他应用同时播放」接入中断 / 耳机拔出 / 输出设备变化。不阻塞
    // 构造；不支持的平台内部跳过。
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
        _positionSubscription ??= _player.positionStream.listen(
          _onPlayerPosition,
        );
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
    if (_suppressPositionUpdates) return;
    _position = position;
    // 位置首次前进 = 解码时钟真的在走（起播埋点的「首声」代理）。
    if (position > Duration.zero) PlaybackStartTrace.firstProgress();
    _maybeCompleteFromPosition(position);
    _scheduleNotify();
  }

  /// 后台 1s 轮询：值没变不发通知（暂停 / 缓冲时避免空转唤醒 UI）。
  void _pollPlayerPosition() {
    if (_suppressPositionUpdates) return;
    final position = _player.position;
    // 曲末兜底要先于「值没变」短路：播完后位置本来就不再变化。
    _maybeCompleteFromPosition(position);
    if (position == _position) return;
    _position = position;
    if (position > Duration.zero) PlaybackStartTrace.firstProgress();
    _scheduleNotify();
  }

  /// 是否走桌面 media_kit 后端（just_audio_media_kit 只在 Windows/Linux 接管；
  /// macOS 走 just_audio 原生 AVPlayer）。
  static bool get _usesMediaKitBackend =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// 曲末兜底：桌面 media_kit 自然播完可能不上报 completed。
  ///
  /// 现象（Windows）：mpv 到达 EOF 后停在 keep-open 状态，
  /// `just_audio_media_kit` 没有把 EOF 变成 `ProcessingState.completed`；
  /// just_audio 的 playing 请求态仍是 true，位置被插值钳在时长上——界面停在
  /// 旧歌末尾、也不会自动切歌。位置流连续两次采样都停在同一个末位即判定
  /// 播完，复用同一条完成链路（`trackCompletions` / 定时关闭 / 自动下一首）。
  ///
  /// 只对桌面后端生效：Android/iOS 的 completed 可靠，不靠位置猜测。用户主动
  /// 暂停时 `playing == false`，不会命中；seek 会清空采样（[_seekPlayer]）。
  void _maybeCompleteFromPosition(Duration position) {
    if (!_usesMediaKitBackend) return;
    if (!_player.playing || _player.processingState != ProcessingState.ready) {
      _lastEndPositionSample = null;
      return;
    }
    if (_handlingCompletion || _isLoading || _currentTrack == null) {
      _lastEndPositionSample = null;
      return;
    }
    final duration = _player.duration ?? _duration;
    if (duration <= _trackEndTolerance) return;
    final previous = _lastEndPositionSample;
    _lastEndPositionSample = position;
    if (position < duration - _trackEndTolerance) return;
    // 必须是「位置停在同一个末位」而不是「两次都落在最后 250ms」：正常播放
    // 末尾两次采样仍会前进，按容差判会提前切掉最后半秒。
    if (previous == null || previous != position) return;
    _lastEndPositionSample = null;
    debugPrint('[LocalPlayback] 媒体库未上报 completed，按曲末位置兜底切歌');
    _handleTrackCompleted();
  }

  /// 是否有 audio_session 插件实现（Linux/Windows 没有）。
  bool get _usesAudioSession =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// 当前偏好对应的音乐会话配置（平台差异见 `audio_focus_policy.dart`）。
  AudioSessionConfiguration get _sessionConfiguration =>
      audioSessionConfigurationFor(
        playWithOtherApps: _playWithOtherApps.value,
        platform: defaultTargetPlatform,
      );

  /// 配置 audio_session + 装配音频焦点 / 耳机拔出 / 输出设备监听。
  ///
  /// 注入假流（测试）时只走守卫接线，不触碰插件通道；Linux/Windows 没有
  /// audio_session 实现，按平台跳过，保持桌面端现状。
  Future<void> _configureAudioSession() async {
    final injectedInterruptions = _interruptionsOverride;
    final injectedNoisy = _becomingNoisyOverride;
    final injectedDevices = _audioDevicesOverride;
    if (injectedInterruptions != null ||
        injectedNoisy != null ||
        injectedDevices != null) {
      if (injectedInterruptions != null) {
        _attachFocusGuard(injectedInterruptions);
      }
      if (injectedNoisy != null) {
        _attachBecomingNoisy(injectedNoisy);
      }
      if (injectedDevices != null) {
        _attachDeviceChanges(injectedDevices);
      }
      return;
    }
    if (!_usesAudioSession) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(_sessionConfiguration);
      _attachFocusGuard(session.interruptionEventStream);
      _attachBecomingNoisy(session.becomingNoisyEventStream);
      _attachDeviceChanges(session.devicesChangedEventStream);
    } catch (e) {
      debugPrint('[LocalPlayback] 音频会话配置失败: $e');
    }
  }

  /// 设置切换后重新应用会话配置（iOS / macOS 的 `mixWithOthers`）。
  Future<void> _reconfigureAudioSession() async {
    if (_interruptionsOverride != null ||
        _becomingNoisyOverride != null ||
        _audioDevicesOverride != null) {
      return;
    }
    if (!_usesAudioSession) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(_sessionConfiguration);
    } catch (e) {
      debugPrint('[LocalPlayback] 音频会话重新配置失败: $e');
    }
  }

  void _onPlayWithOtherAppsChanged() {
    unawaited(_reconfigureAudioSession());
  }

  /// 装配音频焦点守卫：其他应用夺走焦点时按设置暂停（语义见 [AudioFocusGuard]）。
  void _attachFocusGuard(Stream<AudioInterruptionEvent> interruptions) {
    final guard = _focusGuard ??= AudioFocusGuard(
      shouldPause: () => shouldPauseForAudioFocus(
        playWithOtherApps: _playWithOtherApps.value,
        platform: defaultTargetPlatform,
      ),
      // fromInterruption 不取消自身登记的「待续播」。
      onFocusLoss: () => pause(fromInterruption: true),
      onFocusGain: _resumeAfterAudioFocus,
    );
    guard.attach(interruptions);
  }

  /// 耳机拔出（becoming noisy）始终立即暂停：just_audio 的内建处理已关闭，
  /// 不补这一条会让外放突然出声；安全优先，不等淡变。
  void _attachBecomingNoisy(Stream<void> events) {
    unawaited(_becomingNoisySubscription?.cancel());
    _becomingNoisySubscription = events.listen(
      (_) => unawaited(pause(urgent: true)),
      onError: (Object e) => debugPrint('[LocalPlayback] 耳机拔出事件失败: $e'),
    );
  }

  /// 输出设备断开始终暂停（与「与其他应用同时播放」无关）。
  ///
  /// 与 becoming noisy 互补：接收器可能因失焦被反注册，而设备回调没有这个
  /// 生命周期限制。判定规则见 [shouldPauseForDeviceRemoval]。
  void _attachDeviceChanges(Stream<AudioDevicesChangedEvent> events) {
    unawaited(_audioDevicesSubscription?.cancel());
    _audioDevicesSubscription = events.listen((event) {
      if (!shouldPauseForDeviceRemoval(event.devicesRemoved)) return;
      // 输出设备消失同理：立即停，不为了听感多放 200ms。
      unawaited(pause(urgent: true));
    }, onError: (Object e) => debugPrint('[LocalPlayback] 音频设备变化失败: $e'));
  }

  /// 焦点归还后的续播（只在守卫确认「本次中断由它暂停」时调用）。
  Future<void> _resumeAfterAudioFocus() async {
    // 切歌卸载后的空窗 / 装载中不能续播：`play()` 会把停掉的旧源拉起来。
    if (_playerDisposed ||
        _currentTrack == null ||
        _player.playing ||
        _isLoading ||
        _sourceUnloaded) {
      return;
    }
    // 急停之后重新出声同样走淡入：焦点归还属于「恢复播放」。
    _resumeCurrentTrack(fadeIn: true);
  }

  bool get hasTrack => _currentTrack != null;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  PlayMode get mode => _mode;
  String? get lastError => _lastError;
  SourceTrack? get currentSourceTrack => _currentTrack;

  /// 当前曲目本次播放选用的音质（`PlaybackEngine` 快照用）。
  String? get currentQuality => _currentQuality;

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

  /// 队列投影：快照的 next / previous / previousOfPrevious / upNext 唯一推导
  /// （纯函数在 `queue_projection.dart`；恢复态共用同一实现）。
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
        shuffleIndices: _mode == PlayMode.shuffle
            ? _shuffleOrder.indices
            : null,
        previousIndex: _order.peekPrevious(),
        previousOfPreviousIndex: _order.peekPreviousOfPrevious(),
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

  /// 曲末判定容差：播放器位置与时长有采样 / 浮点误差，留出极小余量；
  /// 不能放大到「还剩半秒也算播完」，否则会误把正常的末尾续播当成重播。
  static const Duration _trackEndTolerance = Duration(milliseconds: 250);

  /// 曲末解码错误的判定窗口：源文件最后一帧损坏时，mpv 会在距曲末不到
  /// 1s 处报错并释放播放器（processingState → idle），completed 不会到达，
  /// 位置采样也可能停在错误前。窗口内按「已播完」处理，窗口外才算真故障。
  static const Duration _trackEndErrorWindow = Duration(seconds: 3);

  /// 是否已到曲末（可安全地从头重播）。
  ///
  /// 不能只看 [ProcessingState.completed]：Windows/Linux 的
  /// just_audio_media_kit 在暂停中途到达 EOF 时，media_kit 的 pause 会关闭
  /// 播放态广播，`completed` 事件不会上报；此时 processingState 仍是 ready，
  /// 只有位置停在曲末。直接 play() 在 EOF 不会重新出声，表现为最后一秒
  /// 暂停后再点播放没反应。
  bool get _isAtTrackEnd {
    if (_player.processingState == ProcessingState.completed) return true;
    final duration = _player.duration ?? _duration;
    if (duration <= Duration.zero) return false;
    return _player.position >= duration - _trackEndTolerance;
  }

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

  /// 只更新队列中同 id 曲目的元数据（标题等），不重新取链。
  ///
  /// 与 [replaceQueueTrack] 的区别：当前曲目也**不**重载播放器，只替换
  /// 队列 / 当前曲目对象并通知一次，播放进度与音频源保持不变。
  Future<void> updateQueueTrackMetadata(
    String trackId,
    SourceTrack track,
  ) async {
    var hit = false;
    for (var index = 0; index < _queue.length; index++) {
      if (_queue[index].id != trackId) continue;
      _queue[index] = track;
      if (index == _currentIndex) _currentTrack = track;
      hit = true;
    }
    if (!hit) return;
    _queueRevision++;
    notifyListeners();
  }

  /// 换队列 / 显式停止时回收 just_audio 播放器。
  ///
  /// just_audio 0.10.x 把每个 `setAudioSource` 创建的 source 保存在
  /// `AudioPlayer._audioSources`，代理 server 的 handler 也只在 dispose
  /// 时清空；我们长期复用同一个 player，所以播放过的曲目会随队列累积。
  /// 在「队列整体替换 / 停止播放」这种天然断点重建 player，把旧注册表
  /// 一次交还；正在播放的曲目会被新队列重新加载，暂停态不会被重建。
  ///
  /// 单测注入固定 player 时 [_playerFactory] 为 null，不执行（保持测试
  /// 对同一 fake 的断言）。
  Future<void> _recyclePlayerForQueueChange() {
    final existing = _playerRecycleFuture;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _recyclePlayerNow().whenComplete(() {
      if (identical(_playerRecycleFuture, future)) {
        _playerRecycleFuture = null;
      }
    });
    _playerRecycleFuture = future;
    return future;
  }

  Future<void> _recyclePlayerNow() async {
    final factory = _playerFactory;
    if (factory == null || _playerDisposed || _sourceRegistrations == 0) {
      return;
    }
    final old = _player;
    // 用基值而不是当前播放器音量：回收可能落在淡出中途，新播放器必须
    // 回到用户实际设置的音量。
    final volume = _baseVolume;
    _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _errorSubscription?.cancel();
    _errorSubscription = null;
    _cancelPositionSubscription();
    _stopPositionSampleTimer();
    try {
      await old.pause();
    } catch (_) {}
    try {
      await old.dispose();
    } catch (_) {}
    // 回收期间应用退出：不要给已 dispose 的 service 再挂一个新播放器。
    if (_playerDisposed) return;
    _player = factory();
    _playerStateSubscription = _player.playerStateStream.listen(_onPlayerState);
    _errorSubscription = _player.errorStream.listen(_onPlayerError);
    try {
      await _player.setVolume(volume);
    } catch (_) {}
    _envelope = 1.0;
    _lastWrittenVolume = volume;
    _lastProcessingState = ProcessingState.idle;
    _sourceRegistrations = 0;
    _syncPositionSampling();
  }

  /// 托盘内暂停稳定后释放播放器 / audio source（内存守卫在暂停托盘时调用）。
  ///
  /// 暂停态的 just_audio / media_kit 仍持有当前 source 与解码缓冲；释放
  /// player 后由下一次播放按保存进度重新取链。只在已暂停、未加载且生产
  /// factory 可用时执行；恢复播放走 [toggle] 的 `_sourceUnloaded` 分支。
  Future<void> releasePlayerForIdle() async {
    if (_playerDisposed ||
        _isPlaying ||
        _isLoading ||
        _playerFactory == null ||
        _sourceRegistrations == 0) {
      return;
    }
    await _recyclePlayerForQueueChange();
    if (_currentTrack != null) _sourceUnloaded = true;
    notifyListeners();
  }

  /// 装载新队列并从 [index] 起播。
  ///
  /// [shuffleIndices] 是恢复态展示过的本轮洗牌排列（[PlaybackRequest] 透传）：
  /// 恢复快照的 next / upNext 已按它渲染，后端必须沿用同一份，否则接管瞬间
  /// 「下一首」会换人，播放页右槽触发 180ms 槽位淡化。非法 / 未提供时按
  /// [index] 置首重新洗牌。
  Future<void> playTracks(
    List<SourceTrack> tracks,
    int index, {
    String? contextName,
    List<int>? shuffleIndices,
  }) async {
    if (tracks.isEmpty) return;
    // 淡入只属于「从空闲起播 / 恢复同一首」；替换已装载的曲目（哪怕暂停中）
    // 是切歌，不能比手动切歌更柔和。必须在装载前判断（_playIndex 会改状态）。
    final fadeIn = _currentTrack == null && !_player.playing;
    // 旧队列的 source 不再需要：先回收播放器，避免 just_audio 的 source
    // 注册表随「换专辑 / 换歌单」线性累积。必须在装载新源前完成。
    await _recyclePlayerForQueueChange();
    _queue
      ..clear()
      ..addAll(tracks);
    _queueRevision++;
    // 新队列 = 新会话：播放顺序从头开始；shuffle 优先沿用恢复态的排列。
    _order.clear();
    final safeIndex = index.clamp(0, tracks.length - 1);
    if (_mode == PlayMode.shuffle) {
      // 证据只在装载队列 / 进入随机时刷新；本轮进行中的排列不会被重排。
      await _refreshRecentTrackIds();
      final weights = _shuffleWeights();
      if (shuffleIndices != null &&
          isValidShuffleOrder(
            shuffleIndices,
            length: _queue.length,
            currentIndex: safeIndex,
          )) {
        _shuffleOrder.adopt(shuffleIndices, weights: weights);
      } else {
        _shuffleOrder.reset(
          _queue.length,
          startIndex: safeIndex,
          weights: weights,
        );
      }
    } else {
      _shuffleOrder.clear();
    }
    _contextName = contextName;
    await _playIndex(safeIndex, recordHistory: false, fadeIn: fadeIn);
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

  /// 队列内移动一项（[from] → [to]）：只允许非随机模式，当前曲目 / 目标
  /// 为当前曲目或越界/原地不动都返回 false（no-op）。
  ///
  /// 队列是播放顺序的唯一事实：移动后同步播放顺序栈与 shuffle 排列的下标，
  /// 否则 previous / 下一首预览会指到另一首。判定与当前下标平移走
  /// [planQueueMove]，与恢复态共用一套口径。
  bool moveQueueIndex(int from, int to) {
    final plan = planQueueMove(
      mode: _mode,
      length: _queue.length,
      currentIndex: _currentIndex,
      from: from,
      to: to,
    );
    if (!plan.allowed) return false;
    final track = _queue.removeAt(from);
    _queue.insert(to, track);
    _queueRevision++;
    _currentIndex = plan.currentIndex;
    _order.moveIndex(from, to);
    _shuffleOrder.moveIndex(from, to);
    notifyListeners();
    _refreshNextPreload();
    return true;
  }

  /// 从队列移除一项：当前曲目 / 越界返回 false（no-op）。
  ///
  /// 随机模式同样允许移除（产品约定：随机队列只保留「移出队列」）；
  /// 播放顺序栈与洗牌排列同步重映射，轮次剩余不会包含已移除下标。
  bool removeQueueIndex(int index) {
    final plan = planQueueRemove(
      length: _queue.length,
      currentIndex: _currentIndex,
      index: index,
    );
    if (!plan.allowed) return false;
    _queue.removeAt(index);
    _queueRevision++;
    _currentIndex = plan.currentIndex;
    _order.removeIndex(index);
    _shuffleOrder.removeIndex(index);
    notifyListeners();
    _refreshNextPreload();
    return true;
  }

  /// 队列编辑后刷新下一首投机预取：正在播放时以新的 next 重新预载，
  /// 暂停 / 停止时只作废旧目标。
  ///
  /// `NextTrackPreloader.preload` 只取消投机预取、不会碰当前曲目的缓存写入
  /// （`_playback` 所有权），因此这里不需要额外判断“是否正在下载当前曲目”。
  void _refreshNextPreload() {
    final preloader = _nextTrackPreloader;
    if (preloader == null) return;
    if (_isPlaying) {
      unawaited(preloader.preload(nextSourceTrack));
    } else {
      preloader.cancelPending();
    }
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

  /// 以指定音质重新取链当前曲目，保持进度与播放态。
  ///
  /// 只影响当前曲目本次播放：选择按曲目 id 记住（自动重试仍用同一档位），
  /// 切歌后自然回到偏好音质；音质不写入播放会话。
  Future<void> setCurrentQuality(String quality) async {
    if (_playerDisposed || quality.isEmpty) return;
    final track = _currentTrack;
    if (track == null || _currentIndex < 0 || _currentIndex >= _queue.length) {
      return;
    }
    final resolved = track.pickQuality(quality);
    if (resolved == _currentQuality) return;
    final resumeAt = _isAtTrackEnd ? Duration.zero : _position;
    final wasPlaying = _isPlaying;
    _qualityOverride = resolved;
    _qualityOverrideTrackId = track.id;
    await _playIndex(
      _currentIndex,
      recordHistory: false,
      resumeAt: resumeAt,
      autoplay: wasPlaying,
      unloadCurrent: false,
    );
  }

  /// 播放队列下标：手动切歌 / 换源 / 切音质 / 曲末自动切歌共用。
  ///
  /// [unloadCurrent] 为 true 时在取链前停掉并卸载旧源（手动切歌）；
  /// 音质切换要保持进度、曲末自动切歌的旧源已经播完，这两条路径传 false。
  Future<void> _playIndex(
    int index, {
    bool recordHistory = true,
    Duration? resumeAt,
    bool autoplay = true,
    bool unloadCurrent = true,
    bool fadeIn = false,
  }) async {
    if (index < 0 || index >= _queue.length) return;
    _pauseIntentPending = false;
    // 切歌 / 换音质 / 换源都不继承半淡的音量：新源从用户音量开始。
    // 淡入路径留给起播前自己把电平压到静音（见 [_prepareFadeIn]）。
    if (!fadeIn) await _resetEnvelopeForSource();
    // 新曲目 = 用户主动选择，撤销音频中断的待续播。
    _focusGuard?.cancelPendingResume();
    // 切到不同曲目时把「离开的当前曲目」压入播放顺序；显式回退不重复压栈。
    if (recordHistory && _currentTrack != null && _currentIndex != index) {
      _order.record(_currentIndex);
    }
    final requestId = ++_playRequestId;
    final track = _queue[index];
    final previousTrack = _currentTrack;
    final unloadBeforeLoad = unloadCurrent && previousTrack != null;
    final override = _qualityOverrideTrackId == track.id
        ? _qualityOverride
        : null;
    final preferred = override ?? _preferredQuality?.call();
    final quality = preferred == null ? null : track.pickQuality(preferred);
    final preservePosition = resumeAt != null;
    final startPosition = _clampResumePosition(
      resumeAt ?? Duration.zero,
      track.duration,
    );
    _suppressPositionUpdates = preservePosition || unloadBeforeLoad;
    // 预取所有权：桌面 / 回退直接流播时，如果正在预取的就是这一首，保留
    // 在途任务（不取消、不再起 writer），落位后的缓存供重播命中。移动端
    // 边播边缓存会写同一文件，仍保持「起播前取消」。
    final prefetchOwnsCache =
        _nextTrackPreloader?.retainForPlayback(
          track,
          quality: quality,
          reuseInFlight:
              !_platformSupportsAudioCaching || _audioCacheUnsupported,
        ) ??
        false;
    // 上一首的后台缓存写入（桌面）同理：切歌即停，避免与新曲目抢带宽。
    _cacheWriter?.cancel();
    final startTrace = PlaybackStartTrace.begin(track.id.toString());

    _currentIndex = index;
    _currentTrack = track;
    _currentQuality = quality;
    _isLoading = true;
    _lastError = null;
    _position = startPosition;
    _duration = track.duration ?? Duration.zero;
    // 换曲即重新计时：上一首的末位采样不能参与新曲目的曲末判定。
    _lastEndPositionSample = null;
    if (unloadBeforeLoad) {
      // 切歌立即停声：旧源若在取链期间继续播，会出现「界面已显示新歌、
      // 耳朵还在旧歌」，等新源落位再硬切更突兀。stop() 同时置 playing=false
      // 并释放解码器，等价于「暂停 + 卸载」一次完成。
      _isPlaying = false;
      _sourceUnloaded = true;
    }
    notifyListeners();

    try {
      if (unloadBeforeLoad) {
        await _unloadCurrentSource();
        if (requestId != _playRequestId) return;
      }
      final stream = await _resolver(track, quality: quality);
      if (requestId != _playRequestId) return;
      startTrace?.markResolved();

      final cachePath = await _setAudioSourceWithCache(
        stream.uri,
        track,
        quality: quality,
        headers: stream.headers,
      );
      if (requestId != _playRequestId) return;
      // 新源已落位：旧源空窗结束，播放键恢复正常语义。
      _sourceUnloaded = false;
      startTrace?.markSourceSet(
        cachePath: cachePath,
        prefetched: prefetchOwnsCache,
      );

      // 播放侧没有写缓存（平台不支持边播边缓存 / 后端拒绝后退到直接流播）：
      // 由后台字节下载补上缓存——重播经 `localUriFor` 命中 file://。
      // 目标此刻仍由在途预取负责时不再起第二个 writer（任务可能在上面的
      // setAudioSource 期间刚好落位：writer 会因完整缓存已存在而自动跳过）。
      final prefetchInFlight =
          _nextTrackPreloader?.isCacheWriteInFlight(track, quality: quality) ??
          false;
      if ((!_platformSupportsAudioCaching || _audioCacheUnsupported) &&
          !prefetchInFlight) {
        final writer = _cacheWriter;
        if (writer != null) {
          unawaited(writer.start(track, stream: stream, quality: quality));
        }
      }

      _duration = _player.duration ?? track.duration ?? Duration.zero;
      // 切音质：新源落位后跳回原进度；切歌 / 首次起播 startPosition 为 0。
      if (preservePosition) {
        final target = _clampResumePosition(
          startPosition,
          _player.duration ?? track.duration,
        );
        _position = target;
        if (target > Duration.zero) {
          await _seekPlayer(target);
          if (requestId != _playRequestId) return;
        }
      }
      if (autoplay) {
        // 只有「从空 / 暂停的同一首重新起播」才淡入：播放启动前先把当前
        // 有效音量压到起点（暂停时是 0），避免出现第一声硬切。
        final rampIn = fadeIn && await _prepareFadeIn();
        // 播放启动后立即返回：just_audio 的 play() Future 在「播完/暂停」才
        // 完成，挂在这里会拖住调用方（自动切歌完成处理器）并吞掉后续
        // completed 事件；启动失败单独捕获进 lastError。
        startTrace?.markPlayRequested();
        unawaited(
          _player.play().catchError((Object e) {
            if (requestId == _playRequestId) {
              _lastError = e.toString();
              _isPlaying = false;
              notifyListeners();
            }
          }),
        );
        if (rampIn) unawaited(_runEnvelope(1.0, _fadeDuration));
      } else if (_player.playing) {
        // 暂停中切换音质：只换源 + 对齐进度，不重新起播。
        await _player.pause();
      }
      // 当前曲目已起播：后台预载下一首（直链 + 音频缓存；歌词/封面由
      // 各自链路从播放快照统一触发）。此刻不会与当前取链抢 LX 引擎。
      unawaited(_nextTrackPreloader?.preload(nextSourceTrack));
    } catch (e) {
      if (requestId != _playRequestId) return;
      PlaybackStartTrace.failCurrent();
      _lastError = e.toString();
      _isPlaying = false;
      debugPrint('[LocalPlayback] 播放失败: $e');
    } finally {
      if (requestId == _playRequestId) {
        _isLoading = false;
        _suppressPositionUpdates = false;
        notifyListeners();
      }
    }
  }

  /// 切歌前暂停并卸载旧源。
  ///
  /// [AudioPlayer.stop] 会立即把 playing 置 false 并释放解码器 / 平台播放器，
  /// 不能只靠后面的 `setAudioSource` 隐式换源：否则旧曲目会在整个取链期间
  /// 继续出声。失败只记日志——随后仍要尝试加载新源，stop 失败时再补一次
  /// pause 尽量止声。
  Future<void> _unloadCurrentSource() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[LocalPlayback] 切歌前卸载旧源失败: $e');
      try {
        await _player.pause();
      } catch (e2) {
        debugPrint('[LocalPlayback] 切歌前暂停旧源失败: $e2');
      }
    }
  }

  /// 切音质时把原进度钳到新源时长内；已到曲末则从 0 开始。
  Duration _clampResumePosition(Duration position, Duration? duration) {
    if (position <= Duration.zero) return Duration.zero;
    if (duration != null && duration > Duration.zero && position >= duration) {
      return Duration.zero;
    }
    return position;
  }

  /// 设置音频源：优先边播边缓存（策略开启时），失败回退直接流播。
  ///
  /// 缓存不能影响播放可用性：平台不支持、目录解析失败、网络异常都会
  /// 回退到 `AudioSource.uri`，仅记录日志。返回实际使用的路径，供起播
  /// 埋点按 file / caching / direct 分桶。
  ///
  /// [headers] 来自取链结果，必须同时交给缓存源与直接流播源（B 站等平台
  /// 要求 `Referer`）；为空时传 null，避免给 just_audio 挂空代理。
  Future<PlaybackCachePath> _setAudioSourceWithCache(
    Uri uri,
    SourceTrack track, {
    String? quality,
    Map<String, String> headers = const {},
  }) async {
    final cache = _cacheService;
    final localFile = uri.scheme == 'file';
    final cacheable =
        !localFile &&
        _platformSupportsAudioCaching &&
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
              headers: headers,
            );
            if (source != null) {
              try {
                _sourceRegistrations++;
                await _player
                    .setAudioSource(source)
                    .timeout(const Duration(seconds: 30));
                // 写入开始后执行一次 LRU 淘汰（策略上限）。
                unawaited(cache.enforceAudioLimit());
                return PlaybackCachePath.caching;
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

    _sourceRegistrations++;
    await _player
        .setAudioSource(
          AudioSource.uri(uri, headers: headers.isEmpty ? null : headers),
        )
        .timeout(const Duration(seconds: 30));
    return localFile ? PlaybackCachePath.file : PlaybackCachePath.direct;
  }

  /// 是否尝试边播边缓存：仅 Android / iOS / macOS（见 [platformSupportsAudioCaching]）。
  bool get _platformSupportsAudioCaching => platformSupportsAudioCaching();

  /// 暂停播放（音频焦点被其他应用夺走等外部触发）。
  ///
  /// 返回是否真的暂停了：音频焦点守卫据此判断「中断结束要不要续播」
  /// （本来就没在播 / 无曲目 → false）。
  ///
  /// [fromInterruption] 为 true 时不取消守卫登记的待续播；手动暂停（用户 /
  /// 定时关闭 / 系统媒体键）走默认值，焦点归还后不会被强行续播。
  ///
  /// 与 [toggle] 的暂停分支同语义：无曲目 / 已暂停时无操作（幂等——中断事件
  /// 可能连续到达，重复调用不叠加副作用）。
  /// [urgent] 为 true（耳机拔出 / 输出设备消失 / 音频焦点丢失）时立即暂停：
  /// 安全与响应速度优先于听感，淡变不参与。
  Future<bool> pause({
    bool fromInterruption = false,
    bool urgent = false,
  }) async {
    if (!fromInterruption) _focusGuard?.cancelPendingResume();
    if (_playerDisposed || _currentTrack == null) return false;
    if (!_player.playing) return false;
    final immediate =
        urgent ||
        fromInterruption ||
        _baseVolume <= 0 ||
        _fadeDuration < kMinimumAudibleFade ||
        _envelope <= 0.001;
    if (immediate) {
      // 用户暂停可能落在睡眠淡出途中：撤销它，但不把音量拉回基值再淡出，
      // 否则会先变响再变轻。
      _cancelActiveRamp();
      _sleepFadeActive = false;
      _pauseIntentPending = false;
      await _player.pause();
      return true;
    }
    // 睡眠淡出进行中：交回普通短淡出（从当前电平继续），不重复补一次。
    _sleepFadeActive = false;
    _pauseIntentPending = true;
    final completed = await _runEnvelope(0, _fadeDuration);
    if (!completed) return false;
    _pauseIntentPending = false;
    await _player.pause();
    return true;
  }

  /// 用户 / 系统「播放」键：幂等起播。
  ///
  /// 与 [toggle] 的差别只在暂停淡出窗口：期间对外仍是 playing，toggle 会
  /// 再暂停一次；这里按最新意图反向淡入。
  Future<void> play() async {
    if (!hasTrack) return;
    if (isLoading) return;
    final reversingPause = _pauseIntentPending;
    _pauseIntentPending = false;
    if (reversingPause) {
      _focusGuard?.cancelPendingResume();
      final fadeIn = await _prepareFadeIn();
      unawaited(
        _player.play().catchError((Object e) {
          _lastError = e.toString();
          _isPlaying = false;
          notifyListeners();
        }),
      );
      if (fadeIn) unawaited(_runEnvelope(1.0, _fadeDuration));
      return;
    }
    if (isPlaying) return;
    await toggle();
  }

  /// 暂停淡出是否在进行中（引擎 toggle 据此把「播放」翻译成反向淡入）。
  bool get pauseIntentPending => _pauseIntentPending;

  Future<void> toggle() async {
    if (_currentTrack == null) return;
    // 以对外播放态（completed 视为暂停）判断，而不是 just_audio 原始的
    // `playing`：自然播完后 playing 仍会保持 true，按它判断会把「继续播放」
    // 错走成暂停（第一次点没反应，第二次才重启）。
    if (_isPlaying) {
      await pause();
      return;
    }
    // 切歌卸载后新源还没落位：不能直接 play()，否则 just_audio 会把停掉的
    // 旧源重新拉起来。装载中忽略；装载失败则按当前曲目重新取链。
    if (_isLoading) return;
    if (_sourceUnloaded) {
      await _playIndex(
        _currentIndex,
        recordHistory: false,
        resumeAt: _position,
        unloadCurrent: false,
        fadeIn: true,
      );
      return;
    }
    // 用户主动续播：撤销任何中断待续播，避免焦点归还时重复动播放器。
    _focusGuard?.cancelPendingResume();
    // 已到曲末（含 media_kit 暂停在 EOF、processingState 仍为 ready 的情况）
    // 先回零：直接 play() 在结尾不会重新出声。
    if (_isAtTrackEnd) {
      await _restartFromStart();
    }
    final fadeIn = await _prepareFadeIn();
    unawaited(
      _player.play().catchError((Object e) {
        _lastError = e.toString();
        _isPlaying = false;
        notifyListeners();
      }),
    );
    if (fadeIn) unawaited(_runEnvelope(1.0, _fadeDuration));
  }

  Future<void> seek(Duration position) async {
    if (_currentTrack == null) return;
    if (_sourceUnloaded) {
      await _playIndex(
        _currentIndex,
        recordHistory: false,
        resumeAt: position,
        autoplay: false,
        unloadCurrent: false,
      );
      return;
    }
    await _seekPlayer(position);
  }

  /// 真实位置跳转的唯一入口：跳转后版本号自增并立即对齐进度，媒体会话
  /// 据此补发 state。
  ///
  /// 内部回跳（单曲循环 / 队列只有一首的重播 / 无下一首归零）也走这里：
  /// 它们同样是位置不连续；只靠后台 1s 轮询会让通知按旧锚点插值一整首。
  Future<void> _seekPlayer(Duration position) async {
    // 跳转是主动的位置不连续：曲末兜底不能把「从末尾拖回开头」当成播完。
    // 必须在 await 之前清空——播放器的位置事件可能在 seek 返回前就到达。
    _lastEndPositionSample = null;
    await _player.seek(position);
    _seekRevision++;
    _position = position;
    _scheduleNotify();
  }

  /// 从曲末重启当前曲目：先把底层真正置为暂停，再回零。
  ///
  /// just_audio 播完后 `playing` 仍可能为 true，此时 `play()` 会直接返回；
  /// media_kit（Windows/Linux）在 EOF 也停在暂停态。只 seek + play 时，部分
  /// 后端会「静默地从 0 开始但不出声」。先 pause 一次能保证随后的 play 一定
  /// 下发到平台，再配合 [_seekPlayer] 从 0 起播。
  Future<void> _restartFromStart() async {
    if (_player.playing) {
      await _player.pause();
    }
    await _seekPlayer(Duration.zero);
  }

  /// 用户音量（0..1，构造默认 1.0）：只回报基值，不泄漏淡变中的包络。
  double get volume => _baseVolume;

  /// 当前淡入淡出时长（测试 / 断点观察用）。
  @visibleForTesting
  Duration get fadeDuration => _fadeDuration;

  /// 当前包络倍数（测试 / 断点观察用）。
  @visibleForTesting
  double get envelopeGain => _envelope;

  /// 设置应用内音量：只更新基值，立即按当前包络重算实际音量。
  ///
  /// 拖动滑杆 / 静音都走这里：淡变进行中改音量不会重启淡变，剩余段从新
  /// 基值继续；静音（基值 0）在整个淡变里保持无声。
  Future<void> setVolume(double volume) async {
    _baseVolume = volume.clamp(0.0, 1.0);
    await _applyEffectiveVolume();
  }

  /// 设置淡入淡出时长；进行中的淡变保持原时长。
  void setFadeDuration(Duration duration) {
    _fadeDuration = duration < Duration.zero ? Duration.zero : duration;
  }

  /// 智能随机开关：只影响下一次生成轮次（进行中的排列不重排）。
  ///
  /// 轮末重洗时由 [_commitNextIndex] 重新计算当前权重，因此关闭后下一轮
  /// 立即回到均匀洗牌，不需要等重新装载队列。
  void setSmartShuffleEnabled(bool enabled) {
    _smartShuffleEnabled = enabled;
  }

  /// 把「基值 × 包络」写给播放器；淡变进行中允许跳过中间步。
  Future<void> _applyEffectiveVolume() {
    final target = (_baseVolume * _envelope).clamp(0.0, 1.0);
    // 静音必须立刻归零：即使上一次写入在途，也要排队一次 0，不能等下一
    // 个淡变 tick 才静下来。
    if (target <= 0) return _enqueueVolumeWrite(0);
    // 只有分步淡变在跑时才允许跳步；普通赋值必须落在平台上。
    if (_fadeTimer != null) {
      _offerVolume(target);
      return Future<void>.value();
    }
    return _enqueueVolumeWrite(target);
  }

  /// 排队一次平台音量写入（串行；失败只记日志）。
  Future<void> _enqueueVolumeWrite(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((clamped - _lastWrittenVolume).abs() < 1e-6 &&
        _volumeWritesInFlight == 0) {
      return Future<void>.value();
    }
    _lastWrittenVolume = clamped;
    _volumeWritesInFlight++;
    final future = _volumeWriteTail.then((_) async {
      try {
        await _player.setVolume(clamped);
      } catch (e) {
        debugPrint('[LocalPlayback] 写入音量失败: $e');
      }
    });
    _volumeWriteTail = future.whenComplete(() {
      _volumeWritesInFlight--;
    });
    return future;
  }

  /// 淡变中间步：平台还在写上一笔时直接跳过（墙钟时长不被慢调用拉长）。
  void _offerVolume(double value) {
    if (_volumeWritesInFlight > 0) return;
    unawaited(_enqueueVolumeWrite(value));
  }

  /// 取消正在跑的淡变（不改变当前包络），完成返回 false 的等待方。
  void _cancelActiveRamp() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final pending = _fadeCompleter;
    _fadeCompleter = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  /// 按墙钟推进包络到 [target]；返回是否走到终点（被新意图取代时 false）。
  Future<bool> _runEnvelope(double target, Duration duration) {
    _cancelActiveRamp();
    final completer = Completer<bool>();
    _fadeCompleter = completer;
    final ramp = FadeRamp(
      from: _envelope.clamp(0.0, 1.0),
      to: target.clamp(0.0, 1.0),
      duration: duration,
    );
    if (ramp.isImmediate) {
      _envelope = ramp.to;
      unawaited(
        _enqueueVolumeWrite(_baseVolume * _envelope).then((_) {
          if (identical(_fadeCompleter, completer)) _fadeCompleter = null;
          if (!completer.isCompleted) completer.complete(true);
        }),
      );
      return completer.future;
    }
    final watch = Stopwatch()..start();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (completer.isCompleted) return;
      final elapsed = watch.elapsed;
      if (!ramp.isComplete(elapsed)) {
        _envelope = ramp.gainAt(elapsed);
        _offerVolume(_baseVolume * _envelope);
        return;
      }
      _fadeTimer?.cancel();
      _fadeTimer = null;
      _envelope = ramp.to;
      // 最终值一定写出并等待完成，暂停只能在静音落地之后发生。
      unawaited(
        _enqueueVolumeWrite(_baseVolume * _envelope).then((_) {
          if (identical(_fadeCompleter, completer)) _fadeCompleter = null;
          if (!completer.isCompleted) completer.complete(true);
        }),
      );
    });
    return completer.future;
  }

  /// 起播前的淡入准备：先把当前有效音量写下去，返回是否要启动渐变。
  ///
  /// 已暂停时从 0 开始（即使上次是急停、播放器仍停在基值）；淡出途中
  /// 反向播放则从当前电平继续，避免先跳到 0 再爬升。
  Future<bool> _prepareFadeIn() async {
    _cancelActiveRamp();
    _sleepFadeActive = false;
    _pauseIntentPending = false;
    final base = _baseVolume;
    if (base <= 0 || _fadeDuration < kMinimumAudibleFade) {
      _envelope = 1.0;
      await _enqueueVolumeWrite(base);
      return false;
    }
    final from = _player.playing ? _envelope.clamp(0.0, 1.0) : 0.0;
    _envelope = from;
    await _enqueueVolumeWrite(base * from);
    return true;
  }

  /// 新音源落位后取消包络并回到基值：切歌不能继承半淡的音量。
  Future<void> _resetEnvelopeForSource() async {
    _cancelActiveRamp();
    _sleepFadeActive = false;
    _pauseIntentPending = false;
    _envelope = 1.0;
    await _enqueueVolumeWrite(_baseVolume);
  }

  /// 定时关闭的专用淡出：只降音量，不暂停（暂停由命令面单独下发）。
  void startSleepFade(Duration duration) {
    if (_playerDisposed || _baseVolume <= 0) return;
    // 定时淡出会取代在途的暂停淡出：清掉暂停意图，否则下一次播放键会被
    // 误判成「反向淡入」。
    _pauseIntentPending = false;
    _sleepFadeActive = true;
    unawaited(
      _runEnvelope(
        0,
        duration < kMinimumAudibleFade
            ? const Duration(milliseconds: 50)
            : duration,
      ),
    );
  }

  /// 撤销睡眠淡出：[restore] 时按普通淡变时长回到用户音量。
  void cancelSleepFade({bool restore = true}) {
    if (!_sleepFadeActive) return;
    _sleepFadeActive = false;
    // 撤销淡出同样是「取代暂停意图」：后续播放键必须按正常播放态判断。
    _pauseIntentPending = false;
    _cancelActiveRamp();
    if (restore) {
      // 定时取消 / 后退 seek：把音量还给用户，但不打断正在播放的曲目。
      unawaited(_runEnvelope(1.0, _fadeDuration));
      return;
    }
    // 曲末完成早到：直接压到静音，让随后的暂停立即落地（不再补一次淡出）。
    _envelope = 0;
    unawaited(_enqueueVolumeWrite(0));
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
    final previous =
        _order.popPrevious() ??
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
        // 进入随机 = 刷新一次证据（关闭开关 / 短队列 / 空证据时权重为空）。
        await _refreshRecentTrackIds();
        // 以当前曲目置首重洗：切到随机模式不会立刻跳走正在播放的曲目。
        _shuffleOrder.reset(
          _queue.length,
          startIndex: _currentIndex >= 0 ? _currentIndex : 0,
          weights: _shuffleWeights(),
        );
      } else if (mode != PlayMode.shuffle) {
        _shuffleOrder.clear();
      }
    }
    notifyListeners();
  }

  /// 读取最近的播放证据；失败静默为空集合（降级为均匀洗牌）。
  Future<void> _refreshRecentTrackIds() async {
    final loader = _recentTrackIds;
    if (loader == null) {
      _cachedRecentTrackIds = const {};
      return;
    }
    try {
      _cachedRecentTrackIds = await loader();
    } catch (e) {
      debugPrint('[LocalPlayback] 读取最近播放失败，改用均匀随机: $e');
      _cachedRecentTrackIds = const {};
    }
  }

  /// 当前队列的随机权重；无证据 / 短队列 / 开关关闭时为 null。
  List<double>? _shuffleWeights() => shuffleWeightsFor(
    trackIds: [for (final track in _queue) track.id],
    recentTrackIds: _cachedRecentTrackIds,
    enabled: _smartShuffleEnabled,
  );

  Future<void> toggleMode() async {
    await setMode(_mode.next);
  }

  /// 停止本地播放并清空状态。
  ///
  /// 系统媒体「停止」与用户停止都属于可感知的动作：先按用户淡变时长收声，
  /// 再真正 stop。被新的播放意图抢走时（快速播放）以最新意图为准，不再停。
  Future<void> stop({bool clear = true}) async {
    // 停止是独立意图：在途的暂停淡出 / 睡眠淡出都由本次停止接管。
    _pauseIntentPending = false;
    final shouldFade =
        !_playerDisposed &&
        _player.playing &&
        _baseVolume > 0 &&
        _envelope > 0.001 &&
        _fadeDuration >= kMinimumAudibleFade;
    if (shouldFade) {
      _sleepFadeActive = false;
      _pauseIntentPending = true;
      final completed = await _runEnvelope(0, _fadeDuration);
      if (!completed) return;
      _pauseIntentPending = false;
    } else {
      _cancelActiveRamp();
      _sleepFadeActive = false;
      _pauseIntentPending = false;
    }
    _playRequestId++;
    _stopAfterCurrentTrack = false;
    _suppressPositionUpdates = false;
    _nextTrackPreloader?.cancelAll();
    _cacheWriter?.cancel();
    try {
      await _player.stop();
    } catch (_) {}
    _isPlaying = false;
    // 显式 stop 不是切歌空窗：底层保留当前源，后续 play() 按正常续播处理。
    _sourceUnloaded = false;
    if (clear) {
      _queue.clear();
      _queueRevision++;
      _currentIndex = -1;
      _currentTrack = null;
      _currentQuality = null;
      _qualityOverride = null;
      _qualityOverrideTrackId = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _contextName = null;
      _order.clear();
      _shuffleOrder.clear();
      // 显式停止：下一次播放会重新装载，旧播放器里的 source 注册表可以
      // 整体回收；不清队列的 stop（暂停语义）不换播放器。
      await _recyclePlayerForQueueChange();
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
      // 轮末重洗必须用「当前」开关与证据：权重不在排列里跨轮缓存。
      return _shuffleOrder.next(_currentIndex, weights: _shuffleWeights());
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
        weights: _shuffleWeights(),
      );
    }
  }

  void _onPlayerState(PlayerState state) {
    _isPlaying =
        state.playing && state.processingState != ProcessingState.completed;
    final enteredCompleted =
        state.processingState == ProcessingState.completed &&
        _lastProcessingState != ProcessingState.completed;
    _lastProcessingState = state.processingState;
    // 播放态变化可能改变采样档位（后台暂停 → 停采样；后台续播 → 1s Timer；
    // 前台始终高频流，这里是无操作）。
    _syncPositionSampling();
    if (enteredCompleted) {
      _handleTrackCompleted();
    }
    notifyListeners();
  }

  /// 播放中错误：曲末解码失败按自然播完处理，其余才上报错误。
  ///
  /// Windows 的 media_kit 播放 tx / kw 的 FLAC 时，源文件最后一帧常损坏：
  /// mpv 在距曲末不到 1s 处报 `Error decoding audio` 并释放播放器
  /// （processingState 直接 idle），`completed` 永远不会到达——声音已经放到
  /// 最后一秒，界面却停在旧歌，表现为「播完不自动切歌」。此时按完成链路
  /// 处理（完成事件 / 单曲循环 / 自动下一首 / 定时关闭同一口径）。
  void _onPlayerError(PlayerException error) {
    if (_currentTrack == null) return;
    // 只对桌面 media_kit 做曲末兜底：Android/iOS 的 completed / 错误语义可靠，
    // 不把真实的播放故障吞成「播完」。
    final atEnd =
        _usesMediaKitBackend &&
        _duration > Duration.zero &&
        _position >= _duration - _trackEndErrorWindow;
    if (atEnd) {
      debugPrint('[LocalPlayback] 曲末解码失败，按播完处理并自动切歌');
      _isPlaying = false;
      _handleTrackCompleted();
      return;
    }
    debugPrint('[LocalPlayback] 播放失败（${error.code}）：${error.message}');
    _lastError = error.message ?? error.toString();
    _isPlaying = false;
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
        await _pauseAtTrackEnd();
        return;
      }
      if (_mode == PlayMode.singleRepeat) {
        await _restartFromStart();
        _resumeCurrentTrack();
      } else {
        final index = _commitNextIndex(auto: true);
        if (index < 0) {
          // 顺序播放到队尾：不自动切歌，显式停在曲末（见
          // [_pauseAtTrackEnd]：just_audio 播完后 playing 仍可能为 true）。
          await _pauseAtTrackEnd();
        } else if (index == _currentIndex) {
          // 列表循环 / 随机只有一首歌：下一首就是自己，按重播处理。
          await _restartFromStart();
          _resumeCurrentTrack();
        } else {
          // 自然播完后 just_audio 的 playing 仍为 true；直接 play() 会被它
          // 返回，桌面 media_kit 的 load(play:) 也不保证真正起播（已知坑
          // 77/78）。先显式暂停，让下一首的 play() 一定下发到平台。
          await _pauseBeforeTrackSwitch();
          // 旧曲目已经播完，不再额外卸载：避免为释放播放器再拆建一次平台
          // 播放器，平白拉长曲间空档。
          await _playIndex(index, unloadCurrent: false);
        }
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  /// 自动切歌前显式暂停（仅桌面 media_kit）。
  ///
  /// 自然播完后 just_audio 的 playing 仍是 true，`play()` 会直接返回；下一首
  /// 能否起播取决于 media_kit 内部 `open(play:)` 的标志。先暂停一次，保证
  /// 随后 `_playIndex` 末尾的 play() 是一次真实的平台请求（已知坑 77/78）。
  Future<void> _pauseBeforeTrackSwitch() async {
    if (!_usesMediaKitBackend || !_player.playing) return;
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[LocalPlayback] 自动切歌前暂停失败: $e');
    }
  }

  /// 停在曲末：位置对齐到结尾，并显式暂停底层播放器。
  ///
  /// 定时关闭「播完当前曲」与顺序播放队尾共用。只把 `_isPlaying` 置 false
  /// 不够——just_audio 自然播完后 playing 仍为 true，底层与 UI 状态会分叉，
  /// 下一次点播放会被当成暂停。
  Future<void> _pauseAtTrackEnd() async {
    if (_duration > Duration.zero) _position = _duration;
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[LocalPlayback] 曲末暂停失败: $e');
    }
    _isPlaying = false;
    notifyListeners();
  }

  /// 续播当前曲目（单曲循环重播 / 焦点归还）：与 `_playIndex` 一致，
  /// 不等待整曲播完。
  ///
  /// [fadeIn] 只给用户可感知的「恢复播放」；自动重播（单曲循环 / 列表循环
  /// 单曲）保持硬切，避免每次循环都做一次音量起伏。
  void _resumeCurrentTrack({bool fadeIn = false}) {
    unawaited(() async {
      final rampIn = fadeIn && await _prepareFadeIn();
      unawaited(
        _player.play().catchError((Object e) {
          _lastError = e.toString();
          _isPlaying = false;
          notifyListeners();
        }),
      );
      if (rampIn) unawaited(_runEnvelope(1.0, _fadeDuration));
    }());
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
    // 退出不走淡变：包络立即取消，有界收尾不能被 200ms 音量循环拖住。
    _cancelActiveRamp();
    _sleepFadeActive = false;
    _pauseIntentPending = false;
    // 退出路径不经过 dispose：在途预取 / 后台缓存写入都在这里收掉，避免
    // 进程退出时留下 `.predl` 半成品。
    _nextTrackPreloader?.cancelAll();
    _cacheWriter?.cancel();
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
    _cancelActiveRamp();
    _sleepFadeActive = false;
    _pauseIntentPending = false;
    _stopAfterCurrentTrack = false;
    _powerPolicy.removeListener(_syncPositionSampling);
    _stopPositionSampleTimer();
    _notifyThrottle?.cancel();
    _playerStateSubscription?.cancel();
    _errorSubscription?.cancel();
    _cancelPositionSubscription();
    _nextTrackPreloader?.cancelAll();
    _cacheWriter?.cancel();
    _playWithOtherApps.removeListener(_onPlayWithOtherAppsChanged);
    unawaited(_becomingNoisySubscription?.cancel());
    unawaited(_audioDevicesSubscription?.cancel());
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
