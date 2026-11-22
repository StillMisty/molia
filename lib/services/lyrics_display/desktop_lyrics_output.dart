import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/lyric_line.dart';
import '../../theme/scheme_builder.dart';
import 'lyric_color_resolver.dart';
import 'lyrics_channel.dart';
import 'lyrics_display_settings.dart';
import 'lyrics_output.dart';

/// Android 桌面悬浮歌词输出（原生悬浮窗）。
///
/// 展示策略（暂停回退 / 无歌词回退 / 翻译开关）在 Dart 侧应用后再下发；
/// 原生只渲染文本、处理拖动/锁定/控制条，并自行持久化窗口位置。
///
/// 状态机：所有公开方法只更新「期望状态」（设置 / 权限 / 播放态 / 当前行），
/// 由单飞的 reconcile 串行同步到原生。不能在 `start` / `apply` 里各自 await
/// 然后改 `_shown`——两者交错时会出现「暂停了窗口又被 show 出来」「原生已收窗
/// 但 Dart 仍以为在显示」这类状态分叉。
class DesktopLyricsOutput implements InteractiveLyricsOutput {
  DesktopLyricsOutput({
    LyricsChannel? channel,
    bool? supported,
    this._colorScheme,
    this._artworkColorScheme,
    this._appFontFamily,
  }) : _channel = channel ?? LyricsChannel.instance,
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

  /// 能力变化（权限撤销 / 重新授予）：设置页据此即时更新开关与提示。
  final StreamController<LyricsOutputCapability> _capabilityChanges =
      StreamController<LyricsOutputCapability>.broadcast();

  StreamSubscription<LyricsChannelEvent>? _eventSub;
  LyricsDisplaySettings? _settings;
  LyricsOutputCapability _capability = LyricsOutputCapability.unsupported;

  /// 原生窗口的已知事实（只在 reconcile 内改写，且与通道调用同序）。
  bool _shown = false;

  bool _stopped = false;

  /// 上次成功下发的配置（show / setConfig 都算）：设置变化但配置没变时
  /// 跳过 setConfig，避免原生无谓重建（会打断滚动、瞬间重置横滚位移）。
  Map<String, Object?>? _lastConfig;

  /// 原生内容是否已处于「显式清空」态：清空是幂等命令，间奏期间每个位置
  /// tick 都重发会白白增加通道流量。
  bool _blank = false;

  /// 当前期望内容；null = 无曲目 / 已清空。
  LyricsPresentation? _presentation;

  /// 上次投送的播放态（暂停隐藏 `desktop.hideOnPause` 的窗口生命周期依据）。
  ///
  /// 未知视为未播放：首次投送到达前不主动显示，避免恢复出的暂停会话先闪
  /// 一下窗口；播放中启用桌面歌词时，首次投送会立刻把窗口带出来。
  bool _playing = false;

  /// 单飞 reconcile：同一时间只有一个异步循环在改原生状态。
  Future<void>? _reconciling;
  bool _dirty = false;

  @override
  String get id => LyricsOutputIds.desktop;

  @override
  LyricsOutputCapability get capability =>
      _supported ? _capability : LyricsOutputCapability.unsupported;

  @override
  Stream<LyricsOutputAction> get actions => _actions.stream;

  /// 权限能力变化流（原生 `desktop.onPermissionChanged` + 主动复查）。
  Stream<LyricsOutputCapability> get capabilityChanges =>
      _capabilityChanges.stream;

  void _onChannelEvent(LyricsChannelEvent event) {
    switch (event.method) {
      case 'desktop.onAction':
        final action = _actionFromName(event.arguments['action']?.toString());
        if (action != null) _actions.add(action);
      case 'desktop.onPermissionChanged':
        final granted = event.arguments['granted'] == true;
        _setCapability(
          granted
              ? LyricsOutputCapability.ready
              : LyricsOutputCapability.needsPermission,
        );
        // 原生每次回前台都会上报权限 + 窗口事实：以它校正本地 `_shown`。
        // 权限撤销瞬间 Android 可能已把窗口移除，此时只有 `shown=false`
        // 才能让 Dart 重新走 show，避免「以为在显示、实际投送进黑洞」。
        final shown = event.arguments['shown'];
        if (!granted || shown == false) {
          _shown = false;
          _lastConfig = null;
        } else if (shown == true) {
          _shown = true;
        }
        unawaited(_scheduleSync());
      case 'desktop.onScreenState':
        // 息屏冻结 / 亮屏解冻由原生内部完成：Dart 不需要额外命令。
        // 保留事件分支，避免以后新增消费面时被误判为未知事件。
        break;
    }
  }

