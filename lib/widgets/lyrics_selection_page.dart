import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/lyric_line.dart';
import '../models/poster_lyric_line.dart';
import '../providers/playback_provider.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../theme/app_semantic_colors.dart';
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

  const LyricsSelectionPage({
    super.key,
    required this.lyrics,
    required this.trackTitle,
    required this.artistName,
    this.albumCoverUrl,
  });

  @override
  State<LyricsSelectionPage> createState() => _LyricsSelectionPageState();
}

class _LyricsSelectionPageState extends State<LyricsSelectionPage> {
  late final List<LyricLine> _lyricLines;
  // bool _isLoading = false; // isLoading can be final
  final bool _isLoading = false;

  /// 选中行下标（模型不可变，选中态属于页面状态）。
  final Set<int> _selectedIndices = {};

  final _scrollController = ScrollController();
  final SettingsService _settingsService = SettingsService();

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

  // 获取当前播放行的索引（与播放页歌词共用同一二分查找）
  int _getCurrentLineIndex(Duration currentPosition) =>
      lyricLineIndexAt(_lyricLines, currentPosition);

  void _deselectAllLines() {
    HapticFeedback.lightImpact();
    setState(() {
      _selectedIndices.clear();
    });
  }

  void _toggleLineSelection(int index) {
    if (index < 0 || index >= _lyricLines.length) return;

    HapticFeedback.selectionClick();
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
            PosterLyricLine(text: _lyricLines[i].text),
      ];

  bool _hasSelectedLyrics() => _selectedIndices.isNotEmpty;

  Future<void> _copySelectedLyrics() async {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.noLyricsSelected);
      return;
    }

    final copyAsSingleLine = await _settingsService.getCopyLyricsAsSingleLine();

    // 根据设置格式化文本
    final String text;
    if (copyAsSingleLine) {
      // 复制为单行，用空格替换换行符
      text = selectedLyrics.join(' ');
    } else {
      // 复制为多行，保持原有格式
      text = selectedLyrics.join('\n');
    }

    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.selectedLyricsCopied(selectedLyrics.length));
    }
  }

  Future<void> _shareAsPoster() async {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context)!;
    final selectedLyrics = _getSelectedLyrics();
    if (selectedLyrics.isEmpty) {
      Provider.of<NotificationService>(context, listen: false)
          .showSnackBar(l10n.noLyricsSelected);
      return;
    }

    // 检查行数限制
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

    // 导航到海报预览页面
    ResponsiveNavigation.showSecondaryPage(
      context: context,
      child: LyricsPosterPreviewPage(
        lyrics: posterLyricLines.map((line) => line.text).join('\n'),
        posterLyricLines: posterLyricLines,
        trackTitle: widget.trackTitle,
        artistName: widget.artistName,
        albumCoverUrl: widget.albumCoverUrl,
      ),
      preferredMode: SecondaryPageMode.fullScreen,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final detailLayout = context.layoutType(ResponsivePageType.detail);

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.selectLyrics),
        automaticallyImplyLeading: true,
        actions: [
          M3EMenu.entries(
            position: M3EMenuAnchorPosition.bottomEnd,
            anchorBuilder: (context, open) => M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: Icon(Icons.more_vert_rounded),
              onPressed: open,
              tooltip: l10n.copyButtonText,
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
            M3EButton.text(
              onPressed: _isLoading ? null : _copySelectedLyrics,
              child: Text(l10n.copyButtonText),
            ),
          if (_hasSelectedLyrics())
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: _selectedIndices.length > 15
                          ? AppSemanticColors.of(context).onWarningContainer
                          : theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      // 进度订阅 position 独立通道：仅当高亮行号变化时重建，
      // 不再随每次进度 tick 整页重建。
      body: PositionLineIndexBuilder(
        position: playbackProvider.position,
        lineIndexFor: _getCurrentLineIndex,
        builder: (context, currentLineIndex) {
          return Column(
            children: [
              // 歌词列表 - 包含歌曲信息的统一滚动
              Expanded(
                child: ResponsivePageContainer(
                  pageType: ResponsivePageType.detail,
                  child: ListView.builder(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount:
                        _lyricLines.length + 1, // +1 for the song info header
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        // 第一项：歌曲信息卡片
                        return Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              AppNetworkImage(
                                url: widget.albumCoverUrl,
                                width: 60,
                                height: 60,
                                borderRadius: BorderRadius.circular(8),
                                memCacheWidth: (60 *
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
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
                        // 其余项：歌词行
                        final lyricIndex = index - 1;

                        // 计算当前行是否为连续选中组的首尾
                        bool isFirstInGroup = false;
                        bool isLastInGroup = false;

                        if (_selectedIndices.contains(lyricIndex)) {
                          // 检查是否为组的第一行
                          isFirstInGroup = lyricIndex == 0 ||
                              !_selectedIndices.contains(lyricIndex - 1);

                          // 检查是否为组的最后一行
                          isLastInGroup =
                              lyricIndex == _lyricLines.length - 1 ||
                                  !_selectedIndices.contains(lyricIndex + 1);
                        }

                        return _LyricTile(
                          index: lyricIndex,
                          line: _lyricLines[lyricIndex],
                          isSelected: _selectedIndices.contains(lyricIndex),
                          onTap: () => _toggleLineSelection(lyricIndex),
                          isFirstInGroup: isFirstInGroup,
                          isLastInGroup: isLastInGroup,
                          isCurrentlyPlaying:
                              lyricIndex == currentLineIndex, // 传递当前播放状态
                        );
                      }
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),

      // 底部操作栏
      bottomNavigationBar: Container(
        padding: EdgeInsets.only(
          left: detailLayout.horizontalPadding,
          right: detailLayout.horizontalPadding,
          top: 16,
          bottom: 16 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
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
                          tooltip: l10n.deselectAll,
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
                        style: theme.textTheme.bodyMedium?.copyWith(
                          // 操作引导是次要文本，不用强调色。
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
        ),
      ),
    );
  }
}

// 简化的歌词行组件
class _LyricTile extends StatelessWidget {
  final int index;
  final LyricLine line;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool isCurrentlyPlaying;

  const _LyricTile({
    // super.key, // Parameter 'key' is not used
    required this.index,
    required this.line,
    required this.isSelected,
    required this.onTap,
    this.isFirstInGroup = false,
    this.isLastInGroup = false,
    this.isCurrentlyPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 计算圆角
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
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 18,
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
