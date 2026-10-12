/// 换源页：歌词换源 / 音频换源两个 tab 的统一入口。
///
/// 两个 tab 都以同一首曲目（[SourceSwapRequest.seed]）为对象：
/// - 歌词：逐平台搜索歌词并写回缓存（[LyricsSourceSearchView]）；
/// - 音频：跨音源找回同一首歌并原位替换（[SourceSwapView]）。
///
/// 入口：播放页歌词快捷操作栏「换源」（默认歌词 tab）、收藏页左划
/// 「换源」（默认音频 tab，placement 为列表/历史原位替换）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/lyrics_provider.dart';
import '../providers/source_swap_provider.dart';
import '../utils/responsive.dart';
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
    // 大屏侧边弹层：页面自带 AppBar（含返回），不再叠一层关闭行。
    showCloseButton: false,
    child: SourceSwapPage(
      request: request,
      lyricsProvider: lyricsProvider,
      initialTab: initialTab,
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
  });

  final SourceSwapRequest request;
  final LyricsProvider lyricsProvider;
  final SourceSwapTab initialTab;

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
    setState(() {
      _tab = _tabs[index];
      _visited.add(_tab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seed = widget.request.seed;
    final artist = seed.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    final selectedIndex = _tabs.indexOf(_tab);

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.sourceSwap),
        automaticallyImplyLeading: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: M3ETabs(
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
          ),
          Expanded(
            child: M3ETabsView(
              selectedIndex: selectedIndex,
              onTabSelected: _selectTab,
              children: [
                if (_visited.contains(SourceSwapTab.lyrics))
                  LyricsSourceSearchView(
                    initialTrackTitle: seed.title,
                    initialArtistName: artist,
                    trackId: seed.id.uri,
                    lyricsProvider: widget.lyricsProvider,
                    preferredSourceKey: seed.id.sourceKey,
                    // 仅默认 tab 为歌词时自动聚焦：音频入口不抢键盘。
                    autofocusSearch:
                        widget.initialTab == SourceSwapTab.lyrics,
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
        ],
      ),
    );
  }
}
