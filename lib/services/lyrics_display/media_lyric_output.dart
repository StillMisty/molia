import 'media_lyric_composer.dart';
import 'lyrics_display_settings.dart';
import 'lyrics_output.dart';

/// 媒体会话元数据输出：通知/锁屏 profile + 蓝牙 profile 合并写入
/// [LocalAudioHandler] 的歌词覆盖入口（同一份 MediaItem 驱动通知与 AVRCP）。
class MediaLyricOutput implements LyricsOutput {
  MediaLyricOutput({
    required bool Function() supported,
    required void Function(LyricMetadataOverride? override) applyOverride,
    required bool Function() a2dpConnected,
    MediaLyricComposer composer = const MediaLyricComposer(),
  })  : _supported = supported,
        _applyOverride = applyOverride,
        _a2dpConnected = a2dpConnected,
        _composer = composer;

  final bool Function() _supported;
  final void Function(LyricMetadataOverride?) _applyOverride;
  final bool Function() _a2dpConnected;
  final MediaLyricComposer _composer;

  LyricsDisplaySettings? _settings;
  LyricMetadataOverride? _last;
  LyricsOutputCapability _capability = LyricsOutputCapability.unsupported;

  @override
  String get id => LyricsOutputIds.media;

  @override
  LyricsOutputCapability get capability => _capability;

  @override
  Future<void> start(LyricsDisplaySettings settings) async {
    _settings = settings;
    _capability = _supported()
        ? LyricsOutputCapability.ready
        : LyricsOutputCapability.unsupported;
  }

  @override
  Future<void> apply(LyricsPresentation presentation) async {
    final settings = _settings;
    if (settings == null ||
        _capability != LyricsOutputCapability.ready) {
      return;
    }
    final override = _composer.compose(
      presentation: presentation,
      settings: settings,
      a2dpConnected: _a2dpConnected(),
    );
    if (override == _last) return;
    _last = override;
    _applyOverride(override);
  }

  @override
  Future<void> clear() async {
    if (_last == null) return;
    _last = null;
    _applyOverride(null);
  }

  @override
  Future<void> stop() => clear();
}
