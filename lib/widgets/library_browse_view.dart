/// 专辑 / 歌手聚合浏览：分组列表 + 页内详情 + 重复版本展开。
///
/// 桌面宽屏为左右两栏（左分组 / 右详情），窄屏在同一个 widget 内切换列表 /
/// 详情（返回按钮）；不新增路由、不占用左侧合集列表。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library_browse.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../theme/m3e_context.dart';
import 'app_network_image.dart';
import 'collection_track_list.dart';
import 'desktop_layout.dart';
import 'empty_state.dart';
import 'row_actions.dart';
import 'track_row.dart';

/// 一个浏览分组（专辑或歌手），由页面从聚合索引投影。
class LibraryBrowseGroup {
  const LibraryBrowseGroup({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.tracks,
    this.coverUrl,
    this.icon,
  });

  final String key;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final IconData? icon;
  final List<BrowseTrack> tracks;
}

class LibraryBrowseView extends StatefulWidget {
  const LibraryBrowseView({
    super.key,
    required this.groups,
    required this.modeName,
    required this.query,
    required this.emptyTitle,
    required this.emptyBody,
    required this.searchEmpty,
    required this.selectHint,
    required this.resetSignature,
    required this.onPlay,
    required this.onPlayTrack,
    required this.onAdd,
    required this.onToggleFavorite,
    required this.isFavorite,
    required this.canRefreshLocal,
    required this.onRefreshLocal,
    required this.onSwap,
    this.twoPane = false,
  });

  final List<LibraryBrowseGroup> groups;
  final String modeName;
  final String query;
  final String emptyTitle;
  final String emptyBody;
  final String searchEmpty;
  final String selectHint;

  /// 模式 / 搜索 / 排序变化时清空重复版本展开。
  final String resetSignature;

  final Future<void> Function(
    LibraryBrowseGroup group,
    List<BrowseTrack> tracks, {
    bool shuffle,
  })
  onPlay;
  final Future<void> Function(BrowseTrack track) onPlayTrack;
  final Future<void> Function(List<BrowseTrack> tracks) onAdd;
  final Future<void> Function(BrowseTrack track) onToggleFavorite;
  final bool Function(BrowseTrack track) isFavorite;
  final bool Function(BrowseTrack track) canRefreshLocal;
  final Future<void> Function(BrowseTrack track) onRefreshLocal;
  final Future<void> Function(BrowseTrack track) onSwap;
  final bool twoPane;

  @override
  State<LibraryBrowseView> createState() => _LibraryBrowseViewState();
}

class _LibraryBrowseViewState extends State<LibraryBrowseView> {
  String? _selectedKey;
  final Set<String> _expanded = {};
  final Set<String> _selectedTracks = {};
  final ScrollController _listController = ScrollController();
  final ScrollController _detailController = ScrollController();

