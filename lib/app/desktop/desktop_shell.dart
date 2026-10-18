/// 桌面应用骨架（Linux / Windows / macOS）。
///
/// 顶栏（最左搜索入口 + 空白拖动区 + 设置 + 窗口按钮）+ 恒折叠侧栏（96dp）+
/// 页面栈 + 常驻底部播放条（播放页里整条让位）。手机 / 平板骨架不经过本文件
/// （`app_shell.dart` 按平台分流）。
///
/// 骨架本身无状态：侧栏恒折叠、队列并入播放页右栏之后，与窗口相关的可变量
/// 只剩当前目的地（由 [chrome] 带入），页面实例与共享元素飞行仍由壳层 State
/// 单一持有。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/nav_provider.dart';
import '../../services/window/window_chrome.dart';
import '../../utils/responsive.dart';
import '../../widgets/desktop_layout.dart';
import '../../widgets/global_search.dart';
import '../../widgets/player_morph.dart';
import '../shell_chrome.dart';
import 'desktop_shortcuts.dart';
import 'now_playing_bar.dart';

/// 桌面骨架：顶栏 + 恒折叠侧栏 + 页面栈 + 底部播放条。
///
/// 整棵树包在 [DesktopShortcuts] 里：全局快捷键在壳层顶层监听，播放动作走
/// provider，其余（聚焦搜索 / 切目的地 / 收队列）走壳层回调。
///
/// 导航与顶栏的共享部分（目的地映射 / 标签 / 设置按钮 / 窗口控件 / 拖动区）
/// 消费 [ShellChrome]，与移动骨架同一份 spec；布局阈值消费 [DesktopLayout]
/// （壳层解析一次，见 `widgets/desktop_layout.dart`）。
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.chrome,
    required this.pageStack,
    required this.morph,
    required this.searchController,
    required this.onViewAllResults,
    required this.onOpenSearch,
    required this.onFocusSearch,
    required this.onSelectDestinationIndex,
    required this.onOpenQueue,
    required this.onCloseQueuePanel,
  });

  /// 导航 / 顶栏 spec（与移动骨架共用，见 `shell_chrome.dart`）。
  final ShellChrome chrome;

  /// 分层页面栈（页面实例与过渡动画由壳层持有）。
  final Widget pageStack;

  /// 顶栏 ↔ 播放页共享元素控制器（底部播放条封面锚点与隐藏状态）。
  final PlayerMorphController morph;

  /// 顶栏搜索的控制器（宽窗 pill 与面板共用；窄窗图标不挂它）。
  final GlobalSearchController searchController;

  /// 顶栏搜索「查看全部结果」（或面板内回车）→ 切到资料库目的地
  /// （完整结果 / 分页 / 歌手链接都在那里，同一 `SearchProvider` 实例）。
  final VoidCallback onViewAllResults;

  /// 窄窗口搜索入口（图标态）→ 打开搜索：由壳层决定落点
  /// （当前 = 资料库目的地的搜索页，见 [_buildTitleBar]）。
  final VoidCallback onOpenSearch;

  /// 全局快捷键 Ctrl+F：聚焦 / 打开全局搜索。宽窗聚焦顶栏搜索 pill；
  /// 窄窗顶栏搜索已退化为图标，落到与图标同一条路径（壳层按同一个
  /// 宽度阈值分流，回调只负责各自落点）。
  final VoidCallback onFocusSearch;

  /// 全局快捷键 Ctrl+1/2/3：切到第 index 个可见目的地
  /// （顺序 = `NavProvider.visibleDestinations`；越界时壳层回调自行忽略）。
  final ValueChanged<int> onSelectDestinationIndex;

  /// 底栏队列按钮：跳播放页 + 让页内右栏切到队列 tab。
  final VoidCallback onOpenQueue;

  /// Esc 的壳层命令（可配置的「关闭队列」）：队列并入播放页右栏后，
  /// 落点 = 收起队列视图（见壳层回调）。
  final VoidCallback onCloseQueuePanel;

  /// 顶栏搜索槽宽度：包内默认 360–720 是页面内搜索的规格，顶栏入口只需
  /// 一个工具条宽度。
  static const double searchSlotWidth = 320;

  /// 顶栏搜索入口的稳定 Key（宽窗 pill / 窄窗图标同一逻辑槽位，测试定位用）。
  static const Key searchEntryKey = Key('desktopGlobalSearch');

  /// 搜索右侧空白拖动区的稳定 Key（双击最大化挂在它上面）。
  static const Key titleDragAreaKey = Key('desktopTitleDragArea');

  /// 顶栏搜索槽高度 = M3 最小触控目标（取包内搜索条自己的触控尺寸默认值
  /// `M3ESearchBarTheme.tapTargetSize`，不写死数值）。
  static double searchSlotHeight(BuildContext context) =>
      M3ETheme.of(context).searchBarTheme.tapTargetSize;

  @override
  Widget build(BuildContext context) {
    final appBar = chrome.appBar(
      context: context,
      title: _buildTitleBar(context),
    );

    return DesktopShortcuts(
      onFocusSearch: onFocusSearch,
      onSelectDestinationIndex: onSelectDestinationIndex,
      onCloseQueuePanel: onCloseQueuePanel,
      child: Scaffold(
        appBar: appBar,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            M3ENavigationRail(
              // 恒折叠：无展开按钮、也不可展开；窗口宽不影响侧栏形态。
              type: M3ENavigationRailType.alwaysCollapse,
              // 标签一律隐藏：折叠轨里图标是唯一常显信息，标签留给无障碍名
              // （项高随之走包内 shortItemHeight）。
              labelBehavior: M3ENavigationRailLabelBehavior.alwaysHide,
              selectedIndex: chrome.selectedIndex,
              onDestinationSelected: chrome.selectDestinationAt,
              sections: [
                M3ENavigationRailSection(
                  destinations: chrome.railDestinations(),
                ),
              ],
            ),
            Expanded(child: pageStack),
          ],
        ),
        // 播放页是沉浸主场：整条底栏让位（传输 / 音量 / 队列在页内都有落点），
        // 其余目的地常驻。瞬时让位（不做收起动画）：进入播放页的共享飞行以
        // 底栏封面为起点，收起动画会把起点拖走、副本与被动画的封面错位。
        bottomNavigationBar:
            chrome.selectedDestination == ShellDestination.nowPlaying
                ? null
                : DesktopNowPlayingBar(
                    key: DesktopNowPlayingBar.shellKey,
                    morph: morph,
                    onOpenPlayer: () => chrome.onDestinationSelected(
                      ShellDestination.nowPlaying,
                    ),
                    onOpenQueue: onOpenQueue,
                  ),
      ),
    );
  }

  /// 顶栏：最左搜索入口（左缘对齐内容左缘）+ 右侧空白拖动区（双击最大化）。
  ///
  /// 内容左缘 = 侧栏折叠宽 + 页面留白；AppBar 从 `titleSpacing` 处开始排
  /// title，减去同一常量才是落点。侧栏宽取自 M3E 导航轨主题（恒折叠档），
  /// 页面留白取自页面自己消费的那一档，两者都不写死数值。
  ///
  /// 窄窗（[DesktopLayout.searchCompact]）顶栏不挂 docked 面板：面板最小宽
  /// 360dp，锚点只剩一个图标时展开后是一块不成比例的浮层；改为把搜索交给
  /// 资料库搜索页（同一 provider，分段 / 分页 / 歌手链接齐全）。
  Widget _buildTitleBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final layout = DesktopLayout.of(context);
    final double inset = math.max(
      0,
      layout.railWidth +
          context.layoutType(ResponsivePageType.browse).horizontalPadding -
          ShellChrome.appBarTitleSpacing,
    );
    return Padding(
      padding: EdgeInsets.only(left: inset),
      child: Row(
        children: [
          if (layout.searchCompact)
            M3EIconButton(
              key: DesktopShell.searchEntryKey,
              variant: M3EIconButtonVariant.standard,
              semanticLabel: l10n.libraryTabSearch,
              icon: const Icon(Icons.search_rounded),
              onPressed: onOpenSearch,
            )
          else
            SizedBox(
              width: DesktopShell.searchSlotWidth,
              height: DesktopShell.searchSlotHeight(context),
              child: GlobalSearch(
                key: DesktopShell.searchEntryKey,
                controller: searchController,
                onViewAllResults: onViewAllResults,
              ),
            ),
          // 空白拖动区：窗口拖动由 AppBar 外层的 WindowDragArea 承担，这里
          // 只补「双击最大化」。高度取搜索条那一档（同一条工具行上的可点
          // 区域等高）；只包空白区 —— 双击搜索入口或按钮不该顺带改窗口状态。
          Expanded(
            child: WindowDoubleTapMaximize(
              key: DesktopShell.titleDragAreaKey,
              child: SizedBox(height: DesktopShell.searchSlotHeight(context)),
            ),
          ),
        ],
      ),
    );
  }
}
