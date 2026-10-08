import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../domain/models/track.dart';
import '../providers/playback_provider.dart';
import '../l10n/app_localizations.dart';
import 'app_network_image.dart';
import 'molia_mark.dart';

/// 「正在播放」行所需的最小信息。
///
/// record（值语义）而非 Map：`context.select` 返回 Map/List 引用会因每次
/// 通知都是新对象而失效，导致无关 tick 也重建整个队列。
typedef _NowPlayingInfo = ({
  String name,
  String artist,
  String? coverUrl,
  bool isPlaying,
});

/// 播放队列：顶部「正在播放」高亮行 + 「接下来」列表。
///
/// 恢复态（冷启动未真正加载）同样可用：当前曲目来自会话快照，
/// 点击「接下来」条目会从该曲目恢复播放。
class QueueDisplay extends StatelessWidget {
  const QueueDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    // snapshot.upcoming 在同一快照内是稳定 List 实例：进度 tick / 无关通知
    // 不会重建队列列表，仅队列快照变化时重建。
    final currentQueue = context.select<PlaybackProvider, List<Track>>(
      (provider) => provider.snapshot.upcoming,
    );
    final nowPlaying =
        context.select<PlaybackProvider, _NowPlayingInfo?>(_selectNowPlaying);
    final playbackProvider = context.read<PlaybackProvider>();

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (nowPlaying != null) ...[
            _sectionLabel(context, l10n.nowPlayingSection),
            M3EListItem(
              selected: true,
              leading: _cover(context, nowPlaying.coverUrl, size: 44, radius: 10),
              headline: nowPlaying.name,
              supportingText: nowPlaying.artist,
              // 播放中 = 均衡器动效图形（primary 强调）；暂停 = 暂停图形。
              trailing: Icon(
                nowPlaying.isPlaying
                    ? Icons.graphic_eq_rounded
                    : Icons.pause_rounded,
                size: 20,
                color: nowPlaying.isPlaying
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              onTap: () {
                HapticFeedback.lightImpact();
                playbackProvider.togglePlayPause();
              },
            ),
            const SizedBox(height: 16),
          ],
          if (currentQueue.isNotEmpty) ...[
            _sectionLabel(context, l10n.upNextSection),
            M3ECard(
              variant: M3ECardVariant.filled,
              padding: EdgeInsets.zero,
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: currentQueue.length,
                separatorBuilder: (context, index) => const M3EDivider(),
                itemBuilder: (context, index) {
                  final track = currentQueue[index];
                  return M3EListItem(
                    leading: _cover(
                      context,
                      _coverUrlOf(track),
                      size: 40,
                      radius: 8,
                    ),
                    headline: track.title,
                    supportingText: _artistsOf(track),
                    trailingText: _formatDuration(track.duration),
                    onTap: () {
                      // 本地音源曲目：交给本地播放队列（恢复态自动续播）。
                      playbackProvider.playLocalQueueItemById(track.id.uri);
                    },
                  );
                },
              ),
            ),
          ] else if (nowPlaying == null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.currentQueueEmpty,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
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

  Widget _cover(
    BuildContext context,
    String? url, {
    required double size,
    required double radius,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: url == null
          ? Center(
              child: MoliaMark(
                size: size * 0.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : AppNetworkImage(
              url: url,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(radius),
              // 平台封面可能 403（防盗链）：统一组件内部带浏览器 UA/Referer，
              // 失败回退音符图标。
              fallbackIconSize: size * 0.5,
            ),
    );
  }

  /// 当前曲目 → 值语义 record（供 select 使用）。
  static _NowPlayingInfo? _selectNowPlaying(PlaybackProvider provider) {
    final track = provider.snapshot.current;
    if (track == null) return null;
    return (
      name: track.title,
      artist: _artistsOf(track),
      coverUrl: _coverUrlOf(track),
      isPlaying: provider.isPlaying,
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
