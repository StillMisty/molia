import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载对话框而不注册 delegate，
/// 此时回退到简体中文（与收藏页 / 其它弹层同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 链接导入输入（平台 + 链接/ID）。
class LinkImportInput {
  const LinkImportInput(this.sourceKey, this.rawId);

  final String sourceKey;
  final String rawId;
}

/// 五平台歌单链接导入对话框：选择平台并粘贴链接/ID。
///
/// [channels] 是平台 key + 展示名（顺序与发现页一致）；取消返回 null。
/// 只负责收集输入，实际拉取与写入由调用方完成。
Future<LinkImportInput?> showLinkImportDialog(
  BuildContext context, {
  required List<({String key, String name})> channels,
}) {
  return M3EDialog.show<LinkImportInput>(
    context,
    dialog: _LinkImportDialog(channels: channels),
  );
}

class _LinkImportDialog extends StatefulWidget {
  const _LinkImportDialog({required this.channels});

  /// 平台列表（key + 展示名，顺序与发现页一致）。
  final List<({String key, String name})> channels;

  @override
  State<_LinkImportDialog> createState() => _LinkImportDialogState();
}

class _LinkImportDialogState extends State<_LinkImportDialog> {
  late String _sourceKey = widget.channels.first.key;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = _l10n(context);
    final rawId = _controller.text.trim();
    if (rawId.isEmpty) {
      setState(() => _error = l10n.discoverOpenPlaylistHint);
      return;
    }
    Navigator.of(context).pop(LinkImportInput(_sourceKey, rawId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EDialog(
      title: l10n.playlistImportFromLink,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3EDropdownMenu<String>(
            items: [
              for (final channel in widget.channels)
                M3EDropdownItem<String>(
                  label: channel.name,
                  value: channel.key,
                  selected: channel.key == _sourceKey,
                ),
            ],
            singleSelect: true,
            showChipAnimation: false,
            fieldStyle: M3EDropdownFieldStyle(
              hintText: l10n.playlistImportChannel,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onSelectionChanged: (items) {
              if (items.isEmpty) return;
              setState(() => _sourceKey = items.first.value);
            },
          ),
          const SizedBox(height: 12),
          M3ETextField(
            controller: _controller,
            placeholder: l10n.discoverOpenPlaylistHint,
            autofocus: true,
            // 弹窗表单与音源配置等其它弹窗一致用 outlined（这不是搜索框）。
            variant: M3ETextFieldVariant.outlined,
            errorText: _error,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: _submit,
          child: Text(l10n.discoverOpen),
        ),
      ],
    );
  }
}
