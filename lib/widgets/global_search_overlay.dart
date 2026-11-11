/// 桌面壳层全局搜索遮罩：全屏 scrim + 中上居中搜索条 + 就地结果面板。
///
/// 与资料库页共用同一个 [SearchProvider]（不新建 provider）：关键词、渠道、
/// 分段、结果与「查看全部结果」后的完整结果链天然同源。结果行点击复用
/// [SearchProvider.playItem]（与资料库搜索结果同一条播放路径：只取当前渠道的
/// 已加载结果、从该行开始、上下文名 = 渠道显示名），不复制第二套播放语义。
///
/// 形态：壳层没有常驻搜索条（顶栏最左让位给品牌区），Ctrl+F / 品牌区点击经
/// [GlobalSearchController] 打开本遮罩。宿主是一个不可见、不可点的占位盒：
/// 只有位置与尺寸有意义——遮罩打开时实测它的矩形，把搜索条与结果面板摆在
/// 同一位置（route 挂在根导航器上、坐标是整窗口径，所以顶栏高度不用写死在这里）。
///
/// 搜索条是 [ChannelSearchBar]：左侧渠道下拉（与发现页同一个当前渠道）、
/// 中间细分割线、右侧输入 + 清除键；选择渠道会同时切发现内容与搜索，并把
/// 焦点还给输入框。当前渠道不支持搜索时，面板显示专用空态，下拉仍可切换。
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
/// 结果列表面板内限高滚动：当前渠道最多就地预览
/// [SearchResultsView.maxDockedPreviewRows] 行，更长的列表交给资料库目的地
/// （「查看全部结果」回调由壳层给）；行映射 / 失败 / 空态统一在
/// [SearchResultsView]（与资料库搜索结果页同一份实现）。
///
/// 键盘：输入框保持焦点时 ↑↓ 移动高亮、Enter 播放 / 打开高亮项、Ctrl+Enter
/// 始终看全部结果；Tab 由 `FocusScope` 锁在遮罩内；遮罩打开期间经 [KeyClaims]
/// 让桌面壳层把方向键 / Space / Enter 交给焦点控件。
///
/// 与 M3E 搜索视图的取舍细节见 `docs/pitfalls.md` 已知坑 57。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/channel_selection.dart';
import '../providers/search_provider.dart';
import '../providers/sources_provider.dart';
import '../services/escape_claims.dart';
import '../services/key_claims.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import 'app_search_bar.dart';
import 'channel_search_bar.dart';
import 'search_results_view.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文，与中文正式环境文案一致（口径同 `search_section.dart`）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 搜索条与结果面板之间的间隙（M3E docked 口径：2dp）。
const double _barPanelGap = 2;

/// 面板与窗口底缘的最小留白：结果再多也不贴底。
const double _panelBottomMargin = 24;

/// 开合时长：scrim（路由 barrier）与内容同一拍，取 M3E effects `short4`。
///
/// 减弱动效时调用处会把它收成 [Duration.zero]，开合直接跳变。
const Duration _openDuration = M3EMotion.short4;

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

  /// 1.0× 静止条高（M3E docked 头部同档）；实际占位高度用
  /// `appSearchBarMinHeightOf(context)`，会随系统文字缩放增长。
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
/// 已打开时把焦点拉回输入框并全选已有文本（焦点可能停在结果行 / chips）。
class GlobalSearchController {
  _GlobalSearchOverlayState? _overlay;

  /// 遮罩开合（打开 = 搜索视图路由在场）。
  ///
  /// 壳层用它驱动「跟着遮罩一起出现」的装饰面（背景模糊层）；开合即时翻转，
  /// 淡入淡出由消费面自己补。
  final ValueNotifier<bool> open = ValueNotifier<bool>(false);

  /// 打开搜索遮罩并聚焦输入框；已打开时重新聚焦并全选。
  void focus() => _overlay?._open();

  void _attach(_GlobalSearchOverlayState overlay) => _overlay = overlay;

  void _detach(_GlobalSearchOverlayState overlay) {
    if (_overlay == overlay) _overlay = null;
  }

  void dispose() => open.dispose();
}

class _GlobalSearchOverlayState extends State<GlobalSearchOverlay> {
  /// 遮罩打开：Esc / 导航键占用登记的判据。
  bool _isOpen = false;

  /// 当前打开的视图 State：已打开时 Ctrl+F 用它重新聚焦并全选。
  final GlobalKey<_GlobalSearchViewState> _viewKey = GlobalKey();

  /// 遮罩打开期间接管方向键 / Space / Enter：壳层全局快捷键让位给焦点分发
  /// （行激活 / 高亮移动 / chips 左右切换）。
  late final KeyClaim _keyClaim;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    // Esc：自建视图自带关闭绑定；登记占用让壳层可配置命令（默认「关闭队列」）
    // 让位——焦点不在输入框（Tab 到结果区）时同一次 Esc 不会被两处消费
    // （协议见 escape_claims.dart）。
    EscapeClaims.add(_claimEscape);
    _keyClaim = KeyClaims.add(keys: searchClaimedKeys, active: () => _isOpen);
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
    KeyClaims.remove(_keyClaim);
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

