import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../models/lyric_line.dart';
import '../models/poster_lyric_line.dart';
import '../providers/playback_provider.dart';
import '../services/covers/cover_resolution.dart';
import '../services/haptics.dart';
import '../services/lyrics_display/lyric_timing_policy.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'lyrics_poster_preview_page.dart';
import 'playback_selectors.dart';
import 'track_artwork.dart';

class LyricsSelectionPage extends StatefulWidget {
  // 共享歌词模型（不可变）：选中态由页面自身的下标集合维护。
  final List<LyricLine> lyrics;
  final String trackTitle;
  final String artistName;
  final String? albumCoverUrl;

  /// 当前曲目身份：页头缩略图与海报取自定义封面用（可空：独立测试挂载）。
  final TrackId? trackId;

  /// 与 [lyrics] 等索引的翻译 / 罗马音（'' = 该行无扩展文本）。
  /// 来自歌词页同一份时间戳对齐结果，选择页与海报都据此展示。
  final List<String> translations;
  final List<String> romas;

  /// 是否有时间轴（未同步歌词没有可高亮的当前行）。
  final bool isSynced;

  /// 与歌词页一致的两个展示开关（关闭时扩展行不展示、不进海报）。
  final bool showTranslation;
  final bool showRoma;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  const LyricsSelectionPage({
    super.key,
    required this.lyrics,
    required this.trackTitle,
    required this.artistName,
    this.albumCoverUrl,
    this.trackId,
    this.translations = const [],
    this.romas = const [],
    this.isSynced = true,
    this.showTranslation = false,
    this.showRoma = false,
    this.embedded = false,
  });

  @override
  State<LyricsSelectionPage> createState() => _LyricsSelectionPageState();
}

class _LyricsSelectionPageState extends State<LyricsSelectionPage> {
  late final List<LyricLine> _lyricLines;
  final bool _isLoading = false;

  /// 选中行下标（模型不可变，选中态属于页面状态）。
  final Set<int> _selectedIndices = {};

  /// 范围起点（最后一次点选的行；长按另一行时从这里起算区间）。
  int? _rangeAnchor;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _lyricLines = widget.lyrics;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _copyAllOriginalLyrics() async {
    final l10n = AppLocalizations.of(context)!;
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );

