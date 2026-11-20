/// 桌面骨架播放页的左右两栏版式（左侧播放器 + 右侧队列 / 歌词 / 信息）。
///
/// 从 `nowplaying.dart` 抽出的纯版式：页面 State 只传当前 tab、三个滚动
/// 控制器与歌词可见性包装；本组件不认识展开 / 返回 / 外部请求。抽出是为了
/// 让页面状态机留在原文件，不再往 800 行棘轮上堆版式代码。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/lyrics.dart';
import '../widgets/now_playing_layout_metrics.dart';
import '../widgets/player.dart';
import '../widgets/player_morph.dart';
import '../widgets/queue.dart';
import '../widgets/track_info_view.dart';

/// 桌面播放页版式：左「播放器」列 + 右「队列 / 歌词 / 歌曲信息」三 tab。
///
/// 与移动版式的差别：没有迷你态与圆点切换（也不需要展开/收起与内容下拉
/// 手势），页序与默认页跟移动端一致（队列 / 歌词 / 信息，默认歌词）。
/// 左栏宽度按内容宽在 360–480 之间收缩，优先保右栏 420（见
/// `now_playing_layout_metrics.dart`）。
class NowPlayingDesktopLayout extends StatelessWidget {
  const NowPlayingDesktopLayout({
    super.key,
    required this.morph,
    required this.selectedTab,
    required this.onTabSelected,
    required this.queueController,
    required this.lyricsController,
    required this.infoController,
    required this.wrapLyrics,
  });

  /// 顶栏共享元素控制器；桌面播放页只提供页内封面锚点。
  final PlayerMorphController? morph;

  /// 当前右栏 tab（页序见 `now_playing_controller.dart`）。
  final int selectedTab;

  /// 点 tab / 滑动分页 / 外部请求共用的切换入口。
  final ValueChanged<int> onTabSelected;

  final ScrollController queueController;
  final ScrollController lyricsController;
  final ScrollController infoController;

  /// 歌词页可见性包装：只有停在歌词 tab 且壳层可见时才订阅播放进度
  /// （与移动版式 PageView 同一语义，由页面 State 提供）。
  final Widget Function(Widget child) wrapLyrics;

  /// 桌面版式右栏内容与 tab 栏之间的间距（M3E：tab 栏与内容同为 16 口径，
  /// 内容左右边距由各内容组件自持）。
  static const double contentTopPadding = 16;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playerWidth = desktopNowPlayingPlayerWidth(
      DesktopLayout.of(context).contentWidth,
    );
    return Scaffold(
      key: const Key('desktopNowPlayingLayout'),
      body: Row(
        children: [
          SizedBox(
            key: const Key('desktopPlayerColumn'),
            width: playerWidth,
            // 大屏播放器布局：封面自适应 + 歌名/歌手两行 + 进度 + 传输控制
            // （desktopLayout：传输排在播放器列里，见 player.dart）。
            child: Player(
              isLargeScreen: true,
              desktopLayout: true,
              morph: morph,
            ),
          ),
          Expanded(
            key: const Key('desktopSidePane'),
            child: Column(
              children: [
                Padding(
                  // 次 tab（图标 + 文案一行）：行高由 M3ETabTheme.height（48）
                  // 决定，纵向不再叠加自拟内边距；左右 16 与下方内容同一
                  // 内容边距（M3E 口径）。
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: M3ETabs(
                    // 次 tab：图标在文案左侧、同一行排布（桌面右栏是内容区里
                    // 的分组切换，不是顶层导航）。
                    variant: M3ETabsVariant.secondary,
                    tabs: [
                      M3ETab(
                        icon: const Icon(M3EIcons.queue_music_rounded),
                        label: l10n.queueTab,
                      ),
                      M3ETab(
                        icon: const Icon(M3EIcons.lyrics_rounded),
                        label: l10n.lyricsTab,
                      ),
                      M3ETab(
                        icon: const Icon(M3EIcons.info_rounded),
                        label: l10n.trackInfoTabTitle,
                      ),
                    ],
                    selectedIndex: selectedTab,
                    onTabSelected: onTabSelected,
                  ),
                ),
                Expanded(
                  child: M3ETabsView(
                    selectedIndex: selectedTab,
                    onTabSelected: onTabSelected,
                    children: [
                      RepaintBoundary(
                        // 当前曲目由左侧播放器承载，队列页只列其后曲目
                        // （includeCurrent 保持 false，不重复展示）。
                        child: QueueDisplay(
                          controller: queueController,
                          // tab 栏与内容之间留 16（M3E 口径）。
                          topPadding: contentTopPadding,
                        ),
                      ),
                      RepaintBoundary(
                        // 歌词页是唯一订阅播放进度的页内 tab：停在别的 tab
                        // 时通过 nearest scope 放弃 position 订阅（与移动版式
                        // 的 PageView 同一语义）。
                        child: wrapLyrics(
                          LyricsWidget(
                            // 桌面歌词区常展开（无迷你条可让位），快捷操作常显。
                            quickActionsEnabled: true,
                            controller: lyricsController,
                          ),
                        ),
                      ),
                      RepaintBoundary(
                        // 分页左右没有圆点过渡带，顶部留白按 tab 栏下的内容间距；
                        // 内容左右边距由内容自带（16，与 tab 栏对齐）。
                        child: TrackInfoView(
                          controller: infoController,
                          topPadding: contentTopPadding,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
