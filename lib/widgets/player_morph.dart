/// 顶栏 ↔ 播放页共享元素飞行的锚点几何与控制。
///
/// **只共享封面**：顶栏与播放页各自持有封面真身，切换 tab 时两端封面隐藏，
/// 由 Overlay 上的飞行副本完成 Rect / 圆角插值。歌名/进度不参与共享飞行
/// （「所有元素一起飞」观感不成熟，反而廉价）。
///
/// 飞行副本的外观与插值在 `cover_appearance.dart`（`CoverAppearance` /
/// `CoverFlight` / `CoverFlightLayer`）——本文件只负责锚点捕获与飞行生命周期。
library;

import 'package:material_ui/material_ui.dart';

import 'cover_appearance.dart';

/// 封面外观与飞行副本定义在 `cover_appearance.dart`；这里再导出给顶栏 /
/// 播放页 / 飞行宿主（既有 import 面不变）。
export 'cover_appearance.dart'
    show MorphCover, barCoverFallbackIconSize, playerCoverFallbackIconRatio;

/// 读取锚点当前矩形（含祖先变换）；元素未挂载/未布局时返回 null。
///
/// 必须映射左上/右下两个角，不能用 `localToGlobal(Offset.zero) & box.size`：
/// 祖先存在持续缩放（如暂停态的封面播放态缩放 0.98）时，后者的位置与尺寸
/// 都不是真身的屏幕矩形，飞行副本会以错误大小/位置落位、交接瞬间跳变。
/// 旋转中的锚点取外接矩形（可接受：抓取只发生在稳态几何上）。
///
/// [container] 非空时返回相对该容器的本地矩形（播放页内迷你⇄完整飞行副本
/// 定位用）；为空时返回全局坐标（Overlay 上的顶栏⇄播放页飞行）。
Rect? anchorRectOf(GlobalKey key, {GlobalKey? container}) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final Rect global = Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
  final containerBox =
      container?.currentContext?.findRenderObject() as RenderBox?;
  if (containerBox == null) return global;
  return Rect.fromPoints(
    containerBox.globalToLocal(global.topLeft),
    containerBox.globalToLocal(global.bottomRight),
  );
}

/// 顶栏 ↔ 播放页共享元素飞行控制器。
class PlayerMorphController extends ChangeNotifier {
  /// 顶栏封面锚点。
  final GlobalKey barCoverKey = GlobalKey(debugLabel: 'morphBarCover');

  /// 播放页封面锚点。
  final GlobalKey pageCoverKey = GlobalKey(debugLabel: 'morphPageCover');

  bool _barHeaderHidden = false;
  bool _pageHeaderHidden = false;

  /// 顶栏封面/歌名/进度是否隐藏（播放页激活或飞行中）。
  bool get barHeaderHidden => _barHeaderHidden;

  /// 播放页封面是否隐藏（飞行中，由飞行副本承接）。
  bool get pageHeaderHidden => _pageHeaderHidden;

  void setBarHeaderHidden(bool value) {
    if (_barHeaderHidden == value) return;
    _barHeaderHidden = value;
    notifyListeners();
  }

  void setPageHeaderHidden(bool value) {
    if (_pageHeaderHidden == value) return;
    _pageHeaderHidden = value;
    notifyListeners();
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
    return Stack(
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
    );
  }
}
