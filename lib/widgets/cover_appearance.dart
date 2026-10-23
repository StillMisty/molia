/// 封面外观与共享元素飞行（cover appearance / cover flight）。
///
/// 全 App 只有这一份「封面卡片长什么样」与「共享元素飞行怎么插值」：
/// - [CoverAppearance]：圆角 / 描边 / 阴影 / 回退图标；三个端点是命名值
///   （[CoverAppearance.bar] / [CoverAppearance.mini] / [CoverAppearance.page]），
///   任意两端之间可线性插值；
/// - [CoverCard]：按外观渲染卡片的唯一实现（外框 + 内缘裁剪 + 内容构建器），
///   三端真身与飞行副本共用；图片内容不在这里收口——真身用 `AppNetworkImage`
///   （placeholder / errorWidget 语义），飞行副本用 [MorphCover]（同步出帧，
///   落位帧不闪），两者是同一取图逻辑的两个 adapter；
/// - [CoverFlight] / [CoverFlightLayer]：一次飞行的几何与外观求值 + 副本渲染。
///
/// 两条原先靠散文与三处手抄维持的不变量，在这里成为代数关系：
/// - 描边透明度 = 描边宽度（顶栏端 0 = 无描边，播放页端 1 = 1px）；
/// - 图片裁剪半径 = 外圆角 − 描边宽度（顶栏端 8，播放页端 17），
///   因此飞行中图片边缘恰好等于描边带内缘：既不留缝，也不探入带内。
library;

import 'dart:ui' show lerpDouble;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/track.dart';
import '../managers/artwork_cache.dart';
import '../utils/playback_cover_decode.dart';
import 'molia_mark.dart';

/// 曲目封面 URL（空串视同无封面；领域 Track 自带可靠 id/artwork）。
///
/// 封面词汇的唯一来源：真身渲染、飞行副本、切歌会话的占位 URL 与
/// 迷你/顶栏取值都走它（`player_cover_deck.dart` 再导出）。
String? artworkUrlOf(Track? track) {
  final url = track?.artwork?.uri.toString();
  return url == null || url.isEmpty ? null : url;
}

/// 曲目的稳定 key（领域 id）。
String? trackKeyOf(Track? track) => track?.id.uri;

/// 顶栏 40×40 封面真身的回退图标尺寸。
///
/// 两端真身与飞行副本共用，禁止任一端再写死（尺寸漂移会让图标态飞行的
/// 起手/落点跳变）。
const double barCoverFallbackIconSize = 22;

/// 迷你播放条 48×48 封面真身的回退图标尺寸（共用理由同上）。
const double miniCoverFallbackIconSize = 24;

/// 播放页封面卡回退图标尺寸占卡片边长的比例（共用理由同上）。
const double playerCoverFallbackIconRatio = 0.35;

/// 封面卡片外观：圆角、描边、阴影与回退图标。
@immutable
class CoverAppearance {
  const CoverAppearance({
    required this.radius,
    this.stroke = 0,
    this.shadow = 0,
    this.iconRatio = playerCoverFallbackIconRatio,
    this.iconSize,
  });

  /// 外圆角。
  final double radius;

  /// 描边宽度（0 = 无描边）；渲染时透明度取同一值——顶栏端的「无描边」与
  /// 播放页端的「1px 描边」因此只是同一条轴上的 0 与 1。
  final double stroke;

  /// 阴影强度（0 = 无阴影，1 = 播放页端的柔和阴影）。
  final double shadow;

  /// 回退图标占卡片边长的比例（仅在 [iconSize] 为空时生效）。
  final double iconRatio;

  /// 回退图标固定尺寸（顶栏/迷你端：真身边长固定，比例不适用）。
  final double? iconSize;

  /// 顶栏端（40×40 封面真身：r8、无描边阴影）。
  static const CoverAppearance bar = CoverAppearance(
    radius: 8,
    iconSize: barCoverFallbackIconSize,
  );

  /// 迷你播放条端（48×48 封面真身：r8、无描边阴影）。
  static const CoverAppearance mini = CoverAppearance(
    radius: 8,
    iconSize: miniCoverFallbackIconSize,
  );

  /// 播放页端（cover deck 封面真身：r18 + 1px 描边 + 柔和阴影）。
  static const CoverAppearance page = CoverAppearance(
    radius: 18,
    stroke: 1,
    shadow: 1,
  );

  /// 图片裁剪半径（描边内缘）。
  BorderRadius get clip => BorderRadius.circular(radius - stroke);

  /// 回退图标尺寸（[edge] = 卡片边长）。
  double iconSizeFor(double edge) => iconSize ?? edge * iconRatio;

