import 'package:material_ui/material_ui.dart';

import '../services/covers/custom_cover_store.dart';
import 'app_network_image.dart';

/// 资料库通用封面缩略图（历史/列表曲目行）。
///
/// [useDefaultCover] 只给歌曲行使用：没有封面时显示设置里的默认封面。
/// 歌手 / 歌单 / 专辑头像不打开（默认封面只作用于歌曲封面）。
class LibraryCoverThumb extends StatelessWidget {
  final String? url;
  final double size;
  final bool useDefaultCover;

  const LibraryCoverThumb({
    super.key,
    this.url,
    this.size = 44,
    this.useDefaultCover = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!useDefaultCover) return _build(context, null);
    // 默认封面变化时缩略图立即刷新（自定义封面路径每次替换都会变，由
    // 调用方的曲目键解析负责）。
    return ValueListenableBuilder<int>(
      valueListenable: CustomCoverStore.instance.revision,
      builder: (context, _, __) =>
          _build(context, CustomCoverStore.instance.defaultCoverUrl),
    );
  }

  Widget _build(BuildContext context, String? fallbackUrl) {
    return AppNetworkImage(
      url: url,
      fallbackUrl: fallbackUrl,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(10),
      memCacheWidth: (size * MediaQuery.of(context).devicePixelRatio).round(),
      fallbackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      fallbackIconSize: size * 0.5,
    );
  }
}
