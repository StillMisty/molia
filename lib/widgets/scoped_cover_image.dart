/// 非曲目封面（专辑 / 歌手 / 歌单 / 发现）的展示入口。
///
/// 只有「所有封面图片」范围才派生风格图；「仅播放中」只处理当前曲目，
/// 这些图片保持原图。封面选择器、海报预览与导出、默认封面、查看原图
/// 不经过这里，始终使用原始封面。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/cover_style.dart';
import '../managers/artwork_cache.dart';
import '../services/covers/cover_style_cache.dart';
import '../services/covers/cover_style_settings.dart';
import 'app_network_image.dart';
import 'styled_cover_image.dart';

/// 按封面风格范围展示非曲目封面。
///
/// Provider 缺失（独立挂载 / 旧测试）或缓存不可用时回退原图，不抛异常；
/// 与 [StyledCoverImage] 的「处理失败保持原图」语义一致。
class ScopedCoverImage extends StatelessWidget {
  const ScopedCoverImage({
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
    this.fallbackIconSize,
    this.fallbackColor,
    this.artworkCache,
    this.onError,
    this.edge,
  });

  /// 真实封面地址；null / 空串直接走原图占位路径。
  final String? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Widget? placeholder;
  final Widget? errorWidget;
  final double? fallbackIconSize;
  final Color? fallbackColor;
  final ArtworkCache? artworkCache;
  final void Function(Object error)? onError;

  /// 派生图物理边长；缺省按显示尺寸 / 解码宽度推导后分桶。
  final int? edge;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<CoverStyleSettings?>();
    final cache = context.read<CoverStyleCache?>();
    final style = settings == null || settings.scope != CoverStyleScope.all
        ? CoverStyle.original
        : settings.style;
    final source = url;
    if (source == null ||
        source.isEmpty ||
        !style.isStylized ||
        cache == null) {
      return AppNetworkImage(
        url: url,
        width: width,
        height: height,
        fit: fit,
        borderRadius: borderRadius,
        memCacheWidth: memCacheWidth,
        memCacheHeight: memCacheHeight,
        placeholder: placeholder,
        errorWidget: errorWidget,
        fallbackIconSize: fallbackIconSize,
        fallbackColor: fallbackColor,
        artworkCache: artworkCache,
        onError: onError,
      );
    }
    return StyledCoverImage(
      url: source,
      style: style,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: placeholder,
      errorWidget: errorWidget,
      fallbackIconSize: fallbackIconSize,
      fallbackColor: fallbackColor,
      artworkCache: artworkCache,
      onError: onError,
      cache: cache,
      edge: edge,
    );
  }
}
