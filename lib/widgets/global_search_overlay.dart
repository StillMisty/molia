/// 桌面壳层全局搜索遮罩：全屏 scrim + 上方居中搜索条 + 就地结果面板。
///
/// 与资料库页共用同一个 [SearchProvider]（不新建 provider）：关键词、分段、
/// 结果与「查看全部结果」后的完整结果链天然同源。结果行点击复用
/// [SearchProvider.playItem]（与资料库搜索结果同一条播放路径：当前类型已加载
/// 结果整体进队列、从该行开始、上下文名 = 音源显示名），不复制第二套播放语义。
///
/// 形态：壳层没有常驻搜索条（顶栏最左让位给品牌区），Ctrl+F / 品牌区点击经
/// [GlobalSearchController] 打开本遮罩。锚点是一个不可见、不可点的占位盒：
/// 只有位置与尺寸有意义——M3E 搜索视图从锚点矩形做容器变换，展开成全屏 scrim
/// + 居中搜索条 + 贴合内容高度的结果面板（docked 形态；整屏不透明页与
/// 「遮罩」语义不符）。结果列表在面板内限高滚动，更长的列表交给资料库目的地
/// （「查看全部结果」回调由壳层给）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../l10n/app_localizations.dart';
import '../providers/search_provider.dart';
import '../services/escape_claims.dart';
import '../services/haptics.dart';
import '../utils/duration_text.dart';
import 'artist_row.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文，与中文正式环境文案一致（口径同 `search_section.dart`）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 壳层搜索遮罩宿主：隐形锚点 + M3E 搜索视图（打开入口见
/// [GlobalSearchController.focus]）。
class GlobalSearchOverlay extends StatefulWidget {
  const GlobalSearchOverlay({
    super.key,
    required this.onViewAllResults,
    this.controller,
  });

  /// 「查看全部结果」（或面板内回车）→ 关闭遮罩并切到资料库目的地。
  final VoidCallback onViewAllResults;

  /// 壳层打开入口（Ctrl+F / 品牌区点击）：把「打开并聚焦」暴露给壳层。
  final GlobalSearchController? controller;

  /// 遮罩内搜索条的静止宽度：docked 视图从锚点宽度起步（窄窗由视图自己
  /// 按屏宽收窄，这里只给桌面宽窗的目标值）。
  static const double anchorWidth = 640;

  /// 静止条高：M3E docked 头部同档（56），开合变换的起止高度一致。
  static const double anchorHeight = 56;

  /// 锚点纵向位置：屏幕「中上」（15% 屏高）。
  ///
  /// 夹在 72–160 之间：最小窗口（600 高）不贴顶、不与顶栏（56）重叠，
  /// 高窗口不被顶栏拉下去。搜索条从这条位置展开，结果面板向下生长。
  static double anchorTopFor(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.15).clamp(72.0, 160.0);

  @override
  State<GlobalSearchOverlay> createState() => _GlobalSearchOverlayState();
}

/// 全局搜索的壳层入口：把「打开 / 聚焦搜索」暴露给壳层（Ctrl+F / 品牌区）。
///
/// 只持有当前挂载的 [M3ESearchController] 引用；未挂载（如独立测试）时
/// [focus] 是 no-op。已打开时同样 no-op——输入框本就持有焦点。
class GlobalSearchController {
  M3ESearchController? _search;

  /// 遮罩开合（打开 = 搜索视图路由在场）。
  ///
  /// 壳层用它驱动「跟着遮罩一起出现」的装饰面（背景模糊层）；开合即时翻转，
  /// 淡入淡出由消费面自己补。
  final ValueNotifier<bool> open = ValueNotifier<bool>(false);

  /// 打开搜索遮罩（打开动画落定后包内让输入框取得焦点）。
  void focus() {
    final search = _search;
    if (search == null || !search.isAttached || search.isOpen) return;
    search.openView();
  }

  void _attach(M3ESearchController search) => _search = search;

  void _detach(M3ESearchController search) {
    if (_search == search) _search = null;
  }

  void dispose() => open.dispose();
}

class _GlobalSearchOverlayState extends State<GlobalSearchOverlay> {
  /// 遮罩与结果行共用的控制器（打开后编辑在视图头部，锚点不参与编辑）。
  final M3ESearchController _controller = M3ESearchController();

