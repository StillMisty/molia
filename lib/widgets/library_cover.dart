import 'package:material_ui/material_ui.dart';

import 'app_network_image.dart';

/// 通用封面缩略图（歌手 / 歌单 / 专辑头像与非曲目行）。
///
/// **不再承担曲目封面策略**：曲目行请用 `TrackArtwork`（自定义封面 +
/// 默认封面 + 变更订阅都在适配器内）。这里只按给定 URL 渲染方块缩略图。
class LibraryCoverThumb extends StatelessWidget {
  final String? url;
  final double size;

  const LibraryCoverThumb({
    super.key,
    this.url,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return AppNetworkImage(
      url: url,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(10),
      memCacheWidth: (size * MediaQuery.of(context).devicePixelRatio).round(),
      fallbackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      fallbackIconSize: size * 0.5,
    );
  }
}
