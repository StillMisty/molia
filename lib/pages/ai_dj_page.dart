/// AI 推歌页：配置 + 模式开关 + 当前批次 + 反馈摘要。
///
/// 入口：统计页右上角「AI 推歌」+ 设置 › 内容（Web 平台隐藏）。
/// 模式状态机与播放协调在 [AiDjProvider]；本页只做展示与交互。
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/playback_provider.dart';
import '../services/notification_service.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/track_row.dart';

class AiDjPage extends StatefulWidget {
  const AiDjPage({super.key});

  @override
  State<AiDjPage> createState() => _AiDjPageState();
}

class _AiDjPageState extends State<AiDjPage> {
  late final AiDjProvider _provider;
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();

  /// 配置表单展开态：未配置时默认展开。
  bool _editingConfig = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AiDjProvider>();
    final config = _provider.config;
    if (config == null) {
      // 首次配置：默认预填第一个内置预设（DeepSeek），只需粘 API Key。
      final preset = LlmProviderPreset.builtIn.first;
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
    } else {
      _loadConfigIntoControllers(config);
    }
    _editingConfig = !_provider.hasConfig;
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _loadConfigIntoControllers(LlmConfig? config) {
    _baseUrlController.text = config?.baseUrl ?? '';
    _apiKeyController.text = config?.apiKey ?? '';
    _modelController.text = config?.model ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiDjTitle)),
      body: SafeArea(
        child: Consumer<AiDjProvider>(
          builder: (context, provider, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _statusCard(l10n, provider),
              const SizedBox(height: 16),
              _configCard(l10n, provider),
              if (provider.currentBatch != null) ...[
                const SizedBox(height: 16),
                _batchCard(l10n, provider),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final statusText = switch (provider.status) {
      AiDjStatus.off => l10n.aiDjStatusOff,
      AiDjStatus.preparing => l10n.aiDjStatusPreparing,
      AiDjStatus.playing => l10n.aiDjStatusPlaying,
      AiDjStatus.error => l10n.aiDjStatusError,
    };
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjToggle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                statusText,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 8),
              M3ESwitch(
                key: const Key('aiDjModeSwitch'),
                value: provider.isActive,
                onChanged:
                    _busy ? null : (value) => value ? _start() : _confirmStop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.aiDjToggleSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          if (provider.isActive) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(l10n.aiDjQueued(provider.queuedCount)),
                if (provider.skippedLabels.isNotEmpty)
                  Text(l10n.aiDjSkippedCount(provider.skippedLabels.length)),
                if (provider.likedLabels.isNotEmpty)
                  Text(l10n.aiDjLikedCount(provider.likedLabels.length)),
              ],
            ),
            const SizedBox(height: 8),
            M3EButton.tonal(
              key: const Key('aiDjFeedMoreButton'),
              onPressed: provider.isBusy ? null : () => _provider.feedMore(),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.aiDjFeedMore),
            ),
          ],
          if (provider.lastError != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    aiDjFailureText(l10n, provider.lastError!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: provider.isBusy
                      ? null
                      : () =>
                          provider.isActive ? _provider.feedMore() : _start(),
                  child: Text(l10n.aiDjRetry),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _configCard(AppLocalizations l10n, AiDjProvider provider) {
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjConfigTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!_editingConfig && provider.hasConfig)
                TextButton(
                  onPressed: () {
                    setState(() => _editingConfig = true);
                  },
                  child: Text(l10n.aiDjOpenSettings),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_editingConfig)
            _configForm(l10n)
          else
            _configSummary(l10n, provider),
          const SizedBox(height: 12),
          Row(
            children: [
              M3EButton.tonal(
                key: const Key('aiDjTestConnectionButton'),
                onPressed: _busy ? null : _testConnection,
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: Text(l10n.aiDjTestConnection),
              ),
              if (!_editingConfig && provider.hasConfig) ...[
                const SizedBox(width: 8),
                M3EButton.text(
                  onPressed: _busy ? null : _clearConfig,
                  child: Text(l10n.aiDjClearConfig),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _configForm(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in LlmProviderPreset.builtIn)
              M3EChip(
                label: preset.name,
                type: M3EChipType.filter,
                selected: _baseUrlController.text.trim() == preset.baseUrl,
                onPressed: () => _applyPreset(l10n, preset),
              ),
            M3EChip(
              label: l10n.aiDjPresetCustom,
              type: M3EChipType.filter,
              selected: !_matchesAnyPreset(),
              onPressed: () => setState(() {}),
            ),
          ],
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjBaseUrlField'),
          controller: _baseUrlController,
          label: l10n.aiDjBaseUrl,
          placeholder: 'https://api.deepseek.com',
          leading: const Icon(Icons.link_rounded),
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjApiKeyField'),
          controller: _apiKeyController,
          label: l10n.aiDjApiKey,
          obscureText: true,
          showPasswordToggle: true,
          leading: const Icon(Icons.key_rounded),
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjModelField'),
          controller: _modelController,
          label: l10n.aiDjModel,
          placeholder: 'deepseek-chat',
          leading: const Icon(Icons.smart_toy_rounded),
        ),
        const SizedBox(height: 12),
        M3EButton.filled(
          key: const Key('aiDjSaveConfigButton'),
          onPressed: _busy ? null : _saveConfig,
          icon: const Icon(Icons.check_rounded),
          label: Text(l10n.aiDjSaveConfig),
        ),
      ],
    );
  }

  Widget _configSummary(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final config = provider.config;
    if (config == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(config.baseUrl, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(
          '${config.model} · ${config.maskedApiKey}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  bool _matchesAnyPreset() => LlmProviderPreset.builtIn
      .any((preset) => preset.baseUrl == _baseUrlController.text.trim());

  void _applyPreset(AppLocalizations l10n, LlmProviderPreset preset) {
    setState(() {
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
    });
  }

  Widget _batchCard(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final batch = provider.currentBatch!;
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.aiDjQueued(provider.queuedCount),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < batch.items.length; i++) ...[
            if (i > 0) SizedBox(height: TrackRow.gapOf(context)),
            TrackRow(
              title: batch.items[i].track.title,
              artist: batch.items[i].track.artists
                  .map((artist) => artist.name)
                  .join(', '),
              coverUrl: batch.items[i].track.artwork?.uri.toString(),
              position: calculateCardPosition(i, batch.items.length),
              trailingText: batch.items[i].source.reason.isEmpty
                  ? null
                  : batch.items[i].source.reason,
              onTap: () => context
                  .read<PlaybackProvider>()
                  .playLocalQueueItemById(batch.items[i].track.id.uri),
            ),
          ],
          if (batch.unresolved.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.aiDjUnresolved(batch.unresolved.length),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 4),
            for (final item in batch.unresolved.take(10))
              Text(
                '· ${item.label}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    if (!provider.hasConfig) {
      setState(() => _editingConfig = true);
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    if (!await ensureAiDjConsent(context, provider)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await provider.start();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmStop() async {
    final l10n = AppLocalizations.of(context)!;
    final keepQueue = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjStopDialogTitle,
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          M3EButton.text(
            key: const Key('aiDjStopKeepQueueButton'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.aiDjStopKeepQueue),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.aiDjStopClearQueue),
          ),
        ],
      ),
    );
    if (keepQueue == null || !mounted) return;
    await _provider.stop(keepQueue: keepQueue);
  }

  Future<void> _saveConfig() async {
    final l10n = AppLocalizations.of(context)!;
    final config = LlmConfig(
      baseUrl: _baseUrlController.text,
      apiKey: _apiKeyController.text,
      model: _modelController.text,
    );
    if (!config.isComplete) {
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _provider.saveConfig(config);
      if (!mounted) return;
      setState(() => _editingConfig = false);
      _notify(l10n.aiDjConfigSaved);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    final config = _editingConfig
        ? LlmConfig(
            baseUrl: _baseUrlController.text,
            apiKey: _apiKeyController.text,
            model: _modelController.text,
          )
        : provider.config;
    if (config == null || !config.isComplete) {
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await provider.testConnection(config);
      if (!mounted) return;
      _notify(l10n.aiDjTestSucceeded);
    } on SourceFailure catch (failure) {
      if (!mounted) return;
      _notify(aiDjFailureText(l10n, failure), error: true);
    } catch (_) {
      if (!mounted) return;
      _notify(l10n.aiDjRequestFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearConfig() async {
    await _provider.clearConfig();
    if (!mounted) return;
    _loadConfigIntoControllers(null);
    setState(() => _editingConfig = true);
  }

  void _notify(String message, {bool error = false}) {
    final notifications = context.read<NotificationService?>();
    if (notifications == null) {
      M3ESnackbar.show(context, message: message);
      return;
    }
    if (error) {
      notifications.showErrorSnackBar(message);
    } else {
      notifications.showSuccessSnackBar(message);
    }
  }
}

/// Web 平台隐藏（CORS 与密钥安全）；其余平台可用。
bool get aiDjSupportedPlatform => !kIsWeb;
