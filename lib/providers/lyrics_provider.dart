import 'package:flutter/foundation.dart';

import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import '../services/lyrics_service.dart';

/// 歌词加载状态。
enum LyricsStatus { idle, loading, ready, empty }

/// 当前曲目的歌词状态（不可变；lines 仅在 ready 时非空）。
@immutable
class LyricsState {
  final String? trackId;
  final LyricsStatus status;
  final List<LyricLine> lines;

  /// 是否有时间轴（false = 未同步歌词，行时间戳为展示用伪值）。
  final bool isSynced;
  final String? providerName;

  const LyricsState({
    this.trackId,
    this.status = LyricsStatus.idle,
    this.lines = const [],
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
      other.isSynced == isSynced &&
      other.providerName == providerName;

  @override
  int get hashCode =>
      Object.hash(trackId, status, Object.hashAll(lines), isSynced, providerName);
}

/// 歌词会话模块：取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现。
///
/// 旧实现把这些步骤分别拼装在 LyricsWidget / LyricsSearchPage 内
/// （widget 里 `new LyricsService()`、两套时间戳正则、失败路径重复取词）；
/// 现在 UI 只调用 [load] / [preload] / [saveManual] 并渲染 [state]。
class LyricsProvider extends ChangeNotifier {
  LyricsProvider({LyricsService? service})
      : _service = service ?? LyricsService();

  final LyricsService _service;

  LyricsState _state = LyricsState.idle;
  LyricsState get state => _state;

  /// 过期响应守卫：每次发起新加载自增。
  int _requestId = 0;

  /// 已成功预取 / 正在预取的曲目 id（避免重复取词）。
  final Set<String> _preloadedTrackIds = {};
  final Set<String> _preloadingTrackIds = {};

  /// 加载曲目歌词；同一曲目已有结果 / 正在加载时直接复用。
  Future<void> load(Track track) async {
    final trackId = track.id.uri;
    if (_state.trackId == trackId &&
        _state.status != LyricsStatus.idle) {
      return;
    }
    final requestId = ++_requestId;
    _setState(LyricsState(trackId: trackId, status: LyricsStatus.loading));
    final result = await _service.getLyrics(
      track.title,
      _artistNames(track),
      trackId,
    );
    if (requestId != _requestId) return; // 过期响应：丢弃
    _setState(_stateFor(trackId, result?.lyric, result?.provider));
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
      final result =
          await _service.getLyrics(track.title, _artistNames(track), trackId);
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
  Future<void> saveManual({
    required String trackId,
    required String lyric,
    required String providerName,
  }) async {
    await _service.saveLyrics(trackId, lyric, providerName);
    if (_state.trackId == trackId) {
      _setState(_stateFor(trackId, lyric, providerName));
    }
  }

  /// 清空（无曲目时由 UI 调用）。
  void reset() {
    _requestId++;
    _setState(LyricsState.idle);
  }

  LyricsState _stateFor(
    String trackId,
    String? rawLyrics,
    String? providerName,
  ) {
    if (rawLyrics == null) {
      return LyricsState(
        trackId: trackId,
        status: LyricsStatus.empty,
        providerName: providerName,
      );
    }
    if (hasLyricTimestamps(rawLyrics)) {
      final parsed = parseLyrics(rawLyrics);
      if (parsed.isNotEmpty) {
        return LyricsState(
          trackId: trackId,
          status: LyricsStatus.ready,
          lines: parsed,
          isSynced: true,
          providerName: providerName,
        );
      }
    }
    final unsynced = buildUnsyncedLyrics(rawLyrics);
    if (unsynced.isEmpty) {
      return LyricsState(
        trackId: trackId,
        status: LyricsStatus.empty,
        providerName: providerName,
      );
    }
    return LyricsState(
      trackId: trackId,
      status: LyricsStatus.ready,
      lines: unsynced,
      isSynced: false,
      providerName: providerName,
    );
  }

  void _setState(LyricsState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  static String _artistNames(Track track) => track.artists
      .map((artist) => artist.name)
      .where((name) => name.isNotEmpty)
      .join(', ');
}
