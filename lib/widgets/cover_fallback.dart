/// 封面回退构建器（播放页 / 顶栏 / 迷你条 / 飞行副本共用）。
///
/// 抽成独立文件是为了打破 `player_cover_deck.dart` 与 `now_playing_summary.dart`
/// 之间的循环：两端都要用同一份「无封面长什么样」，但都不需要对方的渲染。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../providers/playback_provider.dart';
import '../services/covers/custom_cover_store.dart';
import '../utils/playback_cover_decode.dart';
import 'app_network_image.dart';
import 'molia_mark.dart';

/// 无封面 / 回退图也失败时的中性占位：主题容器色背景 + Molia 标志。
///
/// [iconSize] 供共享元素飞行副本按两端真身插值（默认 64 = 卡片级占位）。
Widget buildFallbackArtwork(
  BuildContext context, {
  Key? key,
  double iconSize = 64,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    key: key,
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: MoliaMark(size: iconSize, color: scheme.onSurfaceVariant),
  );
}

/// 构建默认 / 回退封面：全局默认封面优先；没有（或加载失败）时用持久化的
/// 最后播放封面，再回退到中性占位。
///
/// [iconSize] 透传给回退图标（飞行副本按进度插值；默认 64 不变）。
Widget buildDefaultArtwork(
  BuildContext context, {
  Key? key,
  BoxFit fit = BoxFit.cover,
  double iconSize = 64,
}) {
  final defaultCoverUrl = CustomCoverStore.instance.defaultCoverUrl;
  final lastPlayedImageUrl = context
      .read<PlaybackProvider?>()
      ?.lastPlayedImageUrl;
  final fallback = lastPlayedImageUrl != null
      ? AppNetworkImage(
          key: key ?? const ValueKey('last_played_image'),
          url: lastPlayedImageUrl,
          fit: fit,
          fallbackIconSize: iconSize,
          memCacheWidth: playbackCoverDecodeEdge(context),
          errorWidget: buildFallbackArtwork(
            context,
            key: key,
            iconSize: iconSize,
          ),
        )
      : buildFallbackArtwork(
          context,
          key: key ?? const ValueKey('default_image'),
          iconSize: iconSize,
        );

  if (defaultCoverUrl == null) return fallback;
  return AppNetworkImage(
    key: key ?? const ValueKey('default_cover_image'),
    url: defaultCoverUrl,
    fit: fit,
    fallbackIconSize: iconSize,
    memCacheWidth: playbackCoverDecodeEdge(context),
    errorWidget: fallback,
  );
}
