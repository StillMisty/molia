import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'lyric_color_resolver.dart';
import 'lyrics_channel.dart';
import 'lyrics_display_settings.dart';
import 'lyrics_output.dart';

/// Android 桌面悬浮歌词输出（原生悬浮窗）。
///
/// 展示策略（暂停回退 / 无歌词回退 / 翻译开关）在 Dart 侧应用后再下发；
/// 原生只渲染文本、处理拖动/锁定/控制条，并自行持久化窗口位置。
class DesktopLyricsOutput implements InteractiveLyricsOutput {
  DesktopLyricsOutput({
    LyricsChannel? channel,
    bool? supported,
    ColorScheme Function()? colorScheme,
  })  : _channel = channel ?? LyricsChannel.instance,
        _supported = supported ?? LyricsChannel.isSupportedPlatform,
        _colorScheme = colorScheme {
    if (_supported) {
      _eventSub = _channel.events.listen(_onChannelEvent);
    }
  }

  final LyricsChannel _channel;
  final bool _supported;

  /// 主题色板提供者（跟随主题的颜色来源；为空时只有自定义色可用）。
  final ColorScheme Function()? _colorScheme;
  final StreamController<LyricsOutputAction> _actions =
      StreamController<LyricsOutputAction>.broadcast();

  StreamSubscription<LyricsChannelEvent>? _eventSub;
  LyricsDisplaySettings? _settings;
  LyricsOutputCapability _capability = LyricsOutputCapability.unsupported;
  bool _shown = false;

  @override
  String get id => LyricsOutputIds.desktop;

  @override
  LyricsOutputCapability get capability =>
      _supported ? _capability : LyricsOutputCapability.unsupported;

  @override
  Stream<LyricsOutputAction> get actions => _actions.stream;

  void _onChannelEvent(LyricsChannelEvent event) {
    if (event.method != 'desktop.onAction') return;
    final action = _actionFromName(event.arguments['action']?.toString());
    if (action != null) _actions.add(action);
  }

  static LyricsOutputAction? _actionFromName(String? name) {
    for (final action in LyricsOutputAction.values) {
      if (action.name == name) return action;
    }
    return null;
  }

  /// 复查悬浮窗权限（授权返回 / 回前台时调用）。
  Future<void> refreshCapability() async {
    if (!_supported) return;
    _capability = await _channel.canDrawOverlays()
        ? LyricsOutputCapability.ready
        : LyricsOutputCapability.needsPermission;
  }

  /// 跳系统悬浮窗授权页。
  Future<void> requestPermission() async {
    if (!_supported) return;
    await _channel.openOverlayPermission();
  }

  /// 重置悬浮窗位置（原生侧持久化同步清除）。
  Future<void> resetPosition() async {
    if (!_supported) return;
    await _channel.resetDesktopPosition();
  }

  @override
  Future<void> start(LyricsDisplaySettings settings) async {
    _settings = settings;
    if (!_supported) return;
    await refreshCapability();
    if (!settings.desktopEnabled ||
        _capability != LyricsOutputCapability.ready) {
      await _hideIfShown();
      return;
    }
    final config = _configOf(settings);
    if (!_shown) {
      await _channel.showDesktop(config);
      _shown = true;
    }
    await _channel.setDesktopConfig(config);
  }

  @override
  Future<void> apply(LyricsPresentation presentation) async {
    final settings = _settings;
    if (!_shown || settings == null || !settings.desktopEnabled) return;
    await _channel.updateDesktop(_presentationMap(presentation, settings));
  }

  @override
  Future<void> clear() => _hideIfShown();

  @override
  Future<void> stop() async {
    await _hideIfShown();
    await _eventSub?.cancel();
    _eventSub = null;
    await _actions.close();
  }

  Future<void> _hideIfShown() async {
    if (!_shown) return;
    _shown = false;
    await _channel.hideDesktop();
  }

  Map<String, Object?> _configOf(LyricsDisplaySettings s) {
    final scheme = _colorScheme?.call();
    return {
      'fontSize': s.desktopFontSize,
      'opacity': s.desktopOpacity,
      'playedColor':
          _resolveColor(s.desktopPlayedColorSource, s.desktopPlayedColor, scheme),
      'unplayedColor': _resolveColor(
          s.desktopUnplayedColorSource, s.desktopUnplayedColor, scheme),
      'shadowColor':
          _resolveColor(s.desktopShadowColorSource, s.desktopShadowColor, scheme),
      'widthPercent': s.desktopWidthPercent,
      'singleLine': s.desktopSingleLine,
      'maxLines': s.desktopMaxLines,
      'textAlignX': s.desktopTextAlignX.name,
      'textAlignY': s.desktopTextAlignY.name,
      'lock': s.desktopLock,
      'freezeOnScreenOff': s.desktopFreezeOnScreenOff,
      'showToggleAnimation': s.desktopShowToggleAnimation,
      'controls': s.desktopControls,
    };
  }

  int _resolveColor(LyricColorSource source, int custom, ColorScheme? scheme) =>
      scheme == null ? custom : resolveLyricColor(source, custom, scheme);

  Map<String, Object?> _presentationMap(
      LyricsPresentation p, LyricsDisplaySettings s) {
    var line = p.line;
    if (!p.hasLyrics) {
      line = s.desktopNoLyricsBehavior == DesktopNoLyricsBehavior.title
          ? p.title
          : '';
    } else if (!p.isPlaying) {
      switch (s.desktopPauseBehavior) {
        case LyricsPauseBehavior.keep:
          break;
        case LyricsPauseBehavior.title:
          line = p.title;
        case LyricsPauseBehavior.clear:
          line = '';
      }
    }
    return {
      'title': p.title,
      'line': line,
      'extended': p.extended,
      'upcoming': p.upcoming,
      'isPlaying': p.isPlaying,
      'hasLyrics': p.hasLyrics,
    };
  }
}
