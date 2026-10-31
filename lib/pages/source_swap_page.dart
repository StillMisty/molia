/// 换源页：歌词换源 / 音频换源两个 tab 的统一入口。
///
/// 两个 tab 都以同一首曲目（[SourceSwapRequest.seed]）为对象：
/// - 歌词：逐平台搜索歌词，选中后确认才写回缓存（[LyricsSourceSearchView]）；
/// - 音频：跨音源找回同一首歌并原位替换（[SourceSwapView]）。
///
/// 入口：播放页歌词快捷操作栏「换源」（默认歌词 tab）、收藏页左划
/// 「换源」（默认音频 tab，placement 为列表/历史原位替换）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/lyrics_provider.dart';
import '../providers/source_swap_provider.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import '../utils/lyrics_provider_label.dart';
import '../utils/responsive.dart';
import '../widgets/detail_page/detail_page_chrome.dart';
import '../widgets/lyrics_source_search_view.dart';
import '../widgets/source_swap_view.dart';

/// 换源页的默认 tab。
enum SourceSwapTab { lyrics, audio }

/// 打开换源页。
///
/// 歌词 tab 选中结果经本页 pop 返回（[LyricsSearchSelection]），由调用方
/// 落地；音频 tab 走完流程后返回 null。独立打开（无调用方消费）时歌词
/// 结果只写缓存，展示侧经 [LyricsProvider] 通知自行同步。
Future<LyricsSearchSelection?> showSourceSwapPage(
  BuildContext context, {
  required Track seed,
  required LyricsProvider lyricsProvider,
  SourceSwapTab initialTab = SourceSwapTab.audio,
  int? playlistId,
  TrackKey? historyKey,
}) {
  final request = SourceSwapRequest(
    seed: seed,
    placement: historyKey != null
        ? SourceSwapPlacement.history
        : playlistId != null
        ? SourceSwapPlacement.playlist
        : SourceSwapPlacement.queue,
    playlistId: playlistId,
    historyKey: historyKey,
  );
  return ResponsiveNavigation.showSecondaryPage<LyricsSearchSelection>(
    context: context,
    title: AppLocalizations.of(context)!.sourceSwap,
    body: SourceSwapPage(
      request: request,
      lyricsProvider: lyricsProvider,
      initialTab: initialTab,
      embedded: true,
    ),
  );
}

@visibleForTesting
class SourceSwapPage extends StatefulWidget {
  const SourceSwapPage({
    super.key,
    required this.request,
    required this.lyricsProvider,
    this.initialTab = SourceSwapTab.audio,
    this.embedded = false,
    this.lyricsSources,
  });

  final SourceSwapRequest request;
  final LyricsProvider lyricsProvider;
  final SourceSwapTab initialTab;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  /// 测试注入歌词来源（缺省走标准歌词来源注册表）。
  final List<LyricsSourceStrategy>? lyricsSources;

  @override
  State<SourceSwapPage> createState() => _SourceSwapPageState();
}

class _SourceSwapPageState extends State<SourceSwapPage> {
  static const List<SourceSwapTab> _tabs = [
    SourceSwapTab.lyrics,
    SourceSwapTab.audio,
  ];

  late SourceSwapTab _tab = widget.initialTab;

  /// 已访问过的 tab：未访问过的页签不构建（打开音频 tab 不应发起歌词搜索）。
  late final Set<SourceSwapTab> _visited = {widget.initialTab};

  void _selectTab(int index) {
    // 键盘跟着离屏搜索框会悬在列表上：切 tab 一律先收焦点。
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _tab = _tabs[index];
      _visited.add(_tab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seed = widget.request.seed;
    final artist = seed.artistLabel;
    final selectedIndex = _tabs.indexOf(_tab);
    final horizontalPadding = detailPageHorizontalPadding(context);
    // 只读一次：来源标签 / 渠道顺序不随搜索通知变化，页面不应因 provider
    // 通知整页重建。标签只用可搜索描述符；停用 / 非搜索脚本不在其中，
    // 标签回退源 key。
    final swapProvider = context.read<SourceSwapProvider>();
    final sourceDescriptors = swapProvider.searchableSources;
    // 歌词来源跟随渠道停用：取「已启用渠道」而不是「可搜索渠道」，
    // 五个音乐平台没有 LX 脚本时仍能用歌词来源。
    final enabledChannelKeys = swapProvider.enabledChannelKeys;
    // chips 顺序取渠道管理的全部渠道顺序：五个音乐平台即使当前不可搜索，
    // 仍可能作为歌词来源出现，不能按 searchableSources 排到后面。
    final channelOrder = swapProvider.orderedChannelKeys;
    // 曲目条副标题保留「歌手 · 当前来源」：换源对象是这首歌，来源名让
    // 用户确认正在从哪个渠道找回同一首。
    final sourceLabel = lyricsProviderLabel(
      l10n,
      sourceDescriptors,
      seed.id.sourceKey,
    );
    final subtitle = artist.isEmpty ? sourceLabel : '$artist · $sourceLabel';

    final body = Column(
      children: [
        // 头部 / tab 栏自带详情页水平边距，下方内容只补一次，避免双层内缩。
        DetailPageTrackHeader(track: seed, subtitle: subtitle),
        DetailPageTabBar(
          tabs: [
            M3ETab(
              icon: const Icon(Icons.lyrics_rounded),
              label: l10n.sourceSwapTabLyrics,
            ),
            M3ETab(
              icon: const Icon(Icons.music_note_rounded),
              label: l10n.sourceSwapTabAudio,
            ),
          ],
          selectedIndex: selectedIndex,
          onTabSelected: _selectTab,
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: M3ETabsView(
              selectedIndex: selectedIndex,
              onTabSelected: _selectTab,
              children: [
                if (_visited.contains(SourceSwapTab.lyrics))
                  LyricsSourceSearchView(
                    initialTrackTitle: seed.title,
                    initialArtistName: artist,
                    initialAlbum: seed.album,
                    initialDuration: seed.duration,
                    trackId: seed.id.uri,
                    lyricsProvider: widget.lyricsProvider,
                    sourceDescriptors: sourceDescriptors,
                    sources: widget.lyricsSources,
                    enabledChannelKeys: enabledChannelKeys,
                    channelOrder: channelOrder,
                  )
                else
                  const SizedBox.shrink(),
                if (_visited.contains(SourceSwapTab.audio))
                  SourceSwapView(request: widget.request)
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.sourceSwap),
        automaticallyImplyLeading: true,
      ),
      body: body,
    );
  }
}
