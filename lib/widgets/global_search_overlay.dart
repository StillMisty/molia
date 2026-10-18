/// 桌面壳层全局搜索遮罩：全屏 scrim + 中上居中搜索条 + 就地结果面板。
///
/// 与资料库页共用同一个 [SearchProvider]（不新建 provider）：关键词、分段、
/// 结果与「查看全部结果」后的完整结果链天然同源。结果行点击复用
/// [SearchProvider.playItem]（与资料库搜索结果同一条播放路径：当前类型已加载
/// 结果整体进队列、从该行开始、上下文名 = 音源显示名），不复制第二套播放语义。
///
/// 形态：壳层没有常驻搜索条（顶栏最左让位给品牌区），Ctrl+F / 品牌区点击经
/// [GlobalSearchController] 打开本遮罩。宿主是一个不可见、不可点的占位盒：
/// 只有位置与尺寸有意义——遮罩打开时实测它的矩形，把搜索条与结果面板摆在
/// 同一位置（route 挂在根导航器上、坐标是整窗口径，所以顶栏高度不用写死在这里）。
///
/// **为什么自建 route，而不是 M3E 的 search view**：
/// - 包内 docked 视图的目标矩形完全由锚点矩形推导（`_dockedRect` 的 x / y / 宽
///   都取自 `begin`）：锚点本就摆在搜索条静止位置时，容器变换的位移是 0，
///   开合只剩一层容易被忽略的 scrim 淡入淡出——表现就是「搜索框闪现闪消」；
/// - 包内只在容器变换弹簧落定后才给输入框聚焦（`_tryFocusViewField` 挂在
///   弹簧的 TickerFuture 上）：Ctrl+F 之后立刻打字的按键会被吞掉；
/// - 包内没有暴露动画 / 聚焦钩子，这两点只能靠自建 route 解决：开合走
///   「scrim 淡入 + 内容淡入 + 轻微缩放」，输入框在首帧就 autofocus。
///
/// 结果列表在面板内限高滚动，更长的列表交给资料库目的地（「查看全部结果」
/// 回调由壳层给）。
///
/// 与 M3E 搜索视图的取舍细节见 `docs/pitfalls.md` 已知坑 56。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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
import 'app_search_bar.dart';
import 'artist_row.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文，与中文正式环境文案一致（口径同 `search_section.dart`）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 搜索条与结果面板之间的间隙（M3E docked 口径：2dp）。
const double _barPanelGap = 2;

/// 面板与窗口底缘的最小留白：结果再多也不贴底。
const double _panelBottomMargin = 24;

/// 开合时长：scrim（路由 barrier）与内容同一拍，M3E effects 档量级。
const Duration _openDuration = Duration(milliseconds: 200);

/// 内容入场缩放起点：只做「轻微」缩放，避免整块像弹窗一样飞进来。
const double _enterScale = 0.97;

/// 壳层搜索遮罩宿主：静止位置占位盒 + 自建搜索视图（打开入口见
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

  /// 遮罩内搜索条的静止宽度（宽窗目标值；窄窗由宿主约束夹取）。
  static const double barWidth = 640;

  /// 静止条高：M3E docked 头部同档（56），占位盒与搜索条等高。
  static const double barHeight = 56;

  /// 静止条纵向位置：内容区「中上」（15% 屏高）。
  ///
  /// 夹在 72–160 之间：最小窗口（600 高）不贴顶、不与顶栏（56）重叠，
  /// 高窗口不被顶栏拉下去。搜索条落在这条位置，结果面板向下生长。
  static double barTopFor(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.15).clamp(72.0, 160.0);

  /// 开合过渡的稳定 Key（测试定位用）。
  static const Key transitionKey = Key('globalSearchTransition');

  @override
  State<GlobalSearchOverlay> createState() => _GlobalSearchOverlayState();
}

/// 全局搜索的壳层入口：把「打开 / 聚焦搜索」暴露给壳层（Ctrl+F / 品牌区）。
///
/// 只持有当前挂载的遮罩 State；未挂载（如独立测试）时 [focus] 是 no-op。
/// 已打开时同样 no-op——输入框本就持有焦点。
class GlobalSearchController {
  _GlobalSearchOverlayState? _overlay;

  /// 遮罩开合（打开 = 搜索视图路由在场）。
  ///
  /// 壳层用它驱动「跟着遮罩一起出现」的装饰面（背景模糊层）；开合即时翻转，
  /// 淡入淡出由消费面自己补。
  final ValueNotifier<bool> open = ValueNotifier<bool>(false);

  /// 打开搜索遮罩并聚焦输入框（搜索条自身 autofocus，首帧即拿到焦点）。
  void focus() => _overlay?._open();

  void _attach(_GlobalSearchOverlayState overlay) => _overlay = overlay;

