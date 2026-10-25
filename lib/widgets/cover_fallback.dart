/// 封面回退构建器（播放页 / 顶栏 / 迷你条 / 飞行副本共用）。
///
/// 抽成独立文件是为了打破 `player_cover_deck.dart` 与 `now_playing_summary.dart`
/// 之间的循环：两端都要用同一份「无封面长什么样」，但都不需要对方的渲染。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../providers/playback_provider.dart';
import '../services/covers/cover_resolution.dart';
import '../utils/playback_cover_decode.dart';
import 'app_network_image.dart';
import 'molia_mark.dart';
import 'track_artwork.dart';

/// 无封面 / 回退图也失败时的最终占位：主题容器色背景 + Molia 标志。
///
/// 默认封面自身的加载失败也落到这里（[buildFallbackArtwork] 只在这里画
/// 标志），因此不会递归重试默认封面。
Widget _buildMoliaMark(
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

/// 构建回退封面：全局默认封面优先，没有（或加载失败）时用 Molia 标志。
///
/// [iconSize] 供共享元素飞行副本按两端真身插值（默认 64 = 卡片级占位）。
/// 默认封面是「歌曲没有封面」的占位；这里刻意不回落最后播放封面——当前
/// 曲目缺图时显示上一首的封面会被误读成当前曲目的封面。
Widget buildFallbackArtwork(
  BuildContext context, {
  Key? key,
  double iconSize = 64,
}) {
  return CoverChangeBuilder(
    builder: (context, covers) => _buildFallbackArtwork(
      context,
      covers,
      key: key,
      iconSize: iconSize,
    ),
  );
}

Widget _buildFallbackArtwork(
  BuildContext context,
  CoverResolver covers, {
  Key? key,
  required double iconSize,
}) {
  final defaultCoverUrl = covers.defaultCoverUrl;
  final mark = _buildMoliaMark(
    context,
    key: key ?? const ValueKey('default_image'),
    iconSize: iconSize,
  );
  if (defaultCoverUrl == null) return mark;
  return AppNetworkImage(
    key: key ?? const ValueKey('default_cover_image'),
    url: defaultCoverUrl,
    fit: BoxFit.cover,
    fallbackIconSize: iconSize,
    memCacheWidth: playbackCoverDecodeEdge(context),
    errorWidget: mark,
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
  return CoverChangeBuilder(
    builder: (context, covers) => _buildDefaultArtwork(
      context,
      covers,
      key: key,
      fit: fit,
      iconSize: iconSize,
    ),
  );
}

Widget _buildDefaultArtwork(
  BuildContext context,
  CoverResolver covers, {
  Key? key,
  required BoxFit fit,
  required double iconSize,
}) {
  final defaultCoverUrl = covers.defaultCoverUrl;
  final lastPlayedImageUrl =
      context.read<PlaybackProvider?>()?.lastPlayedImageUrl;
  final fallback = lastPlayedImageUrl != null
      ? AppNetworkImage(
          key: key ?? const ValueKey('last_played_image'),
          url: lastPlayedImageUrl,
          fit: fit,
          fallbackIconSize: iconSize,
          memCacheWidth: playbackCoverDecodeEdge(context),
          errorWidget: _buildMoliaMark(
            context,
            key: key,
            iconSize: iconSize,
          ),
        )
      : _buildMoliaMark(
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