  /// 打开搜索遮罩（Ctrl+F / 品牌区点击）。
  ///
  /// 已打开时把焦点从结果行 / chips 拉回输入框并全选已有文本，符合命令面板
  /// 「再按一次搜索键继续输入」的肌肉记忆。
  ///
  /// 路由由根导航器承载（`showGeneralDialog` 默认 `useRootNavigator`）：
  /// 遮罩盖在壳层之上，顶栏 / 底栏一起压暗。
  Future<void> _open() async {
    if (_isOpen) {
      _viewKey.currentState?.focusField();
      return;
    }
    _setOpen(true);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: _l10n(context).searchClose,
      barrierColor: _scrimColor(context),
      transitionDuration: effectDurationOf(context, _openDuration),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _GlobalSearchView(
            key: _viewKey,
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
      curve: M3EMotion.emphasizedDecelerate,
      reverseCurve: M3EMotion.emphasizedAccelerate,
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
      appSearchBarMinHeightOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 占位盒：只提供搜索条静止位置与宽度，自己不画任何东西。
    // 高度与真实 AppSearchBar 同源；否则大字体会让结果面板按旧锚点错位。
    return SizedBox(
      width: GlobalSearchOverlay.barWidth,
      height: appSearchBarMinHeightOf(context),
    );
  }
}

/// 搜索视图（route 内容）：搜索条 + 结果面板，落在宿主的静止矩形上。
///
/// 直接订阅 [SearchProvider]：关键词、类型分段、结果与失败态都在 provider 里，
/// 面板只做展示；输入框在首帧 autofocus（打开即能打字，不丢按键）。
class _GlobalSearchView extends StatefulWidget {
  const _GlobalSearchView({
    super.key,
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
  /// 遮罩与结果行共用的控制器（本视图独占；绑定器负责与会话双向同步）。
  final TextEditingController _field = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'globalSearchField');
  final FocusNode _channelFocusNode = FocusNode(
    debugLabel: 'globalSearchChannelDropdown',
  );

  late final SearchProvider _search;
  late final SearchSession _session;
  late final SearchInputBinding _input;

  /// 上一次已播报的内容（关键词 + 文案）：同一条消息不重复播报。
  String? _lastAnnouncement;

  /// 关闭动作只执行一次：平台回车与祖先 Focus 可能同时到达。
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _search = context.read<SearchProvider>();
    _session = _search.session;
    // 会话是搜索状态的唯一源：遮罩打开时用绑定器种上当前关键词，
    // 之后资料库改词 / 清空也会立即反映到输入框（不再逐帧补同步）。
    _input = SearchInputBinding(session: _session, controller: _field);
    _search.addListener(_onSearchChanged);
    _session.preview.addListener(_onPreviewChanged);
    // 打开 / 重新聚焦都全选已有文本：Ctrl+F 后直接输入即替换上次关键词。
    WidgetsBinding.instance.addPostFrameCallback((_) => focusField());
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _session.preview.removeListener(_onPreviewChanged);
    _input.dispose();
    _field.dispose();
    _focusNode.dispose();
    _channelFocusNode.dispose();
    super.dispose();
  }

  /// 把焦点拉回搜索框并全选已有文本（Ctrl+F 已打开时的重新聚焦入口）。
  ///
  /// 切渠道时传 `selectAll: false`：只还焦点，不打断用户继续编辑的光标。
  void focusField({bool selectAll = true}) {
    if (!mounted) return;
    _focusNode.requestFocus();
    if (!selectAll || _field.text.isEmpty) return;
    _field.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _field.text.length,
    );
  }

  /// 渠道下拉选择：发现内容与搜索一起切，然后把焦点还给输入框。
  void _selectChannel(String key) {
    context.read<ChannelSelection>().select(key);
    final textLength = _field.text.length;
    final selection = _field.selection;
    final wasSelectAll =
        textLength > 0 && selection.start == 0 && selection.end == textLength;
    // 下拉关闭动画期间包内 focus trap 仍在，立即 requestFocus 会被拒绝。
    // 逐帧重试：关闭动画结束时 focus trap 释放，这一帧就能把焦点交给输入框。
    var attempts = 0;
    void restoreFocus() {
      if (!mounted) return;
      _channelFocusNode.unfocus();
      focusField(selectAll: false);
      // 打开遮罩时的「全选」不应在切渠道后保留：把光标放到末尾，下一次
      // 输入是追加而不是整词替换；用户原有的局部选区保持不变。
      if (wasSelectAll) {
        _field.selection = TextSelection.collapsed(offset: textLength);
      }
      if (_focusNode.hasFocus || ++attempts >= 30) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        restoreFocus();
        WidgetsBinding.instance.scheduleFrame();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      restoreFocus();
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  /// 会话通知：输入激活态 / 结果 / 播报都跟同一份投影走。
  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {});
    _announceResults();
  }

  /// 预览通知：↑↓ 只改高亮，不触发搜索状态（也不重算结果）。
  void _onPreviewChanged() {
    if (mounted) setState(() {});
  }

  SearchPreviewItem? get _highlightedItem => _session.preview.highlightedItem;

