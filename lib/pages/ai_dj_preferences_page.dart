/// AI 推荐偏好页：本地草稿 + 保存（保存只影响下一次生成，不自动生成）。
///
/// 分组：生成（批次大小 / 自动补歌 / 只推荐没听过的 / 探索度）、风格、场景、
/// 语言、年代、补充要求、发送范围、找歌渠道、「多来点这种」种子。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../services/notification_service.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/settings/settings_tiles.dart';

class AiDjPreferencesPage extends StatefulWidget {
  const AiDjPreferencesPage({super.key});

  @override
  State<AiDjPreferencesPage> createState() => _AiDjPreferencesPageState();
}

class _AiDjPreferencesPageState extends State<AiDjPreferencesPage> {
  late final AiDjProvider _provider;
  late AiPreferences _draft;
  late final TextEditingController _extraController;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AiDjProvider>();
    _draft = _provider.preferences;
    _extraController =
        TextEditingController(text: _provider.preferences.extraPrompt);
  }

  @override
  void dispose() {
    _extraController.dispose();
    super.dispose();
  }

  AiPreferences get _currentDraft => _draft.copyWith(
        extraPrompt: _extraController.text,
      );

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    await _provider.savePreferences(_currentDraft);
    if (!mounted) return;
    _notify(l10n.aiDjPrefsSaved);
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjPrefsResetTitle,
        content: Text(l10n.aiDjPrefsResetBody),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            key: const Key('aiDjPrefsResetConfirm'),
            onPressed: () => navigator.pop(true),
            child: Text(l10n.aiDjPrefsReset),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _draft = AiPreferences.defaults.copyWith(seeds: _provider.seeds);
      _extraController.clear();
    });
    await _provider.savePreferences(_draft);
    if (!mounted) return;
    _notify(l10n.aiDjPrefsResetDone);
  }

  Future<bool> _confirmScope(AiUpstreamSection section) async {
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

  void _notify(String message) {
    final notifications = context.read<NotificationService?>();
    if (notifications == null) {
      M3ESnackbar.show(context, message: message);
    } else {
      notifications.showSuccessSnackBar(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<AiDjProvider>();
    final sources = provider.availableSources;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.aiDjPreferencesTitle),
        automaticallyImplyLeading: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SettingsSectionCard(
              title: l10n.aiDjPrefsGenerationGroup,
              children: [
                SettingsSwitchTile(
                  key: const Key('aiDjPrefAutoFeedSwitch'),
                  icon: Icons.autorenew_rounded,
                  title: l10n.aiDjAutoFeedTitle,
                  subtitle: l10n.aiDjAutoFeedSubtitle,
                  value: _draft.autoFeed,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(autoFeed: value),
                  ),
                ),
                SettingsSwitchTile(
                  key: const Key('aiDjPrefOnlyUnheardSwitch'),
                  icon: Icons.hearing_rounded,
                  title: l10n.aiDjPrefsOnlyUnheardTitle,
                  subtitle: l10n.aiDjPrefsOnlyUnheardSubtitle,
                  value: _draft.onlyUnheard,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(onlyUnheard: value),
                  ),
                ),
                SettingsDropdownRow<int>(
                  key: const Key('aiDjPrefBatchSizeRow'),
                  dropdownKey: const Key('aiDjPrefBatchSizeDropdown'),
                  icon: Icons.layers_rounded,
                  title: l10n.aiDjBatchSizeTitle,
                  value: _draft.batchSize,
                  options: [
                    for (final size in kAiBatchSizeOptions)
                      (size, l10n.aiDjBatchSize(size)),
                  ],
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(batchSize: value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _sectionTitle(l10n.aiDjPrefsExplorationTitle),
            _optionChips(
              options: kAiExplorationOptions,
              selected: {_draft.exploration},
              labelOf: (value) => aiDjExplorationLabel(l10n, value),
              singleSelect: true,
              onToggle: (value) => setState(
                () => _draft = _draft.copyWith(exploration: value),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsStylesGroup),
            _optionChips(
              options: kAiStyleOptions,
              selected: _draft.styles.toSet(),
              labelOf: (value) => aiDjStyleLabel(l10n, value),
              onToggle: (value) => setState(
                () => _draft = _draft.copyWith(
                  styles: _toggle(_draft.styles, value, kAiStyleOptions),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsScenesGroup),
            _optionChips(
              options: kAiSceneOptions,
              selected: _draft.scenes.toSet(),
              labelOf: (value) => aiDjSceneLabel(l10n, value),
              onToggle: (value) => setState(
                () => _draft = _draft.copyWith(
                  scenes: _toggle(_draft.scenes, value, kAiSceneOptions),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsLanguagesGroup),
            _optionChips(
              options: kAiLanguageOptions,
              selected: _draft.languages.toSet(),
              labelOf: (value) => aiDjLanguageLabel(l10n, value),
              onToggle: (value) => setState(
                () => _draft = _draft.copyWith(
                  languages:
                      _toggle(_draft.languages, value, kAiLanguageOptions),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsEraGroup),
            _optionChips(
              options: kAiEraOptions,
              selected: {_draft.era},
              labelOf: (value) => aiDjEraLabel(l10n, value),
              singleSelect: true,
              onToggle: (value) => setState(
                () => _draft = _draft.copyWith(era: value),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsExtraGroup),
            M3ETextField(
              key: const Key('aiDjPrefExtraField'),
              controller: _extraController,
              label: l10n.aiDjPrefsExtraGroup,
              supportingText: l10n.aiDjPrefsExtraHint,
              maxLength: AiPreferences.extraPromptLimit,
              showCounter: true,
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: 24),
            SettingsSectionCard(
              title: l10n.aiDjPrefsDataScope,
              footer: SettingsSectionHint(text: l10n.aiDjScopeHint),
              children: [
                for (final section in AiUpstreamSection.values)
                  SettingsSwitchTile(
                    key: Key('aiDjPrefScope_${section.storageValue}'),
                    icon: _scopeIcon(section),
                    title: aiDjSectionLabel(l10n, section),
                    subtitle: '',
                    value: _draft.sections.contains(section),
                    onChanged: (value) {
                      unawaited(_toggleScope(section, value));
                    },
                  ),
              ],
            ),
            _sectionTitle(l10n.aiDjChannelsTitle),
            Text(
              l10n.aiDjChannelsHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            if (sources.isEmpty)
              Text(
                l10n.aiDjChannelsEmpty,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final source in sources)
                    M3EChip(
                      key: Key('aiDjPrefChannel_${source.key}'),
                      type: M3EChipType.filter,
                      label: source.displayName,
                      selected: _draft.sourceKeys.contains(source.key),
                      onPressed: () => _toggleChannel(source.key),
                    ),
                  M3EChip(
                    key: const Key('aiDjPrefChannelAuto'),
                    type: M3EChipType.filter,
                    label: l10n.aiDjChannelsAuto,
                    selected: _draft.sourceKeys.isEmpty,
                    onPressed: () => setState(
                      () => _draft = _draft.copyWith(sourceKeys: const []),
                    ),
                  ),
                ],
              ),
            if (_draft.sourceKeys.isNotEmpty &&
                !sources.any(
                  (source) => _draft.sourceKeys.contains(source.key),
                )) ...[
              const SizedBox(height: 6),
              Text(
                l10n.aiDjChannelsUnavailable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
              ),
            ],
            _sectionTitle(l10n.aiDjSeedsTitle),
            Text(
              l10n.aiDjSeedsHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            if (_provider.seeds.isEmpty)
              Text(
                l10n.aiDjSeedsEmpty,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final seed in _provider.seeds)
                    M3EChip(
                      key: Key('aiDjPrefSeed_$seed'),
                      type: M3EChipType.input,
                      label: l10n.aiDjSeedLabel(seed),
                      onDeleted: () => unawaited(_provider.removeSeed(seed)),
                    ),
                ],
              ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                M3EButton.filled(
                  key: const Key('aiDjPrefsSaveButton'),
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(l10n.aiDjPrefsSave),
                ),
                M3EButton.text(
                  key: const Key('aiDjPrefsResetButton'),
                  onPressed: _reset,
                  child: Text(l10n.aiDjPrefsReset),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleScope(AiUpstreamSection section, bool value) async {
    if (value && !_draft.acknowledgedScopes.contains(section)) {
      final agreed = await _confirmScope(section);
      if (!agreed || !mounted) return;
    }
    if (!mounted) return;
    setState(() {
      final sections = Set<AiUpstreamSection>.of(_draft.sections);
      final acknowledged = Set<AiUpstreamSection>.of(_draft.acknowledgedScopes);
      if (value) {
        sections.add(section);
        acknowledged.add(section);
      } else {
        sections.remove(section);
      }
      _draft = _draft.copyWith(
        sections: sections,
        acknowledgedScopes: acknowledged,
      );
    });
  }

  void _toggleChannel(String key) {
    final ordered = [
      for (final source in _provider.availableSources)
        if (source.key == key || _draft.sourceKeys.contains(source.key))
          source.key,
    ];
    // 已选渠道被取消时无法从上面的过滤里区分，单独移除。
    final next = _draft.sourceKeys.contains(key)
        ? [
            for (final value in ordered)
              if (value != key) value
          ]
        : ordered;
    setState(() => _draft = _draft.copyWith(sourceKeys: next));
  }

  static List<String> _toggle(
    List<String> values,
    String value,
    List<String> options,
  ) {
    final next = values.toSet();
    if (!next.remove(value)) next.add(value);
    return [
      for (final option in options)
        if (next.contains(option)) option,
    ];
  }

  static IconData _scopeIcon(AiUpstreamSection section) => switch (section) {
        AiUpstreamSection.summary => Icons.insights_rounded,
        AiUpstreamSection.topArtists => Icons.people_alt_rounded,
        AiUpstreamSection.topTracks => Icons.music_note_rounded,
        AiUpstreamSection.timeAndSource => Icons.schedule_rounded,
        AiUpstreamSection.recentEvents => Icons.history_rounded,
        AiUpstreamSection.listenedExclusions => Icons.hearing_disabled_rounded,
        AiUpstreamSection.favorites => Icons.favorite_rounded,
        AiUpstreamSection.playlists => Icons.queue_music_rounded,
      };

  Widget _sectionTitle(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(title, style: theme.textTheme.titleMedium),
    );
  }

  Widget _optionChips({
    required List<String> options,
    required Set<String> selected,
    required String Function(String) labelOf,
    required ValueChanged<String> onToggle,
    bool singleSelect = false,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          M3EChip(
            key: Key('aiDjPrefOption_$option'),
            type: M3EChipType.filter,
            label: labelOf(option),
            selected: selected.contains(option),
            onPressed: () {
              if (singleSelect && selected.contains(option)) return;
              onToggle(option);
            },
          ),
      ],
    );
  }
}
