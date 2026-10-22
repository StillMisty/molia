/// AI 推荐偏好页：即时保存（所见即所得），没有保存按钮。
///
/// 分组：生成（批次大小 / 自动补歌 / 只推荐没听过的 / 探索度）、风格、场景、
/// 语言、年代、补充要求、发送范围、「多来点这种」种子。
/// 找歌渠道不在这里出现：解析统一按音源页渠道顺序使用全部可搜索渠道。
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
  /// 补充要求的防抖窗口：输入停顿后再落盘，避免逐字写偏好。
  static const Duration _extraSaveDelay = Duration(milliseconds: 400);

  late final AiDjProvider _provider;
  late final TextEditingController _extraController;
  Timer? _extraSaveTimer;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AiDjProvider>();
    _extraController =
        TextEditingController(text: _provider.preferences.extraPrompt);
  }

  @override
  void dispose() {
    _extraSaveTimer?.cancel();
    // 防抖窗口内退出页面：补写一次，避免最后一段输入丢失。放到帧末，
    // 避免在路由卸载/树重建过程中同步 notify 触发祖先重建。
    final pending = _extraController.text;
    if (pending != _provider.preferences.extraPrompt) {
      final provider = _provider;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(provider.savePreferences(
          provider.preferences.copyWith(extraPrompt: pending),
        ));
      });
    }
    _extraController.dispose();
    super.dispose();
  }

  void _update(AiPreferences next) {
    unawaited(_provider.savePreferences(next));
  }

  void _saveExtraSoon(String value) {
    _extraSaveTimer?.cancel();
    _extraSaveTimer = Timer(_extraSaveDelay, () {
      _update(_provider.preferences.copyWith(extraPrompt: value));
    });
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
    _extraSaveTimer?.cancel();
    await _provider.resetPreferences();
    if (!mounted) return;
    _extraController.clear();
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
    final prefs = provider.preferences;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.aiDjPreferencesTitle),
        automaticallyImplyLeading: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SettingsSectionHint(text: l10n.aiDjPrefsAutoSaveHint),
            const SizedBox(height: 12),
            SettingsSectionCard(
              title: l10n.aiDjPrefsGenerationGroup,
              children: [
                SettingsSwitchTile(
                  key: const Key('aiDjPrefAutoFeedSwitch'),
                  icon: Icons.autorenew_rounded,
                  title: l10n.aiDjAutoFeedTitle,
                  subtitle: l10n.aiDjAutoFeedSubtitle,
                  value: prefs.autoFeed,
                  onChanged: (value) => _update(
                    _provider.preferences.copyWith(autoFeed: value),
                  ),
                ),
                SettingsSwitchTile(
                  key: const Key('aiDjPrefOnlyUnheardSwitch'),
                  icon: Icons.hearing_rounded,
                  title: l10n.aiDjPrefsOnlyUnheardTitle,
                  subtitle: l10n.aiDjPrefsOnlyUnheardSubtitle,
                  value: prefs.onlyUnheard,
                  onChanged: (value) => _update(
                    _provider.preferences.copyWith(onlyUnheard: value),
                  ),
                ),
                SettingsDropdownRow<int>(
                  key: const Key('aiDjPrefBatchSizeRow'),
                  dropdownKey: const Key('aiDjPrefBatchSizeDropdown'),
                  icon: Icons.layers_rounded,
                  title: l10n.aiDjBatchSizeTitle,
                  value: prefs.batchSize,
                  options: [
                    for (final size in kAiBatchSizeOptions)
                      (size, l10n.aiDjBatchSize(size)),
                  ],
                  onChanged: (value) {
                    // 选择回调里同步 notify 会重建并销毁正在收尾的下拉控制器；
                    // 推迟到本帧结束再写偏好。
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _update(
                        _provider.preferences.copyWith(batchSize: value),
                      );
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            _sectionTitle(l10n.aiDjPrefsExplorationTitle),
            _optionChips(
              options: kAiExplorationOptions,
              selected: {prefs.exploration},
              labelOf: (value) => aiDjExplorationLabel(l10n, value),
              singleSelect: true,
              onToggle: (value) => _update(
                _provider.preferences.copyWith(exploration: value),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsStylesGroup),
            _optionChips(
              options: kAiStyleOptions,
              selected: prefs.styles.toSet(),
              labelOf: (value) => aiDjStyleLabel(l10n, value),
              onToggle: (value) => _update(
                _provider.preferences.copyWith(
                  styles: _toggle(
                    _provider.preferences.styles,
                    value,
                    kAiStyleOptions,
                  ),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsScenesGroup),
            _optionChips(
              options: kAiSceneOptions,
              selected: prefs.scenes.toSet(),
              labelOf: (value) => aiDjSceneLabel(l10n, value),
              onToggle: (value) => _update(
                _provider.preferences.copyWith(
                  scenes: _toggle(
                    _provider.preferences.scenes,
                    value,
                    kAiSceneOptions,
                  ),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsLanguagesGroup),
            _optionChips(
              options: kAiLanguageOptions,
              selected: prefs.languages.toSet(),
              labelOf: (value) => aiDjLanguageLabel(l10n, value),
              onToggle: (value) => _update(
                _provider.preferences.copyWith(
                  languages: _toggle(
                    _provider.preferences.languages,
                    value,
                    kAiLanguageOptions,
                  ),
                ),
              ),
            ),
            _sectionTitle(l10n.aiDjPrefsEraGroup),
            _optionChips(
              options: kAiEraOptions,
              selected: {prefs.era},
              labelOf: (value) => aiDjEraLabel(l10n, value),
              singleSelect: true,
              onToggle: (value) => _update(
                _provider.preferences.copyWith(era: value),
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
              onChanged: _saveExtraSoon,
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
                    value: prefs.sections.contains(section),
                    onChanged: (value) {
                      unawaited(_toggleScope(section, value));
                    },
                  ),
              ],
            ),
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
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: M3EButton.text(
                key: const Key('aiDjPrefsResetButton'),
                onPressed: _reset,
                child: Text(l10n.aiDjPrefsReset),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleScope(AiUpstreamSection section, bool value) async {
    final before = _provider.preferences;
    if (value && !before.acknowledgedScopes.contains(section)) {
      final agreed = await _confirmScope(section);
      if (!agreed || !mounted) return;
    }
    if (!mounted) return;
    final latest = _provider.preferences;
    final sections = Set<AiUpstreamSection>.of(latest.sections);
    final acknowledged = Set<AiUpstreamSection>.of(latest.acknowledgedScopes);
    if (value) {
      sections.add(section);
      acknowledged.add(section);
    } else {
      sections.remove(section);
    }
    _update(latest.copyWith(
      sections: sections,
      acknowledgedScopes: acknowledged,
    ));
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
