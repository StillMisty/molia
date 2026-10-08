import 'package:cached_network_image/cached_network_image.dart';
// flutter_cache_manager 是 cached_network_image 的传递依赖；图片组件需要
// 直接引用 CacheManager 类型。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:material_ui/material_ui.dart';

import '../managers/artwork_cache.dart';

/// 统一网络图片组件：封面/头像等所有远端图片都走这里。
///
/// - 请求头统一走 [ArtworkCache.headersFor]（浏览器 UA + 平台 Referer，
///   修复网易云 CDN 对 Dart UA 的 403）；
/// - 缓存统一走 [ArtworkCache] 的共享持久 CacheManager（封面分区策略）；
/// - 占位 / 失败默认回退到音符图标，调用方可覆盖；
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
    this.fallbackIcon = Icons.music_note_rounded,
    this.fallbackIconSize,
    this.fallbackColor,
    this.artworkCache,
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

  /// 加载失败回退（默认音符图标）。
  final Widget? errorWidget;

  final IconData fallbackIcon;
  final double? fallbackIconSize;
  final Color? fallbackColor;

  /// 测试可注入自定义 ArtworkCache（默认全局单例）。
  final ArtworkCache? artworkCache;

  @override
  Widget build(BuildContext context) {
    final imageUrl = url;
    final radius = borderRadius;
    Widget wrap(Widget child) =>
        radius == null ? child : ClipRRect(borderRadius: radius, child: child);

    if (imageUrl == null || imageUrl.isEmpty) {
      return wrap(_fallback(context));
    }

    final cache = artworkCache ?? ArtworkCache.instance;
    // 启动后 manager 已解析（常态）：直接构建，命中 ImageCache 时同步出帧。
    // 不能无条件走 FutureBuilder——它在 future 身份变化时会回到 waiting 渲染
    // 占位；切歌动画会逐帧重建封面，导致整个动画期间显示深色占位（「切歌黑图」）。
    final manager = cache.managerSync;
    if (manager != null) {
      return wrap(_buildImage(context, imageUrl, manager));
    }
    return wrap(
      FutureBuilder<CacheManager?>(
        // future 由 ArtworkCache 缓存、身份稳定，仅启动早期处于 waiting。
        future: cache.managerOrNull(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return placeholder ?? _placeholder(context);
          }
          return _buildImage(context, imageUrl, snapshot.data);
        },
      ),
    );
  }

  Widget _buildImage(
    BuildContext context,
    String imageUrl,
    CacheManager? manager,
  ) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      cacheManager: manager,
      httpHeaders: ArtworkCache.headersFor(imageUrl),
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: (_, __) => placeholder ?? _placeholder(context),
      errorWidget: (_, __, ___) => errorWidget ?? _fallback(context),
    );
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
      child: Icon(
        fallbackIcon,
        size: size,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
