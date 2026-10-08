import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';

/// AppLocalizations 查找：与收藏页同一约定，测试未注册 delegate 时回退中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「加入列表」目标类型。
enum AddToPlaylistTargetKind { favorites, history, playlist }

/// 「加入列表」弹层选择结果：默认收藏 / 播放历史 / 自建列表。
class AddToPlaylistSelection {
  const AddToPlaylistSelection._(this.kind, this.playlistId);

  const AddToPlaylistSelection.favorites()
      : this._(AddToPlaylistTargetKind.favorites, null);

  const AddToPlaylistSelection.history()
      : this._(AddToPlaylistTargetKind.history, null);

  const AddToPlaylistSelection.playlist(int playlistId)
      : this._(AddToPlaylistTargetKind.playlist, playlistId);

  final AddToPlaylistTargetKind kind;
  final int? playlistId;
}

/// 「加入列表」弹层：内置收藏 / 播放历史 / 自建列表，并支持当场新建。
///
/// 返回选择结果（取消返回 null）。调用方需先刷新列表数据；
/// [playlists] 应只包含自建列表（不含默认收藏）。
/// [includeFavorites] / [includeHistory] 用于已经身处对应合集的入口去重。
Future<AddToPlaylistSelection?> showAddToPlaylistSheet(
  BuildContext context, {
  required List<PlaylistInfo> playlists,
  required Future<int> Function(String name) onCreate,
  bool includeFavorites = true,
  bool includeHistory = true,
}) {
  return M3EBottomSheet.show<AddToPlaylistSelection>(
    context,
    builder: (_) => _AddToPlaylistSheet(
      playlists: playlists,
      onCreate: onCreate,
      includeFavorites: includeFavorites,
      includeHistory: includeHistory,
    ),
  );
}

class _AddToPlaylistSheet extends StatefulWidget {
  const _AddToPlaylistSheet({
    required this.playlists,
    required this.onCreate,
    required this.includeFavorites,
    required this.includeHistory,
  });

  final List<PlaylistInfo> playlists;
  final Future<int> Function(String name) onCreate;
  final bool includeFavorites;
  final bool includeHistory;

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  late final List<PlaylistInfo> _playlists = List.of(widget.playlists);

  Future<void> _create() async {
    final l10n = _l10n(context);
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistCreate,
      confirmLabel: l10n.playlistCreateConfirm,
      existingNames: [for (final playlist in _playlists) playlist.name],
    );
    if (name == null || !mounted) return;
    final id = await widget.onCreate(name);
    if (!mounted) return;
    // 新建后直接返回该列表：调用方随即把曲目写进去。
    Navigator.of(context).pop(AddToPlaylistSelection.playlist(id));
  }

  void _pop(AddToPlaylistSelection selection) {
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    // 内置目标（收藏 / 历史） + 新建行 + 自建列表。
    final builtinButtons = <Widget>[
      if (widget.includeFavorites)
        M3EListItem(
          leading: const Icon(Icons.favorite_rounded),
          headline: l10n.favoritesPlaylistName,
          onTap: () => _pop(const AddToPlaylistSelection.favorites()),
        ),
      if (widget.includeHistory)
        M3EListItem(
          leading: const Icon(Icons.history_rounded),
          headline: l10n.libraryHistory,
          onTap: () => _pop(const AddToPlaylistSelection.history()),
        ),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(l10n.addToPlaylist, style: theme.textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ...builtinButtons,
                M3EListItem(
                  leading: const Icon(Icons.add_rounded),
                  headline: l10n.playlistCreate,
                  onTap: _create,
                ),
                for (final playlist in _playlists)
                  M3EListItem(
                    leading: const Icon(Icons.queue_music_rounded),
                    headline: playlist.name,
                    trailingText: l10n.playlistTrackCount(playlist.trackCount),
                    onTap: () => _pop(
                      AddToPlaylistSelection.playlist(playlist.id),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 列表命名对话框（新建 / 重命名共用）：返回去除首尾空格的名称，
/// 取消返回 null；空名称或与已有列表同名时停留并提示。
Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required List<String> existingNames,
  String initialValue = '',
}) {
  return M3EDialog.show<String>(
    context,
    dialog: _PlaylistNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      existingNames: existingNames,
      initialValue: initialValue,
    ),
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.existingNames,
    required this.initialValue,
  });

  final String title;
  final String confirmLabel;
  final List<String> existingNames;
  final String initialValue;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = _l10n(context);
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.playlistNameRequired);
      return;
    }
    if (name != widget.initialValue && widget.existingNames.contains(name)) {
      setState(() => _error = l10n.playlistNameExists);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EDialog(
      title: widget.title,
      content: M3ETextField(
        controller: _controller,
        placeholder: l10n.playlistCreateHint,
        autofocus: true,
        errorText: _error,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
