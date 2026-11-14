import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/source.dart';
import '../l10n/app_localizations.dart';
import '../providers/lyrics_provider.dart';
import '../providers/lyrics_source_search_session.dart';
import '../services/lyrics/lyrics_source_registry.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/lyrics_provider_label.dart';
import 'detail_page/detail_page_chrome.dart';
import 'source_swap/source_swap_chrome.dart';
import 'track_row.dart';

// 宿主页（换源页 / 播放页）只关心 pop 回来的类型，保持从 widget 路径导入。
export '../providers/lyrics_source_search_session.dart'
    show LyricsSearchResult, LyricsSearchSelection;

/// 歌词换源视图：搜索栏 + 来源筛选 + 分组结果 + 底部确认。
///
/// 作为「换源」页的歌词 tab 使用（宿主页负责标题与 tab 切换）。点结果
/// 切换选中态并拉取前几行预览，底部「使用此歌词」才写缓存；成功经
/// `Navigator.pop(LyricsSearchSelection)` 返回给宿主页的调用方。
/// 搜索 / 竞态 / 写缓存在 [LyricsSourceSearchSession]，本文件只负责渲染、
/// 焦点、提示与导航。PageView 切走会销毁离屏页，因此保持存活以保住结果。
class LyricsSourceSearchView extends StatefulWidget {
  final String initialTrackTitle;
  final String initialArtistName;

  /// 种子曲目的专辑 / 时长：只参与最佳匹配，不直接展示。
  final String? initialAlbum;
  final Duration? initialDuration;

  final String trackId; // 保存手动选择的歌词时用

  /// 歌词会话模块：手动选择结果经它写缓存并更新展示状态。
  final LyricsProvider lyricsProvider;

  /// 来源列表（测试注入）；缺省使用 [LyricsSourceRegistry.standard]
  /// （B 站可用性绑定 `BiliSession.shared`，与生产账号服务同一份）。
  final List<LyricsSourceStrategy>? sources;

  /// 渠道描述符：只用于来源标签查找显示名，不参与排序。
  ///
  /// 非搜索 / 已停用脚本不在其中时 `lyricsProviderLabel` 回退源 key。
  final List<SourceDescriptor> sourceDescriptors;

  /// 已启用的渠道 key（停用的渠道不显示歌词来源）；null = 不过滤。
  ///
  /// 由换源页从 `SourceRegistry` 取「已启用渠道」而不是「可搜索渠道」：
  /// 六个音乐平台在没有 LX 脚本时不可搜索，但歌词来源仍然可用。
  final Set<String>? enabledChannelKeys;

  /// 渠道管理里的全部渠道顺序（含停用 / 不可搜索项）。
  ///
  /// 会话据此排列歌词来源；null / 空表 = 保持来源声明顺序。
  final List<String>? channelOrder;

  const LyricsSourceSearchView({
    super.key,
    required this.initialTrackTitle,
    required this.initialArtistName,
    this.initialAlbum,
    this.initialDuration,
    required this.trackId,
    required this.lyricsProvider,
    this.sources,
    this.sourceDescriptors = const [],
    this.enabledChannelKeys,
    this.channelOrder,
  });

  @override
  State<LyricsSourceSearchView> createState() => _LyricsSourceSearchViewState();
}