  static LyricsOutputAction? _actionFromName(String? name) {
    for (final action in LyricsOutputAction.values) {
      if (action.name == name) return action;
    }
    return null;
  }

  /// 复查悬浮窗权限（授权返回 / 回前台时调用）。
  Future<void> refreshCapability() async {
    if (!_supported || _stopped) return;
    final granted = await _channel.canDrawOverlays();
    final next = granted
        ? LyricsOutputCapability.ready
        : LyricsOutputCapability.needsPermission;
    final lost = !granted && _shown;
    _setCapability(next);
    if (lost) {
      // 原生 onResume 会先收窗；这里以权限事实为准，不再等事件。
      _shown = false;
      _lastConfig = null;
    }
    await _scheduleSync();
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
    if (!_supported || _stopped) return;
    // 设置 / 主题变化都可能伴随权限变化（例如刚从系统设置页返回）：
    // 复查是廉价通道调用，保留原有「每次 start 都复查」的语义。
    await refreshCapability();
  }

  /// 当前是否应显示悬浮窗：配置开启 + 权限就绪 + 不在「暂停隐藏」态。
  bool _canShow(LyricsDisplaySettings s) =>
      s.desktopEnabled &&
      _capability == LyricsOutputCapability.ready &&
      !(s.desktopHideOnPause && !_playing);

  @override
  Future<void> apply(LyricsPresentation presentation) async {
    if (_stopped) return;
    _playing = presentation.isPlaying;
    _presentation = presentation;
    await _scheduleSync();
  }

