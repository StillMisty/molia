import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/lyric_line.dart';
import '../models/poster_lyric_line.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import '../services/lyrics_display/lyric_timing_policy.dart';
import '../services/notification_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'app_network_image.dart';
import 'lyrics_poster_preview_page.dart';
import 'playback_selectors.dart';

class LyricsSelectionPage extends StatefulWidget {
  // 共享歌词模型（不可变）：选中态由页面自身的下标集合维护。
  final List<LyricLine> lyrics;
  final String trackTitle;
  final String artistName;
  final String? albumCoverUrl;

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
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  const LyricsSelectionPage({
    super.key,
    required this.lyrics,
    required this.trackTitle,
    required this.artistName,
    this.albumCoverUrl,
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
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);

    final text = _lyricLines.map((line) => line.text).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    notificationService.showSnackBar(l10n.copiedToClipboard(l10n.lyricsTitle));
  }

  // 获取当前播放行的索引（与播放页歌词共用同一时间策略：同一 200ms 提前量）
  int _getCurrentLineIndex(Duration currentPosition) =>
      LyricTimingPolicy.page.lineIndexAt(
        _lyricLines,
        currentPosition,
        isSynced: widget.isSynced,
      );

  void _deselectAllLines() {
    HapticsService.lightImpact();
    setState(() {
      _selectedIndices.clear();
    });
  }

  void _toggleLineSelection(int index) {
    if (index < 0 || index >= _lyricLines.length) return;

    HapticsService.selectionClick();
    setState(() {
      if (!_selectedIndices.remove(index)) _selectedIndices.add(index);
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
              translation:
                  widget.showTranslation && i < widget.translations.length
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

  /// 顶栏操作：复制 split button / ⋮ 菜单 + 选中计数胶囊。
  ///
  /// embedded（侧边弹层没有 AppBar）时渲染在正文顶部，与窄屏 AppBar 的
  /// actions 共用同一份控件与状态，避免两套入口行为漂移。
  List<Widget> _selectionActions(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return [
      // 有选中行时：「复制选中」是主操作，菜单里是它的变体「复制全部」，
      // 合并成一个 split button（原来的独立 ⋮ 只有这一条菜单项）。
      if (_hasSelectedLyrics())
        M3ESplitButton<String>(
          key: const Key('lyricsSelectionCopy'),
          label: l10n.copyButtonText,
          leadingIcon: Icons.copy_rounded,
          style: M3EButtonStyle.outlined,
          enabled: !_isLoading,
          onPressed: _copySelectedLyrics,
          items: [
            M3ESplitButtonItem<String>(
              value: 'copyAll',
              child: Text('${l10n.copyButtonText} · ${l10n.lyricsTitle}'),
            ),
          ],
          onSelected: (value) {
            if (value == 'copyAll') {
              _copyAllOriginalLyrics();
            }
          },
        )
      // 未选中任何行：没有主操作可拆，保留 ⋮（复制全部原文歌词）。
      else
        M3EMenu.entries(
          position: M3EMenuAnchorPosition.bottomEnd,
          anchorBuilder: (context, open) => M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: Icon(Icons.more_vert_rounded),
            onPressed: open,
            semanticLabel: l10n.copyButtonText,
          ),
          onSelected: (value) {
            if (value == 'copyAll') {
              _copyAllOriginalLyrics();
            }
          },
          entries: [
            M3EMenuEntry(
              label: '${l10n.copyButtonText} · ${l10n.lyricsTitle}',
              value: 'copyAll',
            ),
          ],
        ),
      if (_hasSelectedLyrics())
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                // 超过 15 行是「数量超限」提醒，走统一警告语义色；
                // 未超限为普通选中计数。
                color: _selectedIndices.length > 15
                    ? AppSemanticColors.of(context).warningContainer
                    : theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_selectedIndices.length}/15',
                style: context.typeScale.labelMedium.copyWith(
                  color: _selectedIndices.length > 15
                      ? AppSemanticColors.of(context).onWarningContainer
                      : theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Future<void> _copySelectedLyrics() async {
    HapticsService.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.noLyricsSelected);
      return;
    }

    // 复制保持原有分行格式（不合并为单行）。
    final String text = selectedLyrics.join('\n');

    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.selectedLyricsCopied(selectedLyrics.length));
    }
  }

