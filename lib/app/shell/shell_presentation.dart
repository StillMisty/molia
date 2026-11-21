/// 壳层展示决策的唯一所有者（目的地、播放页展开、顶栏播放条、返回层级）。
///
/// **为什么单独成模块**：这些判断原先散在 `_MyAppState`（选中 / 有效 / 上一
/// 目的地、`_showPlayerBar`）、`NowPlayingController`（`expanded` /
/// `miniCapable`）和 `player_flight.dart`（`_morphGeometry` 兼作飞行守卫）里，
/// 壳层每次渲染都要在几份副本之间对齐，只有挂载整个 `MyApp` 才能验证。
/// 把决策收进这里后，widget 层只剩动画 / Overlay / 布局，测试可以在接口上
/// 直接覆盖 ADR-0039 的判定矩阵。
///
/// **边界**：本模块只依赖 foundation + [ShellDestination] 枚举与页面级
/// 返回登记；不 import widgets / pages / material，不持有 Ticker、Overlay 或
/// 页面实例。弹簧、共享封面飞行、淡入淡出仍由壳层渲染层执行。
library;

import 'package:flutter/foundation.dart';

import '../../providers/nav_provider.dart' show ShellDestination;
import '../../services/back_claims.dart';

/// 一次展开 / 收起请求此刻能否执行。
///
/// 三个拒绝原因与 ADR-0039 的「点了必须有反应」口径一一对应：不在播放页、
/// 版式没有收起态、共享封面正在飞行。调用方只在 [accepted] 时继续跑动画。
enum ShellExpansionVerdict {
  /// 可以执行：目的地是播放页、版式可收起、没有飞行在途。
  accepted,

  /// 当前不在播放页：页内手势 / 返回键不应改变播放器高度。
  notOnPlayerPage,

  /// 宽版式 / 桌面骨架没有收起态（`miniCapable == false`）。
  layoutCannotCollapse,

  /// 顶栏 ⇄ 播放页的共享封面飞行正在途中，切换会与副本抢同一份几何。
  flightInProgress,
}

/// 壳层级返回（Android back）的裁决。
enum ShellBackIntent {
  /// 不拦：非展开播放页，或页面级临时状态（[BackClaims]）正接管返回。
  exit,

  /// 壳层先收起展开的播放页；调用方随后执行收起动画，页面落定时回写
  /// [ShellPresentation.expanded]。
  collapsePlayer,
}

/// 壳层展示状态与判定：目的地解析、播放页展开、顶栏播放条、返回层级。
///
/// 状态所有权：
/// - 目的地由壳层在点击 / 可见性变化时写入（[select] / [syncVisibility]）；
/// - [expanded] / [miniCapable] 由播放页在布局或动画落定时回写（[setExpanded] /
///   [setMiniCapable]），壳层不再持有第二份；
/// - [flightInProgress] 由壳层在共享封面起飞 / 落定时写（[setFlightInProgress]）。
///
/// 通知只在 [expanded] / [miniCapable] 变化时发出：它们是页面异步回写的
/// 渲染输入，壳层要据此重算 `PopScope.canPop` 与顶栏。目的地变化不通知，
/// 由壳层自己的 `setState` 推进——切页同帧还要发起封面飞行，多一次通知会
/// 让顶栏在飞行前先闪一次。
class ShellPresentation extends ChangeNotifier {
  /// [visibleDestinations] 必须与构造时的导航偏好一致；[initialDestination]
  /// 来自 `NavProvider.effectiveHomeDestination`（不可见时已兜底到首个可见项）。
  ShellPresentation({
    required ShellDestination initialDestination,
    required List<ShellDestination> visibleDestinations,
  }) : _selected = initialDestination,
       _previous = initialDestination,
       _rendered = initialDestination,
       _visible = List<ShellDestination>.unmodifiable(visibleDestinations);

  ShellDestination _selected;
  ShellDestination _previous;
  ShellDestination _rendered;
  List<ShellDestination> _visible;

  bool _expanded = false;
  bool _miniCapable = false;
  bool _flightInProgress = false;

  /// 最近一次同步的可见目的地（导航顺序，已过滤隐藏项）。
  ///
  /// 壳层仍在构建时 `watch<NavProvider>` 取同一份列表；这里保留一份是为了
  /// [effectiveDestination] / [selectedIndex] 的计算不依赖 BuildContext。
  List<ShellDestination> get visibleDestinations => _visible;

  /// 存储的选中目的地（可能被运行时隐藏）。
  ///
  /// 只用于「隐藏后重新可见时恢复原选中项」；渲染与交互一律消费
  /// [effectiveDestination]。
  ShellDestination get selectedDestination => _selected;

  /// 上一目的地（淡出层用）。
  ///
  /// 只在 [select] 成功时改写：可见性回退不改变「上一页」，否则重新可见的
  /// 选中项会丢失自己的出场层。
  ShellDestination get previousDestination => _previous;

  /// 实际生效的选中目的地：导航 chrome、页面栈与重复点击判定共用的唯一来源。
  ///
  /// 存储的选中项被隐藏（如同步应用远端导航设置）时回退到第一个可见项；
  /// 只读计算，不回写 [selectedDestination]，隐藏项重新可见后天然恢复。
  ShellDestination get effectiveDestination {
    // NavProvider 保证至少保留 1 个可见项；空列表仅作防御。
    if (_visible.isEmpty) return _selected;
    return _visible.contains(_selected) ? _selected : _visible.first;
  }

