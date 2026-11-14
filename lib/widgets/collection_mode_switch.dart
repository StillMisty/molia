import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/collection_mode.dart';
import '../services/haptics.dart';

/// 曲库合集内的展示模式切换（专辑 / 歌手）。
///
/// 只在「曲库」视图出现：收藏 / 历史 / 本地歌曲 / 自建列表是纯列表，
/// 不再有模式行。控件按内容宽度左对齐，不横跨整行。
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
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: M3ESegmentedButton<CollectionMode>(
        key: const Key('libraryBrowseModeSwitch'),
        segments: [
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
