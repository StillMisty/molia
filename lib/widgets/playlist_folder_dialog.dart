/// 分组命名对话框：与列表详情共用同一份分组名归一 / 校验。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/playlist_folders.dart';
import '../l10n/app_localizations.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 打开分组命名对话框；取消返回 null，确认返回归一后的非空名称。
Future<String?> showPlaylistFolderNameDialog(
  BuildContext context, {
  String initialValue = '',
}) {
  return M3EDialog.show<String>(
    context,
    dialog: _PlaylistFolderNameDialog(initialValue: initialValue),
  );
}

class _PlaylistFolderNameDialog extends StatefulWidget {
  const _PlaylistFolderNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_PlaylistFolderNameDialog> createState() =>
      _PlaylistFolderNameDialogState();
}

class _PlaylistFolderNameDialogState extends State<_PlaylistFolderNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = _l10n(context);
    final check = checkPlaylistFolderName(_controller.text);
    if (check.normalized.isEmpty) {
      setState(() => _error = l10n.playlistFolderNameRequired);
      return;
    }
    if (!check.isValid) {
      setState(
        () => _error = switch (check.issue!) {
          PlaylistFolderNameIssue.tooLong => l10n.playlistFolderNameTooLong,
          PlaylistFolderNameIssue.controlCharacters =>
            l10n.playlistFolderNameInvalid,
        },
      );
      return;
    }
    Navigator.of(context).pop(check.normalized);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EDialog(
      title: l10n.playlistFolderRename,
      content: M3ETextField(
        key: const Key('playlistFolderNameField'),
        controller: _controller,
        placeholder: l10n.playlistFolder,
        autofocus: true,
        errorText: _error,
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
          key: const Key('playlistFolderNameConfirm'),
          onPressed: _submit,
          child: Text(l10n.saveChanges),
        ),
      ],
    );
  }
}
