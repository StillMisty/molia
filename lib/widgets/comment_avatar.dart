/// 评论头像：空地址 / 加载失败时回退人像图标，瞬时失败自动重试一次。
///
/// 平台经常返回空头像（酷我 `u_pic`、QQ 最新楼中楼），若沿用封面的品牌
/// 标志回退，会让正常的「没有头像」看起来像图片加载失败。这里统一用人像
/// 占位，并对真正的网络失败做一次延迟重试。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../managers/artwork_cache.dart';
import 'app_network_image.dart';

class CommentAvatar extends StatefulWidget {
  const CommentAvatar({
    super.key,
    required this.url,
    required this.size,
    this.artworkCache,
  });

  /// 头像地址；null / 空串直接显示人像占位，不触网。
  final String? url;

  final double size;

  /// 测试可注入自定义 ArtworkCache（默认全局单例）。
  final ArtworkCache? artworkCache;

  @override
  State<CommentAvatar> createState() => _CommentAvatarState();
}

class _CommentAvatarState extends State<CommentAvatar> {
  /// 只自动重试一次：网络抖动时给第二次机会，持续失败则回退人像。
  static const int _maxRetries = 1;
  static const Duration _retryDelay = Duration(milliseconds: 700);

  int _attempt = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(CommentAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _attempt = 0;
      _retryScheduled = false;
    }
  }

  void _handleError(Object error) {
    if (_retryScheduled || _attempt >= _maxRetries) return;
    // 省流模式明确要求不发网络请求，重试只会得到同一个结果。
    if (error is ArtworkNetworkBlockedException) return;
    final failedUrl = widget.url;
    _retryScheduled = true;
    unawaited(
      Future<void>.delayed(_retryDelay, () {
        if (!mounted || widget.url != failedUrl) return;
        setState(() {
          _attempt += 1;
          _retryScheduled = false;
        });
      }),
    );
  }

  Widget _fallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.person_rounded,
        size: widget.size * 0.55,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null || url.isEmpty) return _fallback(context);
    return AppNetworkImage(
      // 重试时换 key 重建 CachedNetworkImage，避免沿用上一次的失败状态。
      key: ValueKey('$url#$_attempt'),
      url: url,
      width: widget.size,
      height: widget.size,
      borderRadius: BorderRadius.circular(widget.size / 2),
      artworkCache: widget.artworkCache,
      placeholder: _fallback(context),
      errorWidget: _fallback(context),
      onError: _handleError,
    );
  }
}
