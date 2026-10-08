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
class PlayerMorphFlight extends StatelessWidget {
  const PlayerMorphFlight({
    super.key,
    required this.animation,
    required this.geometry,
  });

  /// 几何飞行占比；到达后宿主移除副本并显示目标端真身。
  static const double flightPortion = 0.75;

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

  /// 封面副本：描边/阴影与播放页真身同款并按 t 插值（顶栏端 32×32、圆角 8、
  /// 无描边阴影），落位瞬间不出现描边「弹出」。
  Widget _cover(BuildContext context, String? url, double t) {
    final scheme = Theme.of(context).colorScheme;
    final radius = lerpDouble(8, 18, t)!;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: t),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.28 * t),
            blurRadius: 24 * t,
            offset: Offset(0, 10 * t),
          ),
        ],
      ),
      child: MorphCover(
        url: url,
        borderRadius: BorderRadius.circular(radius - 1),
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
    if (provider == null) return _fallback(context);
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Image(
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
