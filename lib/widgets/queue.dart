import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import 'track_row.dart';

/// 播放队列：只列出当前曲目之后的「接下来」。
///
/// 当前播放曲目由上方播放器承载（封面/标题/进度），列表里不再重复一行。
/// 懒加载：`SliverFixedExtentList` + [TrackRow] 固定行高，队列再长也只构建
/// 视口附近的行、只请求视口内的封面；固定 extent 让滚动条拇指尺寸与拖动
/// 定位精确（`interactive` + `thumbVisibility`，可手按住拖动）。
///
/// 恢复态（冷启动未真正加载）同样可用：点击「接下来」条目会从该曲目恢复播放。
class QueueDisplay extends StatelessWidget {
  const QueueDisplay({
    super.key,
    required this.controller,
    this.topPadding = 0,
  });

  /// 队列滚动控制器（滚动条与父页面「滑到顶下拉收起」共用）。
  final ScrollController controller;

  /// 内容顶部额外留白（播放页圆点过渡带）。
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cardRadius = M3ETheme.of(context).cardTheme.radius;

    // snapshot.upNext 在同一快照内是稳定 List 实例：进度 tick / 无关通知
    // 不会重建队列列表，仅队列快照变化时重建；shuffle 时即洗牌排列剩余。
    final currentQueue = context.select<PlaybackProvider, List<Track>>(
      (provider) => provider.snapshot.upNext,
    );
    final playbackProvider = context.read<PlaybackProvider>();

    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(24, topPadding, 24, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (currentQueue.isNotEmpty)
                    _sectionLabel(context, l10n.upNextSection),
                ],
              ),
            ),
          ),
          if (currentQueue.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 1px 分隔线：固定 extent，滚动条拖动一次定位。
                itemExtent: TrackRow.extent + 1,
                itemCount: currentQueue.length,
                itemBuilder: (context, index) {
                  final track = currentQueue[index];
                  final isLast = index == currentQueue.length - 1;
                  return Column(
                    children: [
                      TrackRow(
                        title: track.title,
                        artist: _artistsOf(track),
                        coverUrl: _coverUrlOf(track),
                        coverSize: 40,
                        radius: _trackRadius(cardRadius, index, currentQueue.length),
                        trailingText: _formatDuration(track.duration),
                        onTap: () {
                          // 本地音源曲目：交给本地播放队列（恢复态自动续播）。
                          playbackProvider
                              .playLocalQueueItemById(track.id.uri);
                        },
                      ),
                      if (!isLast) const M3EDivider(),
                    ],
                  );
                },
              ),
            )
          else
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.currentQueueEmpty,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  /// 整组首/末行取卡片圆角，中间行直角拼成一张连续卡片。
  BorderRadius _trackRadius(double radius, int index, int count) {
    if (count <= 1) return BorderRadius.circular(radius);
    if (index == 0) {
      return BorderRadius.vertical(top: Radius.circular(radius));
    }
    if (index == count - 1) {
      return BorderRadius.vertical(bottom: Radius.circular(radius));
    }
    return BorderRadius.zero;
  }

  /// 分组标签：与列表行文字同一文本契约（次要信息用 onSurfaceVariant）。
  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  static String? _coverUrlOf(Track track) {
    final url = track.artwork?.uri.toString();
    return url == null || url.isEmpty ? null : url;
  }

  static String _artistsOf(Track track) => track.artists
      .map((artist) => artist.name)
      .where((name) => name.isNotEmpty)
      .join(', ');

  String _formatDuration(Duration? duration) {
    final value = duration ?? Duration.zero;
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