    final text = _lyricLines.map((line) => line.text).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    notificationService.showSnackBar(l10n.copiedToClipboard(l10n.lyricsTitle));
  }

  // 当前播放行按播放页歌词同一时间策略（同一 200ms 提前量）计算
  int _getCurrentLineIndex(Duration currentPosition) => LyricTimingPolicy.page
      .lineIndexAt(_lyricLines, currentPosition, isSynced: widget.isSynced);

  void _deselectAllLines() {
    HapticsService.lightImpact();
    setState(() {
      _selectedIndices.clear();
      _rangeAnchor = null;
    });
  }

  /// 可参与「全选」的行：空文本行没有内容可复制 / 进海报，跳过。
  Iterable<int> get _selectableIndices sync* {
    for (var i = 0; i < _lyricLines.length; i++) {
      if (_lyricLines[i].text.trim().isNotEmpty) yield i;
    }
  }

  bool get _allSelectableSelected {
    final selectable = _selectableIndices.toList(growable: false);
    return selectable.isNotEmpty && selectable.every(_selectedIndices.contains);
  }

  /// 全选非空行。全选只负责选中；清空 / 退出只走底栏 ✕。
  void _selectAllLines() {
    HapticsService.selectionClick();
    setState(() {
      _selectedIndices
        ..clear()
        ..addAll(_selectableIndices);
      // 全选不是「点选起点」：长按区间要等下一次点行落下锚点。
      _rangeAnchor = null;
    });
  }

  /// 范围选择：选中锚点到 [index] 的闭区间（与合集多选同一语义）。
  void _selectRangeTo(int index) {
    final anchor = _rangeAnchor;
    if (anchor == null) return;
    HapticsService.selectionClick();
    setState(() {
      final start = math.min(anchor, index);
      final end = math.max(anchor, index);
      _selectedIndices
        ..clear()
        ..addAll([for (var i = start; i <= end; i++) i]);
      _rangeAnchor = index;
    });
  }

  void _toggleLineSelection(int index) {
    if (index < 0 || index >= _lyricLines.length) return;

    HapticsService.selectionClick();
    setState(() {
      if (!_selectedIndices.remove(index)) _selectedIndices.add(index);
      // 范围起点 = 最后一次点选的行（无论这次是选中还是取消）。
      _rangeAnchor = index;
    });
  }

  /// 行长按：已经选中过行时把这一行作为区间终点；否则先选中它。
  ///
  /// 触摸端没有 Shift，长按承担桌面 Shift 点击的第二段手势。
  void _onLineLongPress(int index) {
    if (index < 0 || index >= _lyricLines.length) return;
    if (_selectedIndices.isNotEmpty && _rangeAnchor != null) {
      _selectRangeTo(index);
      return;
    }
    HapticsService.selectionClick();
    setState(() {
      _selectedIndices.add(index);
      _rangeAnchor = index;
    });
  }

  List<String> _getSelectedLyrics() => [
    for (var i = 0; i < _lyricLines.length; i++)
      if (_selectedIndices.contains(i)) _lyricLines[i].text,
  ];

  List<PosterLyricLine> _getPosterLyricLines() => [
    for (var i = 0; i < _lyricLines.length; i++)
      if (_selectedIndices.contains(i))
        PosterLyricLine(
          text: _lyricLines[i].text,
          // 扩展行与歌词页同一份对齐结果 + 同一对开关：歌词页看到什么，
          // 海报就画什么。
          translation: widget.showTranslation && i < widget.translations.length
              ? widget.translations[i]
              : '',
          roma: widget.showRoma && i < widget.romas.length
              ? widget.romas[i]
              : '',
        ),
  ];

  /// 该行的扩展行文本（展示用；与歌词页一致：空文本不占位）。
  (String translation, String roma) _extendedOf(int index) {
    final translation =
        widget.showTranslation && index < widget.translations.length
        ? widget.translations[index]
        : '';
    final roma = widget.showRoma && index < widget.romas.length
        ? widget.romas[index]
        : '';
    return (translation, roma);
  }

  bool _hasSelectedLyrics() => _selectedIndices.isNotEmpty;

  Future<void> _copySelectedLyrics() async {
    HapticsService.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(
        context,
        listen: false,
      ).showSnackBar(l10n.noLyricsSelected);
      return;
    }

    // 复制保持原有分行格式（不合并为单行）。
    final String text = selectedLyrics.join('\n');

    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      Provider.of<NotificationService>(
        context,
        listen: false,
      ).showSnackBar(l10n.selectedLyricsCopied(selectedLyrics.length));
    }
  }

  /// 展示封面（自定义 > 原始 > 默认）的唯一解析入口。
  ///
  /// 页头与海报输入都从这里取同一个 URL：两处各自再解析一次会在自定义
  /// 封面切换的瞬间出现「页头已经换了、海报还是旧图」的分叉。
  String? _displayCoverUrl(CoverResolver covers) => covers
      .displayForId(widget.trackId, originalUrl: widget.albumCoverUrl)
      .url;

  Future<void> _shareAsPoster() async {
    HapticsService.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(
        context,
        listen: false,
      ).showSnackBar(l10n.noLyricsSelected);
      return;
    }

    final posterLyricLines = _getPosterLyricLines();
    if (posterLyricLines.isEmpty) {
      Provider.of<NotificationService>(
        context,
        listen: false,
      ).showSnackBar(l10n.noLyricsSelected);
      return;
    }

    ResponsiveNavigation.showFullScreenPage<void>(
      context: context,
      child: LyricsPosterPreviewPage(
        lyrics: posterLyricLines.map((line) => line.text).join('\n'),
        posterLyricLines: posterLyricLines,
        trackTitle: widget.trackTitle,
        artistName: widget.artistName,
        // 页头与海报共用同一份展示封面（自定义封面必须两处一致）。
        albumCoverUrl: _displayCoverUrl(coverResolverOf(context)),
        trackId: widget.trackId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final detailLayout = context.layoutType(ResponsivePageType.detail);

    final playbackProvider = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    );

    // 进度订阅走 position 独立通道：仅当高亮行号变化时重建，
    // 避免每次进度 tick 整页重建。
    final pageBody = PositionLineIndexBuilder(
      position: playbackProvider.position,
      lineIndexFor: _getCurrentLineIndex,
      builder: (context, currentLineIndex) {
        return Column(
          children: [
            Expanded(
              child: ResponsivePageContainer(
                pageType: ResponsivePageType.detail,
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _lyricLines.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      // 列表首项固定为歌曲信息头部（itemCount = 歌词数 + 1）。
                      // 封面走 CoverChangeBuilder：自定义封面替换后页头立即
                      // 更新，且与海报输入共用同一个展示封面 URL。
                      return CoverChangeBuilder(
                        builder: (context, covers) {
                          final scheme = Theme.of(context).colorScheme;
                          final coverUrl = _displayCoverUrl(covers);
                          return Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                TrackArtwork(
                                  // 已经解析好的展示封面：不再按 trackId 二次
                                  // 解析，页头画的就是海报会用的那一张。
                                  originalUrl: coverUrl,
                                  width: 72,
                                  height: 72,
                                  borderRadius: BorderRadius.circular(12),
                                  memCacheWidth:
                                      (72 *
                                              MediaQuery.of(context)
                                                  .devicePixelRatio)
                                          .round(),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.trackTitle,
                                        style: context.typeScale.titleMedium
                                            .copyWith(
                                              color: scheme.onSurface,
                                              fontWeight: FontWeight.w700,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        widget.artistName,
                                        style: context.typeScale.bodyMedium
                                            .copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    } else {
                      final lyricIndex = index - 1;

                      // 计算当前行是否为连续选中组的首尾
                      bool isFirstInGroup = false;
                      bool isLastInGroup = false;

                      if (_selectedIndices.contains(lyricIndex)) {
                        isFirstInGroup =
                            lyricIndex == 0 ||
                            !_selectedIndices.contains(lyricIndex - 1);

                        isLastInGroup =
                            lyricIndex == _lyricLines.length - 1 ||
                            !_selectedIndices.contains(lyricIndex + 1);
                      }

                      return _LyricTile(
                        index: lyricIndex,
                        line: _lyricLines[lyricIndex],
                        extended: _extendedOf(lyricIndex),
                        isSelected: _selectedIndices.contains(lyricIndex),
                        onTap: () => _toggleLineSelection(lyricIndex),
                        onLongPress: () => _onLineLongPress(lyricIndex),
                        // 选中过行之后，长按才表示「选中到这里」。
                        longPressSemanticLabel: _hasSelectedLyrics()
                            ? l10n.selectionRangeToHere
                            : null,
                        isFirstInGroup: isFirstInGroup,
                        isLastInGroup: isLastInGroup,
                        isCurrentlyPlaying: lyricIndex == currentLineIndex,
                      );
                    }
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    final bottomBar = _buildBottomBar(context, l10n, theme, detailLayout);

    if (widget.embedded) {
      // 侧边弹层里没有 Scaffold：正文 + 底部操作条自己拼成一列。
      return Column(
        children: [
          Expanded(child: pageBody),
          bottomBar,
        ],
      );
    }

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.selectLyrics),
        automaticallyImplyLeading: true,
      ),
      body: pageBody,
      bottomNavigationBar: bottomBar,
    );
  }

  /// 底部操作条：取消全选 / 生成海报，或「点选歌词」引导。
  ///
  /// embedded 时由页面自身拼到正文底部（没有 Scaffold 的
  /// bottomNavigationBar 槽）；侧边弹层在外层已移除正文的底部系统栏
  /// padding，这里统一按 MediaQuery 补窄屏安全区。
  ///
  /// 嵌入时背景必须是透明的：宽屏宿主是 M3E 侧边弹层，其 modal 容器色是
  /// `surfaceContainerLow`，写死 `surface` 会在弹层底部拉出一条不同色的横带。
  Widget _buildBottomBar(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    ResponsiveLayoutSpec detailLayout,
  ) {
    return Container(
      padding: EdgeInsets.only(
        left: detailLayout.horizontalPadding,
        right: detailLayout.horizontalPadding,
        top: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        // 嵌入时让背景来自宿主（宽屏是 M3E 弹层容器，窄屏是外层 Scaffold
        // 的 surface）；独立挂载仍用 surface，保持旧观感。
        color: widget.embedded ? Colors.transparent : theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      // 最小高度而不是固定 56：200% 字号下按钮 / 文案可以撑高，不裁切。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: _isLoading
            ? const Center(child: M3ELoadingIndicator())
            : _hasSelectedLyrics()
            ? Row(
                children: [
                  M3EIconButton(
                    key: const Key('lyricsDeselectAll'),
                    variant: M3EIconButtonVariant.tonal,
                    size: M3EIconButtonSize.md,
                    visualSize: const Size(56, 56),
                    onPressed: _deselectAllLines,
                    icon: const Icon(Icons.close_rounded),
                    semanticLabel: l10n.deselectAll,
                  ),
                  const SizedBox(width: 8),
                  M3EIconButton(
                    key: const Key('lyricsSelectAll'),
                    variant: M3EIconButtonVariant.tonal,
                    size: M3EIconButtonSize.md,
                    visualSize: const Size(56, 56),
                    // 全选只负责选中；已全选时禁用，清空走 ✕。
                    onPressed: _allSelectableSelected ? null : _selectAllLines,
                    icon: const Icon(Icons.select_all_rounded),
                    semanticLabel: l10n.selectAllItems,
                  ),
                  const Spacer(),
                  M3EButton.text(
                    key: const Key('lyricsCopySelected'),
                    onPressed: _copySelectedLyrics,
                    child: Text(
                      l10n.copySelectedLines(_selectedIndices.length),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: M3EButton.filled(
                      // 行数不设上限：海报按选中行数计算高度。
                      onPressed: _shareAsPoster,
                      icon: const Icon(Icons.image_rounded),
                      label: Text(l10n.posterButtonLabel),
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.lyricsSelectionHint,
                      style: context.typeScale.bodyMedium.copyWith(
                        // 操作引导是次要文本，不用强调色。
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  M3EButton.text(
                    key: const Key('lyricsCopyAll'),
                    onPressed: _copyAllOriginalLyrics,
                    child: Text(l10n.copyAll),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LyricTile extends StatelessWidget {
  final int index;
  final LyricLine line;

  /// 该行的扩展行（翻译 / 罗马音；空串 = 无）：与歌词页展示一致。
  final (String translation, String roma) extended;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? longPressSemanticLabel;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool isCurrentlyPlaying;

  const _LyricTile({
    required this.index,
    required this.line,
    required this.extended,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    this.longPressSemanticLabel,
    this.isFirstInGroup = false,
    this.isLastInGroup = false,
    this.isCurrentlyPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    BorderRadius borderRadius;
    if (isSelected) {
      borderRadius = BorderRadius.only(
        topLeft: Radius.circular(isFirstInGroup ? 12 : 4),
        topRight: Radius.circular(isFirstInGroup ? 12 : 4),
        bottomLeft: Radius.circular(isLastInGroup ? 12 : 4),
        bottomRight: Radius.circular(isLastInGroup ? 12 : 4),
      );
    } else {
      borderRadius = BorderRadius.circular(12);
    }

    // 角色契约：选中行底色 secondaryContainer、前景 onSecondaryContainer；
    // 当前播放行（未选中）用 primary 强调；普通行正文 onSurface。
    Color textColor;
    if (isSelected) {
      textColor = theme.colorScheme.onSecondaryContainer;
    } else if (isCurrentlyPlaying) {
      textColor = theme.colorScheme.primary;
    } else {
      textColor = theme.colorScheme.onSurface;
    }
    // 扩展行（翻译 / 罗马音）样式与歌词页一致：主字号 × 0.8、次要文本、
    // 不参与强调色。
    final TextStyle extendedStyle = TextStyle(
      fontSize: 18 * 0.8,
      fontWeight: FontWeight.w500,
      color: isSelected
          ? theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.8)
          : theme.colorScheme.onSurfaceVariant,
    );

    final card = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      child: M3ECard(
        variant: M3ECardVariant.filled,
        elevation: 0,
        borderRadius: borderRadius,
        color: isSelected
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surface, // 当前播放行不改变背景色
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        onPressed: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line.text,
              style: context.typeScale.bodyMedium.copyWith(
                fontSize: 18,
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (extended.$1.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(extended.$1, style: extendedStyle),
            ],
            if (extended.$2.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(extended.$2, style: extendedStyle),
            ],
          ],
        ),
      ),
    );
    final semanticLabel = longPressSemanticLabel;
    if (semanticLabel == null) return card;
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: semanticLabel): onLongPress,
      },
      child: card,
    );
  }
}
