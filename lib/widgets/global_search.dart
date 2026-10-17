/// 顶栏全局搜索：M3E 搜索锚点（docked 视图）+ 就地结果面板。
///
/// 与资料库页共用同一个 [SearchProvider]（不新建 provider）：关键词、分段、
/// 结果与「查看全部结果」后的完整结果页天然同源。结果行点击复用
/// [SearchProvider.playItem]（与资料库搜索结果同一条播放路径：当前类型已加载
/// 结果整体进队列、从该行开始、上下文名 = 音源显示名），不复制第二套播放语义。
///
/// 面板形态：docked（`isFullScreen: false`）+ `shrinkWrap` —— 挂在搜索框正下方、
/// 贴合内容高度，不遮满整屏；结果列表在面板内限高滚动，更长的列表交给资料库
/// 目的地（「查看全部结果」回调由壳层给）。样式（pill / 高度 / margin）全部走
/// 包内默认，宽度由壳层的搜索槽约束。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../l10n/app_localizations.dart';
import '../providers/search_provider.dart';
import '../services/haptics.dart';
import '../utils/duration_text.dart';
import 'artist_row.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文，与中文正式环境文案一致（口径同 `search_section.dart`）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 顶栏搜索入口（pill）+ 就地结果面板。
class GlobalSearch extends StatefulWidget {
  const GlobalSearch({
    super.key,
    required this.onViewAllResults,
    this.controller,
  });

  /// 「查看全部结果」（或面板内回车）→ 关闭面板并切到资料库目的地。
  final VoidCallback onViewAllResults;

  /// 壳层聚焦入口（可选）：桌面快捷键 Ctrl+F 经它打开面板并聚焦输入框。
  final GlobalSearchController? controller;

  @override
  State<GlobalSearch> createState() => _GlobalSearchState();
}

/// 全局搜索的壳层聚焦入口：把「打开 / 聚焦搜索」暴露给壳层（Ctrl+F）。
///
/// 只持有当前挂载的 [M3ESearchController] 引用——宽窗顶栏才挂搜索 pill；
/// 窄窗顶栏搜索退化为图标（壳层落到搜索页），此时未被附着，[focus] 是 no-op。
class GlobalSearchController {
  M3ESearchController? _search;

  /// 打开搜索面板（打开动画落定后包内让输入框取得焦点）；未挂载（窄窗
  /// 没有搜索 pill）或面板已打开时 no-op——已打开时输入框本就持有焦点，
  /// 包内也没有「重新聚焦已打开面板」的入口。
  void focus() {
    final search = _search;
    if (search == null || !search.isAttached || search.isOpen) return;
    search.openView();
  }

  void _attach(M3ESearchController search) => _search = search;

  void _detach(M3ESearchController search) {
    if (_search == search) _search = null;
  }
}

class _GlobalSearchState extends State<GlobalSearch> {
  /// 顶栏 pill 与面板头部搜索框共用的控制器（M3E 锚点语义：pill 只读，
  /// 真正编辑发生在面板里）。
  final M3ESearchController _controller = M3ESearchController();

  late final SearchProvider _search = context.read<SearchProvider>();

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_controller);
    // provider → pill 单向同步（provider 是搜索状态的唯一源）：在资料库页
    // 改词 / 清空后顶栏 pill 不能残留旧关键词，否则重新打开面板会出现
    // 「框里有词、结果区却为空」的自相矛盾状态。
    _search.addListener(_syncFromProvider);
    _syncFromProvider();
  }

  @override
  void didUpdateWidget(covariant GlobalSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_controller);
      widget.controller?._attach(_controller);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(_controller);
    _search.removeListener(_syncFromProvider);
    _controller.dispose();
    super.dispose();
  }

  void _syncFromProvider() {
    final query = _search.searchQuery;
    if (_controller.text == query) return;
    _controller.text = query;
  }

  /// 收起面板（仅在打开时）：所有跳转前先关，避免搜索路由盖在目标页上。
  void _closePanel() {
    if (_controller.isOpen) _controller.closeView(null);
  }

  /// 「查看全部结果」：完整结果交给资料库目的地。
  void _openAllResults() {
    _closePanel();
    widget.onViewAllResults();
  }

  /// 面板内回车：立即提交（不等输入防抖）再跳资料库看完整结果。
  void _submit(String value) {
    _search.submitSearch(value);
    _openAllResults();
  }

  /// 单曲 / 歌词行点击：与资料库搜索结果同一条播放路径
  /// （[SearchProvider.playItem]），播放后收起面板。
  void _playItem(Map<String, dynamic> item) {
    _search.playItem(item);
    _closePanel();
  }

  /// 当前搜索类型已加载的结果条数（与面板列表同口径）。
  int get _resultCount => switch (_search.searchKind) {
        SearchKind.song => _search.filteredResults.length,
        SearchKind.artist => _search.artistResults.length,
        SearchKind.lyric => _search.lyricResults.length,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3ESearchAnchor.bar(
      searchController: _controller,
      barHintText: l10n.searchHint,
      // docked：面板挂在 pill 正下方（顶栏搜索的就地展开形态），不铺满整屏。
      isFullScreen: false,
      // 面板高度贴合内容：默认 2/3 屏会在结果少时拖出一大片空白。
      shrinkWrap: true,
      // 包内把 suggestions 的长度当作「结果数」做无障碍播报，而结果区实际由
      // viewBuilder 订阅 provider 自绘（异步结果到达不会重跑 suggestions）；
      // 这里只回填与结果数等长的占位 widget 保住播报计数，widget 本身不用。
      suggestionsBuilder: (context, controller) =>
          List<Widget>.filled(_resultCount, const SizedBox.shrink()),
      viewBuilder: (_) => _GlobalSearchResults(
        onOpenAllResults: _openAllResults,
        onPlayItem: _playItem,
      ),
      onChanged: _search.updateSearchQuery,
      onSubmitted: _submit,
    );
  }
}

