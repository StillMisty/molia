/// 自动检查发现更新后的合并弹窗：应用新版本 + 音源脚本更新。
///
/// 从应用壳层（MaterialApp 之上）调用，必须经 root navigator 的 context 展示；
/// 弹窗本身只返回用户选择，打开哪个设置页由调用方决定。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/update_check_notice.dart';
import '../l10n/app_localizations.dart';

/// 用户对更新提示的选择。
enum UpdatePromptAction {
  /// 稍后处理，关闭弹窗。
  later,

  /// 查看应用更新页。
  app,

  /// 查看音源管理页。
  sources,
}

Future<UpdatePromptAction> showUpdateAvailableDialog(
  BuildContext context,
  UpdateCheckNotice notice,
) async {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final action = await M3EDialog.show<UpdatePromptAction>(
    context,
    dialog: M3EDialog(
      title: l10n.updateAvailableTitle,
      content: _UpdateAvailableContent(notice: notice, l10n: l10n),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(UpdatePromptAction.later),
          child: Text(l10n.updateAvailableLater),
        ),
        if (notice.hasSourceUpdates)
          M3EButton.text(
            key: const Key('updatePromptSourcesButton'),
            onPressed: () => navigator.pop(UpdatePromptAction.sources),
            child: Text(l10n.updateAvailableSourcesAction),
          ),
        if (notice.hasAppUpdate)
          M3EButton.filled(
            key: const Key('updatePromptAppButton'),
            onPressed: () => navigator.pop(UpdatePromptAction.app),
            child: Text(l10n.updateAvailableAppAction),
          ),
      ],
    ),
  );
  return action ?? UpdatePromptAction.later;
}

class _UpdateAvailableContent extends StatelessWidget {
  const _UpdateAvailableContent({required this.notice, required this.l10n});

  final UpdateCheckNotice notice;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3e = M3ETheme.of(context);
    final appRelease = notice.appRelease;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (appRelease != null)
          Text(
            l10n.updateAvailableAppLine(appRelease.version),
            style: m3e.typeScale.bodyMedium,
          ),
        if (appRelease != null && notice.hasSourceUpdates)
          const SizedBox(height: 12),
        if (notice.hasSourceUpdates) ...[
          Text(
            l10n.updateAvailableSourcesTitle,
            style: m3e.typeScale.titleSmall.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final update in notice.sourceUpdates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        l10n.updateAvailableSourceLine(
                          update.name,
                          _version(update.currentVersion),
                          _version(update.latestVersion),
                        ),
                        style: m3e.typeScale.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 脚本版本可能为空：显示占位符，避免出现「 : 1.2」。
  String _version(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '—' : trimmed;
  }
}
