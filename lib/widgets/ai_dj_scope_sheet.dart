import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../utils/responsive.dart';
import 'ai_dj_shared.dart';
import 'settings/settings_tiles.dart';
import 'simple_modal_body.dart';

/// 打开 AI 推荐「发送范围」弹层：八个类别收进一张开关列表。
Future<void> showAiDjScopeSheet(BuildContext context, AiDjProvider provider) {
  final l10n = AppLocalizations.of(context)!;
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: l10n.aiDjPrefsDataScope,
    child: _AiDjScopeSheet(provider: provider),
  );
}

class _AiDjScopeSheet extends StatelessWidget {
  const _AiDjScopeSheet({required this.provider});

  final AiDjProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final prefs = provider.preferences;
        return SimpleModalBody(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          header: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SettingsSectionHint(text: l10n.aiDjScopeSheetHint),
          ),
          children: [
            SettingsSectionCard(
              children: [
                for (final section in AiUpstreamSection.values)
                  SettingsSwitchTile(
                    key: Key('aiDjPrefScope_${section.storageValue}'),
                    icon: _scopeIcon(section),
                    title: aiDjSectionLabel(l10n, section),
                    subtitle: '',
                    value: prefs.sections.contains(section),
                    onChanged: (value) => unawaited(
                      toggleAiDjScope(context, provider, section, value),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 切换一个发送类别：收藏 / 歌单首次开启前要确认隐私影响。
Future<void> toggleAiDjScope(
  BuildContext context,
  AiDjProvider provider,
  AiUpstreamSection section,
  bool value,
) async {
  final before = provider.preferences;
  if (value && !before.acknowledgedScopes.contains(section)) {
    final agreed = await _confirmScope(context, section);
    if (!agreed || !context.mounted) return;
  }
  final latest = provider.preferences;
  final sections = Set<AiUpstreamSection>.of(latest.sections);
  final acknowledged = Set<AiUpstreamSection>.of(latest.acknowledgedScopes);
  if (value) {
    sections.add(section);
    acknowledged.add(section);
  } else {
    sections.remove(section);
  }
  await provider.savePreferences(
    latest.copyWith(sections: sections, acknowledgedScopes: acknowledged),
  );
}

Future<bool> _confirmScope(
  BuildContext context,
  AiUpstreamSection section,
) async {
  final l10n = AppLocalizations.of(context)!;
  final body = switch (section) {
    AiUpstreamSection.favorites => l10n.aiDjScopeFavoritesConfirm,
    AiUpstreamSection.playlists => l10n.aiDjScopePlaylistsConfirm,
    _ => null,
  };
  if (body == null) return true;
  final navigator = Navigator.of(context, rootNavigator: true);
  final agreed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: l10n.aiDjPreferencesTitle,
      content: Text(body),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          key: Key('aiDjScopeConfirm_${section.storageValue}'),
          onPressed: () => navigator.pop(true),
          child: Text(l10n.save),
        ),
      ],
    ),
  );
  return agreed == true;
}

IconData _scopeIcon(AiUpstreamSection section) => switch (section) {
  AiUpstreamSection.summary => Icons.insights_rounded,
  AiUpstreamSection.topArtists => Icons.people_alt_rounded,
  AiUpstreamSection.topTracks => Icons.music_note_rounded,
  AiUpstreamSection.timeAndSource => Icons.schedule_rounded,
  AiUpstreamSection.recentEvents => Icons.history_rounded,
  AiUpstreamSection.listenedExclusions => Icons.hearing_disabled_rounded,
  AiUpstreamSection.favorites => Icons.favorite_rounded,
  AiUpstreamSection.playlists => Icons.queue_music_rounded,
};
