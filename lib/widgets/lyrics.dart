import 'dart:async';

import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import '../models/play_mode.dart';
import '../providers/playback_provider.dart';
import '../services/lyrics_service.dart';
import '../services/notification_service.dart';
import '../utils/lyric_timing_utils.dart';
import '../utils/responsive.dart';
import 'lyrics_search_page.dart';
import 'lyrics_selection_page.dart';
import 'playback_selectors.dart';

final _logger = Logger();

class LyricsWidget extends StatefulWidget {
  const LyricsWidget({super.key, this.quickActionsEnabled = true});

  /// 是否显示歌词快捷操作栏：播放页收起态（歌词区展开）传 true；
  /// 展开态操作栏会与底部控制区重叠，传 false 隐藏。
  final bool quickActionsEnabled;

  @override
  State<LyricsWidget> createState() => _LyricsWidgetState();
}

class _LyricsWidgetState extends State<LyricsWidget>
    with AutomaticKeepAliveClientMixin<LyricsWidget> {
  List<LyricLine> _lyrics = [];
  final LyricsService _lyricsService = LyricsService();
  String? _lastTrackId;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewKey = GlobalKey();
  bool _autoScroll = true;
  bool _isCopyLyricsMode = false;
  PlayMode? _previousPlayMode;
  int _previousLineIndex = -1; // Track last scrolled line
  final List<GlobalKey> _lineKeys = [];
  int? _pendingScrollIndex;
  int? _lastFallbackIndexAttempted;
  int _fallbackAttemptsForCurrentIndex = 0;
  int? _currentTrackDurationMs;
  bool _temporarilyIgnoreUserScroll = false;
  Timer? _userScrollSuppressionTimer;
  Timer? _quickActionsHideTimer;
  bool _manualQuickActionsVisible = false;
  bool _lyricsContentScrollable = true;
  bool _scrollabilityCheckScheduled = false;
  Future<void>? _nextTrackPreloadFuture;
  String? _nextTrackPreloadedId;
  String? _nextTrackPreloadingId;
  bool _lyricsAreSynced = true;
  bool _isLyricsLoading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 初始默认开启自动滚动
    setState(() {
      _autoScroll = true;
    });
    // 能取到当前曲目就立即加载歌词
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadLyrics();
      }
    });
  }

  @override
  void dispose() {
    _userScrollSuppressionTimer?.cancel();
    _quickActionsHideTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    if (!mounted) return;

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final currentTrack = provider.snapshot.current;
    if (currentTrack == null) {
      _nextTrackPreloadFuture = null;
      // 无曲目：清空歌词并复位状态
      if (_lyrics.isNotEmpty || _lastTrackId != null) {
        _quickActionsHideTimer?.cancel();
        setState(() {
          _lyrics = [];
          _lastTrackId = null;
          _autoScroll = true; // Default to auto-scroll when lyrics clear/load
          _previousLineIndex = -1;
          _syncLineKeys(0);
          _currentTrackDurationMs = null;
          _lyricsAreSynced = true;
          _manualQuickActionsVisible = false;
        });
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      }
      return;
    }

    final trackId = currentTrack.id.uri;
    final trackDurationMs = currentTrack.duration?.inMilliseconds;
    // 仅当曲目 id 有效且变化时重新加载
    if (trackId.isEmpty || trackId == _lastTrackId) return;

    _lastTrackId = trackId;
    final songName = currentTrack.title;
    final artistName = _getPrimaryArtistName(currentTrack);

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _quickActionsHideTimer?.cancel();
    setState(() {
      _lyrics = [];
      _autoScroll = true; // Default to auto-scroll when new lyrics load
      _previousLineIndex = -1;
      _syncLineKeys(0);
      _currentTrackDurationMs = trackDurationMs;
      _nextTrackPreloadedId = null;
      _nextTrackPreloadingId = null;
      _lyricsAreSynced = true;
      _manualQuickActionsVisible = false;
      _isLyricsLoading = true;
    });

    final lyricsResult =
        await _lyricsService.getLyrics(songName, artistName, trackId);

    // await 后使用 context 前先检查 mounted
    if (!mounted) return;

    final latestTrackId = Provider.of<PlaybackProvider>(context, listen: false)
        .snapshot.current?.id.uri;
    // 更新状态前确认歌词仍属于当前曲目
    if (latestTrackId != trackId) {
      return;
    }

    if (lyricsResult != null) {
      final rawLyrics = lyricsResult.lyric;
      final summary = LyricTimingUtils.summarize(rawLyrics);
      final parsedLyrics = parseLyrics(rawLyrics);

      if (summary.hasTimestamps && parsedLyrics.isNotEmpty) {
        _quickActionsHideTimer?.cancel();
        setState(() {
          _lyricsAreSynced = true;
          _lyrics = parsedLyrics;
          _autoScroll = true;
          _previousLineIndex = -1;
          _syncLineKeys(_lyrics.length);
          _currentTrackDurationMs = trackDurationMs;
          _pendingScrollIndex = null;
          _lastFallbackIndexAttempted = null;
          _fallbackAttemptsForCurrentIndex = 0;
          _manualQuickActionsVisible = false;
          _isLyricsLoading = false;
        });
        // 始终预加载下一首歌词
        unawaited(_preloadNextTrackResources());
      } else {
        final unsyncedLines = buildUnsyncedLyrics(rawLyrics);
        if (unsyncedLines.isNotEmpty) {
          _quickActionsHideTimer?.cancel();
          setState(() {
            _lyricsAreSynced = false;
            _lyrics = unsyncedLines;
            _autoScroll = false;
            _previousLineIndex = -1;
            _syncLineKeys(_lyrics.length);
            _currentTrackDurationMs = trackDurationMs;
            _pendingScrollIndex = null;
            _lastFallbackIndexAttempted = null;
            _fallbackAttemptsForCurrentIndex = 0;
            _manualQuickActionsVisible = false;
            _isLyricsLoading = false;
          });
          // 始终预加载下一首歌词
          unawaited(_preloadNextTrackResources());
        } else {
          _quickActionsHideTimer?.cancel();
          setState(() {
            _lyricsAreSynced = true;
            _lyrics = [];
            _autoScroll = true;
            _syncLineKeys(0);
            _manualQuickActionsVisible = false;
            _isLyricsLoading = false;
          });
        }
      }
    } else {
      // 取词失败：保持空歌词列表
      _quickActionsHideTimer?.cancel();
      setState(() {
        _lyrics = [];
        _syncLineKeys(0);
        _lyricsAreSynced = true;
        _manualQuickActionsVisible = false;
        _isLyricsLoading = false;
      });
    }
  }

  void _syncLineKeys(int targetLength) {
    if (_lineKeys.length == targetLength) return;
    if (_lineKeys.length < targetLength) {
      final difference = targetLength - _lineKeys.length;
      for (int i = 0; i < difference; i++) {
        _lineKeys.add(GlobalKey());
      }
    } else {
      _lineKeys.removeRange(targetLength, _lineKeys.length);
    }
  }

  String _extractArtistNames(Track track) {
    final names = track.artists
        .map((artist) => artist.name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isNotEmpty) {
      return names.join(', ');
    }
    return 'Unknown Artist';
  }

  String _getPrimaryArtistName(Track track) {
    for (final artist in track.artists) {
      final value = artist.name.trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return _extractArtistNames(track);
  }

  /// 预加载下一首歌曲的歌词（写入 LyricsService 缓存）。
  Future<void> _preloadNextTrackResources() async {
    if (!mounted) {
      return;
    }

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final snapshot = provider.snapshot;
    final nextTrack =
        snapshot.next ?? (snapshot.upcoming.isNotEmpty ? snapshot.upcoming.first : null);

    if (nextTrack == null) {
      return;
    }

    final trackId = nextTrack.id.uri;
    if (trackId.isEmpty ||
        trackId == _lastTrackId ||
        _nextTrackPreloadedId == trackId) {
      return;
    }

    if (_nextTrackPreloadFuture != null && _nextTrackPreloadingId == trackId) {
      return;
    }

    _nextTrackPreloadingId = trackId;
    _nextTrackPreloadFuture = Future(() async {
      try {
        final songName = nextTrack.title;
        final artistName = _getPrimaryArtistName(nextTrack);

        // 预加载歌词（会自动缓存到 SharedPreferences）
        final lyricsResult =
            await _lyricsService.getLyrics(songName, artistName, trackId);
        if (lyricsResult == null || !mounted) {
          _logger
              .d('Preloaded lyrics for next track: $trackId (no lyrics found)');
          return;
        }

        _logger.d(
            'Preloaded lyrics for next track: $trackId (provider: ${lyricsResult.provider})');

        if (!mounted) return;
        _nextTrackPreloadedId = trackId;
      } catch (e) {
        _logger.d('Failed to preload next track resources: $e');
      } finally {
        if (_nextTrackPreloadingId == trackId) {
          _nextTrackPreloadingId = null;
        }
        _nextTrackPreloadFuture = null;
      }
    });
  }

  bool get _requiresManualQuickActions =>
      _lyrics.isNotEmpty && (!_lyricsAreSynced || !_lyricsContentScrollable);

  bool get _shouldShowQuickActionsBar {
    // 复制模式下必须保留出口（否则收起播放器后无法退出复制模式）。
    if (!widget.quickActionsEnabled && !_isCopyLyricsMode) {
      return false;
    }
    if (_isCopyLyricsMode || _lyrics.isEmpty) {
      return true;
    }
    if (_lyricsAreSynced && _lyricsContentScrollable) {
      return !_autoScroll;
    }
    return _requiresManualQuickActions && _manualQuickActionsVisible;
  }

  void _scheduleScrollabilityCheck() {
    if (_scrollabilityCheckScheduled) {
      return;
    }
    _scrollabilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollabilityCheckScheduled = false;
      if (!mounted) {
        return;
      }
      if (!_scrollController.hasClients) {
        _scheduleScrollabilityCheck();
        return;
      }
      final position = _scrollController.position;
      final bool canScroll =
          (position.maxScrollExtent - position.minScrollExtent).abs() > 1.0;
      final bool nextRequiresManual =
          _lyrics.isNotEmpty && (!_lyricsAreSynced || !canScroll);
      final bool manualRequirementChanged =
          _requiresManualQuickActions != nextRequiresManual;
      if (_lyricsContentScrollable != canScroll || manualRequirementChanged) {
        setState(() {
          _lyricsContentScrollable = canScroll;
          if (!nextRequiresManual) {
            _manualQuickActionsVisible = false;
            _quickActionsHideTimer?.cancel();
          }
        });
      }
    });
  }

  void _showManualQuickActionsTemporarily() {
    if (!mounted ||
        !_requiresManualQuickActions ||
        _isCopyLyricsMode ||
        _lyrics.isEmpty) {
      return;
    }
    if (!_manualQuickActionsVisible) {
      setState(() {
        _manualQuickActionsVisible = true;
      });
    }
    _quickActionsHideTimer?.cancel();
    _quickActionsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !_requiresManualQuickActions ||
          _isCopyLyricsMode ||
          _lyrics.isEmpty) {
        return;
      }
      if (_manualQuickActionsVisible) {
        setState(() {
          _manualQuickActionsVisible = false;
        });
      }
    });
  }

  double _computeEffectiveAlignment() {
    if (!_scrollController.hasClients) return 0.5;

    final mediaQuery = MediaQuery.of(context);
    final double viewport = _scrollController.position.viewportDimension;
    if (viewport <= 0) return 0.5;

    final double topOverlay = 40.0 + mediaQuery.padding.top;

    final bool bottomBarVisible = _shouldShowQuickActionsBar;
    final double bottomOverlay =
        bottomBarVisible ? (24.0 + mediaQuery.padding.bottom + 48.0) : 0.0;

    final double delta = ((topOverlay - bottomOverlay) / 2.0) / viewport;
    final double alignment = (0.5 + delta).clamp(0.0, 1.0);
    return alignment;
  }

  double _tailSpace() {
    if (!_scrollController.hasClients) return 400.0;

    final mediaQuery = MediaQuery.of(context);
    final position = _scrollController.position;
    if (!position.hasPixels || position.viewportDimension <= 0) {
      return 400.0;
    }
    final double viewport = position.viewportDimension;

    final double topOverlay = 40.0 + mediaQuery.padding.top;

    final bool bottomBarVisible = _shouldShowQuickActionsBar;
    final double bottomOverlay =
        bottomBarVisible ? (24.0 + mediaQuery.padding.bottom + 48.0) : 0.0;

    final double visibleHeight =
        (viewport - topOverlay - bottomOverlay).clamp(0.0, viewport);
    return (visibleHeight / 2.0) + bottomOverlay + 8.0;
  }

  void _scrollToCurrentLine(int currentLineIndex) {
    if (!mounted ||
        !_autoScroll ||
        !_lyricsAreSynced ||
        !_scrollController.hasClients ||
        currentLineIndex < 0 ||
        currentLineIndex >= _lineKeys.length) {
      return;
    }

    final key = _lineKeys[currentLineIndex];
    final context = key.currentContext;
    if (context == null) {
      if (_lastFallbackIndexAttempted != currentLineIndex) {
        _fallbackAttemptsForCurrentIndex = 0;
      }
      _pendingScrollIndex = currentLineIndex;
      _lastFallbackIndexAttempted = currentLineIndex;
      _fallbackAttemptsForCurrentIndex++;

      final position = _scrollController.position;
      if (position.hasPixels &&
          position.hasContentDimensions &&
          position.viewportDimension > 0 &&
          _lyrics.isNotEmpty) {
        final line = _lyrics[currentLineIndex];
        double ratio;
        if (_currentTrackDurationMs != null &&
            _currentTrackDurationMs! > 0 &&
            line.timestamp.inMilliseconds >= 0) {
          final double totalMs = _currentTrackDurationMs!.toDouble();
          ratio = line.timestamp.inMilliseconds / totalMs;
        } else if (_lyrics.length <= 1) {
          ratio = 0.0;
        } else {
          ratio = currentLineIndex / (_lyrics.length - 1);
        }

        if (!ratio.isFinite) {
          ratio = 0.0;
        } else if (ratio < 0.0) {
          ratio = 0.0;
        } else if (ratio > 1.0) {
          ratio = 1.0;
        }

        final double alignment = _computeEffectiveAlignment();
        final double viewportDim = position.viewportDimension;
        final double viewportHalf = viewportDim * 0.5;
        double targetOffset =
            (ratio * position.maxScrollExtent) - (viewportDim * alignment);

        if (_fallbackAttemptsForCurrentIndex > 1) {
          final double direction =
              (targetOffset >= position.pixels) ? 1.0 : -1.0;
          final double fallbackMagnitude =
              (_fallbackAttemptsForCurrentIndex - 1).clamp(1, 4).toDouble();
          final double extraOffset = viewportHalf * 0.6 * fallbackMagnitude;
          targetOffset += direction * extraOffset;
        }

        if (targetOffset < position.minScrollExtent) {
          targetOffset = position.minScrollExtent;
        } else if (targetOffset > position.maxScrollExtent) {
          targetOffset = position.maxScrollExtent;
        }

        try {
          if ((position.pixels - targetOffset).abs() > 1.0) {
            _scrollController.jumpTo(targetOffset);
          }
        } catch (_) {
          // 跳转失败可忽略：下一帧会重试
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autoScroll && _pendingScrollIndex == currentLineIndex) {
          _scrollToCurrentLine(currentLineIndex);
        }
      });
      return;
    }

    _pendingScrollIndex = null;
    _lastFallbackIndexAttempted = null;
    _fallbackAttemptsForCurrentIndex = 0;

    try {
      final renderObject = context.findRenderObject();
      if (renderObject == null) return;

      final viewport = RenderAbstractViewport.of(renderObject);
      final double alignment = _computeEffectiveAlignment();
      final reveal = viewport.getOffsetToReveal(renderObject, alignment);
      final position = _scrollController.position;
      final targetOffset = reveal.offset;
      final clampedOffset = targetOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );

      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 600),
        curve: Curves.fastOutSlowIn,
      );
    } catch (_) {
      // 滚动失败可忽略：下一 tick 会重试
    }
  }

  void _enableAutoScrollWithSuppression(
      {Duration duration = const Duration(milliseconds: 350)}) {
    if (!mounted) {
      return;
    }
    if (!_lyricsAreSynced) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
      });
      return;
    }
    setState(() {
      _autoScroll = true;
      _temporarilyIgnoreUserScroll = duration > Duration.zero;
    });
    _userScrollSuppressionTimer?.cancel();
    if (duration > Duration.zero) {
      _userScrollSuppressionTimer = Timer(duration, () {
        if (!mounted) return;
        setState(() {
          _temporarilyIgnoreUserScroll = false;
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    // 曲目变化走低频快照 Selector；行高亮订阅 position 独立通道，
    // 仅在行号变化时重建（PositionLineIndexBuilder 内部缓存行号）。
    return Selector<PlaybackProvider, String?>(
      selector: (_, provider) => provider.snapshot.current?.id.uri,
      builder: (context, currentTrackId, _) {
        return PositionLineIndexBuilder(
          position: playbackProvider.position,
          lineIndexFor: _getCurrentLineIndex,
          builder: (context, currentLineIndex) => _buildLyricsContent(
            context,
            l10n,
            currentTrackId,
            currentLineIndex,
          ),
        );
      },
    );
  }

  /// 构建歌词主体：低频触发（换曲/行号变化/滚动状态等）。
  Widget _buildLyricsContent(
    BuildContext context,
    AppLocalizations l10n,
    String? currentTrackId,
    int currentLineIndex,
  ) {
    final bool trackJustChanged = (currentTrackId != _lastTrackId);

    // 曲目变化：按新 id 加载歌词
    if (trackJustChanged) {
      // 换曲时退出复制模式
      if (_isCopyLyricsMode && mounted) {
        Future.microtask(() => _toggleCopyLyricsMode());
      }
      // 加载新曲目歌词（内部处理 null）
      Future.microtask(() async {
        await _loadLyrics();
      });
    }

    _syncLineKeys(_lyrics.length);
    _scheduleScrollabilityCheck();

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    if (_autoScroll &&
        _lyrics.isNotEmpty &&
        mounted &&
        currentLineIndex >= 0) {
      if (_previousLineIndex != currentLineIndex ||
          _pendingScrollIndex != null) {
        _previousLineIndex = currentLineIndex;
        _pendingScrollIndex = currentLineIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _autoScroll &&
              _pendingScrollIndex == currentLineIndex) {
            _scrollToCurrentLine(currentLineIndex);
          }
        });
      }
    }

    final bool shouldShowQuickActions = _shouldShowQuickActionsBar;

    return Material(
      color: Colors.transparent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollNotification) {
          if (!mounted) return true;

          bool userInitiatedScroll = false;
          // 用户手动操作后关闭自动滚动
          if (scrollNotification is UserScrollNotification) {
            if (_temporarilyIgnoreUserScroll) {
              return true;
            }
            if (scrollNotification.direction != ScrollDirection.idle &&
                _autoScroll) {
              setState(() {
                _autoScroll = false;
                _temporarilyIgnoreUserScroll = false;
                _userScrollSuppressionTimer?.cancel();
              });
            }
            if (scrollNotification.direction != ScrollDirection.idle) {
              userInitiatedScroll = true;
            }
          } else if (scrollNotification is ScrollStartNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          } else if (scrollNotification is ScrollUpdateNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          } else if (scrollNotification is OverscrollNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          }

          if (_requiresManualQuickActions && userInitiatedScroll) {
            _showManualQuickActionsTemporarily();
          }
          return true; // Allow notification to bubble up
        },
        child: Stack(
          children: [
            // 歌词加载中时显示居中的加载指示器
            if (_lyrics.isEmpty && _isLyricsLoading)
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: M3EProgressIndicator.circular(
                          size: 24,
                          strokeWidth: 2.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.lyricsLoading,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ListView.builder(
              key: _listViewKey,
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              scrollCacheExtent: const ScrollCacheExtent.pixels(
                  1000.0), // Prebuild nearby items to reduce fallback jumps
              padding: EdgeInsets.only(
                top: 80 + MediaQuery.of(context).padding.top,
                bottom: 40 +
                    MediaQuery.of(context)
                        .padding
                        .bottom, // Reverted bottom padding
              ),
              itemCount: _lyrics.length + 1,
              itemBuilder: (context, index) {
                if (index == _lyrics.length) {
                  return SizedBox(
                      height:
                          _tailSpace()); // Spacer keeps final line centerable
                }
                final theme = Theme.of(context);
                final bool isWideLyricLayout = context
                    .layoutType(ResponsivePageType.detail)
                    .preferTwoPane;
                final bool isWeb = kIsWeb;
                final line = _lyrics[index];
                final bool lyricsSynced = _lyricsAreSynced;
                final bool isCurrentLine =
                    lyricsSynced && index == currentLineIndex;
                final bool isPastLine =
                    lyricsSynced && index < currentLineIndex;
                // 歌词行角色契约：正文用 onSurface/onSurfaceVariant，
                // 仅当前行用 primary 强调（全页唯一强调色）。
                final Color baseTextColor;
                if (!lyricsSynced) {
                  // 无时间戳歌词：普通正文。
                  baseTextColor = theme.colorScheme.onSurface;
                } else if (isPastLine) {
                  // 已唱过的行：次要文本。
                  baseTextColor = theme.colorScheme.onSurfaceVariant;
                } else if (isCurrentLine) {
                  // 当前行：primary 强调。
                  baseTextColor = theme.colorScheme.primary;
                } else {
                  // 即将播放的行：正常正文（配合外层 0.8 透明度）。
                  baseTextColor = theme.colorScheme.onSurface;
                }
                final double lyricFontSize = isWideLyricLayout
                    ? (isWeb ? 30.0 : 24.0)
                    : (isWeb ? 36.0 : 22.0);

                return GestureDetector(
                  key: _lineKeys[index],
                  onTap: () {
                    HapticFeedback.lightImpact();
                    if (!mounted) return;

                    // 跳转到点击行的时间点
                    final tappedTimestamp = _lyrics[index].timestamp;
                    playbackProvider
                        .seekToPosition(tappedTimestamp.inMilliseconds);

                    // 复制模式下退出复制模式，否则确保自动滚动开启
                    bool needsScrollTrigger = false;
                    if (_isCopyLyricsMode) {
                      _toggleCopyLyricsMode(); // Exits copy mode, enables autoScroll
                      needsScrollTrigger = true; // Scroll after exiting
                    } else {
                      if (!_autoScroll) {
                        needsScrollTrigger = true; // Scroll after enabling
                        _enableAutoScrollWithSuppression(
                          duration: const Duration(milliseconds: 250),
                        );
                      } else {
                        // 已在自动滚动时仅 seek 可能足够，
                        // 这里显式触发滚动以立即反馈。
                        needsScrollTrigger = true;
                      }
                    }

                    // 状态变化/seek 后立即触发滚动
                    if (needsScrollTrigger) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _autoScroll) {
                          // 立即滚动到点击行
                          _scrollToCurrentLine(index);
                          _previousLineIndex =
                              index; // Update index after tap scroll
                        }
                      });
                    }
                  },
                  child: AnimatedPadding(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutCubic,
                    padding: EdgeInsets.symmetric(
                      // Web端行间距增大30%
                      vertical: isWeb
                          ? (isCurrentLine ? 15.6 : 10.4)
                          : (isCurrentLine ? 12.0 : 8.0),
                      // 响应式水平留白
                      horizontal: isWideLyricLayout ? 24.0 : 40.0,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        fontSize: lyricFontSize,
                        fontWeight: isCurrentLine
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: baseTextColor,
                        // Web端文字行高增大30%
                        height: isWeb ? 1.43 : 1.1,
                      ),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        opacity: lyricsSynced
                            ? (isCurrentLine ? 1.0 : 0.8)
                            : 1.0,
                        child: Text(
                          line.text,
                          textAlign: TextAlign.left, // Align text left
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 顶部渐变遮罩
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 40 +
                  MediaQuery.of(context).padding.top, // Reverted height
              child: IgnorePointer(
                // 渐变层不接收手势。颜色统一取 colorScheme.surface
                //（ThemeData.scaffoldBackgroundColor 的取值来源），
                // 避免两处背景色来源漂移。
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context).colorScheme.surface,
                        Theme.of(context).colorScheme.surface,
                        Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.8),
                        Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.3, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // 底部按钮层
            if (shouldShowQuickActions)
              Positioned(
                left: context
                        .layoutType(ResponsivePageType.detail)
                        .preferTwoPane
                    ? 24
                    : 16, // Reverted left positioning
                bottom: 24 +
                    MediaQuery.of(context)
                        .padding
                        .bottom, // Reverted bottom positioning
                child: Padding(
                  padding:
                      EdgeInsets.zero, // Removed horizontal padding wrapper
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment
                        .start, // Reverted alignment to start
                    children: [
                      // 居中/恢复滚动按钮
                      if (!_autoScroll &&
                          _lyrics.isNotEmpty &&
                          _lyricsAreSynced) // Show only if synced lyrics exist
                        M3EIconButton(
                          variant: M3EIconButtonVariant.tonal,
                          icon: const Icon(Icons.vertical_align_center_rounded),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            if (!mounted) return;
                            _enableAutoScrollWithSuppression();
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              if (mounted && _autoScroll) {
                                final currentProvider =
                                    Provider.of<PlaybackProvider>(context,
                                        listen: false);
                                final latestPosition =
                                    currentProvider.currentPosition;
                                final latestCurrentIndex =
                                    _getCurrentLineIndex(latestPosition);
                                _scrollToCurrentLine(latestCurrentIndex);
                                _previousLineIndex = latestCurrentIndex;
                              }
                            });
                          },
                          tooltip: l10n
                              .centerCurrentLine, // "Center Current Line"
                        ),
                      if (!_autoScroll &&
                          _lyrics.isNotEmpty &&
                          _lyricsAreSynced)
                        const SizedBox(width: 8), // Spacer

                      // 复制/编辑模式按钮
                      M3EIconButton(
                        variant: M3EIconButtonVariant.tonal,
                        icon: Icon(
                          _isCopyLyricsMode
                              ? Icons.playlist_play_rounded // Exit icon
                              : Icons.edit_note_rounded, // Enter icon
                        ),
                        onPressed: _lyrics.isEmpty
                            ? null
                            : () {
                                // 无歌词时禁用
                                HapticFeedback.lightImpact();
                                _toggleCopyLyricsMode();
                              },
                        tooltip: _isCopyLyricsMode
                            ? l10n
                                .exitCopyModeResumeScroll // "Exit Copy Mode & Resume Scroll"
                            : l10n
                                .enterCopyLyricsMode, // "Enter Copy Lyrics Mode"
                        decoration: M3EIconButtonDecoration(
                          // 复制模式激活 = 选中态：primaryContainer 成对色；
                          // 未激活时回落到 tonal 变体默认（secondaryContainer）。
                          backgroundColor: _isCopyLyricsMode
                              ? WidgetStatePropertyAll(Theme.of(context)
                                  .colorScheme
                                  .primaryContainer)
                              : null,
                          foregroundColor: _isCopyLyricsMode
                              ? WidgetStatePropertyAll(Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),

                      // 搜索歌词按钮
                      M3EIconButton(
                        variant: M3EIconButtonVariant.tonal,
                        icon: const Icon(Icons.search_rounded),
                        onPressed: _showSearchLyricsPage,
                        tooltip: l10n.searchLyrics,
                      ),
                      const SizedBox(width: 8),

                      // 选择歌词按钮
                      M3EIconButton(
                        variant: M3EIconButtonVariant.tonal,
                        icon: const Icon(Icons.checklist_rounded),
                        onPressed: _lyrics.isEmpty
                            ? null
                            : _showLyricsSelectionPage,
                        tooltip: l10n.selectLyricsTooltip,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  int _getCurrentLineIndex(Duration currentPosition) {
    if (!_lyricsAreSynced) return -1;
    return lyricLineIndexAt(_lyrics, currentPosition);
  }

  void _toggleCopyLyricsMode() {
    if (!mounted) return;

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final wasCopyMode = _isCopyLyricsMode;

    setState(() {
      if (_isCopyLyricsMode) {
        // 退出复制模式
        _isCopyLyricsMode = false;
        _autoScroll = _lyricsAreSynced; // Resume auto-scroll only when synced
        _temporarilyIgnoreUserScroll = true;
        _quickActionsHideTimer?.cancel();
        _manualQuickActionsVisible = false;
        // 恢复保存的播放模式
        if (_previousPlayMode != null) {
          provider.setPlayMode(_previousPlayMode!);
          _previousPlayMode = null; // Clear saved mode
        }
        // 退出复制模式并开启自动滚动后触发滚动
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _autoScroll) {
            // 按当前进度取最新行号
            final currentPosition = provider.currentPosition;
            final latestCurrentIndex = _getCurrentLineIndex(currentPosition);
            if (latestCurrentIndex >= 0) {
              _scrollToCurrentLine(latestCurrentIndex);
              _previousLineIndex =
                  latestCurrentIndex; // Update index after scroll
            }
          }
        });
      } else {
        // 进入复制模式
        _isCopyLyricsMode = true;
        _autoScroll = false; // Disable auto-scroll explicitly
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
        _quickActionsHideTimer?.cancel();
        // 记录当前模式并切到单曲循环
        _previousPlayMode = provider.currentMode;
        provider.setPlayMode(PlayMode.singleRepeat);

        // 通过 NotificationService 提示
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          Provider.of<NotificationService>(context, listen: false).showSnackBar(
            l10n.lyricsCopyModeSnackbar, // "Lyrics copy mode: Auto-scroll disabled, tap line to seek."
            duration: const Duration(seconds: 4), // Slightly longer duration
          );
        }
      }
    });

    if (wasCopyMode) {
      _userScrollSuppressionTimer?.cancel();
      _userScrollSuppressionTimer = Timer(
        const Duration(milliseconds: 350),
        () {
          if (!mounted) return;
          setState(() {
            _temporarilyIgnoreUserScroll = false;
          });
        },
      );
    }
  }

  // 打开歌词搜索页
  void _showSearchLyricsPage() {
    if (!mounted) return;

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    if (currentTrack == null) {
      notificationService.showSnackBar(l10n.noCurrentTrackPlaying);
      return;
    }

    final trackId = currentTrack.id.uri;
    final trackName = currentTrack.title;
    final artistName = _extractArtistNames(currentTrack);

    if (trackId.isEmpty || trackName.isEmpty) {
      notificationService.showSnackBar(l10n.cannotGetTrackInfo);
      return;
    }

    // 进入新页面前暂停自动滚动
    final wasAutoScrollEnabled = _autoScroll;
    if (_autoScroll) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
      });
    }

    // 打开搜索页
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (context) => LyricsSearchPage(
          initialTrackTitle: trackName,
          initialArtistName: artistName,
          trackId: trackId,
        ),
      ),
    )
        .then((result) {
      // 搜索页返回后执行
      if (!mounted) return; // Check if widget is still mounted

      LyricsSearchSelection? selection;
      if (result is LyricsSearchSelection) {
        selection = result;
      } else if (result is String && result.isNotEmpty) {
        selection = LyricsSearchSelection(
          lyrics: result,
          provider: '',
        );
      }

      // 搜索页返回了歌词
      if (selection != null && selection.lyrics.isNotEmpty) {
        final summary = LyricTimingUtils.summarize(selection.lyrics);
        final parsed = parseLyrics(selection.lyrics);
        final bool synced = summary.hasTimestamps && parsed.isNotEmpty;
        final newLyrics =
            synced ? parsed : buildUnsyncedLyrics(selection.lyrics);
        _quickActionsHideTimer?.cancel();
        setState(() {
          _lyrics = newLyrics;
          _lyricsAreSynced = synced;
          _lastTrackId =
              trackId; // Update last track ID as we applied lyrics for it
          _previousLineIndex = -1; // Reset previous index
          _syncLineKeys(_lyrics.length);
          _manualQuickActionsVisible = false;

          // 搜索前开启过自动滚动则恢复
          if (wasAutoScrollEnabled && synced) {
            _autoScroll = true;
            _temporarilyIgnoreUserScroll = true;

            // 歌词更新后滚动到当前进度
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _autoScroll) {
                final currentPosition = playbackProvider.currentPosition;
                final currentIndex = _getCurrentLineIndex(currentPosition);
                if (currentIndex >= 0) {
                  _scrollToCurrentLine(currentIndex);
                  _previousLineIndex = currentIndex;
                }
              }
            });
          } else {
            _autoScroll = false; // Keep it disabled if it was disabled before
            _temporarilyIgnoreUserScroll = false;
            _userScrollSuppressionTimer?.cancel();
          }
        });

        if (wasAutoScrollEnabled && _lyricsAreSynced && _autoScroll) {
          _userScrollSuppressionTimer?.cancel();
          _userScrollSuppressionTimer = Timer(
            const Duration(milliseconds: 350),
            () {
              if (!mounted) return;
              setState(() {
                _temporarilyIgnoreUserScroll = false;
              });
            },
          );
        }

        // 成功提示
        notificationService.showSnackBar(l10n.lyricsSearchAppliedSuccess);
      } else {
        // 未返回歌词或用户取消：
        // 恢复此前的自动滚动状态
        if (wasAutoScrollEnabled && !_autoScroll) {
          _enableAutoScrollWithSuppression();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _autoScroll) {
              final currentPosition = playbackProvider.currentPosition;
              final currentIndex = _getCurrentLineIndex(currentPosition);
              if (currentIndex >= 0) {
                _scrollToCurrentLine(currentIndex);
                _previousLineIndex = currentIndex;
              }
            }
          });
        }
      }
    });
  }

  // 打开歌词选择页
  Future<void> _showLyricsSelectionPage() async {
    if (!mounted) return;

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    if (currentTrack == null) {
      notificationService.showSnackBar(l10n.noCurrentTrackPlaying);
      return;
    }

    if (_lyrics.isEmpty) {
      notificationService.showSnackBar(l10n.noLyricsToSelect);
      return;
    }

    final trackName = currentTrack.title;
    final artistName = _extractArtistNames(currentTrack);
    final albumCoverUrl = currentTrack.artwork?.uri.toString();

    // 暂停当前的自动滚动
    final wasAutoScrollEnabled = _autoScroll;
    if (_autoScroll) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
      });
    }

    await ResponsiveNavigation.showSecondaryPage<void>(
      context: context,
      child: LyricsSelectionPage(
        lyrics: _lyrics,
        trackTitle: trackName,
        artistName: artistName,
        albumCoverUrl: albumCoverUrl,
      ),
      preferredMode: SecondaryPageMode.sideSheet,
      maxWidth: 520,
      showCloseButton: false,
      barrierDismissible: false,
    );

    if (!mounted) return;

    if (wasAutoScrollEnabled && !_autoScroll) {
      _enableAutoScrollWithSuppression();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autoScroll) {
          final currentPosition = playbackProvider.currentPosition;
          final currentIndex = _getCurrentLineIndex(currentPosition);
          if (currentIndex >= 0) {
            _scrollToCurrentLine(currentIndex);
            _previousLineIndex = currentIndex;
          }
        }
      });
    }
  }
}
