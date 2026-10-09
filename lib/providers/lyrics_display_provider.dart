import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../services/lyrics_display/audio_route_monitor.dart';
import '../services/lyrics_display/desktop_lyrics_output.dart';
import '../services/lyrics_display/lyric_line_tracker.dart';
import '../services/lyrics_display/lyrics_display_settings.dart';
import '../services/lyrics_display/lyrics_output.dart';
import 'lyrics_provider.dart';

/// 桌面悬浮窗控制条动作 → 播放控制命令（由组合根接回 PlaybackProvider）。
enum LyricsPlaybackCommand { playPause, previous, next }

/// 歌词显示调度：订阅播放快照 / 进度 / 歌词状态，把「当前该展示什么」
/// 投送到各 [LyricsOutput]。
///
/// - 所有展示策略（行定位、偏移、回退、格式、门控）在 Dart 侧应用；
/// - 只在行 / 播放态变化时下发（[LyricsPresentation] 去重）；
/// - 任一输出失败只降级该输出，不影响播放与 UI。
class LyricsDisplayProvider extends ChangeNotifier {
  LyricsDisplayProvider({
    required this.settings,
    required List<LyricsOutput> outputs,
    AudioRouteMonitor? audioRoute,
    Listenable? themeListenable,
    Future<void> Function(Track track)? ensureLyrics,
    void Function(LyricsPlaybackCommand command)? onPlaybackCommand,
  })  : _outputs = List.unmodifiable(outputs),
        _audioRoute = audioRoute,
        _themeListenable = themeListenable,
        _ensureLyrics = ensureLyrics,
        _onPlaybackCommand = onPlaybackCommand {
    for (final output in _outputs) {
      if (output is InteractiveLyricsOutput) {
        _subscriptions.add(output.actions.listen(_onOutputAction));
      }
    }
    settings.addListener(_onSettingsChanged);
    _audioRoute?.addListener(_onA2dpChanged);
    // 主题变化（莫奈 / 封面取色 / 亮度）→ 重新下发跟随主题的颜色。
    _themeListenable?.addListener(_onThemeChanged);
    unawaited(_syncOutputs());
  }

  final LyricsDisplaySettings settings;
  final List<LyricsOutput> _outputs;
  final AudioRouteMonitor? _audioRoute;
  final Listenable? _themeListenable;
  final Future<void> Function(Track track)? _ensureLyrics;
  final void Function(LyricsPlaybackCommand command)? _onPlaybackCommand;
  final LyricLineTracker _tracker = const LyricLineTracker();
  final List<StreamSubscription<LyricsOutputAction>> _subscriptions = [];
  final Map<String, LyricsPresentation> _applied = {};

  Duration _position = Duration.zero;
  Track? _currentTrack;
  bool _isPlaying = false;
  LyricsState _lyricsState = LyricsState.idle;
  String? _requestedTrackId;
  bool _disposed = false;

  bool get a2dpConnected => _audioRoute?.connected ?? false;

  /// 至少一个输出处于启用配置（用于决定是否主动取词）。
  bool get anyOutputEnabled =>
      settings.desktopEnabled ||
      settings.notificationEnabled ||
      settings.bluetoothEnabled;

  /// 输出能力（设置页按此显隐分组 / 提示权限）。
  LyricsOutputCapability capabilityOf(String outputId) {
    for (final output in _outputs) {
      if (output.id == outputId) return output.capability;
    }
    return LyricsOutputCapability.unsupported;
  }

  /// 复查平台能力（授权返回 / 回前台时调用），并按配置重新激活输出。
  Future<void> refreshCapabilities() async {
    await _desktopOutput?.refreshCapability();
    await _syncOutputs();
    if (!_disposed) notifyListeners();
  }

  /// 跳系统悬浮窗授权页。
  Future<void> requestDesktopOverlayPermission() async {
    await _desktopOutput?.requestPermission();
  }

  /// 重置悬浮窗位置。
  Future<void> resetDesktopPosition() async {
    await _desktopOutput?.resetPosition();
  }

  /// 播放快照变化（曲目 / 播放态）。
  void syncPlayback(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    final track = snapshot.current;
    final trackChanged = track?.id.uri != _currentTrack?.id.uri;
    _currentTrack = track;
    _isPlaying = snapshot.isPlaying;
    if (track == null) {
      _dispatch(force: true);
      return;
    }
    if (trackChanged && anyOutputEnabled) {
      _ensureTrackLyrics(track);
    }
    _dispatch(force: trackChanged);
  }

  /// 进度通道（≤4Hz）变化。
  void updatePosition(Duration position) {
    if (_disposed || position == _position) return;
    _position = position;
    _dispatch();
  }