  void _detach(_GlobalSearchOverlayState overlay) {
    if (_overlay == overlay) _overlay = null;
  }

  void dispose() => open.dispose();
}

class _GlobalSearchOverlayState extends State<GlobalSearchOverlay> {
  /// 遮罩是否打开：Esc 占用登记的判据（见 [_claimEscape]）。
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    // Esc：自建视图自带关闭绑定；登记占用让壳层可配置命令（默认「关闭队列」）
    // 让位——焦点不在输入框（Tab 到结果区）时同一次 Esc 不会被两处消费
    // （协议见 escape_claims.dart）。
    EscapeClaims.add(_claimEscape);
  }

  @override
  void didUpdateWidget(covariant GlobalSearchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    EscapeClaims.remove(_claimEscape);
    widget.controller?._detach(this);
    super.dispose();
  }

  /// Esc 归属判定：遮罩打开时由视图自己处理（与视图的关闭路径同源）。
  bool _claimEscape() => _isOpen;

  void _setOpen(bool open) {
    if (!mounted) return;
    _isOpen = open;
    // 壳层装饰面（背景模糊）跟遮罩一起出现 / 消失。
    widget.controller?.open.value = open;
  }

  /// 打开搜索遮罩（Ctrl+F / 品牌区点击；已打开时是空操作）。
  ///
  /// 路由由根导航器承载（`showGeneralDialog` 默认 `useRootNavigator`），与旧
  /// M3E 搜索视图一致：遮罩盖在壳层之上，顶栏 / 底栏一起压暗。
  Future<void> _open() async {
    if (_isOpen) return;
    _setOpen(true);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: _l10n(context).searchClose,
      barrierColor: _scrimColor(context),
      transitionDuration: _openDuration,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _GlobalSearchView(
        restingRect: _restingRect(context),
        onViewAllResults: widget.onViewAllResults,
      ),
      transitionBuilder: _buildTransition,
    );
    // 视图已被 pop（返回键 / Esc / 点结果行 / 点遮罩）：复位开合状态。
    if (!mounted) return;
    _setOpen(false);
  }

  /// 出现 / 消失：内容淡入淡出 + 轻微缩放（scrim 由路由 barrier 自己随动画淡入）。
  ///
  /// 缩放锚点取顶中点：搜索条停在屏幕中上，从它向下展开的观感比居中缩放更贴
  /// 「搜索条就地展开」的语义，也不会让整块横向滑动。
  Widget _buildTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      key: GlobalSearchOverlay.transitionKey,
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: _enterScale, end: 1).animate(curved),
        alignment: Alignment.topCenter,
        child: child,
      ),
    );
  }

  /// 遮罩的压暗底色：与 M3E 搜索视图同一 token（scrim × 32%）。
  Color _scrimColor(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return m3e.searchViewTheme.scrimColor(m3e.colorScheme);
  }

  /// 搜索条静止矩形（整窗坐标）：宿主占位盒的实测矩形。
  ///
  /// route 与占位盒都在同一个窗口坐标系里（导航器覆盖整窗），实测值可以直接
  /// 摆到视图的 `Positioned` 上；窄窗下占位盒被父约束夹窄，这里自然跟着变窄。
  Rect _restingRect(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    // 未布局（理论不可达）：退回「屏宽夹取 + 中上」的估算值。
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(
      GlobalSearchOverlay.barWidth,
      math.max(0.0, screen.width - 48),
    );
    return Rect.fromLTWH(
      (screen.width - width) / 2,
      GlobalSearchOverlay.barTopFor(context),
      width,
      GlobalSearchOverlay.barHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 占位盒：只提供搜索条静止位置与宽度，自己不画任何东西。
    return const SizedBox(
      width: GlobalSearchOverlay.barWidth,
      height: GlobalSearchOverlay.barHeight,
    );
  }
}

/// 搜索视图（route 内容）：搜索条 + 结果面板，落在宿主的静止矩形上。
///
/// 直接订阅 [SearchProvider]：关键词、类型分段、结果与失败态都在 provider 里，
/// 面板只做展示；输入框在首帧 autofocus（打开即能打字，不丢按键）。
class _GlobalSearchView extends StatefulWidget {
  const _GlobalSearchView({
    required this.restingRect,
    required this.onViewAllResults,
  });

  /// 搜索条静止矩形（整窗坐标，来自宿主占位盒的实测值）。
  final Rect restingRect;

  /// 「查看全部结果」（或面板内回车）→ 关闭遮罩并切到资料库目的地。
  final VoidCallback onViewAllResults;

  @override
  State<_GlobalSearchView> createState() => _GlobalSearchViewState();
}

