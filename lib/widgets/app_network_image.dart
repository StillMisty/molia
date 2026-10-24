import 'package:cached_network_image/cached_network_image.dart';
// flutter_cache_manager 是 cached_network_image 的传递依赖；图片组件需要
// 直接引用 CacheManager 类型。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:material_ui/material_ui.dart';

import '../managers/artwork_cache.dart';
import '../utils/local_image_provider.dart';
import 'molia_mark.dart';

/// 统一网络图片组件：封面/头像等所有远端图片都走这里。
///
/// - 请求头统一走 [ArtworkCache.headersFor]（浏览器 UA + 平台 Referer，
///   修复网易云 CDN 对 Dart UA 的 403）；
/// - 缓存统一走 [ArtworkCache] 的共享持久 CacheManager（封面分区策略）；
/// - `file://` 地址（本地下载封面）直接走 [FileImage]，不经过网络缓存；
/// - 占位 / 失败默认回退到 Molia 标志，调用方可覆盖；
/// - [borderRadius] 非空时内部做圆角裁剪（避免各处重复 ClipRRect）。
class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
    this.fallbackUrl,
    this.fallbackIconSize,
    this.fallbackColor,
    this.artworkCache,
    this.onError,
  });

  /// 图片地址；null / 空串直接显示回退图标（不触网）。
  final String? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// 加载中占位（默认半透明 surfaceContainerHighest 色块）。
  final Widget? placeholder;

  /// 加载失败回退（默认 Molia 标志）。
  final Widget? errorWidget;

  /// 主图缺失 / 加载失败时先尝试的回退图（如全局默认封面）。
  ///
  /// 只有主图不可用才展示；回退图自身失败仍回退 [errorWidget] / Molia
  /// 标志，且不会再递归尝试 [fallbackUrl]。
  final String? fallbackUrl;

  final double? fallbackIconSize;
  final Color? fallbackColor;

  /// 测试可注入自定义 ArtworkCache（默认全局单例）。
  final ArtworkCache? artworkCache;

  /// 加载失败回调（错误对象原样传出）；在帧后触发，调用方可在其中重建图片。
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    final imageUrl = url;
    final fallback = fallbackUrl;
    final radius = borderRadius;
    Widget wrap(Widget child) =>
        radius == null ? child : ClipRRect(borderRadius: radius, child: child);

    // 主图缺失：先显示回退图（全局默认封面），没有回退图才用 Molia 标志。
    if (imageUrl == null || imageUrl.isEmpty) {
      if (fallback != null && fallback.isNotEmpty) {
        return wrap(_buildFor(context, fallback, isFallback: true));
      }
      return wrap(_fallback(context));
    }

    return wrap(_buildFor(context, imageUrl, isFallback: false));
  }

  Widget _buildFor(
    BuildContext context,
    String imageUrl, {
    required bool isFallback,
  }) {
    // 本地文件（下载封面 / 自定义封面）：FileImage 直读，不经过网络缓存与
    // 省流网关。
    final localProvider = localFileImageProvider(imageUrl);
    if (localProvider != null) {
      return Image(
        // FileImage 自身不认 memCacheWidth；不包 ResizeImage 时列表里的
        // 下载封面会按原图解码（1k 封面 = 数 MB），与远端缩略图路径不一致。
        image: ResizeImage.resizeIfNeeded(
          memCacheWidth,
          memCacheHeight,
          localProvider,
        ),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, error, ___) {
          if (!isFallback) _notifyError(error);
          return _errorFallback(context, isFallback: isFallback);
        },
      );
    }

    final cache = artworkCache ?? ArtworkCache.instance;
    // 启动后 manager 已解析（常态）：直接构建，命中 ImageCache 时同步出帧。
    // 不能无条件走 FutureBuilder——它在 future 身份变化时会回到 waiting 渲染
    // 占位；切歌动画会逐帧重建封面，导致整个动画期间显示深色占位（「切歌黑图」）。
    final manager = cache.managerSync;
    if (manager != null) {
      return _buildImage(context, imageUrl, manager, isFallback: isFallback);
    }
    return FutureBuilder<CacheManager?>(
      // future 由 ArtworkCache 缓存、身份稳定，仅启动早期处于 waiting。
      future: cache.managerOrNull(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return placeholder ?? _placeholder(context);
        }
        return _buildImage(
          context,
          imageUrl,
          snapshot.data,
          isFallback: isFallback,
        );
      },
    );
  }

  Widget _buildImage(
    BuildContext context,
    String imageUrl,
    CacheManager? manager, {
    required bool isFallback,
  }) {
    // 调用方没显式给尺寸时按布局宽度 / DPR 兜底：96px 的详情页头像、评论区
    // 头像不应该按 1k 原图解码。显式值优先（列表缩略图已按 44/56 传）。
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final cacheWidth = memCacheWidth ??
        (width != null && width!.isFinite && width! > 0
            ? (width! * dpr).round()
            : null);
    final cacheHeight = memCacheHeight ??
        (height != null && height!.isFinite && height! > 0
            ? (height! * dpr).round()
            : null);
    return CachedNetworkImage(
      imageUrl: imageUrl,
      cacheManager: manager,
      httpHeaders: ArtworkCache.headersFor(imageUrl),
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: cacheWidth,
      memCacheHeight: cacheHeight,
      placeholder: (_, __) => placeholder ?? _placeholder(context),
      errorWidget: (_, __, error) {
        if (!isFallback) _notifyError(error);
        return _errorFallback(context, isFallback: isFallback);
      },
    );
  }

  /// 主图失败时的回退：优先调用方给的 [errorWidget]，否则尝试 [fallbackUrl]，
  /// 最后才是 Molia 标志。回退图失败不会再递归（[isFallback] 守卫）。
  Widget _errorFallback(BuildContext context, {required bool isFallback}) {
    final custom = errorWidget;
    if (custom != null) return custom;
    final fallback = fallbackUrl;
    if (!isFallback && fallback != null && fallback.isNotEmpty) {
      // 外层已经做过圆角裁剪，这里不再重复 ClipRRect。
      return _buildFor(context, fallback, isFallback: true);
    }
    return _fallback(context);
  }

  /// 帧后回调，避免 errorWidget 构建期间触发调用方 setState。
  void _notifyError(Object error) {
    final callback = onError;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(error));
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: fallbackColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget _fallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = fallbackIconSize ??
        (width != null && width!.isFinite ? width! * 0.5 : 24.0);
    return Container(
      width: width,
      height: height,
      color: fallbackColor ?? scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: MoliaMark(
        size: size,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