  /// 歌词会话状态变化。
  void syncLyrics(LyricsState state) {
    if (_disposed) return;
    _lyricsState = state;
    _dispatch(force: true);
  }

  void _ensureTrackLyrics(Track track) {
    final id = track.id.uri;
    if (id == _requestedTrackId) return;
    _requestedTrackId = id;
    final ensure = _ensureLyrics;
    if (ensure == null) return;
    unawaited(ensure(track).catchError((Object _) {}));
  }

  LyricsPresentation? _buildPresentation() {
    final track = _currentTrack;
    if (track == null) return null;
    final state = _lyricsState;
    final ready = state.status == LyricsStatus.ready &&
        state.lines.isNotEmpty &&
        state.trackId == track.id.uri;
    final tracked = ready
        ? _tracker.track(
            lines: state.lines,
            translations: state.translations,
            romas: state.romas,
            isSynced: state.isSynced,
            position: _position,
            title: track.title,
            offsetMs: settings.offsetMs,
            translationEnabled: settings.translationEnabled,
            romaEnabled: settings.romaEnabled,
            unsyncedBehavior: settings.unsyncedBehavior,
            maxLines:
                settings.desktopSingleLine ? 1 : settings.desktopMaxLines,
          )
        : const TrackedLine();
    return LyricsPresentation(
      trackId: track.id.uri,
      title: track.title,
      line: tracked.line,
      extended: tracked.extended,
      upcoming: tracked.upcoming,
      isPlaying: _isPlaying,
      hasLyrics: ready,
    );
  }

  void _dispatch({bool force = false}) {
    if (_disposed) return;
    for (final output in _outputs) {
      if (!_isOutputEnabled(output.id)) {
        if (_applied.remove(output.id) != null) {
          unawaited(_guard(output.clear()));
        }
        continue;
      }
      final presentation = _buildPresentation();
      if (presentation == null) {
        if (_applied.remove(output.id) != null) {
          unawaited(_guard(output.clear()));
        }
        continue;
      }
      if (!force && _applied[output.id] == presentation) continue;
      _applied[output.id] = presentation;
      unawaited(_guard(output.apply(presentation)));
    }
  }

  bool _isOutputEnabled(String outputId) {
    switch (outputId) {
      case LyricsOutputIds.desktop:
        return settings.desktopEnabled;
      case LyricsOutputIds.media:
        return settings.notificationEnabled || settings.bluetoothEnabled;
      default:
        return false;
    }
  }

  Future<void> _guard(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // 任一输出失败只降级该输出，不影响播放 / UI。
    }
  }

  Future<void> _syncOutputs() async {
    if (_disposed) return;
    for (final output in _outputs) {
      await _guard(output.start(settings));
    }
    _dispatch(force: true);
  }

  void _onSettingsChanged() {
    if (_disposed) return;
    unawaited(_syncOutputs());
    notifyListeners();
  }

  void _onA2dpChanged() {
    if (_disposed) return;
    _dispatch(force: true);
    notifyListeners();
  }

  void _onThemeChanged() {
    if (_disposed) return;
    // 主题变化（莫奈 / 封面取色 / 亮度）→ 重新下发跟随主题的歌词颜色；
    // 主题自身已有 UI 通知，这里不需要再 notify。
    unawaited(_syncOutputs());
  }

  void _onOutputAction(LyricsOutputAction action) {
    if (_disposed) return;
    switch (action) {
      case LyricsOutputAction.playPause:
        _onPlaybackCommand?.call(LyricsPlaybackCommand.playPause);
      case LyricsOutputAction.previous:
        _onPlaybackCommand?.call(LyricsPlaybackCommand.previous);
      case LyricsOutputAction.next:
        _onPlaybackCommand?.call(LyricsPlaybackCommand.next);
      case LyricsOutputAction.toggleTranslation:
        unawaited(settings.setTranslationEnabled(!settings.translationEnabled));
      case LyricsOutputAction.lock:
        unawaited(settings.setDesktopLock(!settings.desktopLock));
      case LyricsOutputAction.close:
        unawaited(settings.setDesktopEnabled(false));
    }
  }

  DesktopLyricsOutput? get _desktopOutput {
    for (final output in _outputs) {
      if (output is DesktopLyricsOutput) return output;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_onSettingsChanged);
    _audioRoute?.removeListener(_onA2dpChanged);
    _themeListenable?.removeListener(_onThemeChanged);
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    for (final output in _outputs) {
      unawaited(_guard(output.stop()));
    }
    super.dispose();
  }
}