  @override
  void didUpdateWidget(covariant LibraryBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetSignature != widget.resetSignature) {
      _expanded.clear();
      _selectedTracks.clear();
    }
    if (_selectedKey != null &&
        !widget.groups.any((group) => group.key == _selectedKey)) {
      _selectedKey = null;
    }
  }

  @override
  void dispose() {
    _listController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = normalizeBrowseText(widget.query);
    final groups = [
      for (final group in widget.groups)
        if (query.isEmpty ||
            normalizeBrowseText(group.title).contains(query) ||
            normalizeBrowseText(group.subtitle).contains(query))
          group,
    ];
    final selected = _selectedKey;
    LibraryBrowseGroup? group;
    if (selected != null) {
      for (final item in groups) {
        if (item.key == selected) {
          group = item;
          break;
        }
      }
    }
    final detail = group == null
        ? null
        : _buildDetail(context, l10n, group, query);
    final pane = groups.isEmpty
        ? Center(
            child: EmptyState(
              icon: Icons.library_music_rounded,
              message: query.isEmpty ? widget.emptyTitle : widget.searchEmpty,
              hint: query.isEmpty ? widget.emptyBody : null,
            ),
          )
        : ListView.builder(
            key: ValueKey('browseGroups-${widget.modeName}'),
            controller: _listController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final item = groups[index];
              return M3EListItem(
                key: ValueKey('browseGroup-${item.key}'),
                leading: item.icon != null
                    ? Icon(item.icon)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: AppNetworkImage(
                          url: item.coverUrl,
                          width: 44,
                          height: 44,
                          fallbackIconSize: 20,
                        ),
                      ),
                headline: item.title,
                trailingText: '${item.tracks.length}',
                selected: selected == item.key,
                onTap: () => setState(() => _selectedKey = item.key),
              );
            },
          );
    if (!widget.twoPane) {
      return detail ?? pane;
    }
    return Row(
      children: [
        SizedBox(width: DesktopLayout.browseGroupPaneWidth, child: pane),
        const M3EDivider(axis: M3EDividerAxis.vertical),
        Expanded(
          child: group == null
              ? Center(
                  child: EmptyState(
                    icon: Icons.album_rounded,
                    message: widget.selectHint,
                  ),
                )
              : detail!,
        ),
      ],
    );
  }

  Widget _buildDetail(
    BuildContext context,
    AppLocalizations l10n,
    LibraryBrowseGroup group,
    String query,
  ) {
    final normalized = normalizeBrowseText(query);
    final filtered = [
      for (final track in group.tracks)
        if (normalized.isEmpty ||
            normalizeBrowseText(track.title).contains(normalized) ||
            normalizeBrowseText(track.artist).contains(normalized) ||
            normalizeBrowseText(track.album).contains(normalized))
          track,
    ];
    final duplicates = groupDuplicates(filtered);
    final representativeOf = <String, String>{};
    final versionsByRep = <String, List<BrowseTrack>>{};
    for (final duplicate in duplicates) {
      final rep = duplicate.representative.key;
      versionsByRep[rep] = duplicate.versions;
      for (final version in duplicate.versions) {
        representativeOf[version.key] = rep;
      }
    }
    final rows = <_BrowseDisplayRow>[];
    for (final track in filtered) {
      if (representativeOf[track.key] != track.key) continue;
      final versions = versionsByRep[track.key] ?? const <BrowseTrack>[];
      rows.add(
        _BrowseDisplayRow(
          track: track,
          versionCount: versions.length,
          isVersion: false,
        ),
      );
      if (_expanded.contains(track.key)) {
        for (final version in versions) {
          if (version.key == track.key) continue;
          rows.add(
            _BrowseDisplayRow(track: version, versionCount: 0, isVersion: true),
          );
        }
      }
    }
    final representatives = [
      for (final track in filtered)
        if (representativeOf[track.key] == track.key) track,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.arrow_back_rounded),
                semanticLabel: l10n.backButton,
                onPressed: () => setState(() => _selectedKey = null),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  group.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.titleMedium,
                ),
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.play_arrow_rounded),
                semanticLabel: l10n.playAll,
                onPressed: representatives.isEmpty
                    ? null
                    : () => widget.onPlay(group, representatives),
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.shuffle_rounded),
                semanticLabel: l10n.playAllShuffled,
                onPressed: representatives.isEmpty
                    ? null
                    : () =>
                          widget.onPlay(group, representatives, shuffle: true),
              ),
              if (_selectedTracks.isNotEmpty)
                M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(Icons.close_rounded),
                  semanticLabel: l10n.cancel,
                  onPressed: () => setState(_selectedTracks.clear),
                ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.playlist_add_rounded),
                semanticLabel: l10n.addToPlaylist,
                onPressed: representatives.isEmpty
                    ? null
                    : () => widget.onAdd(
                        _selectedTracks.isEmpty
                            ? representatives
                            : [
                                for (final track in filtered)
                                  if (_selectedTracks.contains(track.key))
                                    track,
                              ],
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: EmptyState(
                    icon: Icons.music_note_rounded,
                    message: widget.searchEmpty,
                  ),
                )
              : ListView.builder(
                  controller: _detailController,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final favorite = widget.isFavorite(row.track);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: CollectionTrackRow(
                        row: TrackRowModel(
                          title: row.track.title,
                          artist: row.track.artist,
                          album: row.track.album,
                          coverUrl: row.track.coverUrl,
                          durationMs: row.track.durationMs,
                          trackId: TrackId(
                            row.track.sourceKey,
                            row.track.songId,
                          ),
                          selected: _selectedTracks.contains(row.track.key),
                        ),
                        position: M3ECardPosition.single,
                        trailing: row.versionCount > 1
                            ? M3EButton.text(
                                key: ValueKey('versions-${row.track.key}'),
                                onPressed: () => setState(() {
                                  if (!_expanded.remove(row.track.key)) {
                                    _expanded.add(row.track.key);
                                  }
                                }),
                                child: Text(
                                  l10n.duplicateVersions(row.versionCount),
                                ),
                              )
                            : null,
                        onTap: () {
                          if (_selectedTracks.isNotEmpty) {
                            setState(() {
                              if (!_selectedTracks.remove(row.track.key)) {
                                _selectedTracks.add(row.track.key);
                              }
                            });
                            return;
                          }
                          widget.onPlayTrack(row.track);
                        },
                        onLongPress: () => setState(() {
                          if (!_selectedTracks.remove(row.track.key)) {
                            _selectedTracks.add(row.track.key);
                          }
                        }),
                        actions: [
                          RowAction(
                            icon: Icons.playlist_add_rounded,
                            label: l10n.addToPlaylist,
                            onPressed: () => widget.onAdd([row.track]),
                          ),
                          RowAction(
                            icon: favorite
                                ? Icons.heart_broken_rounded
                                : Icons.favorite_border_rounded,
                            label: favorite
                                ? l10n.favoriteRemove
                                : l10n.favoriteAdd,
                            onPressed: () => widget.onToggleFavorite(row.track),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _BrowseDisplayRow {
  const _BrowseDisplayRow({
    required this.track,
    required this.versionCount,
    required this.isVersion,
  });

  final BrowseTrack track;
  final int versionCount;
  final bool isVersion;
}
