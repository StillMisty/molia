import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'row_actions.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';

/// 封面地址：缺失 / 空串返回 null（行内不占位）。
String? _coverUrlOf(Track track) {
  final url = track.artwork?.uri.toString();
  return url == null || url.isEmpty ? null : url;
}

/// 播放队列：只列出当前曲目之后的曲目。
///
/// 当前播放曲目由上方播放器承载（封面/标题/进度），列表里不重复这一行；
/// 桌面队列面板（[QueueDisplay.includeCurrent]）需要在面板顶部展示当前曲目，
/// 此时在列表之前补一段高亮、不可点的「正在播放」小节。
/// 懒加载：`SliverFixedExtentList` + [TrackRow] 固定行高，队列再长也只构建
/// 视口附近的行、只请求视口内的封面；固定 extent 让滚动条拇指尺寸与拖动
/// 定位精确（`interactive` + `thumbVisibility`，可手按住拖动）。
///
/// 恢复态（冷启动未真正加载）同样可用：点击条目会从该曲目恢复播放。
///
/// 列表不再分「正在播放 / 接下来」两段小标题：面板本身就是队列
/// （tab 文案已说明分组），标题只会把首行往下推。
class QueueDisplay extends StatelessWidget {
  const QueueDisplay({
    super.key,
    required this.controller,
    this.topPadding = 0,
    this.includeCurrent = false,
  });

  /// 队列滚动控制器（滚动条与父页面「滑到顶下拉收起」共用）。
  final ScrollController controller;

  /// 内容顶部额外留白（播放页圆点过渡带 / 桌面版式 tab 栏下的内容间距）。
  final double topPadding;

  /// 队列面板（桌面右栏）用：顶部补一行「正在播放」（当前曲目，高亮、不可点）。
  ///
  /// 播放页版面里当前曲目由播放器承载，保持 false 不重复展示。
  final bool includeCurrent;

  /// 「正在播放」小节与队列列表之间的空气：比行距大，避免两段视觉上粘成一段。
  static const double _sectionSpacing = 16;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cardList = M3ETheme.of(context).listTheme.cardList;

    // snapshot.upNext 在同一快照内是稳定 List 实例：进度 tick / 无关通知
    // 不会重建队列列表，仅队列快照变化时重建；shuffle 时即洗牌排列剩余。
    final currentQueue = context.select<PlaybackProvider, List<Track>>(
      (provider) => provider.snapshot.upNext,
    );
    // 当前曲目只归「正在播放」小节；播放页版式不订阅，避免无关重建。
    final Track? current = includeCurrent
        ? context.select<PlaybackProvider, Track?>(
            (provider) => provider.snapshot.current,
          )
        : null;
    final playbackProvider = context.read<PlaybackProvider>();

    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          // 「正在播放」小节（无当前曲目时整段不存在）。
          if (current != null)
            SliverPadding(
              // 左右 16 与 tab 栏 / 其它内容同一内容边距（M3E 口径）。
              padding: EdgeInsets.fromLTRB(16, topPadding, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sectionLabel(context, l10n.queuePanelNowPlaying),
                    // 当前曲目：高亮但不翻选中勾，也不响应点击——它本身就是
                    // 正在播放的进度行，重复装载同一曲目没有意义。
                    TrackRow(
                      model: TrackRowModel(
                        title: current.title,
                        artist: current.artistLabel,
                        coverUrl: _coverUrlOf(current),
                        durationMs: current.duration?.inMilliseconds,
                        selected: true,
                      ),
                      surface: const TrackRowSurface(
                        coverSize: 40,
                        showCheckWhenSelected: false,
                      ),
                      // 单行小节 = 四周外圆角（calculateCardPosition(0, 1) 约定）。
                      position: M3ECardPosition.single,
                    ),
                  ],
                ),
              ),
            ),
          if (currentQueue.isNotEmpty)
            SliverPadding(
              // 有「正在播放」段时用小节间距分隔两段；否则沿用顶部留白
              // （播放页圆点过渡带 / tab 栏下的内容间距）。
              padding: EdgeInsets.fromLTRB(
                16,
                current != null ? _sectionSpacing : topPadding,
                16,
                0,
              ),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，滚动条拖动一次定位。
                itemExtent: TrackRow.extent + cardList.gap,
                itemCount: currentQueue.length,
                itemBuilder: (context, index) {
                  final track = currentQueue[index];
                  final isLast = index == currentQueue.length - 1;
                  return Column(
                    children: [
                      _QueueTrackRow(
                        track: track,
                        position:
                            calculateCardPosition(index, currentQueue.length),
                        onTap: () {
                          // 本地音源曲目：交给本地播放队列（恢复态自动续播）。
                          playbackProvider.playLocalQueueItemById(track.id.uri);
                        },
                      ),
                      if (!isLast) SizedBox(height: cardList.gap),
                    ],
                  );
                },
              ),
            )
          else if (current == null)
            // 空态只在整块面板没有任何行时出现：「正在播放」段存在时队列为空
            // 只是「播放顺序走完」，不是空面板（空态文案会误导）。
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

  /// 分组标签：与列表行文字同一文本契约（次要信息用 onSurfaceVariant）。
  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        text,
        style: context.typeScale.labelMedium.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 队列行：行内容 + 桌面的行表面右键菜单（收藏开关 / 加入列表，
/// 与搜索结果行共用 [trackRowActionMenuForTrack]）。
///
/// 入口分平台：桌面端行表面右键在落点弹菜单；触摸端队列行无 ⋮、无右键
/// （维持现状）。桌面判定挡在动作定义之前——[trackRowActionMenuForTrack]
/// 含逐行 `select` 订阅，触摸端不需要这份订阅。
class _QueueTrackRow extends StatelessWidget {
  const _QueueTrackRow({
    required this.track,
    required this.position,
    required this.onTap,
  });

  final Track track;
  final M3ECardPosition position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final actions = isDesktopPlatform()
        ? trackRowActionMenuForTrack(context, track)
        : const <RowAction>[];
    return TrackRow(
      model: TrackRowModel(
        title: track.title,
        artist: track.artistLabel,
        coverUrl: _coverUrlOf(track),
        durationMs: track.duration?.inMilliseconds,
      ),
      surface: const TrackRowSurface(coverSize: 40),
      position: position,
      onTap: onTap,
      onSecondaryTap: rowActionsAtPointer(context, actions),
    );
  }
}
