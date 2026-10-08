import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../widgets/app_network_image.dart';
import '../widgets/discover_actions.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现详情页（热榜 / 歌单共用）：
/// - 头部：封面、名称、作者 / 播放量 / 曲目数、简介；
/// - 曲目：播放全部 / 单曲播放 / 收藏 / 加入列表。
///
/// [loader] 由入口注入（榜单曲目或歌单详情），页面自管加载态与错误态。
class DiscoverTracksPage extends StatefulWidget {
  final String title;

  /// 打开时已知的封面（歌单卡片点击进入时避免头部闪烁）。
  final String? coverUrl;

  final Future<DiscoverDetail> Function() loader;

  /// 是否提供「导入到我的列表」（歌单支持；榜单不提供）。
  final bool importable;

  const DiscoverTracksPage({
    super.key,
    required this.title,
    required this.loader,
    this.coverUrl,
    this.importable = false,
  });

  @override
  State<DiscoverTracksPage> createState() => _DiscoverTracksPageState();
}

class _DiscoverTracksPageState extends State<DiscoverTracksPage> {
  DiscoverDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final detail = await widget.loader();
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  void _playFrom(int index) {
    final detail = _detail;
    if (detail == null || detail.tracks.isEmpty) return;
    HapticFeedback.lightImpact();
    context.read<DiscoverProvider>().playTracks(
          detail.tracks,
          index,
          contextName: detail.info.name.isEmpty
              ? widget.title
              : detail.info.name,
        );
  }

  /// 把当前歌单导入本地列表（同名列表复用）。
  Future<void> _importPlaylist() async {
    final detail = _detail;
    if (detail == null) return;
    final l10n = _l10n(context);
    if (detail.tracks.isEmpty) {
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
      return;
    }
    try {
      final result = await context
          .read<DiscoverProvider>()
          .importDetailToLibrary(detail, fallbackName: widget.title);
      if (!mounted) return;
      M3ESnackbar.show(
        context,
        message: result.added > 0
            ? l10n.libraryImportSuccess(result.added)
            : l10n.playlistAlreadyContains,
      );
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        automaticallyImplyLeading: true,
        actions: [
          if (widget.importable && detail != null && detail.tracks.isNotEmpty)
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: _l10n(context).playlistImportToMine,
              icon: const Icon(Icons.download_rounded),
              onPressed: _importPlaylist,
            ),
          if (detail != null && detail.tracks.isNotEmpty)
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: _l10n(context).playAll,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => _playFrom(0),
            ),
        ],
      ),
      body: _buildBody(context, detail),
    );
  }

  Widget _buildBody(BuildContext context, DiscoverDetail? detail) {
    final l10n = _l10n(context);
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_failed || detail == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.discoverLoadFailed,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: _load,
              child: Text(l10n.discoverRetry),
            ),
          ],
        ),
      );
    }
    if (detail.tracks.isEmpty) {
      return Center(
        child: Text(
          l10n.discoverNoContent,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: detail.tracks.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildHeader(context, detail);
        }
        final trackIndex = index - 1;
        return DiscoverTrackTile(
          track: detail.tracks[trackIndex],
          onTap: () => _playFrom(trackIndex),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, DiscoverDetail detail) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final info = detail.info;
    final cover = info.coverUrl ?? widget.coverUrl;
    final subtitleParts = <String>[
      if (info.author.isNotEmpty) l10n.discoverPlaylistAuthor(info.author),
      if (info.playCount > 0) l10n.discoverPlayCount(info.playCountText),
      l10n.playlistTrackCount(detail.tracks.length),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: (cover?.isNotEmpty ?? false)
                      ? AppNetworkImage(
                          url: cover,
                          fit: BoxFit.cover,
                          placeholder: ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                          ),
                          errorWidget: ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.queue_music_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.queue_music_rounded,
                            size: 40,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name.isEmpty ? widget.title : info.name,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitleParts.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((info.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              info.description!.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: M3EButton.icon(
              style: M3EButtonStyle.filled,
              onPressed: () => _playFrom(0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.playAll),
            ),
          ),
        ],
      ),
    );
  }
}
