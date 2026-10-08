import 'package:material_ui/material_ui.dart';

import 'app_network_image.dart';

/// 资料库通用封面缩略图（历史/列表曲目行）。
class LibraryCoverThumb extends StatelessWidget {
  final String? url;
  final double size;

  const LibraryCoverThumb({super.key, this.url, this.size = 44});

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
