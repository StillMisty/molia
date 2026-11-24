/// 壳层展示决策的唯一所有者（目的地、播放页展开、顶栏播放条、返回层级）。
///
/// 目的地解析、展开守卫、顶栏播放条可见性与返回裁决在这里集中计算，壳层
/// State 只消费结果并执行弹簧 / Overlay 飞行 / 布局。判定都是纯函数式状态
/// 读取，接口测试可以直接覆盖 ADR-0039 的矩阵，不需要挂载 `MyApp`。
///
/// **边界**：只依赖 foundation / `snapshot_source` + [ShellDestination]；
/// 不 import widgets / pages / material，不持有 Ticker、Overlay 或页面实例，
/// 也不读进程级登记表（页面级返回占用由调用方以参数传入）。弹簧、共享封面
/// 飞行、淡入淡出由壳层渲染层执行。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/shell_destination.dart';
import '../../utils/snapshot_source.dart';

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
  /// 不拦：播放页已是正常布局（或不在播放页），交给系统退出应用。
  exit,

  /// 播放页的歌词整页（播放器高度 0）先恢复成正常播放页；调用方随后执行
  /// 展开动画，页面落定时回写 [ShellPresentation.expanded]。
  restorePlayer,
}

/// 壳层展示状态的不可变快照。
///
/// 字段沿用旧 [ShellPresentation] 的公开 getter；派生的可见性 / 返回裁决
/// 只读本快照，因此接口测试可以直接覆盖 ADR-0039 的矩阵。
@immutable
class ShellPresentationState {
  const ShellPresentationState({
    required this.visibleDestinations,
    required this.selectedDestination,
    required this.previousDestination,
    required this.effectiveDestination,
    required this.expanded,
    required this.miniCapable,
    required this.flightInProgress,
  });

  /// 最近一次同步的可见目的地（导航顺序，已过滤隐藏项）。
  final List<ShellDestination> visibleDestinations;

  /// 存储的选中目的地（可能被运行时隐藏）。
  final ShellDestination selectedDestination;

  /// 上一目的地（淡出层用）。
  final ShellDestination previousDestination;

  /// 实际生效的选中目的地：导航 chrome、页面栈与重复点击判定共用的唯一来源。
  final ShellDestination effectiveDestination;

  /// 窄版式播放页是否展开。
  final bool expanded;

  /// 当前布局是否有收起态（窄单栏 = true，桌面 / 移动宽版式 = false）。
  final bool miniCapable;

  /// 顶栏 ⇄ 播放页的共享封面飞行是否在途（只作同步守卫）。
  final bool flightInProgress;

  /// 当前目的地是否是播放页。
  bool get onPlayerPage => effectiveDestination == ShellDestination.nowPlaying;

  /// [effectiveDestination] 在 [visibleDestinations] 中的下标（不在列表时 -1）。
  int get selectedIndex => visibleDestinations.indexOf(effectiveDestination);

  /// 目的地当前是否可见（隐藏项不参与切页）。
  bool isVisible(ShellDestination destination) =>
      visibleDestinations.contains(destination);

  /// 顶栏是否显示播放条（封面 + 歌名/作者 + 播放/下一首 + 进度）。
  ///
  /// 移动端顶栏是唯一的迷你播放器：不在播放页时恒显示；在播放页时只有
  /// 窄版式且已收起才显示，展开后让位给品牌位。宽版式 / 桌面没有收起态，
  /// 在播放页永远不显示。
  bool get showsPlayerBar => !onPlayerPage || (miniCapable && !expanded);

  /// 壳层是否要拦截系统返回（歌词整页是唯一的页内层级）。
  bool get interceptsBack => onPlayerPage && miniCapable && !expanded;

  /// 展开 / 收起请求的裁决；调用方只在 [ShellExpansionVerdict.accepted] 时执行。
  ShellExpansionVerdict get expansionVerdict {
    if (!onPlayerPage) return ShellExpansionVerdict.notOnPlayerPage;
    if (!miniCapable) return ShellExpansionVerdict.layoutCannotCollapse;
    if (flightInProgress) return ShellExpansionVerdict.flightInProgress;
    return ShellExpansionVerdict.accepted;
  }

  /// 壳层级返回的裁决：页面级占用优先，其次「歌词整页先恢复正常播放页」。
  ShellBackIntent handleBack({required bool pageClaimsBack}) {
    if (pageClaimsBack) return ShellBackIntent.exit;
    if (!interceptsBack) return ShellBackIntent.exit;
    return ShellBackIntent.restorePlayer;
  }
}

