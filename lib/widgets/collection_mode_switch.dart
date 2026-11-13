import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/collection_mode.dart';
import '../services/haptics.dart';

/// 收藏 / 曲库页顶部的展示模式切换（歌曲 / 专辑 / 歌手）。
///
/// 单行分段控件，放在内容区标题之下；不放进左侧列表，也不新增导航入口。
class CollectionModeSwitch extends StatelessWidget {
  const CollectionModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final CollectionMode mode;
  final ValueChanged<CollectionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: M3ESegmentedButton<CollectionMode>(
        key: const Key('favoritesModeSwitch'),
        segments: [
          M3ESegment(
            value: CollectionMode.songs,
            label: l10n.collectionModeSongs,
          ),
          M3ESegment(
            value: CollectionMode.albums,
            label: l10n.collectionModeAlbums,
          ),
          M3ESegment(
            value: CollectionMode.artists,
            label: l10n.collectionModeArtists,
          ),
        ],
        selected: {mode},
        onSelectionChanged: (selection) {
          if (selection.isEmpty) return;
          HapticsService.lightImpact();
          onChanged(selection.first);
        },
      ),
    );
  }
}
