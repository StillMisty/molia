/// 风格化封面展示：原图垫底 + 派生图淡入。
///
/// 为什么不是直接替换：处理是异步的（worker isolate + 取图），处理完成前必须
/// 显示原图，不能出现空白 / 阻塞；失败或省流无缓存时也保持原图。派生图只影响
/// 这一层像素，主题取色、下载、标签、系统媒体通知、查看原图都不经过这里。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/cover_style.dart';
import '../managers/artwork_cache.dart';
import '../services/covers/cover_style_cache.dart';
import '../theme/motion_policy.dart';
import 'app_network_image.dart';
import 'shell_page_visibility.dart';

/// 风格化封面组件（可注入 cache / source；测试不触网）。
class StyledCoverImage extends StatefulWidget {
  const StyledCoverImage({
    super.key,
    required this.url,
    required this.style,
    this.fallbackUrl,
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
    this.cache,
    this.edge,
  });

  /// 真实封面地址；null / 空串直接走原图 / 占位路径。
  final String? url;

  /// 目标风格；[CoverStyle.original] 时直接委托 [AppNetworkImage]。
  final CoverStyle style;

  /// 主图缺失 / 失败时的默认封面（默认封面本身不参与风格化）。
  final String? fallbackUrl;

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

  /// 测试可注入缓存；缺省读 Provider，再回退全局单例。
  final CoverStyleCache? cache;

  /// 派生图物理边长；缺省按显示尺寸 / 解码宽度推导后分桶。
  final int? edge;

  @override
  State<StyledCoverImage> createState() => _StyledCoverImageState();
}

class _StyledCoverImageState extends State<StyledCoverImage> {
  CoverStyleCache? _cache;
  Uint8List? _bytes;
  String? _requestedKey;
  int _resolvedEdgeValue = 512;
  bool _styledVisible = false;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ShellPageVisibility.maybeVisibleOf(context) ?? true);
    _bindCache();
    _startIfNeeded();
  }

  @override
  void didUpdateWidget(covariant StyledCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.style != widget.style ||
        oldWidget.edge != widget.edge ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height ||
        oldWidget.cache != widget.cache) {
      _requestedKey = null;
      _bytes = null;
      _styledVisible = false;
      _bindCache();
      _startIfNeeded();
    }
  }

  void _bindCache() {
    final cache =
        widget.cache ??
        context.read<CoverStyleCache?>() ??
        CoverStyleCache.instance;
    if (identical(cache, _cache)) return;
    _cache?.removeListener(_onCacheChanged);
    _cache = cache;
    _cache?.addListener(_onCacheChanged);
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final url = widget.url;
    if (url == null || url.isEmpty || !widget.style.isStylized) return;
    final cached = _cache?.peek(url, widget.style, _resolvedEdgeValue);
    if (cached == null || identical(cached, _bytes)) return;
    setState(() {
      _bytes = cached;
      _styledVisible = true;
    });
  }

  int _resolvedEdge(BuildContext context) {
    final explicit = widget.edge;
    if (explicit != null) return CoverStyleCache.bucketFor(explicit);
    final logical = math.max(
      _finite(widget.width),
      math.max(_finite(widget.height), 0.0),
    );
    if (logical > 0) {
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      return CoverStyleCache.edgeForLogical(logical, dpr);
    }
    final memWidth = widget.memCacheWidth;
    if (memWidth != null && memWidth > 0) {
      return CoverStyleCache.bucketFor(memWidth);
    }
    final memHeight = widget.memCacheHeight;
    if (memHeight != null && memHeight > 0) {
      return CoverStyleCache.bucketFor(memHeight);
    }
    return 512;
  }

  static double _finite(double? value) =>
      value != null && value.isFinite && value > 0 ? value : 0;

  void _startIfNeeded() {
    final url = widget.url;
    if (!widget.style.isStylized || url == null || url.isEmpty) return;
    if (!_visible) return;
    final cache = _cache;
    if (cache == null) return;
    final edge = _resolvedEdge(context);
    _resolvedEdgeValue = edge;
    final key = CoverStyleCache.keyFor(url, widget.style, edge);
    if (key == _requestedKey) return;
    _requestedKey = key;
    final cached = cache.peek(url, widget.style, edge);
    if (cached != null) {
      _bytes = cached;
      _styledVisible = true;
      return;
    }
    _bytes = null;
    _styledVisible = false;
    unawaited(
      cache.obtain(url, widget.style, edge: edge).then((bytes) {
        if (!mounted || key != _requestedKey) return;
        setState(() {
          _bytes = bytes;
          // 先以 opacity 0 挂上派生图，下一帧再抬到 1，让淡入真正发生。
          _styledVisible = false;
        });
        if (bytes != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || key != _requestedKey) return;
            setState(() => _styledVisible = true);
          });
        }
      }),
    );
  }

  @override
  void dispose() {
    _cache?.removeListener(_onCacheChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (!widget.style.isStylized || url == null || url.isEmpty) {
      return _original(context, widget.borderRadius);
    }
    final bytes = _bytes;
    if (bytes == null) return _original(context, widget.borderRadius);
    final radius = widget.borderRadius;
    final stack = Stack(
      fit: StackFit.passthrough,
      children: [
        _original(context, null),
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: _styledVisible ? 1 : 0,
            // 减弱动效：effectDurationOf 返回零时长，直接硬切。
            duration: effectDurationOf(context, M3EMotion.short4),
            curve: M3EMotion.emphasizedDecelerate,
            child: Image.memory(
              bytes,
              fit: widget.fit,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ],
    );
    return radius == null
        ? stack
        : ClipRRect(borderRadius: radius, child: stack);
  }

  Widget _original(BuildContext context, BorderRadius? radius) {
    return AppNetworkImage(
      url: widget.url,
      fallbackUrl: widget.fallbackUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      borderRadius: radius,
      memCacheWidth: widget.memCacheWidth,
      memCacheHeight: widget.memCacheHeight,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
      fallbackIconSize: widget.fallbackIconSize,
      fallbackColor: widget.fallbackColor,
      artworkCache: widget.artworkCache,
      onError: widget.onError,
    );
  }
}
