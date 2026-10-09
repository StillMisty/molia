import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/play_mode.dart';
import '../services/cache_service.dart';
import '../sources/source_track.dart';
import 'audio_cache_source.dart';
import 'playback_order.dart';
import 'shuffle_order.dart';

/// 将音源曲目解析为可播放 URL 的回调（由 SourceManager 提供）。
typedef SourceUrlResolver = Future<String> Function(
  SourceTrack track, {
  String? quality,
});

/// 本地播放服务：音源取链后由 App 直接播放。
///
/// 对外输出与旧远程播放 API 一致的曲目结构，现有 NowPlaying / 队列 / 歌词等
/// 界面无需感知播放后端差异。
class LocalPlaybackService extends ChangeNotifier {
  final SourceUrlResolver _resolver;
  final AudioPlayer _player = AudioPlayer();

  /// 当前偏好音质（composition root 注入；省流模式由注入方压低上限）。
  ///
  /// 播放前用它选出本次实际音质：解析器与音频缓存键共用同一值，
  /// 避免省流下缓存的 128k 文件在 Wi-Fi 上被当作标准音质复用。
  final String Function()? _preferredQuality;

  /// 统一缓存门面（默认全局单例；测试可注入临时目录实现）。
  final CacheService? _cacheService;

  /// 已知平台后端不支持 StreamAudioSource（如桌面 media_kit）：
  /// 本会话内不再尝试边播边缓存，直接流播。
  bool _audioCacheUnsupported = false;

  final List<SourceTrack> _queue = [];
  int _currentIndex = -1;
  SourceTrack? _currentTrack;
  String? _contextName;
  PlayMode _mode = PlayMode.sequential;

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
  Timer? _notifyThrottle;
  bool _notifyPending = false;
  int _playRequestId = 0;

  LocalPlaybackService({
    required SourceUrlResolver resolver,
    CacheService? cacheService,
    String Function()? preferredQuality,
    math.Random? random,
  })  : _resolver = resolver,
        _cacheService = cacheService ?? CacheService.instance,
        _preferredQuality = preferredQuality,
        _shuffleOrder = PlaybackShuffleOrder(random: random) {
    _playerStateSubscription = _player.playerStateStream.listen(_onPlayerState);
    _positionSubscription = _player.positionStream.listen((position) {
      _position = position;
      _scheduleNotify();
    });
    // 配置系统音频会话（音乐类型）：iOS 后台播放、Android 音频焦点/duck。
    // 不阻塞构造；不支持的平台内部直接跳过。
    unawaited(_configureAudioSession());
  }