  late final SearchProvider _search = context.read<SearchProvider>();

  /// 遮罩是否打开：Esc 占用登记的判据（见 [_claimEscape]）。
  ///
  /// 只被按键判定读取、不参与 build，故不 setState（避免一次多余重建）。
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_controller);
    // provider → 输入框单向同步（provider 是搜索状态的唯一源）：在资料库页
    // 改词 / 清空后重新打开遮罩不能残留旧关键词，否则会出现「框里有词、
    // 结果区却为空」的自相矛盾状态。
    _search.addListener(_syncFromProvider);
    _syncFromProvider();
    // Esc：M3E 视图自带关闭绑定；登记占用让壳层可配置命令（默认「关闭队列」）
    // 让位——焦点不在输入框（Tab 到关闭键 / 结果区）时同一次 Esc 不会被两处
    // 消费（协议见 escape_claims.dart）。
    EscapeClaims.add(_claimEscape);
  }

  @override
  void didUpdateWidget(covariant GlobalSearchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_controller);
      widget.controller?._attach(_controller);
    }
  }

  @override
  void dispose() {
    EscapeClaims.remove(_claimEscape);
    widget.controller?._detach(_controller);
    _search.removeListener(_syncFromProvider);
    _controller.dispose();
    super.dispose();
  }

  /// Esc 归属判定：遮罩打开时由 M3E 视图处理（与视图自己的关闭路径同源）。
  bool _claimEscape() => _open;

  void _setOpen(bool open) {
    if (!mounted) return;
    _open = open;
    // 壳层装饰面（背景模糊）跟遮罩一起出现 / 消失。
    widget.controller?.open.value = open;
  }

  void _syncFromProvider() {
    final query = _search.searchQuery;
    if (_controller.text == query) return;
    _controller.text = query;
  }

  /// 收起遮罩（仅在打开时）：所有跳转前先关，避免遮罩盖在目标页上。
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
  /// （[SearchProvider.playItem]），播放后收起遮罩。
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
    return M3ESearchAnchor(
      searchController: _controller,
      // 隐形锚点：只提供「搜索条从哪里展开」的几何，不接受点击与焦点
      // （打开只走 Ctrl+F / 品牌区，见 GlobalSearchController）。
      enabled: false,
      // docked：整屏 scrim + 居中搜索条 + 结果面板；不铺满的不透明页才是
      // 「遮罩 + 中上搜索框」的形态。
      isFullScreen: false,
      // 结果面板底自绘（见 _GlobalSearchResults._buildPanel）：包内那层在
      // 空态也会留下一条 4dp 色条（内容为零仍有内边距），置透明后空态就真的
      // 只剩搜索条。
      viewBackgroundColor: Colors.transparent,
      // 结果面板贴合内容高度：默认 2/3 屏会在结果少时拖出一大片空白。
      shrinkWrap: true,
      viewHintText: l10n.searchHint,
      // 视图头部自绘关闭键：包内默认返回键会弹硬编码英文提示
      // （M3ESearchConstants.backButtonTooltip），不符「文案必须走 l10n」。
      // 图标沿用返回箭头（包内语义）：右缘的自绘清除键才是 X，两个 X 并排
      // 会分不清「关面板」与「清关键词」。
      viewLeading: M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.arrow_back_rounded),
        semanticLabel: l10n.searchClose,
        onPressed: () => _controller.closeView(null),
      ),
      // 清除键自绘：包内置键会弹英文硬编码提示，且清除时不回调 onChanged
      // （输入框与 provider 同步，需自行把空词同步过去）。
      showViewClearButton: false,
      viewTrailing: [_SearchClearAction(controller: _controller)],
      // 包内把 suggestions 的长度当作「结果数」做无障碍播报，而结果区实际由
      // viewBuilder 订阅 provider 自绘（异步结果到达不会重跑 suggestions）；
      // 这里只回填与结果数等长的占位 widget 保住播报计数，widget 本身不用。
      suggestionsBuilder: (context, controller) =>
          List<Widget>.filled(_resultCount, const SizedBox.shrink()),
      viewBuilder: (_) => _GlobalSearchResults(
        onOpenAllResults: _openAllResults,
        onPlayItem: _playItem,
      ),
      viewOnChanged: _search.updateSearchQuery,
      viewOnSubmitted: _submit,
      viewOnOpen: () => _setOpen(true),
      viewOnClose: () => _setOpen(false),
      builder: (context, controller) => const SizedBox(
        width: GlobalSearchOverlay.anchorWidth,
        height: GlobalSearchOverlay.anchorHeight,
      ),
    );
  }
}

