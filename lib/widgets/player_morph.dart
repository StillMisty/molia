/// 顶栏 ↔ 播放页共享元素飞行的锚点几何与控制。
///
/// **只共享封面**：顶栏与播放页各自持有封面真身，切换 tab 时两端封面隐藏，
/// 由 Overlay 上的飞行副本完成 Rect / 圆角插值。歌名/进度不参与共享飞行
/// （「所有元素一起飞」观感不成熟，反而廉价）。
///
/// 飞行副本的外观与插值在 `cover_appearance.dart`（`CoverAppearance` /
/// `CoverFlight` / `CoverFlightLayer`）——本文件只负责锚点捕获与飞行生命周期。
library;

import 'package:flutter/foundation.dart' show ValueListenable, immutable;
import 'package:material_ui/material_ui.dart';

import '../utils/snapshot_source.dart';
import 'cover_appearance.dart';

/// 封面外观与飞行副本定义在 `cover_appearance.dart`；这里再导出给顶栏 /
/// 播放页 / 飞行宿主（既有 import 面不变）。
export 'cover_appearance.dart'
    show MorphCover, barCoverFallbackIconSize, playerCoverFallbackIconRatio;

/// 侧邻位展开的飞行窗口起点：只在飞行最后约 45% 从中心展开，前半程保持收起。
///
/// 副本身位在飞行中段才接近播放页中心，侧邻位过早出现会与副本抢视觉；
/// 收起方向按同一窗口反向收回。
const double pageDeckRevealStart = 0.55;

/// 读取锚点当前屏幕矩形（含祖先变换）；元素未挂载/未布局时返回 null。
///
/// 必须映射左上/右下两个角，不能用 `localToGlobal(Offset.zero) & box.size`：
/// 祖先存在持续缩放（如暂停态的封面播放态缩放 0.98）时，后者的位置与尺寸
/// 都不是真身的屏幕矩形，飞行副本会以错误大小/位置落位、交接瞬间跳变。
/// 旋转中的锚点取外接矩形（可接受：抓取只发生在稳态几何上）。
///
/// 顶栏 ⇄ 播放页的副本挂在根 Overlay 上，两端锚点一律用全局坐标。
Rect? anchorRectOf(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
}

/// 共享封面飞行的不可变快照：两端真身的隐藏状态。
///
/// 侧邻位展开进度（[PlayerMorphController.pageDeckReveal]）是逐帧驱动 deck
/// 的高频通道，刻意不放进快照。
@immutable
class PlayerMorphState {
  const PlayerMorphState({
    required this.barHeaderHidden,
    required this.pageHeaderHidden,
  });

  /// 顶栏封面/歌名/进度是否隐藏（播放页激活或飞行中）。
  final bool barHeaderHidden;

  /// 播放页封面是否隐藏（飞行中，由飞行副本承接）。
  final bool pageHeaderHidden;
}

/// 顶栏 ↔ 播放页共享元素飞行控制器。
///
/// 状态形态（ADR-0041「启动期状态对象：快照 + 控制器」）：隐藏状态在
/// [state] 快照里、[changes] 是唯一通知面；侧邻位展开进度仍是独立的
/// `ValueListenable`（逐帧、只驱动 deck 子树，不进快照）。
class PlayerMorphController implements SnapshotSource<PlayerMorphState> {
  /// 顶栏封面锚点。
  final GlobalKey barCoverKey = GlobalKey(debugLabel: 'morphBarCover');

  /// 播放页封面锚点。
  final GlobalKey pageCoverKey = GlobalKey(debugLabel: 'morphPageCover');

  bool _barHeaderHidden = false;
  bool _pageHeaderHidden = false;
  final ValueNotifier<double> _pageDeckReveal = ValueNotifier<double>(1);
  final SnapshotSignal _changes = SnapshotSignal();

  @override
  PlayerMorphState get state => PlayerMorphState(
    barHeaderHidden: _barHeaderHidden,
    pageHeaderHidden: _pageHeaderHidden,
  );

  @override
  Listenable get changes => _changes;

  /// 播放页左右邻位槽的展开进度：0 = 收回中心、1 = 稳态侧槽。
  ///
  /// 由壳层用现有飞行弹簧驱动（不额外建 ticker），只暴露值本身：deck
  /// 监听它逐帧更新侧槽几何，不触发整个壳层重建。center 锚点不受影响。
  ValueListenable<double> get pageDeckReveal => _pageDeckReveal;

