/// 桌面应用骨架（Linux / Windows / macOS）。
///
/// 顶栏（品牌区 = 搜索入口 + 空白拖动区 + 设置 + 窗口按钮）+ 恒折叠、
/// 标签常显侧栏（96dp）+ 页面栈 + 常驻底部播放条（播放页里整条让位）+
/// 搜索遮罩宿主（Ctrl+F / 品牌区点击打开）。手机 / 平板骨架不经过本文件
/// （`app_shell.dart` 按平台分流）。
///
/// 骨架本身无状态：侧栏恒折叠、队列并入播放页右栏之后，与窗口相关的可变量
/// 只剩当前目的地（由 [chrome] 带入），页面实例与共享元素飞行仍由壳层 State
/// 单一持有。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/nav_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/window/window_chrome.dart';
import '../../theme/m3e_context.dart';
import '../../theme/motion_policy.dart';
import '../../widgets/app_search_bar.dart';
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

  /// 品牌胶囊本体的稳定 Key（测几何：40dp 高、内容内边距、hover 底色）。
  static const Key brandCapsuleKey = Key('desktopBrandCapsule');

  /// 搜索遮罩背景模糊层的稳定 Key（测试定位用）。
  static const Key searchBackdropBlurKey = Key('desktopSearchBackdropBlur');

  /// 搜索右侧空白拖动区的稳定 Key（双击最大化挂在它上面）。
  static const Key titleDragAreaKey = Key('desktopTitleDragArea');

  /// 品牌胶囊高度：工具行里居中的可点胶囊，不占满整条工具行（56dp）。
  static const double brandCapsuleHeight = 40;

  /// 品牌区最大宽度：长名称在这里截断，不把右侧拖动区挤没。
  static const double brandMaxWidth = 280;

  /// 品牌区最小宽度 = 胶囊左右内边距 + 标志（12 + 24 + 12）。
  static const double _brandMinWidth = 48;

  /// 名称至少要有的品牌区宽度：再窄就只剩 LOGO 胶囊。
  static const double _brandNameMinWidth = 220;

  /// 品牌胶囊与右侧动作之间的最小拖动区：窗口拖动不能只剩一条缝。
  static const double _titleDragMinWidth = 96;

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
                      // 标签常显：包内有标签时选中指示器是 56×32 胶囊（与移动端
                      // 底栏 / 平板侧栏同几何），无标签会退化成 56×56 圆——选中时
                      // 从 0.4 倍横向拉开，在桌面大图标下很违和。不要改 onlySelected：
                      // 未选中项回到圆、选中项变胶囊，切换会有一档高度跳变。
                      labelBehavior: M3ENavigationRailLabelBehavior.alwaysShow,
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
                // 搜索遮罩宿主：不可见占位盒只提供搜索条的静止位置（中上、居中），
                // 内容由 GlobalSearchOverlay 挂到根导航器上呈现。
                Positioned(
                  top: GlobalSearchOverlay.barTopFor(context),
                  left: 0,
                  right: 0,
                  height: appSearchBarMinHeightOf(context),
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
  /// 品牌块贴窗口左缘（顶栏标题槽的 titleInset 处），不再与内容左缘对齐：
  /// 应用左上角就是标志本身，与侧栏折叠宽 / 页面留白解耦。
  ///
  /// 品牌区有宽度上限：长名称在胶囊内省略，右侧始终给窗口拖动留一段空白。
  /// 标题槽被窗口按钮 / 设置挤窄时退化为「仅 LOGO 胶囊」，不拿右侧动作换
  /// 应用名。
  Widget _buildTitleBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBrand = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - _titleDragMinWidth)
                  .clamp(_brandMinWidth, DesktopShell.brandMaxWidth)
                  .toDouble()
            : DesktopShell.brandMaxWidth;
        final showName = maxBrand >= _brandNameMinWidth;
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxBrand),
              child: _BrandSearchEntry(
                key: DesktopShell.searchEntryKey,
                onTap: onOpenSearch,
                showName: showName,
              ),
            ),
            // 空白拖动区：窗口拖动由顶栏外层的 WindowDragArea 承担，这里
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
        );
      },
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
          // 与 scrim 的淡入同拍（搜索遮罩 `short4` effects），减弱动效时硬切。
          duration: effectDurationOf(context, M3EMotion.short4),
          curve: M3EMotion.emphasizedDecelerate,
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
/// 搜索入口不占顶栏一条搜索框，落点收到这个品牌块上（Ctrl+F 同路径）。
/// 不做悬浮提示：整块贴着窗口左上角、文案（应用名）自解释，键位提示只留在
/// 设置 › 快捷键。桌面鼠标用户需要可点线索：hover / press 时给胶囊底色 +
/// 手型光标，标志与文字都不位移。
///
/// 胶囊本体 40dp 高、左右各 12dp 内边距，垂直居中在工具行里；外层仍保持
/// 工具行高度，命中区域不因视觉胶囊变矮。名称只在标题槽够宽时显示，长名称
/// 由 `ConstrainedBox` + 单行省略收住，不把右侧拖动区挤没。
class _BrandSearchEntry extends StatefulWidget {
  const _BrandSearchEntry({
    super.key,
    required this.onTap,
    required this.showName,
  });

  final VoidCallback onTap;

  /// 标题槽够宽时显示应用名；窄窗只留 LOGO 胶囊。
  final bool showName;

  @override
  State<_BrandSearchEntry> createState() => _BrandSearchEntryState();
}

class _BrandSearchEntryState extends State<_BrandSearchEntry> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = effectDurationOf(context, M3EMotion.short2);
    return ValueListenableBuilder<String>(
      valueListenable: AppBrandingService.titleNotifier,
      builder: (context, title, _) {
        final Color capsuleColor;
        if (_pressed) {
          capsuleColor = scheme.surfaceContainerHighest;
        } else if (_hovered) {
          capsuleColor = scheme.surfaceContainerHigh;
        } else {
          // 静止态用同色零 alpha 而不是 Colors.transparent：隐式动画在
          // 同色系里插值，不会先闪一层灰再回到 surfaceContainerHigh。
          capsuleColor = scheme.surfaceContainerHigh.withValues(alpha: 0);
        }
        return Semantics(
          button: true,
          // 只显示 LOGO 时文字不存在，用应用名补读屏；显示文字时不重复朗读。
          label: widget.showName ? null : title,
          excludeSemantics: !widget.showName,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              // 刻意不用 M3ETappable：它点击时会请求焦点（打断页内输入），
              // GestureDetector 与顶栏其它手势宿主保持同一取舍。
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: SizedBox(
                height: DesktopShell.toolRowHeight(context),
                child: Center(
                  // widthFactor = 1：胶囊按内容取宽，不把品牌区撑满标题槽。
                  widthFactor: 1,
                  child: AnimatedContainer(
                    key: DesktopShell.brandCapsuleKey,
                    duration: duration,
                    curve: M3EMotion.emphasizedDecelerate,
                    height: DesktopShell.brandCapsuleHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: capsuleColor,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(M3EShapes.full),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const MoliaMark(size: 24),
                        if (widget.showName) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // 品牌位与顶栏应用名同一口径：强调字阶，
                              // 不手写字重。
                              style: context.emphasizedTypeScale.titleMedium,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