/// docked 面板内容：类型分段 + 结果列表（限高滚动）+ 底部「查看全部结果」。
///
/// 直接订阅 [SearchProvider]：包内 suggestions 通道只在输入时触发一次，
/// 接不住防抖之后的异步结果，面板内容必须自己订阅 provider 才会实时刷新。
class _GlobalSearchResults extends StatelessWidget {
  const _GlobalSearchResults({
    required this.onOpenAllResults,
    required this.onPlayItem,
  });

  final VoidCallback onOpenAllResults;
  final void Function(Map<String, dynamic> item) onPlayItem;

  /// 结果列表限高：面板贴合内容，长列表在面板内滚动。
  static const double _listMaxHeight = 360;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final search = context.watch<SearchProvider>();
    // 无关键词：面板只留一行输入引导（与资料库搜索页 idle 态同文案）——
    // 包内 docked 结果面始终存在，零内容会留下一条几 dp 的色条。
    if (!search.isSearchActive) return _buildIdle(context, l10n);

    final kinds = search.supportedSearchKinds;
    final isArtistKind = search.searchKind == SearchKind.artist;
    final isLyricKind = search.searchKind == SearchKind.lyric;
    final results = isLyricKind ? search.lyricResults : search.filteredResults;
    final artists = isArtistKind ? search.artistResults : const <ArtistSummary>[];
    final itemCount = isArtistKind ? artists.length : results.length;
    final failure = search.failure;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (kinds.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: _buildKindSwitch(l10n, search, kinds),
          ),
        if (search.isSearching)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: M3EProgressIndicator.linear(),
          ),
        if (failure != null) _buildFailure(context, l10n, search),
        if (itemCount > 0)
          Flexible(
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _listMaxHeight),
              child: ListView.builder(
                // 不接 PrimaryScrollController：面板与页面里的主列表互不干扰。
                primary: false,
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                itemCount: itemCount,
                itemBuilder: (context, index) => isArtistKind
                    ? _buildArtistRow(
                        context, l10n, artists[index], index, itemCount)
                    : _buildTrackRow(context, results[index], index, itemCount),
              ),
            ),
          )
        else if (!search.isSearching && failure == null)
          _buildEmpty(context, l10n, search),
        // 有结果才给「查看全部结果」：零结果时它无处可去（空态文案已说明）。
        if (itemCount > 0) _buildFooter(l10n),
      ],
    );
  }

  /// 未输入关键词：一行输入引导，不渲染结果列表。
  ///
  /// `heightFactor: 1`：面板 shrinkWrap，居中容器必须按内容高度收缩
  /// （默认的 Center 会撑满可用高度，把面板拖成整块空白）。
  Widget _buildIdle(BuildContext context, AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          heightFactor: 1,
          child: Text(
            l10n.searchIdleHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );

  /// 类型分段（单曲 / 歌手 / 歌词）：M3E 分段按钮需要紧约束铺满
  /// （内部 `Positioned.fill`，放松约束会塌成零宽）。
  Widget _buildKindSwitch(
    AppLocalizations l10n,
    SearchProvider search,
    List<SearchKind> kinds,
  ) {
    return SizedBox(
      width: double.infinity,
      child: M3ESegmentedButton<SearchKind>(
        segments: [
          for (final kind in kinds)
            M3ESegment<SearchKind>(value: kind, label: _kindLabel(l10n, kind)),
        ],
        selected: {search.searchKind},
        onSelectionChanged: (selection) {
          // 单选：M3E 语义下重按已选中项不会清空。
          if (selection.isNotEmpty) {
            search.selectSearchKind(selection.first);
          }
        },
      ),
    );
  }

  String _kindLabel(AppLocalizations l10n, SearchKind kind) => switch (kind) {
        SearchKind.song => l10n.searchKindSongs,
        SearchKind.artist => l10n.searchKindArtists,
        SearchKind.lyric => l10n.searchKindLyrics,
      };

  /// 单曲 / 歌词结果行：[TrackRow] 紧凑单列（docked 面板不套宽屏表格列），
  /// 歌词命中片段优先做副标题（与资料库搜索结果行同口径）。
  Widget _buildTrackRow(
    BuildContext context,
    Map<String, dynamic> item,
    int index,
    int count,
  ) {
    final snippet = item['lyric_snippet']?.toString() ?? '';
    return Padding(
      padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
      child: TrackRow(
        key: ValueKey(item['id']),
        title: _titleOf(item),
        artist: snippet.isNotEmpty ? snippet : _artistOf(item),
        coverUrl: _coverUrlOf(item),
        trailingText: durationText(_durationMsOf(item)),
        position: calculateCardPosition(index, count),
        onTap: () {
          HapticsService.lightImpact();
          onPlayItem(item);
        },
      ),
    );
  }

  /// 歌手结果行：[ArtistRow] 只做展示；点击收起面板、跳资料库搜索页
  /// —— 那里有完整歌手结果与进歌手页的链接，面板不重复那套入口编排。
  Widget _buildArtistRow(
    BuildContext context,
    AppLocalizations l10n,
    ArtistSummary artist,
    int index,
    int count,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: ArtistRow.gapOf(context)),
      child: ArtistRow(
        key: ValueKey(artist.id),
        name: artist.name,
        avatarUrl: artist.avatarUrl,
        subtitle: artist.songCount == null
            ? null
            : l10n.artistSongCount(artist.songCount!),
        position: calculateCardPosition(index, count),
        onTap: () {
          HapticsService.lightImpact();
          onOpenAllResults();
        },
      ),
    );
  }

  /// 搜索失败：本地化标题 + 重试（与资料库结果区同一重试入口）。
  Widget _buildFailure(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search,
  ) {
    final theme = Theme.of(context);
    final query = search.searchQuery;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.searchFailed,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
          M3EButton.icon(
            style: M3EButtonStyle.text,
            onPressed: query.trim().isEmpty
                ? null
                : () => search.submitSearch(query),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  /// 有词无结果：一句本地化提示；无可用音源时给音源引导标题
  /// （与资料库结果区同一套键，面板不再堆副标题）。
  Widget _buildEmpty(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        heightFactor: 1,
        child: Text(
          search.hasSelectedSource
              ? l10n.noResultsFound
              : l10n.searchNoSourcesTitle,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 底部出口：完整结果（分段 / 分页 / 歌手链接）在资料库目的地。
  Widget _buildFooter(AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Center(
          heightFactor: 1,
          child: M3EButton.icon(
            style: M3EButtonStyle.text,
            onPressed: onOpenAllResults,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: Text(l10n.viewAllResults),
          ),
        ),
      );
}

/// 搜索结果 item（[SearchProvider] 的兼容 map）→ 展示字段。
///
/// 只做展示提取，播放语义唯一入口是 [SearchProvider.playItem]；字段口径与
/// 资料库搜索结果行一致：封面优先曲目图、其次专辑图，时长缺失不占位。
String _titleOf(Map<String, dynamic> item) => item['name']?.toString() ?? '';

String _artistOf(Map<String, dynamic> item) {
  final artists = item['artists'];
  if (artists is List && artists.isNotEmpty && artists[0] is Map) {
    final name = artists[0]['name'];
    if (name is String) return name;
  }
  return '';
}

String? _coverUrlOf(Map<String, dynamic> item) {
  String? firstImageUrl(Object? images) {
    if (images is List && images.isNotEmpty && images[0] is Map) {
      final url = images[0]['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  final trackCover = firstImageUrl(item['images']);
  if (trackCover != null) return trackCover;
  final album = item['album'];
  return album is Map ? firstImageUrl(album['images']) : null;
}

int? _durationMsOf(Map<String, dynamic> item) {
  final value = item['duration_ms'];
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
