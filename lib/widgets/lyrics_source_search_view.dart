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
import '../utils/lyrics_provider_label.dart';
import 'source_swap/source_swap_chrome.dart';
import 'track_row.dart';

// 宿主页（换源页 / 播放页）只关心 pop 回来的类型，保持从 widget 路径导入。
export '../providers/lyrics_source_search_session.dart'
    show LyricsSearchResult, LyricsSearchSelection;

/// 歌词换源视图：搜索栏 + 来源筛选 + 分组结果 + 底部确认。
///
/// 作为「换源」页的歌词 tab 使用（宿主页负责标题与 tab 切换）。点结果只
/// 切换选中态，底部「使用此歌词」才取词并写缓存；成功经
/// `Navigator.pop(LyricsSearchSelection)` 返回给宿主页的调用方。
/// 搜索 / 竞态 / 写缓存在 [LyricsSourceSearchSession]，本文件只负责渲染、
/// 焦点、提示与导航。PageView 切走会销毁离屏页，因此保持存活以保住结果。
class LyricsSourceSearchView extends StatefulWidget {
  final String initialTrackTitle;
  final String initialArtistName;
  final String trackId; // 保存手动选择的歌词时用

  /// 当前曲目的平台 key（kw/kg/tx/wy/mg/bili）：同源来源的分组置顶。
  final String? preferredSourceKey;

  /// 歌词会话模块：手动选择结果经它写缓存并更新展示状态。
  final LyricsProvider lyricsProvider;

  /// 来源列表（测试注入）；缺省使用 [LyricsSourceRegistry.standard]
  /// （B 站可用性绑定 `BiliSession.shared`，与生产账号服务同一份）。
  final List<LyricsSourceStrategy>? sources;

  /// 当前渠道描述符：来源标签回退脚本显示名（不参与搜索）。
  final List<SourceDescriptor> channels;

  /// 已启用的渠道 key（停用的渠道不显示歌词来源）；null = 不过滤。
  ///
  /// 由换源页从 `SourceRegistry` 取「已启用渠道」而不是「可搜索渠道」：
  /// 五个音乐平台在没有 LX 脚本时不可搜索，但歌词来源仍然可用。
  final Set<String>? enabledChannelKeys;

  /// 进入时是否自动聚焦搜索框（默认 tab 为歌词时聚焦，否则不抢焦点）。
  final bool autofocusSearch;

