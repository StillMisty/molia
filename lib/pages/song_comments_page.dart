/// 评论页：当前曲目的热门 / 最新评论（两个 tab + 分页 + 刷新）。
///
/// 入口：歌词快捷工具栏「评论」（收起态播放页）与播放器进度排「评论」
/// （展开态）；无曲目 / 渠道不支持评论时入口禁用。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/comment.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/comments_provider.dart';
import '../utils/responsive.dart';
import '../widgets/comment_list_view.dart';

/// 打开评论页（[track] 为入口处的当前曲目）。
Future<void> showSongCommentsPage(
  BuildContext context, {
  required Track track,
}) {
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: AppLocalizations.of(context)!.commentsTitle,
    body: SongCommentsPage(track: track, embedded: true),
  );
}

@visibleForTesting
class SongCommentsPage extends StatefulWidget {
  const SongCommentsPage({
    super.key,
    required this.track,
    this.embedded = false,
  });

  final Track track;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<SongCommentsPage> createState() => _SongCommentsPageState();
}

class _SongCommentsPageState extends State<SongCommentsPage> {
  static const List<CommentKind> _tabs = [
    CommentKind.hot,
    CommentKind.latest,
  ];

  late final CommentsProvider _provider = context.read<CommentsProvider>();

  late CommentKind _kind = CommentKind.hot;

  /// 已访问过的 tab：未访问过的页签不构建（打开热门 tab 不应请求最新评论）。
  late final Set<CommentKind> _visited = {CommentKind.hot};

  @override
  void initState() {
    super.initState();
    // open 会同步通知监听者；放到微任务里，避开本组件的首次 build。
    scheduleMicrotask(() {
      if (!mounted) return;
      unawaited(_provider.open(widget.track));
    });
  }

  @override
  void dispose() {
    // 关闭即结束会话：dispose 期间 widget 树处于锁定态，通知会触发
    // markNeedsBuild 断言；推迟到微任务清空，过期在途结果由会话 id 守卫丢弃。
    scheduleMicrotask(_provider.close);
    super.dispose();
  }

  void _selectTab(int index) {
    final kind = _tabs[index];
    setState(() {
      _kind = kind;
      _visited.add(kind);
    });
    unawaited(_provider.selectKind(kind));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<CommentsProvider>();
    final selectedIndex = _tabs.indexOf(_kind);

    final body = Column(
      children: [
        _buildTrackHeader(context, l10n, provider),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: M3ETabs(
            // 次 tab：图标在文案左侧同一行、行高 48（详情页内的分组切换）。
            variant: M3ETabsVariant.secondary,
            tabs: [
              M3ETab(
                icon: const Icon(Icons.local_fire_department_rounded),
                label: _tabLabel(
                  l10n,
                  CommentKind.hot,
                  provider.stateOf(CommentKind.hot).total,
                ),
              ),
              M3ETab(
                icon: const Icon(Icons.schedule_rounded),
                label: _tabLabel(
                  l10n,
                  CommentKind.latest,
                  provider.stateOf(CommentKind.latest).total,
                ),
              ),
            ],
            selectedIndex: selectedIndex,
            onTabSelected: _selectTab,
          ),
        ),
        Expanded(
          child: M3ETabsView(
            selectedIndex: selectedIndex,
            onTabSelected: _selectTab,
            children: [
              for (final kind in _tabs)
                if (_visited.contains(kind))
                  CommentListView(kind: kind)
                else
                  const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.commentsTitle),
        automaticallyImplyLeading: true,
      ),
      body: body,
    );
  }

  /// tab 文案：总数已知时带计数，未知时只显示标题。
  String _tabLabel(AppLocalizations l10n, CommentKind kind, int? total) {
    if (total == null) {
      return kind == CommentKind.hot
          ? l10n.commentsTabHot
          : l10n.commentsTabLatest;
    }
    return kind == CommentKind.hot
        ? l10n.commentsTabHotCount(total)
        : l10n.commentsTabLatestCount(total);
  }

  /// 头部：歌名 · 歌手（与换源页同构，明确评论对象）+ 刷新（窄屏与侧边
  /// 弹层共用同一入口，不再占 AppBar action）。
  Widget _buildTrackHeader(
    BuildContext context,
    AppLocalizations l10n,
    CommentsProvider provider,
  ) {
    final theme = Theme.of(context);
    final seed = widget.track;
    final artist = seed.artistLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Row(
        children: [
          Icon(
            Icons.comment_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              artist.isEmpty ? seed.title : '${seed.title} · $artist',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            semanticLabel: l10n.commentsRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: provider.isSupported
                ? () => unawaited(provider.refresh())
                : null,
          ),
        ],
      ),
    );
  }
}
