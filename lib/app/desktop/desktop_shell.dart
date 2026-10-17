/// 桌面应用骨架（Linux / Windows / macOS）。
///
/// 顶栏瘦身（拖动区 + 当前页面标题 + 全局搜索 + 设置 + 窗口按钮，不再有
/// 播放控制与进度线）+ 可折叠侧栏（96 ⇄ 240）+ 常驻底部播放条（80dp）+
/// 可选队列右面板。手机 / 平板骨架不经过本文件（`app_shell.dart` 按平台
/// 分流）。
///
/// 页面实例与共享元素飞行仍由壳层 State 单一持有（这里只接收页面栈与
/// 回调）；本 State 只持有桌面布局状态（侧栏展开 / 队列面板开关与宽度），
/// 布局记忆见 [ShellLayoutPrefs]。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/nav_provider.dart';
import '../../services/window/window_chrome.dart';
import '../../widgets/global_search.dart';
import '../../widgets/nav_destination_style.dart';
import '../../widgets/player_morph.dart';
import 'desktop_shortcuts.dart';
import 'now_playing_bar.dart';
import 'queue_panel.dart';
import 'shell_layout_prefs.dart';
import 'window_controls.dart';

/// 桌面骨架：顶栏 + 侧栏 + 页面栈 + 队列面板 + 底部播放条。
///
/// 整棵树包在 [DesktopShortcuts] 里：全局快捷键在壳层顶层监听，播放动作走
/// provider，其余（聚焦搜索 / 切目的地 / 关队列面板）走壳层回调。
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.selectedDestination,
    required this.visibleDestinations,
    required this.selectedIndex,
    required this.labelFor,
    required this.pageStack,
    required this.morph,
    required this.onDestinationSelected,
    required this.onOpenSettings,
    required this.onViewAllResults,
    required this.onOpenSearch,
    required this.searchController,
    required this.onFocusSearch,
    required this.onSelectDestinationIndex,
  });

  /// 当前选中的目的地（顶栏标题）。
  final ShellDestination selectedDestination;

  /// 侧栏实际渲染的目的地（NavProvider 过滤隐藏项后的顺序）。
  final List<ShellDestination> visibleDestinations;

  /// [selectedDestination] 在 [visibleDestinations] 中的下标。
  final int selectedIndex;

  /// 目的地 → 本地化标签（与移动骨架共用壳层的唯一映射）。
  final String Function(ShellDestination destination) labelFor;

  /// 分层页面栈（页面实例与过渡动画由壳层持有）。
  final Widget pageStack;

  /// 顶栏 ↔ 播放页共享元素控制器（底部播放条封面锚点与隐藏状态）。
  final PlayerMorphController morph;

  /// 目的地被点击 / 重复点击（与移动骨架同一条壳层回调）。
  final ValueChanged<ShellDestination> onDestinationSelected;

  /// 打开设置弹层。
  final VoidCallback onOpenSettings;

  /// 顶栏搜索「查看全部结果」（或面板内回车）→ 切到资料库目的地
  /// （完整结果 / 分页 / 歌手链接都在那里，同一 `SearchProvider` 实例）。
  final VoidCallback onViewAllResults;

  /// 窄窗口搜索入口（图标态）→ 打开搜索：由壳层决定落点
  /// （当前 = 资料库目的地的搜索页，见 [_buildCompactTitleBar]）。
  final VoidCallback onOpenSearch;

  /// 顶栏搜索的聚焦入口（壳层持有）：快捷键 Ctrl+F 的宽窗路径经它
  /// 打开搜索面板（窄窗没有搜索 pill，见 [onFocusSearch]）。
  final GlobalSearchController searchController;

  /// 全局快捷键 Ctrl+F：聚焦 / 打开全局搜索。宽窗聚焦顶栏搜索 pill；
  /// 窄窗顶栏搜索已退化为图标，落到与图标同一条路径（壳层按同一个
  /// 宽度阈值分流，回调只负责各自落点）。
  final VoidCallback onFocusSearch;

  /// 全局快捷键 Ctrl+1/2/3：切到第 index 个可见目的地
  /// （顺序 = `NavProvider.visibleDestinations`；越界时壳层回调自行忽略）。
  final ValueChanged<int> onSelectDestinationIndex;

  /// 窄窗口分级折叠阈值：宽 <1200 强制关队列面板、<1000 强制折叠侧栏。
  ///
  /// 只影响渲染，不改记忆值——窗口变宽后自动恢复用户设定。
  static const double queueForceCloseWidth = 1200;
  static const double railForceCollapseWidth = 1000;

  /// 顶栏搜索退化为图标按钮的窗口宽阈值（= browse 桌面断点 900，
  /// `Breakpoints.desktop`）：再窄中部放不下可用的搜索框，硬塞会把页面
  /// 标题挤没。
  static const double searchCompactWidth = 900;

  /// 顶栏搜索槽最大宽（含包内默认静止 margin 2×24 → 可见 pill ≈ 460dp）。
  static const double searchSlotMaxWidth = 508;

  /// 搜索槽之外至少留给页面标题的宽度（约 4 个中文字，超出走省略号）。
  static const double searchMinTitleWidth = 120;

  /// 顶栏搜索入口的稳定 Key（宽窗 pill / 窄窗图标同一逻辑槽位，测试定位用）。
  static const Key searchEntryKey = Key('desktopGlobalSearch');

  /// 侧栏展开宽度（M3E rail 的 `expandedWidth`；折叠档由包内定为 96）。
  static const double railExpandedWidth = 240;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final ShellLayoutPrefs _prefs = ShellLayoutPrefs();

  bool _railExpanded = ShellLayoutPrefs.defaultRailExpanded;
  bool _queuePanelOpen = ShellLayoutPrefs.defaultQueuePanelOpen;
  double _queuePanelWidth = ShellLayoutPrefs.defaultQueuePanelWidth;

  @override
  void initState() {
    super.initState();
    _restoreLayoutPrefs();
  }

  /// 恢复设备本地布局：先按默认值渲染首帧，记录就绪后一次 setState
  /// （布局记忆不值得阻塞启动；无记录时默认值即最终值）。
  Future<void> _restoreLayoutPrefs() async {
    final saved = await _prefs.load();
    if (!mounted) return;
    setState(() {
      _railExpanded = saved.railExpanded;
      _queuePanelOpen = saved.queuePanelOpen;
      _queuePanelWidth = saved.queuePanelWidth;
    });
  }

  void _setRailExpanded(bool value) {
    if (_railExpanded == value) return;
    setState(() => _railExpanded = value);
    unawaited(_prefs.saveRailExpanded(value));
  }

  void _setQueuePanelOpen(bool value) {
    if (_queuePanelOpen == value) return;
    setState(() => _queuePanelOpen = value);
    unawaited(_prefs.saveQueuePanelOpen(value));
  }

  void _handleQueueWidthChanged(double width) {
    final clamped = width.clamp(
      ShellLayoutPrefs.minQueuePanelWidth,
      ShellLayoutPrefs.maxQueuePanelWidth,
    );
    if (clamped == _queuePanelWidth) return;
    setState(() => _queuePanelWidth = clamped);
  }

  void _persistQueuePanelWidth(double width) =>
      unawaited(_prefs.saveQueuePanelWidth(width));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final double windowWidth = MediaQuery.sizeOf(context).width;
    final bool railForcedCollapsed =
        windowWidth < DesktopShell.railForceCollapseWidth;
    // 窄窗口下强制折叠且不提供展开入口（alwaysCollapse）：否则点了展开键
    // 也只能维持折叠，控件看起来是坏的；记忆值不动，变宽后按设定恢复。
    final M3ENavigationRailType railType = railForcedCollapsed
        ? M3ENavigationRailType.alwaysCollapse
        : (_railExpanded
            ? M3ENavigationRailType.expanded
            : M3ENavigationRailType.collapsed);
    final bool queuePanelVisible =
        _queuePanelOpen && windowWidth >= DesktopShell.queueForceCloseWidth;
    final bool searchCompact = windowWidth < DesktopShell.searchCompactWidth;

    final appBar = AppBar(
      titleSpacing: 12,
      // 壳层是根页面，永远不需要返回键（理由同移动骨架顶栏）。
      automaticallyImplyLeading: false,
      title: searchCompact
          ? _buildCompactTitleBar(l10n)
          : _buildWideTitleBar(l10n),
      actions: [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          onPressed: widget.onOpenSettings,
          // 顶栏不做悬浮提示（窗口控件区一排按钮，tooltip 反而吵）；
          // 无障碍语义仍保留（icon-only 按钮的可访问名）。
          semanticLabel: l10n.settingsTitle,
          icon: const Icon(Icons.settings_rounded),
        ),
        if (WindowChrome.isSupported) const WindowControls(),
        const SizedBox(width: 8),
      ],
    );

    return DesktopShortcuts(
      onFocusSearch: widget.onFocusSearch,
      onSelectDestinationIndex: widget.onSelectDestinationIndex,
      // 面板没开时 _setQueuePanelOpen(false) 自行 no-op。
      onCloseQueuePanel: () => _setQueuePanelOpen(false),
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(
            AppBar.preferredHeightFor(context, appBar.preferredSize),
          ),
          child: WindowDragArea(child: appBar),
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            M3ENavigationRail(
              type: railType,
              expandedWidth: DesktopShell.railExpandedWidth,
              onTypeChanged: (type) => _setRailExpanded(
                type == M3ENavigationRailType.expanded,
              ),
              expandTooltip: l10n.expandTooltip,
              collapseTooltip: l10n.collapseTooltip,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: (index) => widget.onDestinationSelected(
                widget.visibleDestinations[index],
              ),
              sections: [
                M3ENavigationRailSection(
                  destinations: [
                    for (final destination in widget.visibleDestinations)
                      M3ENavigationRailDestination(
                        icon: destination.outlinedIcon,
                        selectedIcon: destination.filledIcon,
                        label: widget.labelFor(destination),
                      ),
                  ],
                ),
              ],
            ),
            Expanded(child: widget.pageStack),
            if (queuePanelVisible)
              DesktopQueuePanel(
                width: _queuePanelWidth,
                onWidthChanged: _handleQueueWidthChanged,
                onWidthChangeEnd: _persistQueuePanelWidth,
                onClose: () => _setQueuePanelOpen(false),
              ),
          ],
        ),
        bottomNavigationBar: DesktopNowPlayingBar(
          key: DesktopNowPlayingBar.shellKey,
          morph: widget.morph,
          // 按钮态跟实际渲染走（窄窗口被强制关闭时不高亮、且置灰）。
          queueOpen: queuePanelVisible,
          queueAvailable: windowWidth >= DesktopShell.queueForceCloseWidth,
          onOpenPlayer: () =>
              widget.onDestinationSelected(ShellDestination.nowPlaying),
          onToggleQueue: () => _setQueuePanelOpen(!_queuePanelOpen),
        ),
      ),
    );
  }

  /// 宽窗顶栏：页面标题（左）+ 搜索（中部，最多 [DesktopShell.searchSlotMaxWidth]）
  /// + 等宽空位（右）。
  ///
  /// 左右两列等宽，把搜索槽钉在标题区正中；槽宽受
  /// [DesktopShell.searchMinTitleWidth] 保护，标题过长先省略，不会把搜索框
  /// 挤没或挤溢出。
  Widget _buildWideTitleBar(AppLocalizations l10n) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final slotWidth = math.min(
          DesktopShell.searchSlotMaxWidth,
          math.max(
            0.0,
            constraints.maxWidth - DesktopShell.searchMinTitleWidth,
          ),
        );
        return Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildPageTitle(l10n),
              ),
            ),
            SizedBox(
              width: slotWidth,
              child: GlobalSearch(
                key: DesktopShell.searchEntryKey,
                controller: widget.searchController,
                onViewAllResults: widget.onViewAllResults,
              ),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        );
      },
    );
  }

  /// 窄窗顶栏：页面标题 + 图标搜索入口。
  ///
  /// 窄窗不挂 docked 面板：面板最小宽 360dp，而锚点在窄窗只剩一个小圆，
  /// 展开后是一块与锚点不成比例的浮层；改为把搜索交给资料库搜索页
  /// （同一 provider，分段 / 分页 / 歌手链接齐全），窄窗下更顺。
  Widget _buildCompactTitleBar(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildPageTitle(l10n),
          ),
        ),
        M3EIconButton(
          key: DesktopShell.searchEntryKey,
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.libraryTabSearch,
          icon: const Icon(Icons.search_rounded),
          onPressed: widget.onOpenSearch,
        ),
      ],
    );
  }

  /// 页面标题：双击 = 最大化 / 还原（桌面肌肉记忆）。
  ///
  /// 双击区只包标题文本本身：搜索框是交互控件，双击它不该顺带改窗口状态。
  Widget _buildPageTitle(AppLocalizations l10n) {
    return WindowDoubleTapMaximize(
      child: Text(
        widget.labelFor(widget.selectedDestination),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
