import 'dart:ui' show lerpDouble;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../managers/artwork_cache.dart';
import '../providers/playback_provider.dart';
import 'molia_mark.dart';

/// 顶栏 ↔ 播放页共享元素飞行控制器。
///
/// **只共享封面**：顶栏与播放页各自持有封面真身，切换 tab 时两端封面隐藏，
/// 由 Overlay 上的飞行副本完成 Rect / 圆角插值。歌名/进度不再参与共享飞行
/// （「所有元素一起飞」观感不成熟，反而廉价）。
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

  /// 读取锚点当前全局矩形；元素未挂载/未布局时返回 null。
  Rect? rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

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

/// Overlay 飞行副本：只做封面几何飞行，**全程不透明、精确落位**。
///
/// 前 [flightPortion] 行程完成几何移动并精确落在目标端封面矩形上；宿主在
/// 到达的那一帧同时亮出目标端真身并移除本副本。不做「副本淡出 + 真身淡入」
/// 的交叉过渡——两者时间不可能完全对齐，尾段会出现重影与亮度下陷（闪动）。
/// 圆角/描边/阴影同样精确匹配两端：按「播放页端进度」插值，双向飞行在
/// 起点（与真身同帧同形）和落点（真身亮出前完全同款）都不会跳变。
class PlayerMorphFlight extends StatelessWidget {
  const PlayerMorphFlight({
    super.key,
    required this.animation,
    required this.geometry,
  });

  /// 几何飞行占比；到达后宿主移除副本并显示目标端真身。
  static const double flightPortion = 0.75;

  /// 顶栏端封面外观：圆角 8、无描边阴影（对应顶栏 32×32 封面真身）。
  static const double _barRadius = 8;

  /// 播放页端封面外观：外圆角 18、1px 描边 + 柔和阴影
  /// （对应 `player.dart::_buildCoverCard` 的大封面真身）。
  static const double _pageRadius = 18;

  final Animation<double> animation;
  final PlayerMorphGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlaybackProvider>();
    final track = provider.snapshot.current;
    final artworkUrl = track?.artwork?.uri.toString();
    final String? coverUrl =
        artworkUrl == null || artworkUrl.isEmpty ? null : artworkUrl;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final value = animation.value;
        final t = Curves.easeInOutCubic.transform(
          (value / flightPortion).clamp(0.0, 1.0),
        );
        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _positioned(
                Rect.lerp(geometry.coverFrom, geometry.coverTo, t)!,
                _cover(context, coverUrl, t),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _positioned(Rect rect, Widget child) {
    return Positioned.fromRect(rect: rect, child: child);
  }

  /// 封面副本：圆角/描边/阴影与两端真身同款并按飞行方向插值。
  ///
  /// [t] 按飞行方向定义（0 = 起点、1 = 终点），但外观必须按「播放页端
  /// 进度」插值：反向飞行（播放页 → 顶栏）起飞帧 t=0 在播放页端，若仍按
  /// t 插值，大封面圆角会从 18 瞬间掉到 8（看起来圆角消失），又在顶栏端
  /// 以 18 落位（与顶栏真身 8 不匹配）。
  Widget _cover(BuildContext context, String? url, double t) {
    final scheme = Theme.of(context).colorScheme;
    final double pageT = geometry.toPage ? t : 1 - t;
    final double radius = lerpDouble(_barRadius, _pageRadius, pageT)!;
    // 顶栏真身没有 1px 描边，图片裁剪半径即外半径；播放页真身描边内缘
    // 收进 1px（裁剪 17）。描边进度恰好等于裁剪收进量：两端落位都精确
    // 重合，飞行中图片最多只探入半透明的描边带。
    final double clipRadius = radius - pageT;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: pageT),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.28 * pageT),
            blurRadius: 24 * pageT,
            offset: Offset(0, 10 * pageT),
          ),
        ],
      ),
      child: MorphCover(
        url: url,
        borderRadius: BorderRadius.circular(clipRadius),
      ),
    );
  }
}

/// 共享元素封面：直接用与顶栏/播放页同键的 [CachedNetworkImageProvider]，
/// 命中 Flutter ImageCache 时同步出帧（`wasSynchronouslyLoaded`），
/// 不再经过 FutureBuilder 造成首帧占位闪烁。
///
/// 顶栏↔播放页飞行与播放页内迷你⇄完整飞行共用。
class MorphCover extends StatefulWidget {
  const MorphCover({
    super.key,
    required this.url,
    required this.borderRadius,
    this.fallback,
  });

  final String? url;
  final BorderRadius borderRadius;

  /// 未命中缓存/加载失败时的回退（默认主题容器色 + 音符图标）。
  final Widget? fallback;

  @override
  State<MorphCover> createState() => _MorphCoverState();
}

class _MorphCoverState extends State<MorphCover> {
  ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _resolveProvider();
  }

  @override
  void didUpdateWidget(covariant MorphCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _resolveProvider();
    }
  }

  void _resolveProvider() {
    final url = widget.url;
    _provider = (url == null || url.isEmpty)
        ? null
        : CachedNetworkImageProvider(
            url,
            headers: ArtworkCache.headersFor(url),
            cacheManager: ArtworkCache.instance.managerSync,
          );
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    // 回退图（无封面 / 加载中 / 加载失败）也必须裁剪：两端真身都是圆角卡，
    // 回退时方角会在飞行起点与落点造成「圆角消失」的跳变。
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: provider == null
          ? _fallback(context)
          : Image(
              image: provider,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || frame != null) return child;
                return _fallback(context);
              },
              errorBuilder: (_, __, ___) => _fallback(context),
            ),
    );
  }

  Widget _fallback(BuildContext context) {
    final custom = widget.fallback;
    if (custom != null) return custom;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: MoliaMark(
        color: scheme.onSurfaceVariant,
        size: 32,
      ),
    );
  }
}
