/// 列表头部唯一溢出菜单：低频动作集中在这里，不占常驻工具栏。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

class PlaylistHeaderOverflow extends StatelessWidget {
  const PlaylistHeaderOverflow({
    super.key,
    required this.onEditDetails,
    required this.onChangeCover,
    required this.onExport,
    this.onDownloadAll,
  });

  final VoidCallback onEditDetails;
  final VoidCallback onChangeCover;
  final VoidCallback onExport;

  /// 不可下载 / 没有曲目时为 null（入口隐藏）。
  final VoidCallback? onDownloadAll;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EIconButton(
        key: const Key('playlistHeaderOverflow'),
        variant: M3EIconButtonVariant.standard,
        semanticLabel: l10n.playlistDetails,
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: open,
      ),
      onSelected: (value) {
        switch (value) {
          case 'details':
            onEditDetails();
          case 'cover':
            onChangeCover();
          case 'export':
            onExport();
          case 'download':
            onDownloadAll?.call();
        }
      },
      entries: [
        M3EMenuEntry(
          label: l10n.playlistEditDetails,
          value: 'details',
          leading: const Icon(Icons.edit_rounded, size: 20),
        ),
        M3EMenuEntry(
          label: l10n.playlistCoverChange,
          value: 'cover',
          leading: const Icon(Icons.image_rounded, size: 20),
        ),
        M3EMenuEntry(
          label: l10n.shareExportData,
          value: 'export',
          leading: const Icon(Icons.file_upload_rounded, size: 20),
        ),
        if (onDownloadAll != null)
          M3EMenuEntry(
            label: l10n.downloadAll,
            value: 'download',
            leading: const Icon(Icons.download_rounded, size: 20),
          ),
      ],
    );
  }
}

/// 列表头部的主分享入口。
///
/// 与 [PlaylistHeaderOverflow] 分开：分享是常驻主操作，编辑 / 换封面 / 导出 /
/// 全部下载仍收在溢出菜单里，避免同一动作出现两个入口。
class PlaylistShareButton extends StatelessWidget {
  const PlaylistShareButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return M3EIconButton(
      key: const Key('playlistShareButton'),
      variant: M3EIconButtonVariant.standard,
      semanticLabel: _l10n(context).playlistShare,
      icon: const Icon(Icons.ios_share_rounded),
      onPressed: onPressed,
    );
  }
}