  /// 线性插值（飞行用）：[t] = 0 取 [a]、1 取 [b]。
  ///
  /// 只插值几何与装饰轴；回退图标由 [CoverFlight.iconSizeAt] 按两端真身的
  /// 尺寸求值——两端图标事实的形状不同（固定尺寸 / 按边长比例），不能在
  /// 外观对象层面插值。
  static CoverAppearance lerp(CoverAppearance a, CoverAppearance b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return CoverAppearance(
      radius: lerpDouble(a.radius, b.radius, t)!,
      stroke: lerpDouble(a.stroke, b.stroke, t)!,
      shadow: lerpDouble(a.shadow, b.shadow, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoverAppearance &&
      other.radius == radius &&
      other.stroke == stroke &&
      other.shadow == shadow &&
      other.iconRatio == iconRatio &&
      other.iconSize == iconSize;

  @override
  int get hashCode => Object.hash(radius, stroke, shadow, iconRatio, iconSize);
}

/// 一次共享元素飞行：两端矩形与外观 + 方向 → 任意进度的几何/外观/图标。
@immutable
class CoverFlight {
  const CoverFlight({
    required this.otherRect,
    required this.pageRect,
    this.otherAppearance = CoverAppearance.bar,
    this.pageAppearance = CoverAppearance.page,
    required this.toPage,
  });

  /// 非播放页端（顶栏 / 迷你）矩形。
  final Rect otherRect;

  /// 播放页端矩形。
  final Rect pageRect;

  /// 非播放页端外观（默认顶栏端）。
  final CoverAppearance otherAppearance;

  /// 播放页端外观。
  final CoverAppearance pageAppearance;

  /// 几何插值方向：true = 其他端 → 播放页端，false = 播放页端 → 其他端。
  final bool toPage;

  /// 几何起点（[toPage] 决定顶栏/迷你端在前还是播放页端在前）。
  Rect get fromRect => toPage ? otherRect : pageRect;

  /// 几何终点。
  Rect get toRect => toPage ? pageRect : otherRect;

  /// 播放页端进度：0 = 完全在非播放页端，1 = 完全在播放页端。
  ///
  /// 外观必须按它插值而不是按几何进度：反向飞行（播放页 → 顶栏）的起飞帧
  /// t=0 就在播放页端，按 t 插值会让大封面圆角瞬间从 18 掉到 8（看起来
  /// 圆角消失），并在顶栏端以 18 落位（与顶栏真身 8 不匹配）。
  double pageProgressAt(double t) => (toPage ? t : 1 - t).clamp(0.0, 1.0);

  /// 任意进度的封面矩形。
  Rect rectAt(double t) =>
      Rect.lerp(fromRect, toRect, t.clamp(0.0, 1.0))!;

  /// 任意进度的外观。
  CoverAppearance appearanceAt(double t) => CoverAppearance.lerp(
        otherAppearance,
        pageAppearance,
        pageProgressAt(t),
      );

  /// 任意进度的回退图标尺寸：两端真身尺寸按播放页端进度插值。
  ///
  /// 端点固定值——播放页端取 [pageRect] 宽 × 比例，不跟随飞行中的卡片宽。
  /// 两端真身的图标事实不同（固定尺寸 vs 边长比例），固定尺寸会在起手与
  /// 交接两处各跳一次，必须插值。
  double iconSizeAt(double t) => lerpDouble(
        otherAppearance.iconSizeFor(otherRect.width),
        pageAppearance.iconSizeFor(pageRect.width),
        pageProgressAt(t),
      )!;
}

/// 卡片内容构建器：拿到外观算好的裁剪圆角与回退图标尺寸。
typedef CoverCardContent = Widget Function(
  BuildContext context,
  BorderRadius clip,
  double iconSize,
);

/// 封面卡片：三端真身与飞行副本共用的唯一渲染。
///
/// 图片 widget 的差异留在调用侧（真身 `AppNetworkImage`、飞行副本
/// [MorphCover]），这里只负责外观：外框（圆角/描边/阴影）+ 内缘裁剪。
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.size,
    required this.appearance,
    required this.content,
    this.iconSize,
  });

  /// 卡片边长（封面卡恒为方形）。
  final double size;

  final CoverAppearance appearance;

  /// 回退图标尺寸覆盖：飞行副本按两端真身插值（[CoverFlight.iconSizeAt]），
  /// 不跟随所在卡片的当前边长。
  final double? iconSize;

