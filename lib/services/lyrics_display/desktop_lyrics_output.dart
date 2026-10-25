import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/lyric_line.dart';
import '../../theme/scheme_builder.dart';
import 'lyric_color_resolver.dart';
import 'lyrics_channel.dart';
import 'lyrics_display_settings.dart';
import 'lyrics_output.dart';

/// Android 桌面悬浮歌词输出（原生悬浮窗）。
///
/// 展示策略（暂停回退 / 无歌词回退 / 翻译开关）在 Dart 侧应用后再下发；
/// 原生只渲染文本、处理拖动/锁定/控制条，并自行持久化窗口位置。
/// 窗口生命周期同样在本层：暂停整窗隐藏（`desktop.hideOnPause`）与恢复
/// 重显都经 `_canShow` 判定，原生不感知「暂停」这一概念。
class DesktopLyricsOutput implements InteractiveLyricsOutput {
  DesktopLyricsOutput({
    LyricsChannel? channel,
    bool? supported,
    this._colorScheme,
    this._artworkColorScheme,
    this._appFontFamily,
  })  : _channel = channel ?? LyricsChannel.instance,
        _supported = supported ?? LyricsChannel.isSupportedPlatform {
    if (_supported) {
      _eventSub = _channel.events.listen(_onChannelEvent);
    }
  }

  final LyricsChannel _channel;
  final bool _supported;

  /// 应用主题色板提供者（跟随主题的来源之一；为空时只有自定义色可用）。
  final ColorScheme Function()? _colorScheme;

  /// 当前曲目封面色板提供者（「跟随封面」来源；无封面时返回 null，
  /// 由 [resolveSurfaceScheme] 回退应用主题）。
  final ColorScheme? Function()? _artworkColorScheme;

  /// 「应用字体」提供者（设置页所选字体族；null = 系统默认）。
  ///
  /// 悬浮窗文本跟随应用字体：原生只认字体族名，解析不了时回退系统默认字体
  /// （等价于不覆盖）。字体变化经 [LyricsDisplayProvider] 的主题通道重下发，
  /// 配置等价判定（[_configEquals]）保证只在真变化时 `setConfig`。
  final String? Function()? _appFontFamily;
  final StreamController<LyricsOutputAction> _actions =
      StreamController<LyricsOutputAction>.broadcast();

  StreamSubscription<LyricsChannelEvent>? _eventSub;
  LyricsDisplaySettings? _settings;
  LyricsOutputCapability _capability = LyricsOutputCapability.unsupported;
  bool _shown = false;

  /// 上次成功下发的配置（`show` / `setConfig` 都算）：设置变化但悬浮窗
  /// 配置没变（如只改歌词页开关）时跳过 `setConfig`，避免原生无谓重建——
  /// 重建会打断滚动、并在新视图布局完成前瞬间重置横滚位移（闪一下）。
  Map<String, Object?>? _lastConfig;