  /// 配置 audio_session（仅移动端/桌面原生支持平台）。
  ///
  /// Linux/Windows 没有 audio_session 插件实现，调用会抛 MissingPluginException，
  /// 因此按平台跳过，保持桌面端现有行为。
  Future<void> _configureAudioSession() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('[LocalPlayback] 音频会话配置失败: $e');
    }
  }

  // 状态

  bool get hasTrack => _currentTrack != null;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  PlayMode get mode => _mode;
  String? get lastError => _lastError;
  SourceTrack? get currentSourceTrack => _currentTrack;

  /// 最近一次 `playTracks` 传入的上下文名（系统媒体会话/快照映射用）。
  String? get contextName => _contextName;

  /// 按当前模式解析出的下一首（界面预览；shuffle 为排列中的下一首，
  /// 本轮末尾为空——自动播完/手动切歌时才重洗新一轮）。
  SourceTrack? get nextSourceTrack {
    final index = _nextIndexForDisplay();
    return index < 0 ? null : _queue[index];
  }

  /// 已播放顺序（最近在后）。
  List<SourceTrack> get historyTracks => _order.tracksOf(_queue);

  /// 实际播放顺序中当前曲目之后的曲目（队列页「接下来」展示用）：
  /// 顺序模式 = 队列下一位起；shuffle = 本轮洗牌排列的剩余。
  List<SourceTrack> get upNextTracks {
    if (_currentIndex < 0 || _queue.isEmpty) return const [];
    if (_mode == PlayMode.shuffle && _queue.length > 1) {
      _ensureShuffleOrder();
      return List.unmodifiable([
        for (final index in _shuffleOrder.remainingAfter(_currentIndex))
          _queue[index],
      ]);
    }
    return List.unmodifiable([
      for (var i = _currentIndex + 1; i < _queue.length; i++) _queue[i],
    ]);
  }

  /// 当前播放进度（用于系统媒体会话状态映射）。
  Duration get position => _position;

  /// 当前曲目时长（优先使用播放器解析出的时长）。
  Duration get duration => _duration;

  /// 当前队列与下标（用于系统媒体会话的队列展示与跳转）。
  List<SourceTrack> get queueTracks => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  // 播放控制

  Future<void> playTracks(
    List<SourceTrack> tracks,
    int index, {
    String? contextName,
  }) async {
    if (tracks.isEmpty) return;
    _queue
      ..clear()
      ..addAll(tracks);
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
            final fileName = CacheService.audioCacheKey(
              sourceKey: track.sourceKey,
              songId: track.id,
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

  /// 是否尝试边播边缓存：仅 Android / iOS / macOS。
  ///
  /// 桌面（Windows/Linux）的 media_kit 后端把 StreamAudioSource 当普通 URI
  /// 交给 mpv 走 just_audio 本地代理，遇到开放式 Range 请求会触发 just_audio
  /// 内部空值错误；Web 无文件系统。这些平台直接流播，避免缓存拖垮播放。
  bool get _platformSupportsAudioCaching {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  Future<void> toggle() async {
    if (_currentTrack == null) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
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
    await _player.seek(position);
    _position = position;
    _scheduleNotify();
  }

  Future<void> skipToNext() async {
    // 手动切歌与界面预览同源：shuffle 走洗牌排列的下一首（本轮末尾自动
    // 重洗新一轮）；单曲循环下手动切歌走队列下一位（只有自动播完才重播）。
    final index = _nextIndex(auto: false);
    if (index < 0) {
      await _player.pause();
      await _player.seek(Duration.zero);
      return;
    }
    await _playIndex(index);
  }

  Future<void> skipToPrevious() async {
    if (_currentTrack == null || _queue.isEmpty) return;
    // 永远切上一首：滑动/按钮/耳机键同一语义，不做「>3 秒重播本曲」。
    // 有播放顺序（含 shuffle）消费最近一首；否则回退到队列前一位。
    final previous =
        _order.popPrevious() ?? (_currentIndex > 0 ? _currentIndex - 1 : 0);
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
    final next = PlayMode.values[(_mode.index + 1) % PlayMode.values.length];
    await setMode(next);
  }

  /// 停止本地播放并清空状态。
  Future<void> stop({bool clear = true}) async {
    _playRequestId++;
    try {
      await _player.stop();
    } catch (_) {}
    _isPlaying = false;
    if (clear) {
      _queue.clear();
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

  /// 界面预览用的下一首下标：shuffle 读排列中的下一首（不重洗，稳定），
  /// 本轮末尾返回 -1（真正切歌时才会重洗新一轮）；其余模式同手动切歌。
  int _nextIndexForDisplay() {
    if (_queue.isEmpty || _currentIndex < 0) return -1;
    if (_mode == PlayMode.shuffle) {
      if (_queue.length <= 1) return _currentIndex;
      _ensureShuffleOrder();
      return _shuffleOrder.peekNext(_currentIndex) ?? -1;
    }
    return _nextIndex(auto: false);
  }

  /// 下一首下标（自动播完 / 手动切歌共用）：shuffle 走排列，轮末重洗。
  int _nextIndex({required bool auto}) {
    if (_queue.isEmpty) return -1;
    if (_mode == PlayMode.singleRepeat && auto) {
      return _currentIndex;
    }
    if (_mode == PlayMode.shuffle) {
      if (_queue.length == 1) return _currentIndex;
      _ensureShuffleOrder();
      return _shuffleOrder.next(_currentIndex);
    }
    if (_currentIndex + 1 < _queue.length) return _currentIndex + 1;
    return -1;
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
    _isPlaying = state.playing &&
        state.processingState != ProcessingState.completed;
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
      if (_mode == PlayMode.singleRepeat) {
        await _player.seek(Duration.zero);
        _resumeCurrentTrack();
      } else {
        final index = _nextIndex(auto: true);
        if (index >= 0 && index != _currentIndex) {
          await _playIndex(index);
        } else {
          _isPlaying = false;
          notifyListeners();
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

  @override
  void dispose() {
    _playRequestId++;
    _notifyThrottle?.cancel();
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }
}