  const LyricsSourceSearchView({
    super.key,
    required this.initialTrackTitle,
    required this.initialArtistName,
    required this.trackId,
    required this.lyricsProvider,
    this.preferredSourceKey,
    this.sources,
    this.channels = const [],
    this.enabledChannelKeys,
    this.autofocusSearch = true,
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

  /// 本地来源筛选（空串 = 全部）：只影响展示，不重搜、不清选中。
  String _selectedSourceKey = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );

    // 来源与顺序全部取自注册表（缺省时）：同源渠道置顶、其余按渠道声明
    // 顺序；B 站等只有手动换源的来源也在其中（是否可用在搜索时判定）。
    final allStrategies =
        widget.sources ??
        LyricsSourceRegistry.standard.manualSources(
          preferredKey: widget.preferredSourceKey,
        );

    _session = LyricsSourceSearchSession(
      strategies: allStrategies,
      enabledChannelKeys: widget.enabledChannelKeys,
      lyricsProvider: widget.lyricsProvider,
      trackId: widget.trackId,
      trackTitle: widget.initialTrackTitle,
      trackArtist: widget.initialArtistName,
    )..addListener(_onSessionChanged);

    final initialQuery =
        '${widget.initialTrackTitle} ${widget.initialArtistName}'.trim();
    _searchController.text = initialQuery;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runSearch(initialQuery));
      if (!widget.autofocusSearch) return;
      FocusScope.of(context).requestFocus(_searchFocusNode);
      // 选择全部文本方便替换
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
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
    if (_session.isFetchingLyric) return;

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
    final selected = _session.selected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SourceSwapSearchField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: (value) {
              // 清空（清除键或手动删空）：回到初始提示并保留焦点。
              if (value.isEmpty) unawaited(_runSearch(''));
            },
            onSubmitted: (value) {
              unawaited(_runSearch(value));
            },
          ),
        ),
        if (strategies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: SourceSwapSourceChips(
              sources: [
                for (final strategy in strategies)
                  SourceSwapSourceOption(
                    key: strategy.channelKey,
                    label: lyricsProviderLabel(
                      l10n,
                      widget.channels,
                      strategy.channelKey,
                    ),
                  ),
              ],
              selectedKey: _selectedSourceKey,
              // 切换筛选只改展示：候选与选中项都留着，用户来回比较不丢状态。
              onSelected: (key) => setState(() => _selectedSourceKey = key),
            ),
          ),
        if (failed.isNotEmpty)
          SourceSwapNotice.failed(
            message: l10n.sourceSwapFailedSources(
              failed
                  .map(
                    (strategy) => lyricsProviderLabel(
                      l10n,
                      widget.channels,
                      strategy.channelKey,
                    ),
                  )
                  .join(', '),
            ),
            retryKey: const Key('sourceSwapRetryFailedLyrics'),
            onRetry: isLoading || _session.isFetchingLyric
                ? null
                : _session.retryFailed,
          ),
        // 不可用来源（未登录 B 站）是持续状态：有结果时不占用分组头，
        // 由这条提示统一说明「怎么办」。
        for (final reason in _session.unavailableReasons)
          SourceSwapNotice.info(message: _unavailableHint(l10n, reason)),
        if (isLoading && _session.allResults.isNotEmpty)
          const M3EProgressIndicator.linear(),
        Expanded(child: _buildBody(context, l10n, strategies)),
        SourceSwapActionBar(
          selectedTitle: selected?.match.title,
          selectedSource: selected == null
              ? null
              : lyricsProviderLabel(
                  l10n,
                  widget.channels,
                  selected.provider.name,
                ),
          confirmLabel: l10n.sourceSwapLyricsConfirm,
          busy: _session.isFetchingLyric,
          onConfirm: _confirmSelected,
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    List<LyricsSourceStrategy> strategies,
  ) {
    if (strategies.isEmpty) {
      return SourceSwapEmptyState(
        icon: Icons.lyrics_rounded,
        title: l10n.lyricsSourceNoSources,
        hint: l10n.sourceSwapNoSourcesHint,
      );
    }
    if (_session.query.isEmpty) {
      return SourceSwapEmptyState(
        icon: Icons.search_rounded,
        title: l10n.sourceSwapSearchEmpty,
      );
    }
    if (_session.isAnyProviderLoading && _session.allResults.isEmpty) {
      return const SourceSwapLoadingState();
    }
    if (_selectedSourceKey.isNotEmpty &&
        _isStrategyLoading(_selectedSourceKey) &&
        _session
            .resultsOf(_providerNameFor(_selectedSourceKey) ?? '')
            .isEmpty) {
      return const SourceSwapLoadingState();
    }

    final entries = _session.entriesFor(
      _selectedSourceKey.isEmpty ? null : _selectedSourceKey,
    );
    if (entries.isEmpty) {
      if (_selectedSourceKey.isEmpty) {
        return SourceSwapEmptyState(
          icon: Icons.search_off_rounded,
          title: l10n.lyricsEmptyState,
          hint: l10n.sourceSwapEmptyHint,
        );
      }
      return SourceSwapEmptyState(
        icon: Icons.search_off_rounded,
        title: l10n.searchNoResultsInSource(
          lyricsProviderLabel(l10n, widget.channels, _selectedSourceKey),
        ),
        hint: l10n.sourceSwapEmptyHint,
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
          return SourceSwapSectionHeader(
            key: ValueKey<String>(
              'lyricsSourceSection-${entry.strategy!.channelKey}',
            ),
            label: lyricsProviderLabel(
              l10n,
              widget.channels,
              entry.strategy!.channelKey,
            ),
          );
        }
        final results = _session.resultsOf(result.provider.name);
        final resultIndex = results.indexOf(result);
        final isBest = identical(_session.bestMatchOf(result.provider), result);
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: TrackRow(
            key: ValueKey<String>(
              'lyricsSourceRow-${result.provider.name}-${result.match.songId}',
            ),
            model: TrackRowModel(
              title: result.match.title,
              artist: result.match.artist,
              placeholderIcon: Icons.lyrics_rounded,
              selected: _session.isSelected(result),
            ),
            surface: const TrackRowSurface(coverSize: 40),
            position: calculateCardPosition(resultIndex, results.length),
            trailing: isBest
                // 「最佳匹配」是静态徽章（不可点）：用 assist chip 的胶囊语言。
                ? M3EChip(type: M3EChipType.assist, label: l10n.lyricsBestMatch)
                : null,
            // 点行只选中，取词交给底部确认。
            onTap: () => _session.select(result),
          ),
        );
      },
    );
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
}