  @override
  Future<void> clear() async {
    if (_stopped) return;
    _presentation = null;
    await _scheduleSync();
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _presentation = null;
    // 等待在途 reconcile 落定后再收窗，避免它在 stop 之后又把窗口 show 出来。
    final running = _reconciling;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        // 输出失败只降级本输出。
      }
    }
    await _hideIfShown();
    _lastConfig = null;
    await _eventSub?.cancel();
    _eventSub = null;
    await _actions.close();
    await _capabilityChanges.close();
  }

  Future<void> _hideIfShown() async {
    if (!_shown) return;
    _shown = false;
    _lastConfig = null;
    _blank = false;
    await _channel.hideDesktop();
  }

  /// 单飞调度：只保留一个在途 reconcile；期间的新状态用 [_dirty] 合并。
  Future<void> _scheduleSync() {
    _dirty = true;
    final running = _reconciling;
    if (running != null) return running;
    final completer = Completer<void>();
    _reconciling = completer.future;
    unawaited(() async {
      try {
        while (_dirty && !_stopped) {
          _dirty = false;
          await _reconcileOnce();
        }
      } catch (_) {
        // 任一通道失败只降级本输出，不影响播放与其它输出。
      } finally {
        _dirty = false;
        _reconciling = null;
        completer.complete();
      }
    }());
    return completer.future;
  }

  /// 把当前期望状态同步到原生：show / 配置 / 内容 / hide。
  Future<void> _reconcileOnce() async {
    if (_stopped) return;
    final settings = _settings;
    if (settings == null || !_supported) return;
    final presentation = _presentation;
    if (presentation == null || !_canShow(settings)) {
      await _hideIfShown();
      return;
    }
    final config = _configOf(settings);
    if (!_shown) {
      final shown = await _channel.showDesktop(config);
      if (!shown) {
        // 权限在检查与 addView 之间被撤销 / 平台异常：保持 not shown，
        // 下一次 reconcile（重新授权 / 位置 tick）会再试。
        return;
      }
      _shown = true;
      _lastConfig = config;
      _blank = false;
    } else if (!_configEquals(_lastConfig, config)) {
      await _channel.setDesktopConfig(config);
      _lastConfig = config;
    }
    // 空内容（间奏空行 / 暂停回退 clear / 无歌词隐藏）走显式清空：
    // 不依赖一次空文本 update 碰巧走到正确的重建路径；清空是幂等的，
    // 只在下发状态从「有内容」切到「空」时发一次。
    if (_isBlank(presentation, settings)) {
      if (!_blank) {
        _blank = true;
        await _channel.clearDesktop(isPlaying: presentation.isPlaying);
      }
      return;
    }
    _blank = false;
    // 内容每次都重发：provider 已经按 presentation 去重，这里再做一层
    // 值比较会漏掉「设置派生字段」（翻译槽位数 / 暂停回退映射）的变化；
    // 原生收到同结构内容走快路径，不会再重建行视图。
    await _channel.updateDesktop(_presentationMap(presentation, settings));
  }

  /// 当前投送是否应清空内容（而不是显示一行文本）。
  bool _isBlank(LyricsPresentation p, LyricsDisplaySettings s) {
    // 无歌词且设置为隐藏：主行清空。
    if (!p.hasLyrics) {
      return s.desktopNoLyricsBehavior == DesktopNoLyricsBehavior.hide;
    }
    // 暂停回退 clear：主行清空（窗口可保留）。
    if (!p.isPlaying && s.desktopPauseBehavior == LyricsPauseBehavior.clear) {
      return true;
    }
    // 间奏空行：有真实当前行但文本为空。不能把 upcoming 当成当前行。
    return p.hasCurrentLine && p.line.isEmpty;
  }

  void _setCapability(LyricsOutputCapability next) {
    if (_capability == next) return;
    _capability = next;
    if (!_capabilityChanges.isClosed) _capabilityChanges.add(next);
  }

  Map<String, Object?> _configOf(LyricsDisplaySettings s) {
    final scheme = _resolveScheme(s);
    return {
      'fontSize': s.desktopFontSize,
      // 悬浮窗文本跟随「应用字体」：null = 不覆盖，原生用系统默认字体
      // （与 Flutter 侧未自定义字体时的平台默认排版一致）。
      'fontFamily': _appFontFamily?.call(),
      'opacity': s.desktopOpacity,
      'playedColor': _resolveColor(
        s.desktopPlayedColorSource,
        s.desktopPlayedColor,
        scheme,
      ),
      'unplayedColor': _resolveColor(
        s.desktopUnplayedColorSource,
        s.desktopUnplayedColor,
        scheme,
      ),
      'shadowColor': _resolveColor(
        s.desktopShadowColorSource,
        s.desktopShadowColor,
        scheme,
      ),
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
    LyricsPresentation p,
    LyricsDisplaySettings s,
  ) {
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
    final upcoming = replacedLine ? const <String>[] : p.upcoming;
    final hasCurrentLine = !replacedLine && p.hasCurrentLine;
    return {
      'trackId': p.trackId,
      'title': p.title,
      'line': line,
      // 扩展槽数固定窗口行数：翻译 / 罗马音开关变化只改槽内容，不改窗口
      // 高度（原生窗口底缘锚定，高度逐行变化会让主行上下跳）。随内容一起
      // 投送而不是走 setConfig——开关切换时只重建一次，避免配置重下发先做
      // 一次无动画重建、紧接着 update 再重建一次的闪烁。
      'extendedSlots': (s.translationEnabled ? 1 : 0) + (s.romaEnabled ? 1 : 0),
      'extended': replacedLine ? const <String>[] : p.extended,
      'upcoming': upcoming,
      'isPlaying': p.isPlaying,
      'hasLyrics': p.hasLyrics,
      // 行身份：文本相同的副歌也能触发换行；-1 = 前奏预览 / 回退行。
      'lineIndex': replacedLine ? -1 : p.lineIndex,
      'hasCurrentLine': hasCurrentLine,
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