  /// 设置侧邻位展开进度（壳层飞行 tick / 起止路径调用）。
  ///
  /// 不走 [changes]：那是隐藏状态（整树重建）的通道；值监听只让 deck 的
  /// Stack 子树逐帧重建。
  void setPageDeckReveal(double value) {
    final double clamped = value.clamp(0.0, 1.0);
    if (_pageDeckReveal.value == clamped) return;
    _pageDeckReveal.value = clamped;
  }

  /// 飞行行程内的侧邻位 reveal 目标值。
  ///
  /// 进入：飞行最后 [pageDeckRevealStart] 之后从 0 展到 1；离开：时间对称，
  /// 飞行前 45% 先收回中心（`entryWindow(1 - progress)`），页面层后段淡出时
  /// 不会出现「收回看不见」。失败 / 落定路径由壳层直接置 1（见
  /// `_completeMorph`）。
  static double pageDeckRevealAt(double progress, {required bool toPage}) {
    double entryWindow(double value) =>
        ((value.clamp(0.0, 1.0) - pageDeckRevealStart) /
                (1 - pageDeckRevealStart))
            .clamp(0.0, 1.0);
    // 只做窗口裁切；easing 形状由 deck 的侧槽几何统一施加（避免双重缓动）。
    // 减弱动效时 deck 直接按 1 落位。
    return toPage ? entryWindow(progress) : entryWindow(1 - progress);
  }

  void setBarHeaderHidden(bool value) {
    if (_barHeaderHidden == value) return;
    _barHeaderHidden = value;
    _changes.notify();
  }

  void setPageHeaderHidden(bool value) {
    if (_pageHeaderHidden == value) return;
    _pageHeaderHidden = value;
    _changes.notify();
  }

  /// 读取锚点当前屏幕矩形（含祖先变换）；元素未挂载/未布局时返回 null。
  Rect? rectOf(GlobalKey key) => anchorRectOf(key);

  /// 两端封面锚点齐备时的飞行几何；任一缺失返回 null（跳过 morph）。
  PlayerMorphGeometry? captureGeometry({required bool toPage}) {
    final barCover = rectOf(barCoverKey);
    final pageCover = rectOf(pageCoverKey);
    if (barCover == null || pageCover == null) return null;
    return PlayerMorphGeometry(
      barCover: barCover,
      pageCover: pageCover,
      toPage: toPage,
    );
  }

  void dispose() {
    _pageDeckReveal.dispose();
  }
}

/// 一次飞行所需的源/目标矩形（均为全局坐标）。
class PlayerMorphGeometry {
  const PlayerMorphGeometry({
    required this.barCover,
    required this.pageCover,
    required this.toPage,
  });

  final Rect barCover;
  final Rect pageCover;
  final bool toPage;

  Rect get coverFrom => toPage ? barCover : pageCover;
  Rect get coverTo => toPage ? pageCover : barCover;
}

/// Overlay 上的顶栏 ↔ 播放页飞行副本。
///
/// 只做封面几何飞行，**全程不透明、精确落位**：几何/外观插值全在
/// [CoverFlightLayer]（`cover_appearance.dart`），这里只把锚点几何翻译成
/// 一次飞行。
class PlayerMorphFlight extends StatelessWidget {
  const PlayerMorphFlight({
    super.key,
    required this.animation,
    required this.geometry,
    this.url,
    this.fallback,
  });

  /// 几何飞行终点占比；到达后宿主移除副本并显示目标端真身。
  static const double flightPortion = CoverFlightLayer.flightPortion;

  final Animation<double> animation;
  final PlayerMorphGeometry geometry;

  /// 飞行期间展示的封面 URL（宿主在抓取锚点的同一刻确定，飞行中不换图）。
  final String? url;

  /// 未命中缓存/无封面时的回退（拿到插值后的图标尺寸）。
  final Widget Function(BuildContext context, double iconSize)? fallback;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary 把逐帧变化的副本与 Overlay 其它内容隔离：飞行中每帧
    // 只有这一层重绘，不会把整条 Overlay（页面 / 顶栏）拖进 raster。
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CoverFlightLayer(
            animation: animation,
            flight: CoverFlight(
              otherRect: geometry.barCover,
              pageRect: geometry.pageCover,
              toPage: geometry.toPage,
            ),
            url: url,
            fallback: fallback,
          ),
        ],
      ),
    );
  }
}
