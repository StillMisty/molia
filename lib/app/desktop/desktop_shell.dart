/// 桌面应用骨架（Linux / Windows / macOS）。
///
/// 顶栏瘦身（拖动区 + 当前页面标题 + 设置 + 窗口按钮，不再有播放控制与
/// 进度线）+ 可折叠侧栏（96 ⇄ 240）+ 常驻底部播放条（80dp）+ 可选队列
/// 右面板。手机 / 平板骨架不经过本文件（`app_shell.dart` 按平台分流）。
///
/// 页面实例与共享元素飞行仍由壳层 State 单一持有（这里只接收页面栈与
/// 回调）；本 State 只持有桌面布局状态（侧栏展开 / 队列面板开关与宽度），
/// 布局记忆见 [ShellLayoutPrefs]。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/nav_provider.dart';
import '../../services/window/window_chrome.dart';
import '../../widgets/nav_destination_icons.dart';
import '../../widgets/player_morph.dart';
import 'now_playing_bar.dart';
import 'queue_panel.dart';
import 'shell_layout_prefs.dart';
import 'window_controls.dart';

/// 桌面骨架：顶栏 + 侧栏 + 页面栈 + 队列面板 + 底部播放条。
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

  /// 窄窗口分级折叠阈值：宽 <1200 强制关队列面板、<1000 强制折叠侧栏。
  ///
  /// 只影响渲染，不改记忆值——窗口变宽后自动恢复用户设定。
  static const double queueForceCloseWidth = 1200;
  static const double railForceCollapseWidth = 1000;

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

    final appBar = AppBar(
      titleSpacing: 12,
      // 壳层是根页面，永远不需要返回键（理由同移动骨架顶栏）。
      automaticallyImplyLeading: false,
      title: WindowDoubleTapMaximize(
        // 双击顶栏标题区（拖动区的非按钮部分）= 最大化 / 还原（桌面肌肉
        // 记忆）；按钮区不参与，避免双击按钮顺带改窗口状态。
        child: Text(
          widget.labelFor(widget.selectedDestination),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
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

    return Scaffold(
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
            onDestinationSelected: (index) =>
                widget.onDestinationSelected(widget.visibleDestinations[index]),
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
        queueOpen: _queuePanelOpen,
        onOpenPlayer: () =>
            widget.onDestinationSelected(ShellDestination.nowPlaying),
        onToggleQueue: () => _setQueuePanelOpen(!_queuePanelOpen),
      ),
    );
  }
}