  Future<void> _shareAsPoster() async {
    HapticsService.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.noLyricsSelected);
      return;
    }

    // 行数限制：超过 15 行不能生成海报
    if (selectedLyrics.length > 15) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.posterLyricsLimitExceeded);
      return;
    }

    final posterLyricLines = _getPosterLyricLines();
    if (posterLyricLines.isEmpty) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.noLyricsSelected);
      return;
    }

    ResponsiveNavigation.showFullScreenPage<void>(
      context: context,
      child: LyricsPosterPreviewPage(
        lyrics: posterLyricLines.map((line) => line.text).join('\n'),
        posterLyricLines: posterLyricLines,
        trackTitle: widget.trackTitle,
        artistName: widget.artistName,
        albumCoverUrl: widget.albumCoverUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final detailLayout = context.layoutType(ResponsivePageType.detail);

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    // 进度订阅走 position 独立通道：仅当高亮行号变化时重建，
    // 避免每次进度 tick 整页重建。
    final pageBody = PositionLineIndexBuilder(
      position: playbackProvider.position,
      lineIndexFor: _getCurrentLineIndex,
      builder: (context, currentLineIndex) {
        return Column(
          children: [
            // 侧边弹层没有 AppBar：顶栏操作下沉到正文顶部，右侧对齐。
            if (widget.embedded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: _selectionActions(context, l10n, theme),
                ),
              ),
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
                      // 列表首项固定为歌曲信息头部（itemCount = 歌词数 + 1）
                      return Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            AppNetworkImage(
                              url: widget.albumCoverUrl,
                              width: 60,
                              height: 60,
                              borderRadius: BorderRadius.circular(8),
                              memCacheWidth:
                                  (60 * MediaQuery.of(context).devicePixelRatio)
                                      .round(),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.trackTitle,
                                    style:
                                        context.typeScale.titleMedium.copyWith(
                                      // 卡片底为 secondaryContainer：
                                      // 前景必须配 onSecondaryContainer。
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.artistName,
                                    style:
                                        context.typeScale.bodyMedium.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer
                                          .withValues(alpha: 0.8),
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
                    } else {
                      final lyricIndex = index - 1;

                      // 计算当前行是否为连续选中组的首尾
                      bool isFirstInGroup = false;
                      bool isLastInGroup = false;

                      if (_selectedIndices.contains(lyricIndex)) {
                        isFirstInGroup = lyricIndex == 0 ||
                            !_selectedIndices.contains(lyricIndex - 1);

                        isLastInGroup = lyricIndex == _lyricLines.length - 1 ||
                            !_selectedIndices.contains(lyricIndex + 1);
                      }

                      return _LyricTile(
                        index: lyricIndex,
                        line: _lyricLines[lyricIndex],
                        extended: _extendedOf(lyricIndex),
                        isSelected: _selectedIndices.contains(lyricIndex),
                        onTap: () => _toggleLineSelection(lyricIndex),
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
        actions: _selectionActions(context, l10n, theme),
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
      child: SizedBox(
        height: 56.0,
        child: _isLoading
            ? const Center(
                child: M3ELoadingIndicator(),
              )
            : _hasSelectedLyrics()
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 取消全选：普通 tonal 图标键；动作不做额外着色
                      //（特殊色语义只留给状态），禁用态交给 M3E 默认值。
                      M3EIconButton(
                        variant: M3EIconButtonVariant.tonal,
                        size: M3EIconButtonSize.md,
                        visualSize: const Size(56, 56),
                        onPressed: _isLoading ? null : _deselectAllLines,
                        icon: const Icon(Icons.close_rounded),
                        semanticLabel: l10n.deselectAll,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: M3EButton.tonal(
                          onPressed: _selectedIndices.length > 15 || _isLoading
                              ? null
                              : _shareAsPoster,
                          icon: const Icon(Icons.image_rounded),
                          label: Text(l10n.posterButtonLabel),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Text(
                      l10n.tapToSelectLyrics,
                      style: context.typeScale.bodyMedium.copyWith(
                        // 操作引导是次要文本，不用强调色。
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
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
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool isCurrentlyPlaying;

  const _LyricTile({
    required this.index,
    required this.line,
    required this.extended,
    required this.isSelected,
    required this.onTap,
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

    return Padding(
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
  }
}