  /// [effectiveDestination] 在 [visibleDestinations] 中的下标（不在列表时 -1）。
  int get selectedIndex => _visible.indexOf(effectiveDestination);

  /// 目的地当前是否可见（隐藏项不参与切页）。
  bool isVisible(ShellDestination destination) =>
      _visible.contains(destination);

  /// 同步可见集合；返回「有效目的地是否因此变化」。
  ///
  /// 返回值供壳层在 `didChangeDependencies` 里判断要不要把共享封面两端
  /// 对齐到新的稳态（可见性变化绕过了 [select]，没有飞行可撤销）。本方法
  /// 不发通知：调用发生在构建阶段，且该依赖本身已会触发重建。
  bool syncVisibility(List<ShellDestination> visibleDestinations) {
    _visible = List<ShellDestination>.unmodifiable(visibleDestinations);
    final ShellDestination effective = effectiveDestination;
    if (effective == _rendered) return false;
    _rendered = effective;
    return true;
  }

  /// 切到 [destination]；返回是否真的切换。
  ///
  /// 隐藏目的地与「已经在当前有效目的地」都返回 false（调用方据此跳过
  /// 触感 / 飞行）。成功时把切换前的有效目的地记为 [previousDestination]。
  bool select(ShellDestination destination) {
    if (!isVisible(destination)) return false;
    final ShellDestination current = effectiveDestination;
    if (destination == current) return false;
    _previous = current;
    _selected = destination;
    _rendered = destination;
    return true;
  }

  /// 窄版式播放页是否展开（布局 / 动画落定时由页面回写）。
  ///
  /// 表达的是播放器在页面里的高度状态，不是「当前目的地是不是播放页」；
  /// 宽版式 / 桌面两栏没有收起态，恒为 false。
  bool get expanded => _expanded;

  /// 当前布局是否有收起态（窄单栏 = true，桌面 / 移动宽版式 = false）。
  ///
  /// 由页面在布局期回写；壳层据此决定顶栏显示播放条还是品牌位，并拒绝
  /// 一个「点了也收不起来」的收起请求。
  bool get miniCapable => _miniCapable;

  /// 顶栏 ⇄ 播放页的共享封面飞行是否在途（壳层写）。
  ///
  /// 只作同步守卫，不参与渲染，因此变化时不发通知：飞行起止发生在帧回调
  /// / 动画 tick 里，额外 setState 只会和飞行副本抢节奏。
  bool get flightInProgress => _flightInProgress;

  /// 顶栏是否显示播放条（封面 + 歌名/作者 + 播放/下一首 + 进度）。
  ///
  /// 移动端顶栏是唯一的迷你播放器：不在播放页时恒显示；在播放页时只有
  /// 窄版式且已收起才显示，展开后让位给品牌位。宽版式 / 桌面没有收起态，
  /// 在播放页永远不显示。
  bool get showsPlayerBar =>
      effectiveDestination != ShellDestination.nowPlaying ||
      (_miniCapable && !_expanded);

  /// 壳层是否要拦截系统返回（展开的播放页是唯一的页内层级）。
  ///
  /// 页面级占用（[BackClaims]）不参与 `canPop`：它们由页面自己的 `PopScope`
  /// 声明 `canPop == false`，壳层在回调里让位（见 [handleBack]）。
  bool get interceptsBack =>
      effectiveDestination == ShellDestination.nowPlaying && _expanded;

  /// 展开 / 收起请求的裁决；调用方只在 [ShellExpansionVerdict.accepted] 时执行。
  ///
  /// 方向不影响守卫（展开与收起共用同一组前提），因此不接收 `expand`。
  ShellExpansionVerdict get expansionVerdict {
    if (effectiveDestination != ShellDestination.nowPlaying) {
      return ShellExpansionVerdict.notOnPlayerPage;
    }
    if (!_miniCapable) return ShellExpansionVerdict.layoutCannotCollapse;
    if (_flightInProgress) return ShellExpansionVerdict.flightInProgress;
    return ShellExpansionVerdict.accepted;
  }

  /// 壳层级返回的裁决：页面级占用优先，其次「展开的播放页先收起」。
  ///
  /// 只做判定，不改 [expanded]：页面在收起动画落定时才回写，提前清零会让
  /// 收起途中第二次返回直接退出应用。
  ShellBackIntent handleBack() {
    if (BackClaims.any) return ShellBackIntent.exit;
    if (!interceptsBack) return ShellBackIntent.exit;
    return ShellBackIntent.collapsePlayer;
  }

  /// 页面回写展开态；相同值不重复通知。
  void setExpanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    notifyListeners();
  }

  /// 页面回写布局能力；相同值不重复通知。
  void setMiniCapable(bool value) {
    if (_miniCapable == value) return;
    _miniCapable = value;
    notifyListeners();
  }

  /// 壳层回写共享封面飞行状态（只作同步守卫，不发通知）。
  void setFlightInProgress(bool value) => _flightInProgress = value;
}
