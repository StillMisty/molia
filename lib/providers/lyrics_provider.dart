import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import '../services/lyrics_service.dart';

/// 歌词加载状态。
enum LyricsStatus { idle, loading, ready, empty }

/// 当前曲目的歌词状态（不可变；lines 仅在 ready 时非空）。
///
/// [translations] / [romas] 与 [lines] 等长（'' = 该行无对应扩展文本），
/// 为空列表表示该曲目没有翻译 / 罗马音。
@immutable
class LyricsState {
  final String? trackId;
  final LyricsStatus status;
  final List<LyricLine> lines;

  /// 与 [lines] 等长的翻译文本（'' = 无）。
  final List<String> translations;

  /// 与 [lines] 等长的罗马音文本（'' = 无）。
  final List<String> romas;

  /// 是否有时间轴（false = 未同步歌词，行时间戳为展示用伪值）。
  final bool isSynced;
  final String? providerName;

  const LyricsState({
    this.trackId,
    this.status = LyricsStatus.idle,
    this.lines = const [],
    this.translations = const [],
    this.romas = const [],
    this.isSynced = true,
    this.providerName,
  });

  static const LyricsState idle = LyricsState();

  @override
  bool operator ==(Object other) =>
      other is LyricsState &&
      other.trackId == trackId &&
      other.status == status &&
      listEquals(other.lines, lines) &&
      listEquals(other.translations, translations) &&
      listEquals(other.romas, romas) &&
      other.isSynced == isSynced &&
      other.providerName == providerName;

  @override
  int get hashCode => Object.hash(
    trackId,
    status,
    Object.hashAll(lines),
    Object.hashAll(translations),
    Object.hashAll(romas),
    isSynced,
    providerName,
  );
}

/// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
///
/// 曲目变化的加载入口只有 [ensureForTrack]：组合根订阅播放快照后调用，
/// 页面只渲染 [state]（不再从 build 触发取词）。输出侧 / 预取 / 手动选择
/// 分别走 [preload] / [saveManual]；[retry] 供页面或用户显式重试。
class LyricsProvider extends ChangeNotifier {
  LyricsProvider({LyricsService? service})
    : _service = service ?? LyricsService();

  final LyricsService _service;

  LyricsState _state = LyricsState.idle;
  LyricsState get state => _state;

  /// 过期响应守卫：每次发起新加载自增。
  int _requestId = 0;

  /// 会话当前曲目（最近一次 [ensureForTrack] / [load] 的曲目；null = 无曲目）。
  Track? _currentTrack;

  /// 当前曲目空结果后是否已自动重试过一次。
  ///
  /// 播放快照会因播放态 / 队列等变化多次通知；没有这个守卫时，空歌词
  /// 曲目会在每次通知各取一次词。显式 [retry] 不受它限制。
  bool _retriedEmpty = false;

  /// 已成功预取 / 正在预取的曲目 id（避免重复取词）。
  final Set<String> _preloadedTrackIds = {};
  final Set<String> _preloadingTrackIds = {};

  /// 在途取词（按曲目 id 合并 ensure / preload）：组合根在起播后立即预取
  /// 下一首，用户快速切到该曲时 ensure 会再点一次；没有合并的话两条链路
  /// 各自跑完「原生取词 + 六提供者并发回退」，网络与解析都翻倍。
  final Map<String, Future<LyricsResult?>> _inFlight = {};