  /// 结果数变化时给读屏播报（空词 / 加载中不播报；文案走 l10n）。
  ///
  /// 防抖 / 首屏在途时 [SearchProvider.isSearchBusy] 为真；单渠道首屏返回后
  /// 才转 false，因此总条数只播报一次。
  void _announceResults() {
    if (!mounted || !_session.isActive || _session.isBusy) return;
    final message = _l10n(context)
        .searchResultsAnnouncement(_session.resultCount);
    final key = '${_session.query}\u0000$message';
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
    if (_closing) return;
    _closing = true;
    _close();
    widget.onViewAllResults();
  }

  /// 提交当前输入并打开完整结果页（Enter 无高亮 / Ctrl+Enter）。
  void _submitAndOpenAll() {
    if (_closing) return;
    _closing = true;
    _session.submit(_field.text);
    _close();
    widget.onViewAllResults();
  }

  /// 回车：有高亮单曲 → 播放并关闭；歌手 / 无高亮 → 提交并看全部结果。
  void _handleEnter() {
    if (_closing || _field.value.composing.isValid) return;
    final item = _highlightedItem;
    if (item is SearchPreviewTrack) {
      _playItem(item.row);
      return;
    }
    _submitAndOpenAll();
  }

  /// 单曲 / 歌词行点击：与资料库搜索结果同一条播放路径。
  void _playItem(SearchRow row) {
    if (_closing) return;
    _closing = true;
    _search.playItem(row);
    _close();
  }

  /// 遮罩内按键：只有输入框聚焦时拦截 ↑↓；Ctrl+Enter 始终打开完整结果。
  ///
  /// 输入法组合中全部放行，不抢候选词选择 / 上屏。
  KeyEventResult _handleOverlayKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_field.value.composing.isValid) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (ctrl) {
        _submitAndOpenAll();
        return KeyEventResult.handled;
      }
      if (_focusNode.hasFocus) {
        _handleEnter();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!_focusNode.hasFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      _session.preview.moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _session.preview.moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _session.preview.moveHighlight(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _session.preview.moveHighlight(-5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final sources = context.watch<SourcesProvider>();
    final selection = context.watch<ChannelSelection>();
    final enabledChannels = [
      for (final channel in sources.channels)
        if (channel.enabled) channel,
    ];
    final rect = widget.restingRect;
    final showHint = _session.isActive;
    // 面板限高：条下沿到窗口底部留出边距与底部键位提示，更长的列表交给资料库。
    final maxPanelHeight = math.max(
      0.0,
      MediaQuery.sizeOf(context).height -
          rect.bottom -
          _barPanelGap -
          _panelBottomMargin -
          (showHint ? 30 : 0),
    );

    // 模态内循环：FocusScope 默认 traversalEdgeBehavior = closedLoop，
    // Tab / Shift+Tab 到边界时回到另一端，不逃到背后页面。
    return FocusScope(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleOverlayKey,
        child: CallbackShortcuts(
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
                      ChannelSearchBar(
                        controller: _field,
                        focusNode: _focusNode,
                        channelFocusNode: _channelFocusNode,
                        hintText: l10n.searchHint,
                        // 打开即聚焦：开合动画期间按键也直达输入框。
                        autofocus: true,
                        channels: enabledChannels,
                        selectedKey: selection.key,
                        onChannelSelected: _selectChannel,
                        onSubmitted: (_) => _handleEnter(),
                        // Esc：焦点在输入框时由搜索栏自身就近分发（外层
                        // CallbackShortcuts 接不到——包内输入框会先消费 Esc 并
                        // 退化成「失焦」）；焦点在结果区时由外层绑定兜底。
                        onEscape: _close,
                      ),
                      const SizedBox(height: _barPanelGap),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxPanelHeight),
                        child: _GlobalSearchResults(
                          session: _session,
                          onOpenAllResults: _openAllResults,
                          onPlayItem: _playItem,
                        ),
                      ),
                      if (showHint)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Text(
                            l10n.searchKeyboardHint,
                            textAlign: TextAlign.center,
                            style: context.typeScale.bodySmall.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内容（宿主）：结果面统一交给 [SearchResultsView] 的 docked 版式。
///
/// 本宿主只保留导航编排：行点击 = 播放并收起遮罩；「查看全部结果」= 先关
/// 遮罩再切目的地（遮罩是根导航器上的自建 route，顺序反了会在遮罩上叠页）。
/// 行映射 / 分段 / 失败 / 空态 / 8 行预览上限都在统一搜索结果面里，与资料库
/// 搜索结果页同一份实现。
class _GlobalSearchResults extends StatelessWidget {
  const _GlobalSearchResults({
    required this.session,
    required this.onOpenAllResults,
    required this.onPlayItem,
  });

  final SearchSession session;
  final VoidCallback onOpenAllResults;
  final void Function(SearchRow row) onPlayItem;

  @override
  Widget build(BuildContext context) => SearchResultsView(
    variant: SearchResultsVariant.docked,
    session: session,
    onPlay: onPlayItem,
    onOpenAllResults: onOpenAllResults,
  );
}