class _GlobalSearchViewState extends State<_GlobalSearchView> {
  /// 遮罩与结果行共用的控制器（本视图独占；打开时用 provider 的词种上）。
  final TextEditingController _field = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'globalSearchField');

  late final SearchProvider _search = context.read<SearchProvider>();

  /// 上一次已播报的内容（关键词 + 文案）：同一条消息不重复播报。
  String? _lastAnnouncement;

  @override
  void initState() {
    super.initState();
    // provider → 输入框单向同步（provider 是搜索状态的唯一源）：在资料库页
    // 改词 / 清空后重新打开遮罩不能残留旧关键词，否则会出现「框里有词、
    // 结果区却为空」的自相矛盾状态。
    _search.addListener(_onSearchChanged);
    _syncFromProvider();
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _field.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _syncFromProvider();
    _announceResults();
  }

  void _syncFromProvider() {
    final query = _search.searchQuery;
    if (_field.text == query) return;
    _field.text = query;
  }

  /// 当前搜索类型已加载的结果条数（与面板列表同口径）。
  int get _resultCount => switch (_search.searchKind) {
        SearchKind.song => _search.filteredResults.length,
        SearchKind.artist => _search.artistResults.length,
        SearchKind.lyric => _search.lyricResults.length,
      };

  /// 结果数变化时给读屏播报（空词 / 加载中不播报；文案走 l10n）。
  ///
  /// 替换包内硬编码英文的播报：同一份「N 条结果」信息按应用语言读出。
  void _announceResults() {
    if (!mounted || !_search.isSearchActive || _search.isSearching) return;
    final message = _l10n(context).searchResultsAnnouncement(_resultCount);
    final key = '${_search.searchQuery}\u0000$message';
    if (key == _lastAnnouncement) return;
    _lastAnnouncement = key;
    final view = View.maybeOf(context);
    if (view == null) return;
    final direction = Directionality.of(context);
    // 下一帧再播报：本次通知期间结果 widget 还没重建，读屏会读到旧内容。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(SemanticsService.sendAnnouncement(view, message, direction));
    });
  }

  /// 收起遮罩：本视图是 route 内容，pop 即关闭（开合状态由宿主复位）。
  void _close() => Navigator.of(context).maybePop();

  /// 「查看全部结果」：完整结果交给资料库目的地。
  void _openAllResults() {
    _close();
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
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final rect = widget.restingRect;
    // 面板限高：条下沿到窗口底部留出边距，更长的列表交给资料库目的地。
    final maxPanelHeight = math.max(
      0.0,
      MediaQuery.sizeOf(context).height -
          rect.bottom -
          _barPanelGap -
          _panelBottomMargin,
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      // M3E 弹层不提供 Material 祖先，结果行的水波会直接崩溃；
      // 透明 Material 只补齐 ink 绘制层，不改变观感。
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppSearchBar(
                    controller: _field,
                    focusNode: _focusNode,
                    hintText: l10n.searchHint,
                    // 打开即聚焦：键盘输入不再被开合动画吞掉。
                    autofocus: true,
                    // 静止外边距取 M3E search bar 的 resting margin（24），
                    // 与结果面板（满宽）错开一档，保持原搜索视图的观感。
                    margin: 24,
                    // 视图头部自绘关闭键：包内默认返回键会弹硬编码英文提示
                    // （M3ESearchConstants.backButtonTooltip），不符「文案必须
                    // 走 l10n」。图标沿用返回箭头（包内语义）：右缘的自绘清除
                    // 键才是 X，两个 X 并排会分不清「关面板」与「清关键词」。
                    leading: M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      icon: const Icon(Icons.arrow_back_rounded),
                      semanticLabel: l10n.searchClose,
                      onPressed: _close,
                    ),
                    onChanged: _search.updateSearchQuery,
                    onSubmitted: _submit,
                    // Esc：焦点在输入框时由搜索栏自身就近分发（外层
                    // CallbackShortcuts 接不到——包内输入框会先消费 Esc 并
                    // 退化成「失焦」）；焦点在结果区时由外层绑定兜底。
                    onEscape: _close,
                  ),
                  const SizedBox(height: _barPanelGap),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxPanelHeight),
                    child: _GlobalSearchResults(
                      onOpenAllResults: _openAllResults,
                      onPlayItem: _playItem,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板内容：类型分段 + 结果列表 + 底部「查看全部结果」。
///
/// 直接订阅 [SearchProvider]：结果在防抖之后异步到达，面板内容必须自己订阅
/// provider 才会实时刷新。
///
/// 两个版式约束：
/// - 整块内容是一个滚动视图：高度贴合内容，超出可用高度就整体滚动；固定高度的
///   子项（分段 / 底部出口）在 Flex 里遇到更小的可用高度时必然溢出，滚动视图
///   在任何可用高度下都只会裁掉内容，不会出现 RenderFlex 溢出。
/// - 面板底自绘（[_buildPanel]）：空态（无关键词）就只剩搜索条。
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

  /// 结果面板底：颜色与圆角取包内 docked 结果面同一套 token。
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
