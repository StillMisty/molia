/// 桌面应用骨架（Linux / Windows / macOS）。
///
/// 顶栏（品牌区 = 搜索入口 + 空白拖动区 + 设置 + 窗口按钮）+ 恒折叠侧栏
/// （96dp）+ 页面栈 + 常驻底部播放条（播放页里整条让位）+ 搜索遮罩宿主
/// （Ctrl+F / 品牌区点击打开）。手机 / 平板骨架不经过本文件
/// （`app_shell.dart` 按平台分流）。
///
/// 骨架本身无状态：侧栏恒折叠、队列并入播放页右栏之后，与窗口相关的可变量
/// 只剩当前目的地（由 [chrome] 带入），页面实例与共享元素飞行仍由壳层 State
/// 单一持有。
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/nav_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/shortcut_settings.dart';
import '../../services/shortcuts.dart';
import '../../services/window/window_chrome.dart';
import '../../utils/responsive.dart';
import '../../widgets/desktop_layout.dart';
import '../../widgets/global_search_overlay.dart';
import '../../widgets/molia_mark.dart';
import '../../widgets/player_morph.dart';
import '../shell_chrome.dart';
import 'desktop_shortcuts.dart';
import 'now_playing_bar.dart';

/// 桌面骨架：顶栏 + 恒折叠侧栏 + 页面栈 + 底部播放条 + 搜索遮罩。
///
/// 整棵树包在 [DesktopShortcuts] 里：全局快捷键在壳层顶层监听，播放动作走
/// provider，其余（打开搜索 / 切目的地 / 收队列）走壳层回调。
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

  /// 搜索遮罩的打开入口控制器：Ctrl+F 与品牌区点击同一条路径。
  final GlobalSearchController searchController;

  /// 遮罩内「查看全部结果」（或回车）→ 切到资料库目的地
  /// （完整结果 / 分页 / 歌手链接都在那里，同一 `SearchProvider` 实例）。
  final VoidCallback onViewAllResults;

  /// 打开搜索遮罩：顶栏品牌区点击与 Ctrl+F 共用一条路径（快捷键的键位
  /// 可改绑，但落点不变）。
  final VoidCallback onOpenSearch;

  /// 全局快捷键 Ctrl+1/2/3：切到第 index 个可见目的地
  /// （顺序 = `NavProvider.visibleDestinations`；越界时壳层回调自行忽略）。
  final ValueChanged<int> onSelectDestinationIndex;

  /// 底栏队列按钮：跳播放页 + 让页内右栏切到队列 tab。
  final VoidCallback onOpenQueue;

  /// Esc 的壳层命令（可配置的「关闭队列」）：队列并入播放页右栏后，
  /// 落点 = 收起队列视图（见壳层回调）。
  final VoidCallback onCloseQueuePanel;

  /// 顶栏品牌区（= 搜索入口）的稳定 Key（测试定位用）。
  static const Key searchEntryKey = Key('desktopGlobalSearch');

  /// 搜索遮罩背景模糊层的稳定 Key（测试定位用）。
  static const Key searchBackdropBlurKey = Key('desktopSearchBackdropBlur');

  /// 搜索右侧空白拖动区的稳定 Key（双击最大化挂在它上面）。
  static const Key titleDragAreaKey = Key('desktopTitleDragArea');

  /// 顶栏工具行高度 = M3 最小触控目标（品牌区与右侧空白拖动区同高，
  /// 取包内搜索条自己的触控尺寸默认值，不写死数值）。
  static double toolRowHeight(BuildContext context) =>
      M3ETheme.of(context).searchBarTheme.tapTargetSize;

  @override
  Widget build(BuildContext context) {
    final appBar = chrome.appBar(
      context: context,
      title: _buildTitleBar(context),
    );

    return DesktopShortcuts(
      onFocusSearch: onOpenSearch,
      onSelectDestinationIndex: onSelectDestinationIndex,
      onCloseQueuePanel: onCloseQueuePanel,
      child: Stack(
        children: [
          Scaffold(
            appBar: appBar,
            body: Stack(
              children: [
                Row(
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
                // 搜索遮罩宿主：隐形锚点只提供搜索条展开的起始位置（中上、居中），
                // 覆盖层由 M3E 搜索视图在根导航器上呈现（见 GlobalSearchOverlay）。
                Positioned(
                  top: GlobalSearchOverlay.anchorTopFor(context),
                  left: 0,
                  right: 0,
                  height: GlobalSearchOverlay.anchorHeight,
                  child: Center(
                    child: GlobalSearchOverlay(
                      controller: searchController,
                      onViewAllResults: onViewAllResults,
                    ),
                  ),
                ),
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
          // 搜索遮罩的背景模糊：整窗（含顶栏 / 底栏）淡入一层模糊，搜索视图的
          // 半透明 scrim 盖在它上方（见 [_SearchBackdropBlur]）。
          Positioned.fill(
            child: _SearchBackdropBlur(
              key: searchBackdropBlurKey,
              open: searchController.open,
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：最左品牌区（图标 + 应用名，点击打开搜索遮罩）+ 右侧空白拖动区
  /// （双击最大化）。
  ///
  /// 内容左缘 = 侧栏折叠宽 + 页面留白；AppBar 从 `titleSpacing` 处开始排
  /// title，减去同一常量才是落点。侧栏宽取自 M3E 导航轨主题（恒折叠档），
  /// 页面留白取自页面自己消费的那一档，两者都不写死数值。
  Widget _buildTitleBar(BuildContext context) {
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
          _BrandSearchEntry(
            key: DesktopShell.searchEntryKey,
            onTap: onOpenSearch,
          ),
          // 空白拖动区：窗口拖动由 AppBar 外层的 WindowDragArea 承担，这里
          // 只补「双击最大化」。高度取工具行那一档（与品牌区同一条工具行上
          // 的可点区域等高）；只包空白区 —— 双击品牌区或按钮不该顺带改窗口
          // 状态。
          Expanded(
            child: WindowDoubleTapMaximize(
              key: DesktopShell.titleDragAreaKey,
              child: SizedBox(height: DesktopShell.toolRowHeight(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索遮罩的背景模糊层：跟着遮罩开合淡入淡出。
///
/// 为什么在壳层：M3E 搜索视图的 scrim 是纯色压暗（`scrimColor` 无模糊），背景
/// 模糊只能由壳层补——搜索视图路由挂在根导航器上，壳层整体在它下方，半透明
/// 的 scrim 会把这一层的模糊透出来。
///
/// 关闭时 opacity 为 0：`Opacity` 不绘制子树，`BackdropFilter` 也不参与合成，
/// 不留常驻开销（模糊只在遮罩打开的这几秒里算）。
class _SearchBackdropBlur extends StatelessWidget {
  const _SearchBackdropBlur({super.key, required this.open});

  /// 遮罩开合（语义见 [GlobalSearchController.open]）。
  final ValueListenable<bool> open;

  /// 模糊半径：糊住下层文字与封面纹理即可；过大的半径在弱 GPU 上代价高。
  static const double blurSigma = 12;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: open,
        builder: (context, open, _) => AnimatedOpacity(
          opacity: open ? 1 : 0,
          // 与 scrim 的淡入同拍（scrim 走包内 effects 弹簧，约 200ms 量级）。
          duration: const Duration(milliseconds: 200),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// 品牌区（= 搜索入口）：应用标志 + 名称，整块可点打开搜索遮罩。
///
/// 搜索入口不再占顶栏一条搜索框，落点收到这个品牌块上（Ctrl+F 同路径）；
/// tooltip 带上当前生效的键位，顶栏不挂搜索条也能发现快捷键。
class _BrandSearchEntry extends StatelessWidget {
  const _BrandSearchEntry({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ShortcutSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        // 软件内快捷键关闭时不提示键位（按不出来）；键名与设置页同一套书写。
        final combo = settings.inAppEnabled
            ? settings.inAppBindings.comboFor(ShortcutCommand.focusSearch)
            : null;
        final message = combo == null
            ? l10n.libraryTabSearch
            : '${l10n.libraryTabSearch} · ${combo.label()}';
        return Tooltip(
          message: message,
          child: Semantics(
            button: true,
            child: GestureDetector(
              // 刻意不用 M3ETappable：它点击时会请求焦点（打断页内输入），
              // GestureDetector 与顶栏其它手势宿主保持同一取舍。
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: SizedBox(
                height: DesktopShell.toolRowHeight(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MoliaMark(size: 24),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<String>(
                      valueListenable: AppBrandingService.titleNotifier,
                      builder: (context, title, _) => Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