class _LyricsSourceSearchViewState extends State<LyricsSourceSearchView>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  late final LyricsSourceSearchSession _session;

  late NotificationService _notificationService;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );

    // 来源取自注册表（缺省时）；B 站等只有手动换源的来源也在其中
    // （是否可用在搜索时判定）。顺序由 channelOrder 决定。
    final allStrategies =
        widget.sources ?? LyricsSourceRegistry.standard.strategies;

    _session = LyricsSourceSearchSession(
      strategies: allStrategies,
      enabledChannelKeys: widget.enabledChannelKeys,
      channelOrder: widget.channelOrder,
      lyricsProvider: widget.lyricsProvider,
      trackId: widget.trackId,
      trackTitle: widget.initialTrackTitle,
      trackArtist: widget.initialArtistName,
      trackAlbum: widget.initialAlbum,
      trackDuration: widget.initialDuration,
    )..addListener(_onSessionChanged);

    final initialQuery =
        '${widget.initialTrackTitle} ${widget.initialArtistName}'.trim();
    _searchController.text = initialQuery;
    // 与音频 tab 一致：只把光标放到末尾，不聚焦、不全选，避免进入页面就
    // 抢键盘 / 把预填关键词整段高亮成误触。搜索仍在首帧后自动发起。
    _searchController.selection = TextSelection.collapsed(
      offset: initialQuery.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runSearch(initialQuery));
    });
  }

  @override
  void dispose() {
    _session
      ..removeListener(_onSessionChanged)
      ..dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _runSearch(String query) async {
    // 清空（清除键或手动删空）保留焦点与键盘，方便重新输入。
    if (query.trim().isNotEmpty) _searchFocusNode.unfocus(); // 隐藏键盘
    await _session.search(query);
  }

  Future<void> _confirmSelected() async {
    // 选中项切到别的来源后不可见：按钮已禁用，这里再兜一层，避免程序化
    // 回调把用户看不见的候选写进缓存。
    if (_session.isFetchingLyric || !_session.isSelectedVisible) return;

    // 在异步调用前捕获 Navigator / 文案：await 之后只用它们提示与 pop。
    final navigator = Navigator.of(context);
    final l10n = AppLocalizations.of(context)!;

    _notificationService.showSnackBar(l10n.lyricsFetching);

    final outcome = await _session.applySelected();
    if (!mounted) return;

    switch (outcome) {
      case LyricsSelectionSuccess(:final selection):
        navigator.pop(selection);
      case LyricsSelectionNotFound():
        _notificationService.showErrorSnackBar(l10n.lyricsNotFoundForTrack);
      case LyricsSelectionFailed():
        // 不在界面展示原始异常（边界已归一为 LyricsSelectionFailed）；
        // 文案只说「没取到 + 换一个来源」。
        _notificationService.showErrorSnackBar(l10n.lyricsFetchError);
      case LyricsSelectionNone():
      case LyricsSelectionBusy():
        // 底部按钮已禁用 / 已有一轮取词在途：不重复提示。
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final strategies = _session.strategies;
    final isLoading = _session.isAnyProviderLoading;
    final failed = _session.failedStrategies;
    final busy = _session.isFetchingLyric;
    final hasStrategies = strategies.isNotEmpty;
    final hasQuery = _session.query.isNotEmpty;
    final entries = _session.entries;
    final selectedVisible = _session.isSelectedVisible;
    final preview = _session.preview;
    // 底栏只在当前筛选下真有可见结果时出现；选中项切到别的来源后仍保留，
    // 但不可见时确认按钮禁用、预览隐藏，切回来即恢复。
    final showFooter = hasStrategies && hasQuery && _session.hasVisibleResults;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasStrategies)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SourceSwapSearchField(
              key: const Key('sourceSwapSearchFieldLyrics'),
              controller: _searchController,
              focusNode: _searchFocusNode,
              enabled: !busy,
              onChanged: (value) {
                if (busy) return;
                // 清空（清除键或手动删空）：回到初始提示并保留焦点。
                if (value.isEmpty) unawaited(_runSearch(''));
              },
              onSubmitted: (value) {
                if (busy) return;
                unawaited(_runSearch(value));
              },
            ),
          ),
        if (hasStrategies && hasQuery)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: SourceSwapSourceChips(
              sources: [
                for (final strategy in strategies)
                  SourceSwapSourceOption(
                    key: strategy.channelKey,
                    label: lyricsProviderLabel(
                      l10n,
                      widget.sourceDescriptors,
                      strategy.channelKey,
                    ),
                  ),
              ],
              selectedKey: _session.activeSourceKey,
              enabled: !busy,
              // 切换筛选只改展示：候选与选中项都留着，用户来回比较不丢状态。
              onSelected: (key) {
                if (busy) return;
                _session.selectSource(key);
              },
            ),
          ),
        if (hasQuery && failed.isNotEmpty)
          SourceSwapNotice.failed(
            message: l10n.sourceSwapFailedSources(
              failed
                  .map(
                    (strategy) => lyricsProviderLabel(
                      l10n,
                      widget.sourceDescriptors,
                      strategy.channelKey,
                    ),
                  )
                  .join(', '),
            ),
            retryKey: const Key('sourceSwapRetryFailedLyrics'),
            onRetry: isLoading || busy ? null : _session.retryFailed,
          ),
        if (isLoading && _session.allResults.isNotEmpty)
          const M3EProgressIndicator.linear(),
        Expanded(child: _buildBody(context, l10n, strategies, entries)),
        if (selectedVisible && preview != null)
          _buildPreviewPanel(context, l10n, preview),
        if (showFooter)
          SourceSwapActionBar(
            confirmLabel: l10n.sourceSwapLyricsConfirm,
            busy: busy,
            onConfirm: selectedVisible ? _confirmSelected : null,
          ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    List<LyricsSourceStrategy> strategies,
    List<LyricsSearchEntry> entries,
  ) {
    if (strategies.isEmpty) {
      return DetailPageEmpty(
        icon: Icons.lyrics_rounded,
        message: l10n.lyricsSourceNoSources,
        hint: l10n.lyricsSourceNoSourcesHint,
      );
    }
    if (_session.query.isEmpty) {
      return DetailPageEmpty(
        icon: Icons.search_rounded,
        message: l10n.sourceSwapSearchEmpty,
      );
    }
    if (_session.isAnyProviderLoading && _session.allResults.isEmpty) {
      return DetailPageLoading(label: l10n.sourceSwapSearching);
    }
    if (_session.activeSourceKey.isNotEmpty &&
        _isStrategyLoading(_session.activeSourceKey) &&
        _session
            .resultsOf(_providerNameFor(_session.activeSourceKey) ?? '')
            .isEmpty) {
      return DetailPageLoading(label: l10n.sourceSwapSearching);
    }

    final hasResult = entries.any(
      (entry) => entry.type == LyricsSearchEntryType.result,
    );
    if (!hasResult) {
      // 全部模式可能只剩「未登录 B 站」这类 header（提示挂在标题右侧）：
      // header 留在顶部，空态放下面，不能把 header-only 当普通列表渲染。
      final headers = [
        for (final entry in entries)
          if (entry.type == LyricsSearchEntryType.header)
            _buildSectionHeader(l10n, entry.strategy!),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...headers,
          Expanded(child: _buildNoResultState(l10n)),
        ],
      );
    }

    final gap = TrackRow.gapOf(context);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final result = entry.result;
        if (result == null) {
          return _buildSectionHeader(l10n, entry.strategy!);
        }
        final results = _session.resultsOf(result.provider.name);
        final resultIndex = results.indexOf(result);
        final visibleCount = _session.displayedCountOf(result.provider.name);
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: TrackRow(
            key: ValueKey<String>(
              'lyricsSourceRow-${result.provider.name}-${result.match.songId}',
            ),
            model: TrackRowModel(
              title: result.match.title,
              artist: result.match.artist,
              durationMs: result.match.duration?.inMilliseconds,
              placeholderIcon: Icons.lyrics_rounded,
              selected: _session.isSelected(result),
            ),
            surface: const TrackRowSurface(coverSize: 40),
            position: calculateCardPosition(resultIndex, visibleCount),
            trailing: _session.isBestMatch(result)
                // 「最佳匹配」是静态徽章（不可点）：用 assist chip 的胶囊语言。
                ? M3EChip(type: M3EChipType.assist, label: l10n.lyricsBestMatch)
                : null,
            // 点行只选中，取词交给底部确认；取词期间锁住选中。
            onTap: _session.isFetchingLyric
                ? null
                : () => _session.select(result),
          ),
        );
      },
    );
  }

  /// 选中歌词预览：固定在列表与底栏之间，只在选中行当前可见时出现。
  ///
  /// 预览是「确认前看一眼」，不抢列表高度：卡片最多三行歌词，加载 / 空 /
  /// 失败各有明确下一步（失败带重试）。
  Widget _buildPreviewPanel(
    BuildContext context,
    AppLocalizations l10n,
    LyricsPreview preview,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final type = context.typeScale;
    final secondaryStyle = type.bodyMedium.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: M3ECard(
        key: const Key('lyricsSourcePreview'),
        variant: M3ECardVariant.filled,
        elevation: 0,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.subject_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.lyricsPreviewTitle,
                  style: type.labelLarge.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            switch (preview.status) {
              LyricsPreviewStatus.loading => Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: M3EProgressIndicator.circular(
                      size: 16,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.lyricsFetching, style: secondaryStyle),
                ],
              ),
              LyricsPreviewStatus.ready => Text(
                preview.lines.join('\n'),
                maxLines: LyricsSourceSearchSession.previewLineLimit,
                overflow: TextOverflow.ellipsis,
                style: type.bodyMedium.copyWith(
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
              LyricsPreviewStatus.empty => Text(
                l10n.lyricsNotFoundForTrack,
                style: secondaryStyle,
              ),
              LyricsPreviewStatus.failed => Row(
                children: [
                  Expanded(
                    child: Text(l10n.lyricsFetchError, style: secondaryStyle),
                  ),
                  const SizedBox(width: 8),
                  M3EIconButton(
                    key: const Key('lyricsSourcePreviewRetry'),
                    variant: M3EIconButtonVariant.standard,
                    icon: const Icon(Icons.refresh_rounded),
                    semanticLabel: l10n.retry,
                    onPressed: _session.isFetchingLyric
                        ? null
                        : _session.retryPreview,
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    AppLocalizations l10n,
    LyricsSourceStrategy strategy,
  ) {
    final unavailable = _session.unavailableReasonOf(strategy);
    final hasMore = _session.hasMoreOf(strategy);
    return SourceSwapSectionHeader(
      key: ValueKey<String>('lyricsSourceSection-${strategy.channelKey}'),
      label: lyricsProviderLabel(
        l10n,
        widget.sourceDescriptors,
        strategy.channelKey,
      ),
      // 标题右侧空间有限，用 locale 专属的短提示（中文仍为完整文案）；
      // 单源空态另有完整提示。
      hint: unavailable == null
          ? null
          : _unavailableInlineHint(l10n, unavailable),
      trailing: hasMore
          ? M3EButton.text(
              key: ValueKey<String>('sourceSwapViewAll-${strategy.channelKey}'),
              size: M3EButtonSize.xs,
              onPressed: _session.isFetchingLyric
                  ? null
                  : () => _session.selectSource(strategy.channelKey),
              child: Text(l10n.sourceSwapViewAll),
            )
          : null,
    );
  }

  Widget _buildNoResultState(AppLocalizations l10n) {
    final activeSourceKey = _session.activeSourceKey;
    if (activeSourceKey.isEmpty) {
      return DetailPageEmpty(
        icon: Icons.search_off_rounded,
        message: l10n.lyricsEmptyState,
        hint: l10n.sourceSwapEmptyHint,
      );
    }
    final unavailable = _unavailableReasonOfChannel(activeSourceKey);
    return DetailPageEmpty(
      icon: Icons.search_off_rounded,
      message: l10n.searchNoResultsInSource(
        lyricsProviderLabel(l10n, widget.sourceDescriptors, activeSourceKey),
      ),
      hint: unavailable == null
          ? l10n.sourceSwapEmptyHint
          : _unavailableHint(l10n, unavailable),
    );
  }

  LyricsSourceUnavailable? _unavailableReasonOfChannel(String channelKey) {
    for (final strategy in _session.strategies) {
      if (strategy.channelKey == channelKey) {
        return _session.unavailableReasonOf(strategy);
      }
    }
    return null;
  }

  bool _isStrategyLoading(String channelKey) {
    final providerName = _providerNameFor(channelKey);
    return providerName != null &&
        _session.stateOf(providerName) == ProviderSearchState.loading;
  }

  String? _providerNameFor(String channelKey) {
    for (final strategy in _session.strategies) {
      if (strategy.channelKey == channelKey) return strategy.provider.name;
    }
    return null;
  }

  /// 不可用原因 → 「怎么办」文案。
  ///
  /// 用穷尽 switch 而不是 if：以后新增 [LyricsSourceUnavailable] 时编译器
  /// 会提醒补文案，避免 UI 只显示一个空分组头。
  static String _unavailableHint(
    AppLocalizations l10n,
    LyricsSourceUnavailable reason,
  ) {
    return switch (reason) {
      LyricsSourceUnavailable.biliLoginRequired =>
        l10n.biliAccountTileLoggedOut,
    };
  }

  /// 分组标题右侧的单行提示：英文用短句，避免标题行被省略号截断；
  /// 中文保持完整口径。
  static String _unavailableInlineHint(
    AppLocalizations l10n,
    LyricsSourceUnavailable reason,
  ) {
    return switch (reason) {
      LyricsSourceUnavailable.biliLoginRequired =>
        l10n.biliLyricsLoginHintInline,
    };
  }
}