  final CoverCardContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final double icon = iconSize ?? appearance.iconSizeFor(size);
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(appearance.radius),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: appearance.stroke),
            width: appearance.stroke,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.28 * appearance.shadow),
              blurRadius: 24 * appearance.shadow,
              offset: Offset(0, 10 * appearance.shadow),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: appearance.clip,
          child: content(context, appearance.clip, icon),
        ),
      ),
    );
  }
}

/// 共享元素飞行副本：按 [flight] 在动画进度上插值几何与外观。
///
/// 全程不透明、精确落位：宿主要在弹簧落定（零速度）那一帧亮出目标端真身并
/// 移除本副本，不做「副本淡出 + 真身淡入」的交叉过渡——两者时间不可能完全
/// 对齐，尾段会出现重影与亮度下陷（闪动）。
///
/// 必须挂在 [Stack] 下：本组件返回 [Positioned.fromRect]。
class CoverFlightLayer extends StatelessWidget {
  const CoverFlightLayer({
    super.key,
    required this.animation,
    required this.flight,
    required this.url,
    this.fallback,
  });

  /// 几何飞行终点占比；到达后宿主移除副本并显示目标端真身。
  ///
  /// 弹簧驱动时取 1.0：副本在弹簧落定（零速度）那一帧交接，而不是在行程
  /// 中途硬切——中途切会让副本带着速度消失、真身静态亮出（「被抓住」感）。
  static const double flightPortion = 1.0;

  final Animation<double> animation;

  final CoverFlight flight;

  /// 飞行期间展示的封面 URL（由调用方在抓取锚点的同一刻确定）。
  final String? url;

  /// 未命中缓存/无封面时的回退（拿到插值后的图标尺寸）。
  final Widget Function(BuildContext context, double iconSize)? fallback;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // 弹簧原值即运动曲线；归一化到飞行行程。
        final double t = (animation.value / flightPortion).clamp(0.0, 1.0);
        final Rect rect = flight.rectAt(t);
        final double iconSize = flight.iconSizeAt(t);
        return Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: CoverCard(
              size: rect.width,
              appearance: flight.appearanceAt(t),
              iconSize: iconSize,
              content: (context, clip, icon) => MorphCover(
                url: url,
                borderRadius: clip,
                fallbackIconSize: icon,
                fallback: fallback?.call(context, icon),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 共享元素封面：直接用与顶栏/播放页同键的 [CachedNetworkImageProvider]，
/// 命中 Flutter ImageCache 时同步出帧（`wasSynchronouslyLoaded`），
/// 避免 FutureBuilder 首帧占位闪烁。
///
/// 顶栏↔播放页飞行与播放页内迷你⇄完整飞行共用。
class MorphCover extends StatefulWidget {
  const MorphCover({
    super.key,
    required this.url,
    required this.borderRadius,
    this.fallback,
    this.fallbackIconSize,
    this.artworkCache,
  });

  final String? url;
  final BorderRadius borderRadius;

  /// 未命中缓存/加载失败时的回退（默认主题容器色 + 音符图标）。
  final Widget? fallback;

  /// 默认回退图标尺寸（[fallback] 为空时生效）；不传时为 32。
  final double? fallbackIconSize;

  /// 测试可注入自定义 ArtworkCache（默认全局单例），与 `AppNetworkImage`
  /// 同款注入点。
  final ArtworkCache? artworkCache;

  @override
  State<MorphCover> createState() => _MorphCoverState();
}

class _MorphCoverState extends State<MorphCover> {
  ImageProvider? _provider;

  /// 当前解析用的有界解码边长；DPR / 窗口尺寸变化时重算。
  int? _decodeEdge;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final edge = playbackCoverDecodeEdge(context);
    if (edge == _decodeEdge) return;
    _decodeEdge = edge;
    _resolveProvider();
  }

  @override
  void didUpdateWidget(covariant MorphCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.artworkCache != widget.artworkCache) {
      _decodeEdge = playbackCoverDecodeEdge(context);
      _resolveProvider();
    }
  }

  void _resolveProvider() {
    final url = widget.url;
    final cache = widget.artworkCache ?? ArtworkCache.instance;
    if (url == null || url.isEmpty) {
      _provider = null;
      return;
    }
    final provider = CachedNetworkImageProvider(
      url,
      headers: ArtworkCache.headersFor(url),
      cacheManager: cache.managerSync,
    );
    // 与 AppNetworkImage / 预取共用同一个有界解码键：飞行副本命中同一张
    // 已解码图，才不会退回原图尺寸（2000×2000 = 15MB）。
    _provider = ResizeImage.resizeIfNeeded(_decodeEdge, null, provider);
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
        size: widget.fallbackIconSize ?? 32,
      ),
    );
  }
}
