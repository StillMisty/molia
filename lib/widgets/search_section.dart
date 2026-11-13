import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../pages/artist_page.dart';
import '../providers/search_assist_controller.dart';
import '../providers/search_provider.dart';
import 'search_results_view.dart';

/// 搜索结果区（资料库页宿主）：只接线导航与 provider，呈现全部在
/// [SearchResultsView]。
///
/// 分段 / 失败 / 空态 / 行映射由统一搜索结果面负责；本宿主只保留：
/// - 「点击行 → 搜索结果整体进队列」的播放语义（[SearchProvider.playItem]）；
/// - 歌手导航（歌手行与行内歌手链接 → 歌手页）。
///
/// 结果行是收藏页同形的 `TrackRow`（点击播放；操作菜单收藏 / 加入列表，
/// 与 `TrackMenuTile` 同一份动作域：触摸端行尾 ⋮、桌面端行表面右键），
/// 歌手类型用 `ArtistRow`（点击进歌手页）；分段按渠道能力位显隐（脚本源
/// 只有单曲）。
class SearchSection extends StatelessWidget {
  const SearchSection({super.key, this.controller, this.assist});

  /// 结果列表滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时由 [SearchResultsView] 自建（独立挂载 / 测试）。
  final ScrollController? controller;

  /// 共享搜索辅助：零结果纠错候选从这里读，点击走显式提交。
  final SearchAssistController? assist;

  @override
  Widget build(BuildContext context) {
    final search = context.read<SearchProvider>();
    return SearchResultsView(
      variant: SearchResultsVariant.page,
      session: search.session,
      controller: controller,
      correction: assist?.value.correction,
      onCorrectionTap: assist?.acceptCorrection,
      onPlay: search.playItem,
      onOpenArtist: (sourceKey, artistId, {fallbackName}) => showArtistPage(
        context,
        sourceKey,
        artistId,
        fallbackName: fallbackName,
      ),
    );
  }
}