  /// 上次投送的播放态（暂停隐藏 `desktop.hideOnPause` 的窗口生命周期依据）。
  ///
  /// 未知视为未播放：首次投送到达前不主动显示，避免恢复出的暂停会话先闪
  /// 一下窗口；播放中启用桌面歌词时，首次投送会立刻把窗口带出来。
  bool _playing = false;

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
    if (!_canShow(settings)) {
      await _hideIfShown();
      return;
    }
    final config = _configOf(settings);
    if (!_shown) {
      await _channel.showDesktop(config);
      _shown = true;
      _lastConfig = config;
      return;
    }
    // 幂等：配置没变就不重发（播放页开关等设置变化不该重建悬浮窗）。
    if (_configEquals(_lastConfig, config)) return;
    await _channel.setDesktopConfig(config);
    _lastConfig = config;
  }

  /// 当前是否应显示悬浮窗：配置开启 + 权限就绪 + 不在「暂停隐藏」态。
  ///
  /// 权限判定与 [start] 的复查同源——[apply] 也用它决定要不要自行 `show`，
  /// 无权限时绝不 addView（原生会抛 SecurityException）。
  bool _canShow(LyricsDisplaySettings s) =>
      s.desktopEnabled &&
      _capability == LyricsOutputCapability.ready &&
      !(s.desktopHideOnPause && !_playing);

  @override
  Future<void> apply(LyricsPresentation presentation) async {
    final settings = _settings;
    if (settings == null) return;
    _playing = presentation.isPlaying;
    if (!_canShow(settings)) {
      // 暂停隐藏（或权限被撤 / 配置关闭）：窗口整体移除，自然也不投送内容。
      await _hideIfShown();
      return;
    }
    if (!_shown) {
      // 恢复播放（或清空后重新具备条件）：重建窗口 + 首次内容一起下发，
      // 位置由原生按比例持久化，回到暂停前的位置。
      final config = _configOf(settings);
      await _channel.showDesktop(config);
      _shown = true;
      _lastConfig = config;
    }
    await _channel.updateDesktop(_presentationMap(presentation, settings));
  }

  @override
  Future<void> clear() => _hideIfShown();

  @override
  Future<void> stop() async {
    await _hideIfShown();
    _lastConfig = null;
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
    final scheme = _resolveScheme(s);
    return {
      'fontSize': s.desktopFontSize,
      // 悬浮窗文本跟随「应用字体」：null = 不覆盖，原生用系统默认字体
      // （与 Flutter 侧未自定义字体时的平台默认排版一致）。
      'fontFamily': _appFontFamily?.call(),
      'opacity': s.desktopOpacity,
      'playedColor':
          _resolveColor(s.desktopPlayedColorSource, s.desktopPlayedColor, scheme),
      'unplayedColor': _resolveColor(
          s.desktopUnplayedColorSource, s.desktopUnplayedColor, scheme),
      'shadowColor':
          _resolveColor(s.desktopShadowColorSource, s.desktopShadowColor, scheme),
      'widthPercent': s.desktopWidthPercent,
      'maxLines': s.desktopMaxLines,
      'textAlignX': s.desktopTextAlignX.name,
      'lock': s.desktopLock,
      'freezeOnScreenOff': s.desktopFreezeOnScreenOff,
      'showToggleAnimation': s.desktopShowToggleAnimation,
      'controls': s.desktopControls,
      // 控制条配色与描边同源（跟随同一套解析方案），保证悬浮窗在任意背景
      // 上都有一致的 M3 观感；无方案（无宿主注入）时给深色兜底。
      'controlBackground': scheme == null
          ? 0xEE1B1B1F
          : scheme.surfaceContainerHigh.withValues(alpha: 0.94).toARGB32(),
      'controlTint': scheme?.onSurfaceVariant.toARGB32() ?? 0xFFFFFFFF,
    };
  }

  /// 配置等价判定：标量直接比较；`controls` 是每次现取的 unmodifiable map，
  /// 按键值比较（引用比较会永远不等，去重失效）。
  static bool _configEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      final av = entry.value;
      final bv = b[entry.key];
      if (av is Map && bv is Map) {
        if (!mapEquals(av, bv)) return false;
      } else if (av != bv) {
        return false;
      }
    }
    return true;
  }

  /// 「跟随主题角色」所用方案：按设置来源解析，封面缺失回退应用主题；
  /// 应用主题不可用（无宿主注入）时返回 null，颜色行只允许自定义色。
  ColorScheme? _resolveScheme(LyricsDisplaySettings s) {
    final appScheme = _colorScheme?.call();
    if (appScheme == null) return null;
    return resolveSurfaceScheme(
      s.desktopSchemeSource,
      appScheme: appScheme,
      artworkScheme: _artworkColorScheme?.call(),
    );
  }

  int _resolveColor(LyricColorSource source, int custom, ColorScheme? scheme) =>
      scheme == null ? custom : resolveLyricColor(source, custom, scheme);

  Map<String, Object?> _presentationMap(
      LyricsPresentation p, LyricsDisplaySettings s) {
    var line = p.line;
    // 无歌词回退 / 暂停回退（歌名 / 清空）下主行已不是歌词行：翻译与罗马音
    // 必须同步撤下，否则主行换成歌名（或清空）后扩展行仍残留在悬浮窗上。
    // keep 保留原行，扩展行原样下发。
    var replacedLine = false;
    if (!p.hasLyrics) {
      line = s.desktopNoLyricsBehavior == DesktopNoLyricsBehavior.title
          ? p.title
          : '';
      replacedLine = true;
    } else if (!p.isPlaying) {
      switch (s.desktopPauseBehavior) {
        case LyricsPauseBehavior.keep:
          break;
        case LyricsPauseBehavior.title:
          line = p.title;
          replacedLine = true;
        case LyricsPauseBehavior.clear:
          line = '';
          replacedLine = true;
      }
    }
    return {
      'title': p.title,
      'line': line,
      // 扩展槽数固定窗口行数：翻译 / 罗马音开关变化只改槽内容，不改窗口
      // 高度（原生窗口底缘锚定，高度逐行变化会让主行上下跳）。随内容一起
      // 投送而不是走 setConfig——开关切换时只重建一次，避免配置重下发先做
      // 一次无动画重建、紧接着 update 再重建一次的闪烁。
      'extendedSlots': (s.translationEnabled ? 1 : 0) + (s.romaEnabled ? 1 : 0),
      'extended': replacedLine ? const <String>[] : p.extended,
      'upcoming': replacedLine ? const <String>[] : p.upcoming,
      'isPlaying': p.isPlaying,
      'hasLyrics': p.hasLyrics,
      'positionMs': p.positionMs,
      // 采样生效的墙上时刻：原生据此补偿通道传输延迟（主线程繁忙时投递变慢），
      // 否则延迟抖动会直接变成可见的回跳。
      'positionAtEpochMs': p.positionAtEpochMs,
      // 回退行（歌名 / 清空）没有逐字时间轴，也没有行时间轴（不滚动）。
      'lineStartMs': replacedLine ? -1 : p.lineStartMs,
      'lineEndMs': replacedLine ? -1 : p.lineEndMs,
      'scrollFollowsSinging': p.scrollFollowsSinging,
      'words': replacedLine ? null : _wordsMap(p.words),
    };
  }

  /// 逐字时间轴 → 通道结构（绝对毫秒；文本拼接与主行一致）。
  List<Map<String, Object>>? _wordsMap(List<LyricWord>? words) {
    if (words == null || words.isEmpty) return null;
    return [
      for (final word in words)
        <String, Object>{
          't': word.text,
          's': word.start.inMilliseconds,
          'e': word.end.inMilliseconds,
        },
    ];
  }
}
