import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/lyrics_provider.dart';
import '../providers/lyrics_source_search_session.dart';
import '../services/lyrics/lyrics_source_registry.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/lyrics_provider_label.dart';
import 'app_search_bar.dart';

// 宿主页（换源页 / 播放页）只关心 pop 回来的类型，保持从 widget 路径导入。
export '../providers/lyrics_source_search_session.dart'
    show LyricsSearchResult, LyricsSearchSelection;

/// 歌词换源视图：搜索栏 + 逐平台分组结果；选中即写缓存并退出宿主页。
///
/// 作为「换源」页的歌词 tab 使用（宿主页负责标题与 tab 切换）；结果经
/// `Navigator.pop(LyricsSearchSelection)` 返回给宿主页的调用方。
/// 搜索 / 竞态 / 写缓存在 [LyricsSourceSearchSession]，本文件只负责渲染、
/// 焦点、提示与导航。
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
    this.enabledChannelKeys,
    this.autofocusSearch = true,
  });

  @override
  State<LyricsSourceSearchView> createState() => _LyricsSourceSearchViewState();
}

class _LyricsSourceSearchViewState extends State<LyricsSourceSearchView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  late final LyricsSourceSearchSession _session;

  late NotificationService _notificationService;

  @override
  void initState() {
    super.initState();
    _notificationService =
        Provider.of<NotificationService>(context, listen: false);

    // 来源与顺序全部取自注册表（缺省时）：同源渠道置顶、其余按渠道声明
    // 顺序；B 站等只有手动换源的来源也在其中（是否可用在搜索时判定）。
    final allStrategies = widget.sources ??
        LyricsSourceRegistry.standard
            .manualSources(preferredKey: widget.preferredSourceKey);
    final enabled = widget.enabledChannelKeys;
    final strategies = enabled == null
        ? allStrategies
        : [
            for (final strategy in allStrategies)
              if (!strategy.isChannel || enabled.contains(strategy.channelKey))
                strategy,
          ];

    _session = LyricsSourceSearchSession(
      strategies: strategies,
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
          baseOffset: 0, extentOffset: _searchController.text.length);
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

  Future<void> _selectResult(LyricsSearchResult result) async {
    if (_session.isFetchingLyric) return;

    // 在异步调用前捕获 Navigator / 文案：await 之后只用它们提示与 pop。
    final navigator = Navigator.of(context);
    final l10n = AppLocalizations.of(context)!;

    _notificationService.showSnackBar(l10n.lyricsFetching);

    final outcome = await _session.select(result);
    if (!mounted) return;

    switch (outcome) {
      case LyricsSelectionSuccess(:final selection):
        navigator.pop(selection);
      case LyricsSelectionNotFound():
        _notificationService.showErrorSnackBar(l10n.lyricsNotFoundForTrack);
      case LyricsSelectionFailed(:final error):
        _notificationService
            .showErrorSnackBar(l10n.lyricsFetchError(error.toString()));
      case LyricsSelectionBusy():
        // 并发点击：已经有一次取词在途，不重复提示。
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final allResults = _session.allResults;
    final searchEntries = _session.entries;
    final isLoading = _session.isAnyProviderLoading;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: AppSearchBar(
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: l10n.searchHint,
            trailing: [
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: M3EProgressIndicator.circular(
                      size: 16,
                      strokeWidth: 2,
                    ),
                  ),
                ),
            ],
            onChanged: (value) {
              // 清空（清除键或手动删空）：回到初始提示并保留焦点。
              if (value.isEmpty) unawaited(_runSearch(''));
            },
            onSubmitted: (value) {
              unawaited(_runSearch(value));
            },
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              if (!isLoading && allResults.isEmpty && _session.query.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text(
                      l10n.searchHint,
                      textAlign: TextAlign.center,
                      style: context.typeScale.titleMedium.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else if (allResults.isNotEmpty || isLoading)
                ListView.builder(
                  padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
                  itemCount: searchEntries.length,
                  itemBuilder: (context, index) {
                    final entry = searchEntries[index];
                    switch (entry.type) {
                      case LyricsSearchEntryType.header:
                        return _buildProviderHeader(entry.strategy!);
                      case LyricsSearchEntryType.result:
                        return _buildResultTile(entry.result!);
                      case LyricsSearchEntryType.loadingPlaceholder:
                        return _buildLoadingPlaceholder();
                      case LyricsSearchEntryType.divider:
                        return _buildSectionDivider();
                    }
                  },
                )
              else if (!isLoading &&
                  allResults.isEmpty &&
                  _session.query.isNotEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.noResultsFound,
                          textAlign: TextAlign.center,
                          style: context.typeScale.bodyLarge.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        // 无结果时把不可用来源的「怎么办」补在空态里：
                        // 分组头没有渲染，提示不能跟着消失。
                        for (final reason in _session.unavailableReasons) ...[
                          const SizedBox(height: 8),
                          Text(
                            _unavailableHint(l10n, reason),
                            textAlign: TextAlign.center,
                            style: context.typeScale.bodySmall.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              // 只在获取歌词内容时显示遮罩（背景统一取 colorScheme.surface）。
              if (_session.isFetchingLyric)
                Positioned.fill(
                  child: Container(
                    color: theme.colorScheme.surface.withValues(alpha: 0.7),
                    child: const Center(
                      child: M3ELoadingIndicator(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProviderHeader(LyricsSourceStrategy strategy) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final provider = strategy.provider;
    final state = _session.stateOf(provider.name);
    final results = _session.resultsOf(provider.name);
    final unavailable = _session.unavailableReasonOf(strategy);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          // 来源名是静态元数据：M3E assist chip（无 onPressed）统一胶囊
          // 观感，不再自绘圆角 Container。
          M3EChip(
            type: M3EChipType.assist,
            // 显示名统一走 provider 标签（兼容 provider 名 / 渠道 key，
            // 已覆盖 bili / lrclib 与未来的通用渠道）。
            label: lyricsProviderLabel(l10n, const [], provider.name),
          ),
          const SizedBox(width: 8),
          if (state == ProviderSearchState.loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: M3EProgressIndicator.circular(
                size: 14,
                strokeWidth: 2,
              ),
            )
          else if (state == ProviderSearchState.unavailable &&
              unavailable != null)
            Flexible(
              child: Text(
                _unavailableHint(l10n, unavailable),
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (state == ProviderSearchState.loaded && results.isEmpty)
            Text(
              l10n.noResultsFound,
              style: context.typeScale.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else if (state == ProviderSearchState.error)
            Icon(
              Icons.error_outline_rounded,
              size: 16,
              color: theme.colorScheme.error,
            ),
        ],
      ),
    );
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

  Widget _buildResultTile(LyricsSearchResult result) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isBest = identical(_session.bestMatchOf(result.provider), result);
    final isFetching = _session.isFetchingLyric;
    return M3EListItem(
      headline: result.match.title,
      supportingText: result.match.artist,
      trailing: isBest
          // 「最佳匹配」是静态徽章（不可点）：用 assist chip 的胶囊语言，
          // 文案不变、不新增 l10n。
          ? M3EChip(
              type: M3EChipType.assist,
              label: l10n.lyricsBestMatch,
            )
          : Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      onTap: isFetching ? null : () => _selectResult(result),
      enabled: !isFetching,
    );
  }

  Widget _buildLoadingPlaceholder() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 200,
            height: 16,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionDivider() {
    final theme = Theme.of(context);
    return M3EDivider(
      inset: M3EDividerInset.middle,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }
}
