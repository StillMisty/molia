import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/lyrics_provider.dart';
import '../services/lyrics/lyric_provider.dart';
import '../services/lyrics/lyrics_source_registry.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import '../services/lyrics/lyrics_match.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/lyrics_provider_label.dart';
import 'app_search_bar.dart';

final _logger = Logger('molia.lyrics_source_search_view');

class LyricsSearchResult {
  final SongMatch match;
  final LyricProvider provider;

  LyricsSearchResult({required this.match, required this.provider});
}

class LyricsSearchSelection {
  final String lyrics;
  final String provider;

  const LyricsSearchSelection({
    required this.lyrics,
    required this.provider,
  });
}

/// 每个提供者的搜索状态
enum ProviderSearchState {
  idle,
  loading,
  loaded,
  error,

  /// 来源当前不可用（如未登录 B 站）：不发请求，只提示「怎么办」。
  unavailable,
}

enum _LyricsSearchEntryType {
  header,
  result,
  loadingPlaceholder,
  divider,
}

class _LyricsSearchEntry {
  final _LyricsSearchEntryType type;
  final LyricsSourceStrategy? strategy;
  final LyricsSearchResult? result;

  const _LyricsSearchEntry.header(this.strategy)
      : type = _LyricsSearchEntryType.header,
        result = null;

  const _LyricsSearchEntry.result(this.result)
      : type = _LyricsSearchEntryType.result,
        strategy = null;

  const _LyricsSearchEntry.loadingPlaceholder(this.strategy)
      : type = _LyricsSearchEntryType.loadingPlaceholder,
        result = null;

  const _LyricsSearchEntry.divider()
      : type = _LyricsSearchEntryType.divider,
        strategy = null,
        result = null;
}