/// 壳层展示状态与判定：目的地解析、播放页展开、顶栏播放条、返回层级。
///
/// 状态所有权：
/// - 目的地由壳层在点击 / 可见性变化时写入（[select] / [syncVisibility]）；
/// - [state].expanded / [state].miniCapable 由播放页在布局或动画落定时回写
///   （[setExpanded] / [setMiniCapable]）；
/// - [state].flightInProgress 由壳层在共享封面起飞 / 落定时写
///   （[setFlightInProgress]）。
///
/// 通知只在 expanded / miniCapable 变化时发出：它们是页面异步回写的渲染
/// 输入，壳层要据此重算 `PopScope.canPop` 与顶栏。目的地变化不通知，由壳层
/// 自己的 `setState` 推进——切页同帧还要发起封面飞行，多一次通知会让顶栏在
/// 飞行前先闪一次。
///
/// 状态形态（ADR-0041「启动期状态对象：快照 + 控制器」）：可变字段只留在
/// 内部，[state] 暴露不可变快照，[changes] 是变更信号。
class ShellPresentation implements SnapshotSource<ShellPresentationState> {
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

  final SnapshotSignal _changes = SnapshotSignal();

  @override
  ShellPresentationState get state => ShellPresentationState(
    visibleDestinations: _visible,
    selectedDestination: _selected,
    previousDestination: _previous,
    effectiveDestination: _effectiveDestination,
    expanded: _expanded,
    miniCapable: _miniCapable,
    flightInProgress: _flightInProgress,
  );

  @override
  Listenable get changes => _changes;

  /// 实际生效的选中目的地；存储项被隐藏时回退到第一个可见项。
  ///
  /// 只读计算，不回写 [_selected]：隐藏项重新可见后天然恢复。
  ShellDestination get _effectiveDestination {
    // NavProvider 保证至少保留 1 个可见项；空列表仅作防御。
    if (_visible.isEmpty) return _selected;
    return _visible.contains(_selected) ? _selected : _visible.first;
  }

  /// 同步可见集合；返回「有效目的地是否因此变化」。
  ///
  /// 返回值供壳层在 `didChangeDependencies` 里判断要不要把共享封面两端
  /// 对齐到新的稳态（可见性变化绕过了 [select]，没有飞行可撤销）。本方法
  /// 不发通知：调用发生在构建阶段，且该依赖本身已会触发重建。
  bool syncVisibility(List<ShellDestination> visibleDestinations) {
    _visible = List<ShellDestination>.unmodifiable(visibleDestinations);
    final ShellDestination effective = _effectiveDestination;
    if (effective == _rendered) return false;
    _rendered = effective;
    return true;
  }

  /// 切到 [destination]；返回是否真的切换。
  ///
  /// 隐藏目的地与「已经在当前有效目的地」都返回 false（调用方据此跳过
  /// 触感 / 飞行）。成功时把切换前的有效目的地记为 previous。
  bool select(ShellDestination destination) {
    if (!_visible.contains(destination)) return false;
    final ShellDestination current = _effectiveDestination;
    if (destination == current) return false;
    _previous = current;
    _selected = destination;
    _rendered = destination;
    return true;
  }

  /// 壳层级返回的裁决（实现见 [ShellPresentationState.handleBack]）。
  ///
  /// [pageClaimsBack] 由调用方传入（生产为 `BackClaims.any`）：本模块不读
  /// 进程级登记表，接口测试可以用布尔值覆盖优先级。
  ///
  /// 只做判定，不改展开态：页面在展开动画开始时才回写，提前清零会让恢复
  /// 途中的第二次返回又落回歌词整页。
  ShellBackIntent handleBack({required bool pageClaimsBack}) =>
      state.handleBack(pageClaimsBack: pageClaimsBack);

  /// 页面回写展开态；相同值不重复通知。
  void setExpanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    _changes.notify();
  }

  /// 页面回写布局能力；相同值不重复通知。
  void setMiniCapable(bool value) {
    if (_miniCapable == value) return;
    _miniCapable = value;
    _changes.notify();
  }

  /// 壳层回写共享封面飞行状态（只作同步守卫，不发通知）。
  void setFlightInProgress(bool value) => _flightInProgress = value;
}