  /// 取词（single-flight）：同曲目的在途请求共用同一个 Future。
  ///
  /// [ignoreCache] 用于登录后强制重取：绕过 single-flight 与歌词缓存，避免
  /// 复用在途的跨平台请求或旧缓存。
  Future<LyricsResult?> _fetch(Track track, {bool ignoreCache = false}) {
    final trackId = track.id.uri;
    Future<LyricsResult?> fetch() => DataPathTrace.async(
      'lyrics.fetch',
      () => _service.getLyrics(
        track.title,
        track.artistLabel,
        trackId,
        track: track,
        ignoreCache: ignoreCache,
      ),
      fields: () => {'track': trackId},
    );
    if (ignoreCache) return fetch();
    final pending = _inFlight[trackId];
    if (pending != null) return pending;
    final future = fetch();
    _inFlight[trackId] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight[trackId], future)) _inFlight.remove(trackId);
      }),
    );
    return future;
  }

  /// 会话入口：按当前曲目推进加载（组合根在播放快照变化时调用）。
  ///
  /// - 曲目变化：立即加载新曲目；
  /// - 同曲目 ready / loading：直接复用（不重复取词）；
  /// - 同曲目 empty：允许一次自动重试（网络瞬断 / 平台临时失败），之后由
  ///   [retry] 显式重来——正常重复调用不会持续打网络；
  /// - `null`：清空会话。
  Future<void> ensureForTrack(Track? track) async {
    final trackId = track?.id.uri ?? '';
    if (trackId.isEmpty) {
      if (_currentTrack != null || _state.status != LyricsStatus.idle) {
        reset();
      }
      return;
    }

    final sameTrack = trackId == _currentTrack?.id.uri;
    _currentTrack = track;
    if (!sameTrack) {
      _retriedEmpty = false;
      await _load(track!, trackId);
      return;
    }
    if (_state.trackId != trackId) {
      // 会话曲目没变但展示状态被清空（例如 reset 之外的显式状态写入）：
      // 仍按「该曲目需要歌词」处理一次。
      await _load(track!, trackId);
      return;
    }
    switch (_state.status) {
      case LyricsStatus.ready || LyricsStatus.loading:
        return;
      case LyricsStatus.idle:
        await _load(track!, trackId);
      case LyricsStatus.empty:
        if (_retriedEmpty) return;
        _retriedEmpty = true;
        await _load(track!, trackId);
    }
  }

  /// 重取当前曲目歌词（页面级重试 / 空结果后的显式重来）。
  ///
  /// [ignoreCache] 为 true 时强制绕过歌词缓存（B 站登录后刷新）。
  Future<void> retry({bool ignoreCache = false}) async {
    final track = _currentTrack;
    if (track == null) return;
    _retriedEmpty = true;
    if (ignoreCache) {
      // 等在途普通请求落盘后再强刷，避免旧结果后写覆盖 B 站字幕。
      final pending = _inFlight[track.id.uri];
      if (pending != null) {
        try {
          await pending;
        } catch (_) {
          // 旧请求失败不影响强刷。
        }
      }
    }
    await _load(track, track.id.uri, ignoreCache: ignoreCache);
  }

  /// B 站登录（本地扫码 / 同步到达）后刷新当前歌词。
  ///
  /// 当前曲目不是 B 站、已经是 B 站字幕、或用户手动选过歌词时不动。
  Future<void> refreshAfterBiliLogin() async {
    final track = _currentTrack;
    if (track == null || track.id.sourceKey != 'bili') return;
    if (_state.status == LyricsStatus.ready && _state.providerName == 'bili') {
      return;
    }
    try {
      if (await _service.hasManualLyrics(track.id.uri)) return;
    } catch (_) {
      // 缓存读取失败按「非手动」处理，继续尝试同源刷新。
    }
    await retry(ignoreCache: true);
  }

  /// 立即加载曲目歌词（调用方已知需要取词）。
  ///
  /// 曲目变化的统一入口是 [ensureForTrack]；本方法不判断「同一曲目已加载」，
  /// 供性能场景 / 测试直接驱动一次完整取词。
  Future<void> load(Track track) {
    _currentTrack = track;
    _retriedEmpty = false;
    return _load(track, track.id.uri);
  }

  Future<void> _load(
    Track track,
    String trackId, {
    bool ignoreCache = false,
  }) async {
    final requestId = ++_requestId;
    _setState(LyricsState(trackId: trackId, status: LyricsStatus.loading));
    final result = await _fetch(track, ignoreCache: ignoreCache);
    if (requestId != _requestId) return; // 过期响应：丢弃
    _setState(_stateFor(trackId, result));
  }

  /// 预取下一首歌词（只写缓存，不改变当前展示状态）。
  Future<void> preload(Track track) async {
    final trackId = track.id.uri;
    if (_state.trackId == trackId ||
        _preloadedTrackIds.contains(trackId) ||
        !_preloadingTrackIds.add(trackId)) {
      return;
    }
    try {
      final result = await _fetch(track);
      if (result != null) {
        _preloadedTrackIds.add(trackId);
      }
    } catch (_) {
      // 预取失败不影响当前展示；切到该曲目时正常重试。
    } finally {
      _preloadingTrackIds.remove(trackId);
    }
  }

  /// 手动选择歌词：写统一缓存；若仍是当前曲目则同步展示状态。
  ///
  /// [translation] / [roma] / [lxlyric] 缺省时清空旧扩展行；
  /// 歌词搜索页透传平台结构化数据时则一并保留。
  Future<void> saveManual({
    required String trackId,
    required String lyric,
    required String providerName,
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    await _service.saveLyrics(
      trackId,
      lyric,
      providerName,
      translation: translation,
      roma: roma,
      lxlyric: lxlyric,
    );
    if (_state.trackId == trackId) {
      _setState(
        _stateFor(
          trackId,
          LyricsResult(
            lyric: lyric,
            provider: providerName,
            translation: translation,
            roma: roma,
            lxlyric: lxlyric,
          ),
        ),
      );
    }
  }

  /// 清空会话（无曲目时由 [ensureForTrack] 调用）。
  void reset() {
    _requestId++;
    _currentTrack = null;
    _retriedEmpty = false;
    _setState(LyricsState.idle);
  }

  LyricsState _stateFor(String trackId, LyricsResult? result) {
    if (result == null) {
      return LyricsState(trackId: trackId, status: LyricsStatus.empty);
    }
    if (hasLyricTimestamps(result.lyric)) {
      final parsed = DataPathTrace.sync(
        'lyrics.parse',
        () => attachWordTimings(parseLyrics(result.lyric), result.lxlyric),
        fields: () => {
          'synced': 1,
          'chars': result.lyric.length,
          'words': result.lxlyric?.length ?? 0,
        },
      );
      if (parsed.isNotEmpty) {
        return LyricsState(
          trackId: trackId,
          status: LyricsStatus.ready,
          lines: parsed,
          translations: alignExtendedLines(parsed, result.translation),
          romas: alignExtendedLines(parsed, result.roma),
          isSynced: true,
          providerName: result.provider,
        );
      }
    }
    final unsynced = buildUnsyncedLyrics(result.lyric);
    if (unsynced.isEmpty) {
      return LyricsState(
        trackId: trackId,
        status: LyricsStatus.empty,
        providerName: result.provider,
      );
    }
    return LyricsState(
      trackId: trackId,
      status: LyricsStatus.ready,
      lines: unsynced,
      translations: alignExtendedLines(unsynced, result.translation),
      romas: alignExtendedLines(unsynced, result.roma),
      isSynced: false,
      providerName: result.provider,
    );
  }

  void _setState(LyricsState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }
}