/// 歌词换源视图：搜索栏 + 逐平台分组结果；选中即写缓存并退出宿主页。
///
/// 作为「换源」页的歌词 tab 使用（宿主页负责标题与 tab 切换）；结果经
/// `Navigator.pop(LyricsSearchSelection)` 返回给宿主页的调用方。
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
  bool _isFetchingLyric = false;
  String _currentQuery = '';

  final Map<String, ProviderSearchState> _providerStates = {};
  final Map<String, List<LyricsSearchResult>> _providerResults = {};

  late final List<LyricsSourceStrategy> _strategies;

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
    _strategies = enabled == null
        ? allStrategies
        : [
            for (final strategy in allStrategies)
              if (!strategy.isChannel || enabled.contains(strategy.channelKey))
                strategy,
          ];

    for (final strategy in _strategies) {
      _providerStates[strategy.provider.name] = ProviderSearchState.idle;
      _providerResults[strategy.provider.name] = [];
    }

    _currentQuery =
        '${widget.initialTrackTitle} ${widget.initialArtistName}'.trim();
    _searchController.text = _currentQuery;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _performSearch(_currentQuery);
      if (!widget.autofocusSearch) return;
      FocusScope.of(context).requestFocus(_searchFocusNode);
      // 选择全部文本方便替换
      _searchController.selection = TextSelection(
          baseOffset: 0, extentOffset: _searchController.text.length);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool get _isAnyProviderLoading {
    return _providerStates.values
        .any((state) => state == ProviderSearchState.loading);
  }

  /// 当前不可用的来源原因（去重、保持声明顺序）。
  ///
  /// 无结果时要在空态里补一句「怎么办」（如未登录 B 站）；有结果时
  /// 分组头自己会显示提示，不重复。
  List<LyricsSourceUnavailable> get _unavailableReasons {
    final reasons = <LyricsSourceUnavailable>[];
    for (final strategy in _strategies) {
      final reason = _unavailableOf(strategy);
      if (reason != null && !reasons.contains(reason)) reasons.add(reason);
    }
    return reasons;
  }

  /// 来源的可用性在**每次读取时**求值（登录 / 退出会发生在页面打开之后）。
  static LyricsSourceUnavailable? _unavailableOf(
    LyricsSourceStrategy strategy,
  ) =>
      strategy.unavailable?.call();

  List<LyricsSearchResult> get _allResults {
    final results = <LyricsSearchResult>[];
    for (final strategy in _strategies) {
      results.addAll(_providerResults[strategy.provider.name] ?? []);
    }
    return results;
  }

  List<_LyricsSearchEntry> _buildSearchEntries() {
    final entries = <_LyricsSearchEntry>[];
    for (final strategy in _strategies) {
      final providerName = strategy.provider.name;
      final state = _providerStates[providerName] ?? ProviderSearchState.idle;
      final results = _providerResults[providerName] ?? [];

      if (state == ProviderSearchState.idle && _currentQuery.isEmpty) {
        continue;
      }

      entries.add(_LyricsSearchEntry.header(strategy));

      if (results.isNotEmpty) {
        for (final result in results) {
          entries.add(_LyricsSearchEntry.result(result));
        }
      }

      if (state == ProviderSearchState.loading && results.isEmpty) {
        entries.add(_LyricsSearchEntry.loadingPlaceholder(strategy));
      }

      if (_currentQuery.isNotEmpty) {
        entries.add(const _LyricsSearchEntry.divider());
      }
    }
    return entries;
  }

  Future<void> _performSearch(String query) async {
    if (!mounted || query.trim().isEmpty) {
      setState(() {
        _currentQuery = '';
        for (final strategy in _strategies) {
          _providerStates[strategy.provider.name] = ProviderSearchState.idle;
          _providerResults[strategy.provider.name] = [];
        }
      });
      return;
    }

    _searchFocusNode.unfocus(); // 隐藏键盘

    // 不可用来源（未登录 B 站）不发请求：字幕接口只会返回空，白跑一次；
    // 状态置 unavailable，分组头直接显示「怎么办」。
    final searchable = <LyricProvider>[
      for (final strategy in _strategies)
        if (_unavailableOf(strategy) == null) strategy.provider,
    ];

    setState(() {
      _currentQuery = query.trim();
      for (final strategy in _strategies) {
        final providerName = strategy.provider.name;
        _providerResults[providerName] = [];
        _providerStates[providerName] = _unavailableOf(strategy) == null
            ? ProviderSearchState.loading
            : ProviderSearchState.unavailable;
      }
    });

    await Future.wait(
      searchable.map((provider) => _searchProvider(provider, _currentQuery)),
    );
  }

  Future<void> _searchProvider(LyricProvider provider, String query) async {
    const int resultsPerProvider = 3;

    try {
      final matches =
          await provider.searchMultiple(query, '', limit: resultsPerProvider);

      if (!mounted) return;

      // 检查查询是否仍然是当前查询（避免过时的结果）
      if (query != _currentQuery) return;

      final results = matches
          .map((match) => LyricsSearchResult(match: match, provider: provider))
          .toList();

      setState(() {
        _providerResults[provider.name] = results;
        _providerStates[provider.name] = ProviderSearchState.loaded;
      });
    } catch (e) {
      _logger.fine('Provider ${provider.name} search error: $e');

      if (!mounted) return;
      if (query != _currentQuery) return;

      setState(() {
        _providerStates[provider.name] = ProviderSearchState.error;
        _providerResults[provider.name] = [];
      });
    }
  }

  Future<void> _selectResult(LyricsSearchResult result) async {
    if (!mounted || _isFetchingLyric) return;

    // 在异步调用前捕获 Navigator
    final navigator = Navigator.of(context);
    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isFetchingLyric = true;
    });

    try {
      _notificationService.showSnackBar(l10n.lyricsFetching);

      final payload = await result.provider.fetchForMatch(result.match);

      if (!mounted) return;

      final rawLyric = payload?.lyric;
      if (rawLyric != null) {
        final normalizedLyric = result.provider.normalizeLyric(rawLyric);

        if (normalizedLyric.isNotEmpty) {
          await widget.lyricsProvider.saveManual(
            trackId: widget.trackId,
            lyric: normalizedLyric,
            providerName: result.provider.name,
            translation: _normalizeOptional(
              result.provider,
              payload?.translation,
            ),
            roma: _normalizeOptional(result.provider, payload?.roma),
            lxlyric: _normalizeOptional(result.provider, payload?.lxlyric),
          );
          _logger.fine(
              "手动获取的歌词已缓存，曲目ID：${widget.trackId}，提供者：${result.provider.name}");
          navigator.pop(LyricsSearchSelection(
            lyrics: normalizedLyric,
            provider: result.provider.name,
          ));
          return;
        }
      }

      if (mounted) {
        _notificationService.showErrorSnackBar(
            AppLocalizations.of(context)!.lyricsNotFoundForTrack);
      }
    } catch (e) {
      if (mounted) {
        _notificationService.showErrorSnackBar(
            AppLocalizations.of(context)!.lyricsFetchError(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingLyric = false;
        });
      }
    }
  }

  /// 该提供者分组内与当前曲目最相近的结果（时长/歌名/歌手相似度）。
  LyricsSearchResult? _bestMatchOf(LyricProvider provider) {
    final results = _providerResults[provider.name] ?? [];
    if (results.isEmpty) return null;
    final best = pickBestSongMatch(
      [for (final result in results) result.match],
      title: widget.initialTrackTitle,
      artist: widget.initialArtistName,
    );
    if (best == null) return null;
    for (final result in results) {
      if (identical(result.match, best)) return result;
    }
    return null;
  }

  static String? _normalizeOptional(LyricProvider provider, String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final normalized = provider.normalizeLyric(text);
    return normalized.isEmpty ? null : normalized;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final allResults = _allResults;
    final searchEntries = _buildSearchEntries();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: AppSearchBar(
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: l10n.searchHint,
            trailing: [
              if (_isAnyProviderLoading)
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
              if (value.isEmpty) _performSearch('');
            },
            onSubmitted: (value) {
              _performSearch(value);
            },
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              if (!_isAnyProviderLoading &&
                  allResults.isEmpty &&
                  _currentQuery.isEmpty)
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
              else if (allResults.isNotEmpty || _isAnyProviderLoading)
                ListView.builder(
                  padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
                  itemCount: searchEntries.length,
                  itemBuilder: (context, index) {
                    final entry = searchEntries[index];
                    switch (entry.type) {
                      case _LyricsSearchEntryType.header:
                        return _buildProviderHeader(entry.strategy!);
                      case _LyricsSearchEntryType.result:
                        return _buildResultTile(entry.result!);
                      case _LyricsSearchEntryType.loadingPlaceholder:
                        return _buildLoadingPlaceholder();
                      case _LyricsSearchEntryType.divider:
                        return _buildSectionDivider();
                    }
                  },
                )
              else if (!_isAnyProviderLoading &&
                  allResults.isEmpty &&
                  _currentQuery.isNotEmpty)
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
                        for (final reason in _unavailableReasons) ...[
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
              if (_isFetchingLyric)
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
    final state = _providerStates[provider.name] ?? ProviderSearchState.idle;
    final results = _providerResults[provider.name] ?? [];
    final unavailable = _unavailableOf(strategy);

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
    final isBest = identical(_bestMatchOf(result.provider), result);
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
      onTap: _isFetchingLyric ? null : () => _selectResult(result),
      enabled: !_isFetchingLyric,
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
