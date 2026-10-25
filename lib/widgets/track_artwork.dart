/// 封面渲染适配器：widget 层唯一订阅封面变化并渲染解析结果的地方。
///
/// 解析策略在 `services/covers/cover_resolution.dart`，这里只做两件事：
/// - 从 Provider（或全局单例）取 [CoverResolver]，**只订阅一次**变更信号，
///   自定义 / 默认封面替换后自动重建；
/// - 把展示封面拆成「真实主图 + 默认回退」交给 [AppNetworkImage]，保持原有
///   网络 / 本地文件、占位与失败回退语义不变。
///
/// 消费方不再各自 `ValueListenableBuilder(revision)` + `resolve...`：列表行、
/// 顶栏、播放器、AI DJ、歌曲信息页都通过 [TrackArtwork] 渲染。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../managers/artwork_cache.dart';
import '../services/covers/cover_resolution.dart';
import '../services/covers/custom_cover_store.dart';
import 'app_network_image.dart';

/// 当前 Provider 树里的封面解析器（没有注入时回退全局存储单例）。
CoverResolver coverResolverOf(BuildContext context) =>
    (context.read<CustomCoverStore?>() ?? CustomCoverStore.instance).resolution;

/// 订阅封面变化并重建的构建器（不渲染具体图片）。
///
/// 给「图片之外还有状态文案」的宿主使用（歌曲信息页 / 设置默认封面行 /
/// 封面弹层），这样这些页面也不需要手写 `revision.addListener`。
class CoverChangeBuilder extends StatefulWidget {
  const CoverChangeBuilder({
    super.key,
    required this.builder,
    this.listen = true,
  });

  final Widget Function(BuildContext context, CoverResolver covers) builder;

  /// false = 不订阅（外层已有订阅时避免重复监听）。
  final bool listen;

  @override
  State<CoverChangeBuilder> createState() => _CoverChangeBuilderState();
}

class _CoverChangeBuilderState extends State<CoverChangeBuilder> {
  CoverResolver? _covers;
  void Function()? _removeListener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covers = coverResolverOf(context);
    if (!identical(covers, _covers)) {
      _removeListener?.call();
      _removeListener = null;
      _covers = covers;
    }
    _syncListener();
  }

  @override
  void didUpdateWidget(covariant CoverChangeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listen != widget.listen) _syncListener();
  }

  void _syncListener() {
    final covers = _covers;
    if (!widget.listen || covers == null) {
      _removeListener?.call();
      _removeListener = null;
      return;
    }
    _removeListener ??= covers.addChangeListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _removeListener?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _covers ?? coverResolverOf(context));
  }
}

/// 曲目封面（展示语义）：自定义 > 原始 > 全局默认。
///
/// [track] 优先；没有领域曲目时用 [coverKey]（列表行的自定义封面查询键）
/// 或 [trackId] + [originalUrl]。默认封面只作为主图缺失 / 加载失败的回退，
/// 主图始终是真实封面（保证「远端封面坏了」看起来不是「有封面」）。
class TrackArtwork extends StatelessWidget {
  const TrackArtwork({
    super.key,
    this.track,
    this.trackId,
    this.coverKey,
    this.originalUrl,
    this.size,
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
    this.showDefaultCover = true,
    this.listenForChanges = true,
    this.artworkCache,
    this.onError,
  });

  /// 领域曲目（自带 id 与原始封面）。
  final Track? track;

  /// 只有 id 的场景（歌曲信息页 / 歌词页）。
  final TrackId? trackId;

  /// 字符串封面键（`TrackRowModel.effectiveCoverKey`，可带 `local:`）。
  final String? coverKey;

  /// 没有领域曲目时的原始封面 URL。
  final String? originalUrl;

  /// 正方形边长（同时作为宽高；[width] / [height] 显式给出时优先）。
  final double? size;

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

  /// 是否用全局默认封面兜底（歌曲面 true；头像 / 歌单等非曲目面不适用）。
  final bool showDefaultCover;

  /// 外层已有 [CoverChangeBuilder] 时置 false，避免重复订阅同一变更信号。
  final bool listenForChanges;

  /// 测试可注入自定义 ArtworkCache（透传 [AppNetworkImage]）。
  final ArtworkCache? artworkCache;

  /// 加载失败回调（透传 [AppNetworkImage]）。
  final void Function(Object error)? onError;

  bool get _hasQueryKey =>
      track != null ||
      trackId != null ||
      (coverKey != null && coverKey!.isNotEmpty);

  DisplayCover _resolve(CoverResolver covers) {
    final item = track;
    if (item != null) return covers.displayOf(item);
    final key = coverKey;
    if (key != null && key.isNotEmpty) {
      return covers.displayForKey(key, originalUrl: originalUrl);
    }
    final id = trackId;
    if (id != null) {
      return covers.displayForId(id, originalUrl: originalUrl);
    }
    // 没有曲目身份（默认封面缩略图 / 纯 URL）：只走原始 → 默认。
    return covers.displayForKey(null, originalUrl: originalUrl);
  }

  @override
  Widget build(BuildContext context) {
    return CoverChangeBuilder(
      // 没有查询键且不需要默认回退时，原始 URL 不会随封面索引变化。
      listen: listenForChanges && (showDefaultCover || _hasQueryKey),
      builder: (context, covers) {
        final display = _resolve(covers);
        return AppNetworkImage(
          url: display.primaryUrl,
          fallbackUrl: showDefaultCover ? display.defaultUrl : null,
          width: width ?? size,
          height: height ?? size,
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
      },
    );
  }
}
