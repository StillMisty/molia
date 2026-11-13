/// 列表封面缩略图：只读 `CustomCoverStore` 的列表键，不伪造曲目身份。
///
/// 列表没有「默认封面」语义（默认封面是歌曲占位），缺图时显示中性列表图标；
/// 行内 `coverKey` 缺失但 syncId 可推导时，仍按 `playlist:<syncId>` 找到
/// 先到达的远端封面。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../services/covers/custom_cover_store.dart';
import 'app_network_image.dart';

class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.playlist,
    this.size = 40,
    this.borderRadius = 10,
  });

  /// 列表概要；[PlaylistInfo.effectiveCoverKey] 决定封面指针。
  final PlaylistInfo playlist;

  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<CustomCoverStore?>();
    final key = playlist.effectiveCoverKey;
    if (store == null || key == null) return _fallback(context);
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, _, _) {
        final url = store.playlistCoverUrl(key);
        if (url == null || url.isEmpty) return _fallback(context);
        return AppNetworkImage(
          url: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          borderRadius: BorderRadius.circular(borderRadius),
          errorWidget: _fallback(context),
          memCacheWidth: (size * MediaQuery.of(context).devicePixelRatio)
              .round(),
        );
      },
    );
  }

  Widget _fallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.queue_music_rounded,
        size: size * 0.55,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