/// 视图头部的清除键：本地化无障碍名 + 清空后把空词同步给 provider。
///
/// 自绘的原因同 `app_search_bar.dart`：包内置键会弹英文硬编码提示，
/// 且清除只 `controller.clear()`、不触发 onChanged，面板会停留在上一轮结果上。
class _SearchClearAction extends StatelessWidget {
  const _SearchClearAction({required this.controller});

  final M3ESearchController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.text.isEmpty) return const SizedBox.shrink();
        return M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.close_rounded),
          semanticLabel: l10n.clearSearch,
          onPressed: () {
            controller.clear();
            context.read<SearchProvider>().updateSearchQuery('');
          },
        );
      },
    );
  }
}

/// docked 面板内容：类型分段 + 结果列表 + 底部「查看全部结果」。
///
/// 直接订阅 [SearchProvider]：包内 suggestions 通道只在输入时触发一次，
/// 接不住防抖之后的异步结果，面板内容必须自己订阅 provider 才会实时刷新。
///
/// 两个版式约束（都是包内行为倒逼的，不是版式偏好）：
/// - 整块内容是一个滚动视图：高度贴合内容、超出可用高度就整体滚动。M3E 的
///   开合动画会把容器收缩回锚点高度，途中容器可以小于内容，固定高度的子项
///   （分段 / 底部出口）在 Flex 里必然溢出；换成滚动视图后任何可用高度下都
///   不会出现 RenderFlex 溢出（内容被视口裁掉即可）。
/// - 面板底自绘（[_buildPanel]）：包内结果面在空态也会画一条 4dp 色条，所以
///   遮罩把包内那层置透明，卡片由这里画——空态（无关键词）就只剩搜索条。
class _GlobalSearchResults extends StatelessWidget {
  const _GlobalSearchResults({
    required this.onOpenAllResults,
    required this.onPlayItem,
  });

  final VoidCallback onOpenAllResults;
  final void Function(Map<String, dynamic> item) onPlayItem;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final search = context.watch<SearchProvider>();
    // 无关键词：结果面留空（只留搜索条）——打开遮罩就是为了输入，一行
    // 「输入关键词搜索歌曲」的引导是多余的。
    if (!search.isSearchActive) return const SizedBox.shrink();

    final kinds = search.supportedSearchKinds;
    final isArtistKind = search.searchKind == SearchKind.artist;
    final isLyricKind = search.searchKind == SearchKind.lyric;
    final results = isLyricKind ? search.lyricResults : search.filteredResults;
    final artists = isArtistKind ? search.artistResults : const <ArtistSummary>[];
    final itemCount = isArtistKind ? artists.length : results.length;
    final failure = search.failure;

    return _buildPanel(
      context,
      child: SingleChildScrollView(
        // 不接 PrimaryScrollController：面板与页面里的主列表互不干扰。
        primary: false,
        child: Column(
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
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < itemCount; index++)
                      isArtistKind
                          ? _buildArtistRow(
                              context, l10n, artists[index], index, itemCount)
                          : _buildTrackRow(
                              context, results[index], index, itemCount),
                  ],
                ),
              )
            else if (!search.isSearching && failure == null)
              _buildEmpty(context, l10n, search),
            // 有结果才给「查看全部结果」：零结果时它无处可去（空态文案已说明）。
            if (itemCount > 0) _buildFooter(l10n),
          ],
        ),
      ),
    );
  }

  /// 结果面板底：颜色与圆角取包内 docked 结果面同一套 token（遮罩已把包内
  /// 那层设成透明，这里接手它的外观）。
  Widget _buildPanel(BuildContext context, {required Widget child}) {
    final m3e = M3ETheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: m3e.searchViewTheme.containedContainerColor(m3e.colorScheme),
        borderRadius: M3EShapes.radiusExtraLarge,
      ),
      child: ClipRRect(borderRadius: M3EShapes.radiusExtraLarge, child: child),
    );
  }

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
